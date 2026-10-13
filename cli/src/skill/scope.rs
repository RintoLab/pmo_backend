use std::path::{Component, Path, PathBuf};
use std::process::Command;

use clap::Args;

use crate::error::{Error, Result};

#[derive(Args, Default)]
pub struct ScopeArgs {
    /// Use a project directory; omit DIR for the current Git worktree or directory
    #[arg(long, value_name = "DIR", num_args = 0..=1, conflicts_with = "global")]
    project: Option<Option<PathBuf>>,

    /// Use user-wide installations (the default)
    #[arg(long)]
    global: bool,
}

#[derive(Default)]
pub(super) enum Scope {
    #[default]
    Global,
    Project(PathBuf),
}

impl ScopeArgs {
    pub(super) fn resolve(&self) -> Result<Scope> {
        let Some(project) = &self.project else {
            return Ok(Scope::Global);
        };
        let directory = match project {
            Some(path) => path.clone(),
            None => {
                let cwd = std::env::current_dir().map_err(|err| {
                    Error::Io(format!("could not locate current directory: {err}"))
                })?;
                let git = Command::new("git")
                    .args(["rev-parse", "--show-toplevel"])
                    .env_remove("GIT_DIR")
                    .env_remove("GIT_WORK_TREE")
                    .env_remove("GIT_COMMON_DIR")
                    .output();
                match git {
                    Ok(output) if output.status.success() => {
                        let root = String::from_utf8(output.stdout)
                            .map_err(|_| Error::Input("Git root is not UTF-8".into()))?;
                        PathBuf::from(root.trim_end_matches(['\r', '\n']))
                    }
                    _ => cwd,
                }
            }
        };
        let root = directory.canonicalize().map_err(|err| {
            Error::Input(format!(
                "could not open project {}: {err}",
                directory.display()
            ))
        })?;
        if !root.is_dir() {
            return Err(Error::Input(format!(
                "{} is not a project directory",
                root.display()
            )));
        }
        println!("project: {}", root.display());
        Ok(Scope::Project(root))
    }
}

impl Scope {
    pub(super) fn state_path(&self) -> Result<PathBuf> {
        let path = match self {
            Self::Global => crate::config::directory()?.join(super::STATE_FILE),
            Self::Project(root) => root.join(".rinto").join(super::STATE_FILE),
        };
        self.validate(&path)?;
        Ok(path)
    }

    /// Project records are portable. Resolve them only after rejecting absolute
    /// paths and traversal, then check existing symlinks before any reads/writes.
    pub(super) fn resolve_record(&self, path: &Path) -> Result<PathBuf> {
        match self {
            Self::Global => Ok(path.to_path_buf()),
            Self::Project(root) => {
                if path.as_os_str().is_empty()
                    || path
                        .components()
                        .any(|part| !matches!(part, Component::Normal(_)))
                {
                    return Err(Error::Input(format!(
                        "project skill path must be relative and stay inside the project: {}",
                        path.display()
                    )));
                }
                let resolved = root.join(path);
                self.validate(&resolved)?;
                Ok(resolved)
            }
        }
    }

    pub(super) fn stored_path<'a>(&self, path: &'a Path) -> Result<&'a Path> {
        self.validate(path)?;
        match self {
            Self::Global => Ok(path),
            Self::Project(root) => path
                .strip_prefix(root)
                .map_err(|_| Error::Input(format!("{} is outside the project", path.display()))),
        }
    }

    pub(super) fn validate(&self, path: &Path) -> Result<()> {
        let Self::Project(root) = self else {
            return Ok(());
        };
        let relative = path
            .strip_prefix(root)
            .map_err(|_| Error::Input(format!("{} is outside the project", path.display())))?;
        let mut current = root.clone();
        for component in relative.components() {
            if !matches!(component, Component::Normal(_)) {
                return Err(Error::Input(format!(
                    "{} escapes the project",
                    path.display()
                )));
            }
            current.push(component);
            match std::fs::symlink_metadata(&current) {
                Ok(_) => {
                    let resolved = current.canonicalize().map_err(|err| {
                        Error::Io(format!("could not resolve {}: {err}", current.display()))
                    })?;
                    if !resolved.starts_with(root) {
                        return Err(Error::Input(format!(
                            "{} resolves outside the project",
                            current.display()
                        )));
                    }
                }
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => break,
                Err(err) => {
                    return Err(Error::Io(format!(
                        "could not inspect {}: {err}",
                        current.display()
                    )))
                }
            }
        }
        Ok(())
    }

    pub(super) fn command_suffix(&self) -> String {
        match self {
            Self::Global => String::new(),
            // Quote even simple paths so suggestions also work for projects
            // containing spaces, quotes, or shell metacharacters.
            Self::Project(root) => format!(
                " --project '{}'",
                root.to_string_lossy().replace('\'', "'\\''")
            ),
        }
    }
}
