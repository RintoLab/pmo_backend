use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use serde_json::{json, Value};

use crate::client::{self, Client};
use crate::error::{Error, Result};

const API_ENV: &str = "RINTO_API";
const TOKEN_ENV: &str = "RINTO_TOKEN";
const CONVERSATION_ENV: &str = "RINTO_CONVERSATION_ID";
const CONFIG_ENV: &str = "RINTO_CONFIG";
const CONFIG_DIR: &str = "rinto-pmo";
const CONFIG_FILE: &str = "config.json";

/// Where this run is happening, and as whom.
///
/// Two situations, and they are configured differently on purpose.
///
/// A developer runs this on their own machine: `config init` writes a file
/// naming the API and carrying the token, and writes are theirs.
///
/// The agent inside a topic runs it with an environment instead. The backend
/// spawns that process and injects the topic, because which topic it is
/// answering in is a fact about the process rather than something to ask a model
/// to carry. There is no actor: a write made inside a topic is by that topic's
/// assistant, and the server derives it -- see `RintoPMO.Documents`. This
/// program never names an author.
///
/// The token is required either way. It is what the server answers at all, and
/// it also decides who a write outside a topic is credited to -- which is why
/// `actor_id` is now only ever printed, never sent.
pub struct Config {
    api: String,
    token: Option<String>,
    actor_id: Option<String>,
    conversation_id: Option<String>,
}

impl Config {
    pub fn load() -> Result<Self> {
        let file = read_file()?;
        let api = std::env::var(API_ENV)
            .ok()
            .filter(|api| !api.trim().is_empty())
            .or_else(|| {
                file.as_ref()
                    .and_then(|(value, _path)| string(value, "api"))
            })
            .ok_or_else(|| {
                Error::Config(format!(
                    "no API URL: set {API_ENV}, or run `rinto-pmo config init --api <URL>`"
                ))
            })?;

        Ok(Self {
            api,
            // Environment first, like the API URL: the backend spawns the
            // in-topic agent with one and never writes it a file.
            token: std::env::var(TOKEN_ENV)
                .ok()
                .filter(|token| !token.trim().is_empty())
                .or_else(|| {
                    file.as_ref()
                        .and_then(|(value, _path)| string(value, "token"))
                }),
            actor_id: file
                .as_ref()
                .and_then(|(value, _path)| string(value, "actor_id")),
            conversation_id: std::env::var(CONVERSATION_ENV)
                .ok()
                .filter(|id| !id.trim().is_empty()),
        })
    }

    pub fn api(&self) -> &str {
        &self.api
    }

    /// The token every request carries.
    pub fn token(&self) -> Result<&str> {
        self.token.as_deref().ok_or_else(|| {
            Error::Config(format!(
                "no API token: set {TOKEN_ENV}, or run \
                 `rinto-pmo config init --api <URL> --token <TOKEN>`. \
                 The server prints one from `mix rinto.actors.setup_human`"
            ))
        })
    }

    /// The topic this run is happening inside, if it is happening inside one.
    pub fn conversation_id(&self) -> Option<&str> {
        self.conversation_id.as_deref()
    }

    /// The human this CLI is configured as, as recorded by `config init`.
    ///
    /// Nothing sends this any more -- the server reads the token and knows.
    /// It is kept so that `config show` can say who you are without a request,
    /// and for the task filters, which ask *about* an actor rather than acting
    /// as one.
    pub fn actor_id(&self) -> Result<&str> {
        self.actor_id.as_deref().ok_or_else(|| {
            Error::Config(format!(
                "no actor recorded; run `rinto-pmo config init --api <URL> --token <TOKEN>`, \
                 or set {CONVERSATION_ENV} to work inside a topic"
            ))
        })
    }
}

/// The configuration file, when there is one.
///
/// Absent is not an error here: the agent inside a topic has an environment and
/// no file, and asking it to run `config init` would configure it as a person.
fn read_file() -> Result<Option<(Value, PathBuf)>> {
    let path = path()?;

    match std::fs::read_to_string(&path) {
        Ok(source) => {
            let value: Value = serde_json::from_str(&source).map_err(|err| {
                Error::Config(format!("{} is not valid JSON: {err}", path.display()))
            })?;

            Ok(Some((value, path)))
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(Error::Config(format!(
            "could not read {}: {err}",
            path.display()
        ))),
    }
}

fn string(value: &Value, field: &str) -> Option<String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_string)
        .filter(|found| !found.trim().is_empty())
}

#[derive(Subcommand)]
pub enum ConfigCommand {
    /// Save the API URL and token, and record who the token belongs to
    Init(InitArgs),
    /// Show the active configuration
    Show,
}

#[derive(Args)]
pub struct InitArgs {
    /// API base URL; falls back to RINTO_API for initial setup
    #[arg(long, value_name = "URL")]
    api: Option<String>,
    /// API token; falls back to RINTO_TOKEN. The server prints one from
    /// `mix rinto.actors.setup_human`
    #[arg(long, value_name = "TOKEN")]
    token: Option<String>,
}

pub fn run(command: ConfigCommand) -> Result<()> {
    match command {
        ConfigCommand::Init(args) => init(args),
        ConfigCommand::Show => show(),
    }
}

fn init(args: InitArgs) -> Result<()> {
    let api = args
        .api
        .or_else(|| std::env::var(API_ENV).ok())
        .ok_or_else(|| {
            Error::Config(format!(
                "no API URL supplied; pass --api or set {API_ENV} for initial setup"
            ))
        })?;
    let token = args
        .token
        .or_else(|| std::env::var(TOKEN_ENV).ok())
        .filter(|token| !token.trim().is_empty())
        .ok_or_else(|| {
            Error::Config(format!(
                "no API token supplied; pass --token or set {TOKEN_ENV}. \
                 The server prints one from `mix rinto.actors.setup_human`"
            ))
        })?;

    // The token is checked by using it rather than by being stored on trust:
    // finding out here beats finding out on the first write.
    let client = Client::new(&api, &token)?;
    let actor = client::data(client.get("/actors/me", &[])?)?;
    if actor.get("kind").and_then(Value::as_str) != Some("human") {
        return Err(Error::Network(
            "the token belongs to a non-human actor".to_string(),
        ));
    }
    let actor_id = actor
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Network("the actor had no id".to_string()))?;
    let actor_name = actor
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("(unnamed)");

    let config = json!({
        "api": api.trim_end_matches('/'),
        "token": token.trim(),
        "actor_id": actor_id
    });
    let rendered = serde_json::to_string_pretty(&config)
        .map_err(|err| Error::Io(format!("could not render the configuration: {err}")))?;
    let path = path()?;
    write_config(&path, &format!("{rendered}\n"))?;

    println!(
        "configured human actor {actor_name} ({actor_id}) in {}",
        path.display()
    );
    Ok(())
}

fn show() -> Result<()> {
    let config = Config::load()?;
    println!("config: {}", path()?.display());
    println!("api: {}", config.api());

    // Never the token itself. `config show` is the command somebody runs while
    // screen-sharing to work out why a call is failing.
    match config.token() {
        Ok(_configured) => println!("token: (configured)"),
        Err(_missing) => println!("token: (none; no request will be answered)"),
    }

    match config.actor_id() {
        Ok(actor_id) => println!("actor_id: {actor_id}"),
        Err(_no_actor) => println!("actor_id: (none; writes are by the topic's assistant)"),
    }

    match config.conversation_id() {
        Some(conversation_id) => println!("conversation_id: {conversation_id}"),
        None => println!("conversation_id: (none; not running inside a topic)"),
    }

    Ok(())
}

fn path() -> Result<PathBuf> {
    if let Ok(path) = std::env::var(CONFIG_ENV) {
        if !path.trim().is_empty() {
            return Ok(PathBuf::from(path));
        }
    }

    if let Ok(directory) = std::env::var("XDG_CONFIG_HOME") {
        if !directory.trim().is_empty() {
            return Ok(Path::new(&directory).join(CONFIG_DIR).join(CONFIG_FILE));
        }
    }

    let home = std::env::var("HOME").map_err(|_| {
        Error::Config(format!(
            "HOME is not set, so the config path cannot be resolved; set {CONFIG_ENV} explicitly"
        ))
    })?;
    Ok(Path::new(&home)
        .join(".config")
        .join(CONFIG_DIR)
        .join(CONFIG_FILE))
}

fn write_config(path: &Path, content: &str) -> Result<()> {
    let directory = path
        .parent()
        .ok_or_else(|| Error::Config(format!("{} has no parent directory", path.display())))?;
    std::fs::create_dir_all(directory)
        .map_err(|err| Error::Io(format!("could not create {}: {err}", directory.display())))?;

    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, content)
        .map_err(|err| Error::Io(format!("could not write {}: {err}", temporary.display())))?;
    restrict(&temporary)?;
    std::fs::rename(&temporary, path)
        .map_err(|err| Error::Io(format!("could not replace {}: {err}", path.display())))?;
    Ok(())
}

/// Owner-only, because this file now holds the token.
///
/// Applied to the temporary file before the rename, so the configuration is
/// never briefly world-readable at its real path.
#[cfg(unix)]
fn restrict(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .map_err(|err| Error::Io(format!("could not restrict {}: {err}", path.display())))
}

#[cfg(not(unix))]
fn restrict(_path: &Path) -> Result<()> {
    Ok(())
}
