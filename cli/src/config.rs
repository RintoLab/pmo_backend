use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use serde_json::{json, Value};

use crate::client::{self, Client};
use crate::error::{Error, Result};

const API_ENV: &str = "RINTO_API";
const CONFIG_ENV: &str = "RINTO_CONFIG";
const CONFIG_DIR: &str = "rinto-pmo";
const CONFIG_FILE: &str = "config.json";

pub struct Config {
    api: String,
    actor_id: String,
}

impl Config {
    pub fn load() -> Result<Self> {
        let path = path()?;
        let source = std::fs::read_to_string(&path).map_err(|err| {
            Error::Config(format!(
                "could not read {}: {err}; run `rinto-pmo config init --api <URL>` first",
                path.display()
            ))
        })?;
        let value: Value = serde_json::from_str(&source)
            .map_err(|err| Error::Config(format!("{} is not valid JSON: {err}", path.display())))?;

        Ok(Self {
            api: required_string(&value, "api", &path)?,
            actor_id: required_string(&value, "actor_id", &path)?,
        })
    }

    pub fn api(&self) -> &str {
        &self.api
    }

    pub fn actor_id(&self) -> &str {
        &self.actor_id
    }
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
    println!("actor_id: {}", config.actor_id());
    Ok(())
}

fn required_string(value: &Value, field: &str, path: &Path) -> Result<String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(ToString::to_string)
        .ok_or_else(|| {
            Error::Config(format!(
                "{} has no non-empty {field:?} field; run `rinto-pmo config init --api <URL>` again",
                path.display()
            ))
        })
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
