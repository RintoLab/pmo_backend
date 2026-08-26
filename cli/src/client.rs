use serde_json::Value;

use crate::error::{Error, Result};

/// A thin HTTP client over the Rinto PMO REST API.
///
/// Deliberately dumb: it does not validate request bodies, does not retry, and
/// does not rewrite server errors. See `docs/ai-document-cli.md` -- retrying a
/// conflict is a semantic decision and must happen where the model can see it,
/// not inside this process.
pub struct Client {
    base_url: String,
    token: String,
    agent: ureq::Agent,
}

impl Client {
    pub fn new(base_url: &str, token: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/');
        if base_url.is_empty() {
            return Err(Error::Config("the API base URL is empty".to_string()));
        }
        if token.trim().is_empty() {
            return Err(Error::Config("the API token is empty".to_string()));
        }

        Ok(Self {
            base_url: base_url.to_string(),
            token: token.trim().to_string(),
            agent: ureq::AgentBuilder::new().build(),
        })
    }

    pub fn get(&self, path: &str, query: &[(&str, &str)]) -> Result<Value> {
        let mut request = self.request("GET", path);
        for (key, value) in query {
            request = request.query(key, value);
        }
        Self::send(request.call())
    }

    pub fn post(&self, path: &str, body: Value) -> Result<Value> {
        Self::send(self.request("POST", path).send_json(body))
    }

    pub fn patch(&self, path: &str, body: Value) -> Result<Value> {
        Self::send(self.request("PATCH", path).send_json(body))
    }

    pub fn delete(&self, path: &str) -> Result<()> {
        match self.request("DELETE", path).call() {
            Ok(_response) => Ok(()),
            Err(ureq::Error::Status(status, response)) => {
                Err(Self::response_error(status, response))
            }
            Err(ureq::Error::Transport(transport)) => Err(Error::Network(format!("{transport}"))),
        }
    }

    /// Every request carries the token. The server has no anonymous route, so
    /// there is nothing to decide per call.
    fn request(&self, method: &str, path: &str) -> ureq::Request {
        self.agent
            .request(method, &self.url(path))
            .set("Authorization", &format!("Bearer {}", self.token))
    }

    fn url(&self, path: &str) -> String {
        format!("{}/{}", self.base_url, path.trim_start_matches('/'))
    }

    fn send(outcome: std::result::Result<ureq::Response, ureq::Error>) -> Result<Value> {
        match outcome {
            Ok(response) => response
                .into_json::<Value>()
                .map_err(|err| Error::Network(format!("could not parse the response body: {err}"))),

            // A non-2xx status. Surface the server's own wording verbatim.
            Err(ureq::Error::Status(status, response)) => {
                Err(Self::response_error(status, response))
            }

            Err(ureq::Error::Transport(transport)) => Err(Error::Network(format!("{transport}"))),
        }
    }

    fn response_error(status: u16, response: ureq::Response) -> Error {
        let body = response.into_json::<Value>().unwrap_or(Value::Null);

        let mut details = Vec::new();
        if let Some(reported) = body.get("details") {
            crate::error::flatten_details(reported, "", &mut details);
        }

        Error::Api {
            status,
            code: string_field(&body, "error"),
            message: match string_field(&body, "message") {
                message if message.is_empty() => "no message supplied by the server".to_string(),
                message => message,
            },
            details,
        }
    }
}

fn string_field(body: &Value, key: &str) -> String {
    body.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

/// Unwraps the `{"data": ...}` envelope every endpoint responds with.
pub fn data(body: Value) -> Result<Value> {
    body.get("data")
        .cloned()
        .ok_or_else(|| Error::Network("response had no \"data\" field".to_string()))
}

#[cfg(test)]
mod tests {
    use super::{data, Client};
    use crate::error::Error;
    use crate::testing::{Reply, StubServer};
    use serde_json::json;

    fn client(server: &StubServer) -> Client {
        Client::new(server.base_url(), "  test-actor-token  ").expect("could not build the client")
    }

    #[test]
    fn every_request_carries_the_bearer_token_trimmed() {
        let server = StubServer::start(vec![Reply::json(200, json!({"data": {}}))]);

        client(&server).get("/tasks/schema", &[]).unwrap();

        let requests = server.only_request();
        assert_eq!(
            requests[0].header("authorization"),
            Some("Bearer test-actor-token")
        );
    }

    /// The base URL is configured with `/api/v1` on it and paths are written
    /// with a leading slash, so exactly one separator has to survive.
    #[test]
    fn a_path_joins_the_base_url_without_doubling_the_slash() {
        let server = StubServer::start(vec![Reply::json(200, json!({"data": []}))]);
        let base = format!("{}/", server.base_url());

        Client::new(&base, "token")
            .unwrap()
            .get("/projects/demo/tasks", &[])
            .unwrap();

        assert_eq!(
            server.only_request()[0].target,
            "/api/v1/projects/demo/tasks"
        );
    }

    #[test]
    fn query_pairs_reach_the_wire_in_order() {
        let server = StubServer::start(vec![Reply::json(200, json!({"data": []}))]);

        client(&server)
            .get(
                "/projects/demo/tasks",
                &[("kind", "work"), ("assignee_id", "none"), ("live", "true")],
            )
            .unwrap();

        assert_eq!(
            server.only_request()[0].target,
            "/api/v1/projects/demo/tasks?kind=work&assignee_id=none&live=true"
        );
    }

    #[test]
    fn post_sends_json_and_says_so() {
        let server = StubServer::start(vec![Reply::json(201, json!({"data": {"id": "task-id"}}))]);

        let body = client(&server)
            .post("/projects/demo/tasks", json!({"title": "Wire it up"}))
            .unwrap();

        let requests = server.only_request();
        assert_eq!(requests[0].method, "POST");
        assert_eq!(requests[0].json(), json!({"title": "Wire it up"}));
        assert!(requests[0]
            .header("content-type")
            .unwrap_or_default()
            .starts_with("application/json"));
        assert_eq!(data(body).unwrap(), json!({"id": "task-id"}));
    }

    #[test]
    fn patch_reaches_the_server_as_patch() {
        let server = StubServer::start(vec![Reply::json(200, json!({"data": {}}))]);

        client(&server)
            .patch("/tasks/task-id", json!({"priority": 1}))
            .unwrap();

        let requests = server.only_request();
        assert_eq!(requests[0].method, "PATCH");
        assert_eq!(requests[0].json(), json!({"priority": 1}));
    }

    #[test]
    fn delete_succeeds_on_a_body_less_response() {
        let server = StubServer::start(vec![Reply::empty(204)]);

        assert!(client(&server).delete("/tasks/task-id").is_ok());
        assert_eq!(server.only_request()[0].method, "DELETE");
    }

    /// The distinction §4.2 of the gaps review put in the server is only worth
    /// anything if it survives the client: 409 means claim it first, 403 means
    /// stop asking. Both have to come back with the server's own code.
    #[test]
    fn a_refusal_keeps_the_servers_status_code_and_wording() {
        let server = StubServer::start(vec![Reply::json(
            403,
            json!({
                "error": "task_not_yours",
                "message": "This task belongs to somebody else.",
                "details": {"assignee_id": "other-actor"}
            }),
        )]);

        let error = client(&server)
            .post("/tasks/task-id/start", json!({}))
            .unwrap_err();

        match error {
            Error::Api {
                status,
                code,
                message,
                details,
            } => {
                assert_eq!(status, 403);
                assert_eq!(code, "task_not_yours");
                assert_eq!(message, "This task belongs to somebody else.");
                assert_eq!(details, vec!["assignee_id: other-actor"]);
            }
            other => panic!("expected an API error, got {other:?}"),
        }
    }

    #[test]
    fn a_validation_failure_flattens_its_nested_details() {
        let server = StubServer::start(vec![Reply::json(
            422,
            json!({
                "error": "validation_error",
                "message": "Request validation failed.",
                "details": {"children": {"0": {"title": ["can't be blank"]}}}
            }),
        )]);

        let error = client(&server)
            .post("/tasks/task-id/split", json!({"children": [{}]}))
            .unwrap_err();

        assert!(error
            .to_string()
            .contains("children.0.title: can't be blank"));
    }

    /// A refusal that is not JSON must not turn into a parse error: the status
    /// is the actionable part, and losing it to "could not parse" would send
    /// the caller looking in the wrong place.
    #[test]
    fn a_refusal_without_a_json_body_still_reports_its_status() {
        let server = StubServer::start(vec![Reply::raw(404, "<html>nope</html>")]);

        let error = client(&server).get("/tasks/missing", &[]).unwrap_err();

        assert_eq!(
            error.to_string(),
            "server returned 404: no message supplied by the server"
        );
    }

    #[test]
    fn a_success_that_is_not_json_is_a_network_error() {
        let server = StubServer::start(vec![Reply::raw(200, "not json at all")]);

        let error = client(&server).get("/tasks/schema", &[]).unwrap_err();

        assert!(matches!(error, Error::Network(_)), "got {error:?}");
        assert!(error.to_string().contains("could not parse the response"));
    }

    /// Nothing answered at all. The message must say so rather than blaming
    /// the request, because the fix is "start the server" or "fix the URL".
    #[test]
    fn a_dead_server_is_a_network_error() {
        // Bind and drop, so the port is one nothing is listening on.
        let dead = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = dead.local_addr().unwrap().port();
        drop(dead);

        let error = Client::new(&format!("http://127.0.0.1:{port}/api/v1"), "token")
            .unwrap()
            .get("/tasks/schema", &[])
            .unwrap_err();

        assert!(matches!(error, Error::Network(_)), "got {error:?}");
    }

    #[test]
    fn a_response_without_the_envelope_is_refused_rather_than_guessed_at() {
        let server = StubServer::start(vec![Reply::json(200, json!({"tasks": []}))]);

        let body = client(&server).get("/projects/demo/tasks", &[]).unwrap();

        assert!(data(body).is_err());
    }

    #[test]
    fn an_empty_base_url_or_token_is_refused_before_any_socket() {
        assert!(matches!(Client::new("  ", "token"), Err(Error::Config(_))));
        assert!(matches!(
            Client::new("http://example.test", "   "),
            Err(Error::Config(_))
        ));
    }
}
