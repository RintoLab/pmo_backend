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

use crate::error::{Error, Result};

/// Where pi discovers user-level skills.
const DEFAULT_DIR: &str = "~/.pi/agent/skills";

pub struct Skill {
    pub name: &'static str,
    pub body: &'static str,
}

/// Every skill this binary can install.
///
/// Deliberately not installed as a set: the two are written for different
/// audiences, and a server-side agent carrying the client-side workflow is the
/// noise the two-skill split exists to avoid.
pub const SKILLS: &[Skill] = &[
    Skill {
        name: "rinto-document-authoring",
        body: include_str!("../../skills/rinto-document-authoring/SKILL.md"),
    },
    Skill {
        name: "rinto-docs-reference",
        body: include_str!("../../skills/rinto-docs-reference/SKILL.md"),
    },
];

#[derive(Subcommand)]
pub enum SkillCommand {
    /// Show the skills this binary carries
    List,
    /// Write a skill where an agent will discover it
    Install(InstallArgs),
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

pub fn run(command: SkillCommand) -> Result<()> {
    match command {
        SkillCommand::List => list(),
        SkillCommand::Install(args) => install(args),
    }
}

fn list() -> Result<()> {
    for skill in SKILLS {
        println!("{}\n  {}\n", skill.name, description_of(skill.body));
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
            return Ok(());
        }
        if !args.force {
            return Err(Error::Input(format!(
                "{} exists and differs; pass --force to replace it",
                path.display()
            )));
        }
    }

    std::fs::create_dir_all(&directory)
        .map_err(|err| Error::Io(format!("could not create {}: {err}", directory.display())))?;

    std::fs::write(&path, skill.body)
        .map_err(|err| Error::Io(format!("could not write {}: {err}", path.display())))?;

    println!("installed {} to {}", skill.name, path.display());
    Ok(())
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
    use super::{description_of, SKILLS};

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
