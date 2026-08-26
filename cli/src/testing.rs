//! A real HTTP server, for tests that need the wire rather than a seam.
//!
//! Everything in this binary was unit-tested as pure functions, which left the
//! one thing a CLI is -- a program that talks to an API -- untested: whether a
//! command sends the method, path, query, header and body it means to, and
//! whether the server's own refusal survives the trip back. Those are bugs a
//! test against an injected fake cannot have an opinion about, because the fake
//! is written from the same misunderstanding as the code.
//!
//! ## Why it is hand-rolled
//!
//! `mockito` and `wiremock` each drag hyper and tokio into the build, which
//! would be a larger dependency tree than the whole product -- this crate has
//! three dependencies, and `update.rs` computes SHA-256 by hand rather than
//! take a fourth. Sixty lines of `TcpListener` also test *more*: a real socket,
//! a real `ureq`, and real HTTP framing, instead of a library's idea of them.
//!
//! ## How it behaves
//!
//! Canned responses are handed out in order, one per connection. Every reply
//! carries `Connection: close`, so `ureq` opens a fresh connection per request
//! and the loop below never has to multiplex one.
//!
//! Requests are recorded into shared state rather than returned by joining the
//! thread: a test that makes fewer calls than it queued responses would
//! otherwise hang on a thread still blocked in `accept`. The server thread is
//! simply abandoned at the end of a test and dies with the process.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

/// One request as it arrived on the socket.
pub struct RecordedRequest {
    pub method: String,
    /// Path and query string exactly as written on the request line.
    pub target: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl RecordedRequest {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    pub fn json(&self) -> serde_json::Value {
        serde_json::from_str(&self.body).unwrap_or(serde_json::Value::Null)
    }
}

/// One canned reply.
pub struct Reply {
    status: u16,
    body: String,
}

impl Reply {
    pub fn json(status: u16, body: serde_json::Value) -> Self {
        Self {
            status,
            body: body.to_string(),
        }
    }

    /// A body that is not JSON at all, for the paths that have to survive one.
    pub fn raw(status: u16, body: &str) -> Self {
        Self {
            status,
            body: body.to_string(),
        }
    }

    pub fn empty(status: u16) -> Self {
        Self {
            status,
            body: String::new(),
        }
    }
}

pub struct StubServer {
    base_url: String,
    received: Arc<Mutex<Vec<RecordedRequest>>>,
}

impl StubServer {
    /// Serves `replies` in order, one per request, then stops answering.
    pub fn start(replies: Vec<Reply>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("could not bind a test port");
        let port = listener.local_addr().expect("no local address").port();
        let received = Arc::new(Mutex::new(Vec::new()));
        let recording = Arc::clone(&received);

        std::thread::spawn(move || {
            for reply in replies {
                let Ok((stream, _peer)) = listener.accept() else {
                    return;
                };

                serve(stream, reply, &recording);
            }
        });

        Self {
            base_url: format!("http://127.0.0.1:{port}/api/v1"),
            received,
        }
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Everything received so far. A request is recorded before its reply is
    /// written, so a returned client call means its request is already here.
    pub fn requests(&self) -> std::sync::MutexGuard<'_, Vec<RecordedRequest>> {
        self.received
            .lock()
            .expect("the recording lock was poisoned")
    }

    /// The single request a one-call test made.
    pub fn only_request(&self) -> std::sync::MutexGuard<'_, Vec<RecordedRequest>> {
        let requests = self.requests();
        assert_eq!(requests.len(), 1, "expected exactly one request");
        requests
    }
}

/// A client pointed at a stub server, with the token every test uses.
pub fn client(server: &StubServer) -> crate::client::Client {
    crate::client::Client::new(server.base_url(), "test-actor-token")
        .expect("could not build the client")
}

/// A JSON file for the commands that read one, in the system temp directory.
///
/// Named per call so that tests running in parallel cannot collide, and left
/// behind: a few bytes in a temp directory costs less than a cleanup that runs
/// while another test is still reading the file.
pub fn json_file(value: serde_json::Value) -> std::path::PathBuf {
    use std::sync::atomic::{AtomicUsize, Ordering};
    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    let path = std::env::temp_dir().join(format!(
        "rinto-cli-test-{}-{}.json",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));

    std::fs::write(&path, value.to_string()).expect("could not write the test input file");
    path
}

fn serve(stream: std::net::TcpStream, reply: Reply, received: &Mutex<Vec<RecordedRequest>>) {
    let mut reader = BufReader::new(stream);
    let mut request_line = String::new();

    if reader.read_line(&mut request_line).is_err() || request_line.is_empty() {
        return;
    }

    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_string();
    let target = parts.next().unwrap_or_default().to_string();

    let mut headers = Vec::new();
    let mut content_length = 0usize;

    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).is_err() {
            return;
        }

        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            break;
        }

        if let Some((name, value)) = line.split_once(':') {
            let (name, value) = (name.trim().to_string(), value.trim().to_string());
            if name.eq_ignore_ascii_case("content-length") {
                content_length = value.parse().unwrap_or(0);
            }
            headers.push((name, value));
        }
    }

    let mut body = vec![0u8; content_length];
    if content_length > 0 && reader.read_exact(&mut body).is_err() {
        return;
    }

    received
        .lock()
        .expect("the recording lock was poisoned")
        .push(RecordedRequest {
            method,
            target,
            headers,
            body: String::from_utf8_lossy(&body).to_string(),
        });

    let response = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        reply.status,
        reason(reply.status),
        reply.body.len(),
        reply.body
    );

    let mut stream = reader.into_inner();
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        422 => "Unprocessable Entity",
        _ => "Status",
    }
}
