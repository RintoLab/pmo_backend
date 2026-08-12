use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use serde_json::{json, Value};

use crate::client::{self, Client};
use crate::error::{Error, Result};

const API_ENV: &str = "RINTO_API";
const CONVERSATION_ENV: &str = "RINTO_CONVERSATION_ID";
const CONFIG_ENV: &str = "RINTO_CONFIG";
const CONFIG_DIR: &str = "rinto-pmo";
const CONFIG_FILE: &str = "config.json";

/// Where this run is happening, and as whom.
///
/// Two situations, and they are configured differently on purpose.
///
/// A developer runs this on their own machine: `config init` writes a file
/// naming the API and the one human actor, and writes are theirs.
///
/// The agent inside a topic runs it with an environment instead. The backend
/// spawns that process and injects the topic, because which topic it is
/// answering in is a fact about the process rather than something to ask a model
/// to carry. There is no actor: a write made inside a topic is by that topic's
/// assistant, and the server derives it -- see `RintoPMO.Documents`. This
/// program never names an author.
pub struct Config {
    api: String,
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

    /// The topic this run is happening inside, if it is happening inside one.
    pub fn conversation_id(&self) -> Option<&str> {
        self.conversation_id.as_deref()
    }

    /// The human this CLI is configured as.
    ///
    /// Only needed for a write made outside any topic -- inside one, the author
    /// is the topic's assistant and the server works it out. So the error names
    /// the case rather than assuming the configuration is simply missing.
    pub fn actor_id(&self) -> Result<&str> {
        self.actor_id.as_deref().ok_or_else(|| {
            Error::Config(format!(
                "no actor configured; run `rinto-pmo config init --api <URL>`, \
                 or set {CONVERSATION_ENV} to write as a topic's assistant"
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
    /// Find the server's only human actor and save this CLI's configuration
    Init(InitArgs),
    /// Show the active configuration
    Show,
}

#[derive(Args)]
pub struct InitArgs {
    /// API base URL; falls back to RINTO_API for initial setup
    #[arg(long, value_name = "URL")]
    api: Option<String>,
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
    let client = Client::new(&api)?;
    let actor = client::data(client.get("/actors/human", &[])?)?;
    if actor.get("kind").and_then(Value::as_str) != Some("human") {
        return Err(Error::Network(
            "the human actor endpoint returned a non-human actor".to_string(),
        ));
    }
    let actor_id = actor
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Network("the human actor had no id".to_string()))?;
    let actor_name = actor
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("(unnamed)");

    let config = json!({
        "api": api.trim_end_matches('/'),
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
    std::fs::rename(&temporary, path)
        .map_err(|err| Error::Io(format!("could not replace {}: {err}", path.display())))?;
    Ok(())
}
