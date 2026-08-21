//! Skills shipped inside the binary, and the command that installs them.
//!
//! Embedding rather than distributing files alongside solves two things named
//! in `docs/ai-document-cli.md`:
//!
//! * **drift** -- a skill describes this CLI's own commands, so it belongs to
//!   the same artifact as `--help`. A binary can no longer be paired with a
//!   skill written for a different version of itself.
//! * **deployment that lives in someone's memory** -- `rinto-pmo skill install`
//!   is one line in a Dockerfile, where copying a directory tree is a step
//!   somebody forgets when rebuilding an image.
//!
//! This does not contradict "fetch teaching material from the server": that
//! rule covers the vocabulary a model constructs *data* against (block schema),
//! which the server owns. How to invoke this CLI is this CLI's own business.

use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use serde_json::{json, Value};

use crate::error::{Error, Result};
use crate::update::sha256_hex;

/// Where pi discovers user-level skills.
const DEFAULT_DIR: &str = "~/.pi/agent/skills";

/// What was installed, and what it looked like when this CLI wrote it.
///
/// Kept beside the config, because it is the same kind of fact: a record of how
/// this machine was set up, not something the server knows.
const STATE_FILE: &str = "skills.json";

pub struct Skill {
    pub name: &'static str,
    pub body: &'static str,
}

/// Every skill this binary can install.
///
/// Deliberately not installed as a set: each is written for a different job,
/// and an agent carrying a workflow it will never run is the noise the split
/// exists to avoid. A server-side agent writing documents has no use for the
/// claim-implement-report loop, and neither of them retires work.
pub const SKILLS: &[Skill] = &[
    Skill {
        name: "rinto-document-authoring",
        body: include_str!("../../skills/rinto-document-authoring/SKILL.md"),
    },
    Skill {
        name: "rinto-docs-reference",
        body: include_str!("../../skills/rinto-docs-reference/SKILL.md"),
    },
    Skill {
        name: "rinto-backlog-cleanup",
        body: include_str!("../../skills/rinto-backlog-cleanup/SKILL.md"),
    },
];

#[derive(Subcommand)]
pub enum SkillCommand {
    /// Show the skills this binary carries
    List,
    /// Write a skill where an agent will discover it
    Install(InstallArgs),
    /// Re-install every skill already installed on this machine
    Sync(SyncArgs),
}

#[derive(Args)]
pub struct InstallArgs {
    /// Skill to install; see `rinto-pmo skill list`
    name: String,

    /// Where to install; defaults to pi's user skill directory
    #[arg(long, value_name = "DIR")]
    dir: Option<PathBuf>,

    /// Replace an existing file whose content differs
    #[arg(long)]
    force: bool,
}

#[derive(Args, Default)]
pub struct SyncArgs {
    /// Replace files edited since this CLI installed them
    #[arg(long)]
    pub force: bool,
}

pub fn run(command: SkillCommand) -> Result<()> {
    match command {
        SkillCommand::List => list(),
        SkillCommand::Install(args) => install(args),
        SkillCommand::Sync(args) => sync(args),
    }
}

fn list() -> Result<()> {
    let installed = State::load().unwrap_or_default();

    for skill in SKILLS {
        let where_installed = match installed.find(skill.name) {
            Some(record) => format!("\n  installed: {}", record.path.display()),
            None => String::new(),
        };
        println!(
            "{}\n  {}{where_installed}\n",
            skill.name,
            description_of(skill.body)
        );
    }

    println!("install with: rinto-pmo skill install <name>");
    Ok(())
}

fn install(args: InstallArgs) -> Result<()> {
    let skill = SKILLS
        .iter()
        .find(|skill| skill.name == args.name)
        .ok_or_else(|| {
            let known: Vec<&str> = SKILLS.iter().map(|skill| skill.name).collect();
            Error::Input(format!(
                "no skill named {:?}; this binary carries: {}",
                args.name,
                known.join(", ")
            ))
        })?;

    let directory = match args.dir {
        Some(dir) => dir,
        None => expand_home(DEFAULT_DIR)?,
    }
    .join(skill.name);

    let path = directory.join("SKILL.md");

    // An installed skill is editable, and someone may have tuned it. Replacing
    // that silently would lose work with no trace, so a differing file needs
    // --force.
    if let Ok(existing) = std::fs::read_to_string(&path) {
        if existing == skill.body {
            println!("already current: {}", path.display());
            // Still recorded: an install that found the file already right is
            // how a machine whose state file was lost gets one back.
            return remember(skill, &path);
        }
        if !args.force {
            return Err(Error::Input(format!(
                "{} exists and differs; pass --force to replace it",
                path.display()
            )));
        }
    }

    write_skill(skill, &directory, &path)?;

    println!("installed {} to {}", skill.name, path.display());
    remember(skill, &path)
}

/// Re-apply this binary's skills wherever a previous install put them.
///
/// Runs after a self-update, and by hand. Nothing is installed that was not
/// installed before -- the record is the whole input, so `skill sync` on a
/// machine that never ran `skill install` does nothing, which keeps the
/// "install names one skill, never all of them" split intact.
fn sync(args: SyncArgs) -> Result<()> {
    let mut state = State::load()?;
    if state.records.is_empty() {
        println!("no skills installed by this CLI; nothing to sync");
        return Ok(());
    }

    let mut kept = Vec::new();
    // Only the run that had nothing at all to say gets the closing line; a run
    // that reported a skipped or dropped skill saying "already current" under
    // it reads as if the report were nothing to act on.
    let mut said_something = false;

    for record in std::mem::take(&mut state.records) {
        let Some(skill) = SKILLS.iter().find(|skill| skill.name == record.name) else {
            // A skill this binary dropped is no longer ours to maintain. The
            // file stays -- deleting someone's skill during an update is not a
            // thing an updater should do -- but we stop claiming it.
            println!(
                "no longer shipped: {} (left {} alone)",
                record.name,
                record.path.display()
            );
            said_something = true;
            continue;
        };

        match std::fs::read_to_string(&record.path) {
            // Removed by hand is an uninstall. Putting it back on every update
            // would make the record impossible to get out of.
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                println!("gone, dropping from the record: {}", record.path.display());
                said_something = true;
                continue;
            }
            Err(err) => {
                return Err(Error::Io(format!(
                    "could not read {}: {err}",
                    record.path.display()
                )))
            }
            Ok(existing) => match decide(&existing, skill.body, &record.sha256, args.force) {
                Action::Current => kept.push(record.refreshed(skill)),
                Action::Replace => {
                    let directory = record.path.parent().unwrap_or(Path::new("."));
                    write_skill(skill, directory, &record.path)?;
                    println!("synced {} in {}", skill.name, record.path.display());
                    said_something = true;
                    kept.push(record.refreshed(skill));
                }
                Action::Edited => {
                    println!(
                        "edited since install, left alone: {}\n  \
                         take this binary's copy with: rinto-pmo skill install {} --force",
                        record.path.display(),
                        skill.name
                    );
                    said_something = true;
                    kept.push(record);
                }
            },
        }
    }

    state.records = kept;
    state.save()?;

    if !said_something {
        println!("skills already current");
    }
    Ok(())
}

#[derive(Debug, Eq, PartialEq)]
enum Action {
    /// On disk already, byte for byte.
    Current,
    /// Untouched since this CLI wrote it, so replacing it loses nothing.
    Replace,
    /// Someone tuned the wording; theirs wins over an update's.
    Edited,
}

fn decide(existing: &str, body: &str, recorded: &str, force: bool) -> Action {
    if existing == body {
        Action::Current
    } else if force || sha256_hex(existing.as_bytes()) == recorded {
        Action::Replace
    } else {
        Action::Edited
    }
}

fn write_skill(skill: &Skill, directory: &Path, path: &Path) -> Result<()> {
    std::fs::create_dir_all(directory)
        .map_err(|err| Error::Io(format!("could not create {}: {err}", directory.display())))?;

    std::fs::write(path, skill.body)
        .map_err(|err| Error::Io(format!("could not write {}: {err}", path.display())))
}

fn remember(skill: &Skill, path: &Path) -> Result<()> {
    let mut state = State::load()?;
    state.record(skill, path);
    state.save()
}

/// What this CLI installed, and what it wrote.
///
/// The hash is the point. Without it, a sync after an update cannot tell "the
/// old version's text" from "the text someone tuned", and would have to either
/// overwrite tuned wording silently or refuse to do anything useful.
#[derive(Clone)]
struct Record {
    name: String,
    path: PathBuf,
    sha256: String,
}

impl Record {
    fn refreshed(mut self, skill: &Skill) -> Self {
        self.sha256 = sha256_hex(skill.body.as_bytes());
        self
    }
}

#[derive(Default)]
struct State {
    records: Vec<Record>,
}

impl State {
    fn load() -> Result<Self> {
        let path = state_path()?;
        let source = match std::fs::read_to_string(&path) {
            Ok(source) => source,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(err) => {
                return Err(Error::Io(format!(
                    "could not read {}: {err}",
                    path.display()
                )))
            }
        };

        let value: Value = serde_json::from_str(&source)
            .map_err(|err| Error::Config(format!("{} is not valid JSON: {err}", path.display())))?;

        Ok(Self {
            records: Self::parse(&value),
        })
    }

    fn parse(value: &Value) -> Vec<Record> {
        value
            .get("installed")
            .and_then(Value::as_array)
            .map(|entries| {
                entries
                    .iter()
                    .filter_map(|entry| {
                        Some(Record {
                            name: entry.get("name")?.as_str()?.to_string(),
                            path: PathBuf::from(entry.get("path")?.as_str()?),
                            sha256: entry.get("sha256")?.as_str()?.to_ascii_lowercase(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    fn find(&self, name: &str) -> Option<&Record> {
        self.records.iter().find(|record| record.name == name)
    }

    /// One record per skill: installing the same skill somewhere else moves it
    /// rather than leaving a stale path that sync would keep writing to.
    fn record(&mut self, skill: &Skill, path: &Path) {
        self.records.retain(|record| record.name != skill.name);
        self.records.push(Record {
            name: skill.name.to_string(),
            path: path.to_path_buf(),
            sha256: sha256_hex(skill.body.as_bytes()),
        });
    }

    fn as_json(&self) -> Value {
        let installed: Vec<Value> = self
            .records
            .iter()
            .map(|record| {
                json!({
                    "name": record.name,
                    "path": record.path.to_string_lossy(),
                    "sha256": record.sha256,
                })
            })
            .collect();
        json!({ "installed": installed })
    }

    fn save(&self) -> Result<()> {
        let path = state_path()?;
        let directory = path
            .parent()
            .ok_or_else(|| Error::Io(format!("{} has no parent directory", path.display())))?;
        std::fs::create_dir_all(directory)
            .map_err(|err| Error::Io(format!("could not create {}: {err}", directory.display())))?;

        let body = serde_json::to_string_pretty(&self.as_json())
            .map_err(|err| Error::Io(format!("could not serialize the skill record: {err}")))?;

        std::fs::write(&path, format!("{body}\n"))
            .map_err(|err| Error::Io(format!("could not write {}: {err}", path.display())))
    }
}

fn state_path() -> Result<PathBuf> {
    Ok(crate::config::directory()?.join(STATE_FILE))
}

fn expand_home(path: &str) -> Result<PathBuf> {
    let Some(rest) = path.strip_prefix("~/") else {
        return Ok(PathBuf::from(path));
    };

    let home = std::env::var("HOME")
        .map_err(|_| Error::Config("HOME is not set, so ~ cannot be resolved".to_string()))?;

    Ok(Path::new(&home).join(rest))
}

/// Pulls `description:` out of the YAML frontmatter.
///
/// A hand-rolled read of one field rather than a YAML dependency: the
/// frontmatter is ours, its shape is fixed by the Agent Skills spec, and this
/// is the only field anything here needs.
fn description_of(body: &str) -> &str {
    body.lines()
        // Past the opening `---`, then up to the closing one.
        .skip(1)
        .take_while(|line| line.trim() != "---")
        .find_map(|line| line.strip_prefix("description:"))
        .map(str::trim)
        .unwrap_or("(no description)")
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use serde_json::json;

    use super::{decide, description_of, sha256_hex, Action, Record, Skill, State, SKILLS};

    #[test]
    fn every_skill_carries_content() {
        for skill in SKILLS {
            assert!(
                skill.body.starts_with("---\n"),
                "{} is missing frontmatter",
                skill.name
            );
        }
    }

    /// pi keys a skill by its frontmatter `name`, while the install path comes
    /// from the registry, so a mismatch would install to a directory the agent
    /// then reports under a different name.
    #[test]
    fn frontmatter_name_matches_the_registry() {
        for skill in SKILLS {
            let declared = skill
                .body
                .lines()
                .find_map(|line| line.strip_prefix("name:"))
                .map(str::trim);

            assert_eq!(declared, Some(skill.name));
        }
    }

    /// The whole reason the record carries a hash: an update must be able to
    /// replace its own previous text without replacing someone's edit.
    #[test]
    fn sync_replaces_its_own_text_and_spares_an_edit() {
        let old = "---\nname: x\n---\nold text";
        let new = "---\nname: x\n---\nnew text";
        let recorded = sha256_hex(old.as_bytes());

        assert_eq!(decide(new, new, &recorded, false), Action::Current);
        assert_eq!(decide(old, new, &recorded, false), Action::Replace);
        assert_eq!(
            decide("tuned by hand", new, &recorded, false),
            Action::Edited
        );
        assert_eq!(
            decide("tuned by hand", new, &recorded, true),
            Action::Replace
        );
    }

    /// A machine that never installed anything must stay that way: sync reads
    /// the record, and an absent one is empty rather than "install everything".
    #[test]
    fn an_absent_record_syncs_nothing() {
        assert!(State::parse(&json!({})).is_empty());
        assert!(State::parse(&json!({"installed": []})).is_empty());
        assert!(State::parse(&json!({"installed": [{"name": "x"}]})).is_empty());
    }

    #[test]
    fn the_record_round_trips_and_keeps_one_path_per_skill() {
        let skill = Skill {
            name: "rinto-docs-reference",
            body: "---\nname: rinto-docs-reference\n---\nbody",
        };
        let mut state = State::default();
        state.record(&skill, Path::new("/one/SKILL.md"));
        state.record(&skill, Path::new("/two/SKILL.md"));

        assert_eq!(state.records.len(), 1);
        assert_eq!(
            state.find("rinto-docs-reference").unwrap().path,
            PathBuf::from("/two/SKILL.md")
        );

        let restored = State::parse(&state.as_json());
        assert_eq!(restored.len(), 1);
        assert_eq!(restored[0].sha256, sha256_hex(skill.body.as_bytes()));
        assert_eq!(restored[0].path, PathBuf::from("/two/SKILL.md"));
    }

    /// A `sync` immediately after one that replaced a file must be a no-op, so
    /// the hash written back has to be the *new* body's, not the old record's.
    #[test]
    fn a_synced_record_carries_the_new_hash() {
        let skill = Skill {
            name: "x",
            body: "---\nname: x\n---\nnew",
        };
        let record = Record {
            name: "x".to_string(),
            path: PathBuf::from("/x/SKILL.md"),
            sha256: sha256_hex(b"old"),
        }
        .refreshed(&skill);

        assert_eq!(record.sha256, sha256_hex(skill.body.as_bytes()));
        assert_eq!(
            decide(skill.body, skill.body, &record.sha256, false),
            Action::Current
        );
    }

    #[test]
    fn every_skill_has_a_description() {
        for skill in SKILLS {
            let description = description_of(skill.body);

            assert_ne!(description, "(no description)", "{}", skill.name);
            assert!(
                description.len() > 20,
                "{} description is too thin",
                skill.name
            );
        }
    }
}
