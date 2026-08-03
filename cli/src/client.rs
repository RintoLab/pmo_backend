use serde_json::Value;

use crate::error::{Error, Result};

const API_ENV: &str = "RINTO_API";
const ACTOR_ENV: &str = "RINTO_ACTOR_ID";

/// A thin HTTP client over the Rinto PMO REST API.
///
/// Deliberately dumb: it does not validate request bodies, does not retry, and
/// does not rewrite server errors. See `docs/ai-document-cli.md` -- retrying a
/// conflict is a semantic decision and must happen where the model can see it,
/// not inside this process.
pub struct Client {
    base_url: String,
    actor_id: String,
    agent: ureq::Agent,
}

impl Client {
    pub fn from_env() -> Result<Self> {
        let base_url = std::env::var(API_ENV).map_err(|_| {
            Error::Config(format!(
                "{API_ENV} is not set (expected the API base URL, e.g. http://localhost:4000/api/v1)"
            ))
        })?;

        let actor_id = std::env::var(ACTOR_ENV).map_err(|_| {
            Error::Config(format!(
                "{ACTOR_ENV} is not set (expected the UUID of the actor this agent writes as)"
            ))
        })?;

        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            actor_id,
            agent: ureq::AgentBuilder::new().build(),
        })
    }

    /// The actor every write is attributed to.
    ///
    /// Read from the environment rather than taken as an argument: which
    /// persona an agent writes as is a property of how it was started, not
    /// something a model should be choosing per call.
    pub fn actor_id(&self) -> &str {
        &self.actor_id
    }

    pub fn get(&self, path: &str, query: &[(&str, &str)]) -> Result<Value> {
        let mut request = self.agent.get(&self.url(path));
        for (key, value) in query {
            request = request.query(key, value);
        }
        Self::send(request.call())
    }

    pub fn post(&self, path: &str, body: Value) -> Result<Value> {
        Self::send(self.agent.post(&self.url(path)).send_json(body))
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
                let body = response.into_json::<Value>().unwrap_or(Value::Null);

                let mut details = Vec::new();
                if let Some(reported) = body.get("details") {
                    crate::error::flatten_details(reported, "", &mut details);
                }

                Err(Error::Api {
                    status,
                    code: string_field(&body, "error"),
                    message: match string_field(&body, "message") {
                        message if message.is_empty() => {
                            "no message supplied by the server".to_string()
                        }
                        message => message,
                    },
                    details,
                })
            }

            Err(ureq::Error::Transport(transport)) => Err(Error::Network(format!("{transport}"))),
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
