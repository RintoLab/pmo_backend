use std::fmt;

/// Everything that can go wrong, rendered as one human-readable line.
///
/// The audience is an AI agent reading stderr, so a message must say what
/// failed and what would fix it -- never a JSON blob and never a bare code.
#[derive(Debug)]
pub enum Error {
    /// Missing or malformed environment configuration.
    Config(String),
    /// The caller passed something this program cannot use.
    Input(String),
    /// Reading or writing a local file failed.
    Io(String),
    /// The request never produced an HTTP response.
    Network(String),
    /// The server answered with a non-2xx status.
    ///
    /// Deliberately carries the server's own message rather than a rewritten
    /// one: the constraint lives on the server, so its wording is the truth.
    ///
    /// `details` matters more than `message` in practice. A validation failure
    /// answers `"Request validation failed."` at the top level and puts the
    /// only actionable part -- which field, and why -- in the nested details
    /// object. Reporting the message alone tells the caller nothing it can act
    /// on.
    Api {
        status: u16,
        code: String,
        message: String,
        details: Vec<String>,
    },
}

/// How many detail lines to print before summarising the rest.
///
/// A cap rather than everything: one bad block in a long document can produce a
/// detail per field, and a wall of them costs more context than it repays.
const MAX_DETAILS: usize = 10;

/// Flattens a nested error-details object into `path: message` lines.
///
/// Ecto renders changeset errors as `{field: [messages]}` nested by
/// association, so a string array is a leaf, not a list to be indexed.
pub fn flatten_details(value: &serde_json::Value, path: &str, out: &mut Vec<String>) {
    use serde_json::Value;

    let labelled = |text: String| {
        if path.is_empty() {
            text
        } else {
            format!("{path}: {text}")
        }
    };

    match value {
        Value::Object(fields) => {
            for (field, nested) in fields {
                let nested_path = if path.is_empty() {
                    field.clone()
                } else {
                    format!("{path}.{field}")
                };
                flatten_details(nested, &nested_path, out);
            }
        }

        Value::Array(items) if items.iter().all(Value::is_string) => {
            let messages: Vec<&str> = items.iter().filter_map(Value::as_str).collect();
            if !messages.is_empty() {
                out.push(labelled(messages.join(", ")));
            }
        }

        Value::Array(items) => {
            for (index, nested) in items.iter().enumerate() {
                flatten_details(nested, &format!("{path}[{index}]"), out);
            }
        }

        Value::String(text) => out.push(labelled(text.clone())),
        Value::Null => {}
        scalar => out.push(labelled(scalar.to_string())),
    }
}

impl Error {
    pub fn exit_code(&self) -> i32 {
        match self {
            Error::Config(_) | Error::Input(_) => 2,
            _ => 1,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Config(msg) => write!(f, "configuration: {msg}"),
            Error::Input(msg) => write!(f, "input: {msg}"),
            Error::Io(msg) => write!(f, "io: {msg}"),
            Error::Network(msg) => write!(f, "network: {msg}"),
            Error::Api {
                status,
                code,
                message,
                details,
            } => {
                write!(f, "server returned {status}")?;
                if !code.is_empty() {
                    write!(f, " ({code})")?;
                }
                write!(f, ": {message}")?;

                for detail in details.iter().take(MAX_DETAILS) {
                    write!(f, "\n  {detail}")?;
                }
                if details.len() > MAX_DETAILS {
                    write!(f, "\n  ... and {} more", details.len() - MAX_DETAILS)?;
                }

                Ok(())
            }
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;

#[cfg(test)]
mod tests {
    use super::{flatten_details, Error};
    use serde_json::json;

    fn flatten(value: serde_json::Value) -> Vec<String> {
        let mut out = Vec::new();
        flatten_details(&value, "", &mut out);
        out
    }

    #[test]
    fn flattens_a_nested_changeset_error() {
        let details = json!({"revisions": [{"blocks": [{"actor_id": ["is invalid"]}]}]});

        assert_eq!(
            flatten(details),
            vec!["revisions[0].blocks[0].actor_id: is invalid"]
        );
    }

    #[test]
    fn joins_several_messages_for_one_field() {
        let details = json!({"title": ["can't be blank", "is too short"]});

        assert_eq!(
            flatten(details),
            vec!["title: can't be blank, is too short"]
        );
    }

    #[test]
    fn ignores_nulls_and_empty_containers() {
        assert!(flatten(json!({"a": null, "b": {}, "c": []})).is_empty());
    }

    #[test]
    fn renders_details_under_the_message() {
        let error = Error::Api {
            status: 422,
            code: "validation_error".to_string(),
            message: "Request validation failed.".to_string(),
            details: vec!["blocks[0].actor_id: is invalid".to_string()],
        };

        assert_eq!(
            error.to_string(),
            "server returned 422 (validation_error): Request validation failed.\n  \
             blocks[0].actor_id: is invalid"
        );
    }

    #[test]
    fn summarises_details_past_the_cap() {
        let error = Error::Api {
            status: 422,
            code: String::new(),
            message: "nope".to_string(),
            details: (0..12).map(|index| format!("field{index}: bad")).collect(),
        };

        assert!(error.to_string().ends_with("... and 2 more"));
    }
}
