//! Where a project's code is on the machine this runs on.
//!
//! Only useful to something running on the server: the path that comes back is
//! the server's own, and there is nothing at that path anywhere else. A
//! developer's checkout is their own, made with their own credentials -- see
//! `skills/rinto-docs-reference`, which is about being in the right one rather
//! than about being given one.

use clap::{Args, Subcommand};
use serde_json::{json, Value};

use crate::client::{self, Client};
use crate::config::Config;
use crate::error::{Error, Result};

#[derive(Subcommand)]
pub enum RepoCommand {
    /// Put a branch on disk and say where it is
    Checkout(CheckoutArgs),
}

#[derive(Args)]
pub struct CheckoutArgs {
    /// Which repository, as <project-slug>/<repo-name>
    target: String,
    /// Branch to check out. Defaults to the remote's current default branch.
    /// Applies to this call only -- nothing remembers it between calls
    #[arg(long)]
    branch: Option<String>,
    /// Fetch even if the last one was recent. For a person who has just pushed
    #[arg(long)]
    force: bool,
}

pub fn run(command: RepoCommand) -> Result<()> {
    let config = Config::load()?;
    let client = &Client::new(config.api(), config.token()?)?;

    match command {
        RepoCommand::Checkout(args) => checkout(client, args),
    }
}

fn checkout(client: &Client, args: CheckoutArgs) -> Result<()> {
    let (slug, name) = split_target(&args.target)?;
    let id = resolve_id(client, slug, name)?;

    let mut body = json!({"force": args.force});
    if let Some(branch) = &args.branch {
        body["branch"] = Value::String(branch.clone());
    }

    let path = format!("/projects/{slug}/repos/{id}/checkout");
    let checkout = client::data(client.post(&path, body)?)?;

    print!("{}", report(&checkout));
    Ok(())
}

/// The name is a natural key within its project, and the id is what the API
/// addresses. One extra round trip rather than a second way to name a
/// repository: `project show` prints names, so a name is what a caller has.
fn resolve_id(client: &Client, slug: &str, name: &str) -> Result<String> {
    let path = format!("/projects/{slug}/repos");
    let repos = client::data(client.get(&path, &[])?)?;
    let repos = repos.as_array().map(Vec::as_slice).unwrap_or_default();

    let found = repos
        .iter()
        .find(|repo| repo.get("name").and_then(Value::as_str) == Some(name))
        .and_then(|repo| repo.get("id"))
        .and_then(Value::as_str);

    match found {
        Some(id) => Ok(id.to_string()),

        // The alternatives are listed rather than left to be guessed at: the
        // caller is usually a model, and a model told only "no such thing"
        // invents a plausible name and asks again.
        None => {
            let known: Vec<&str> = repos
                .iter()
                .filter_map(|repo| repo.get("name").and_then(Value::as_str))
                .collect();
            let known = if known.is_empty() {
                "none are registered".to_string()
            } else {
                format!("registered: {}", known.join(", "))
            };

            Err(Error::Input(format!(
                "project \"{slug}\" has no repository named \"{name}\" ({known})"
            )))
        }
    }
}

fn split_target(target: &str) -> Result<(&str, &str)> {
    match target.split_once('/') {
        Some((slug, name)) if !slug.is_empty() && !name.is_empty() && !name.contains('/') => {
            Ok((slug, name))
        }
        _malformed => Err(Error::Input(format!(
            "\"{target}\" is not <project-slug>/<repo-name>"
        ))),
    }
}

/// The path on its own line, because that is what gets used; everything else
/// after it, because a statement about this code is only worth as much as the
/// commit it was read at.
///
/// `sync_error` gets a line of its own when it is there. It means the copy
/// could be served but not refreshed, and a reader that misses it will describe
/// an old tree as the current one.
fn report(checkout: &Value) -> String {
    let mut output = format!(
        "{}\nbranch={}  commit={}  synced={}\n",
        string(checkout, "path", "?"),
        string(checkout, "branch", "?"),
        short(string(checkout, "commit", "?")),
        string(checkout, "synced_at", "never")
    );

    if let Some(error) = checkout.get("sync_error").and_then(Value::as_str) {
        output.push_str(&format!(
            "STALE: could not refresh this copy, so it may be older than the remote -- {error}\n"
        ));
    }

    output
}

fn short(commit: &str) -> &str {
    if commit.len() > 12 {
        &commit[..12]
    } else {
        commit
    }
}

fn string<'a>(value: &'a Value, field: &str, fallback: &'a str) -> &'a str {
    value.get(field).and_then(Value::as_str).unwrap_or(fallback)
}

#[cfg(test)]
mod tests {
    use super::{checkout, report, split_target, CheckoutArgs};
    use crate::testing::{client, Reply, StubServer};
    use serde_json::json;

    fn args(target: &str, branch: Option<&str>, force: bool) -> CheckoutArgs {
        CheckoutArgs {
            target: target.to_string(),
            branch: branch.map(str::to_string),
            force,
        }
    }

    fn repos() -> Reply {
        Reply::json(
            200,
            json!({"data": [{"id": "repo-id", "name": "backend"}, {"id": "other", "name": "web"}]}),
        )
    }

    fn checked_out() -> Reply {
        Reply::json(
            200,
            json!({"data": {
                "path": "/srv/workspace/acme/backend/worktrees/main",
                "branch": "main",
                "commit": "1a2b3c4d5e6f7890",
                "synced_at": "2026-08-29T10:00:00Z",
                "sync_error": null
            }}),
        )
    }

    #[test]
    fn a_name_is_resolved_to_an_id_before_the_checkout() {
        let server = StubServer::start(vec![repos(), checked_out()]);

        checkout(&client(&server), args("acme/backend", None, false)).unwrap();

        let requests = server.requests();
        assert_eq!(requests[0].target, "/api/v1/projects/acme/repos");
        assert_eq!(
            requests[1].target,
            "/api/v1/projects/acme/repos/repo-id/checkout"
        );
    }

    #[test]
    fn the_branch_is_sent_only_when_one_was_asked_for() {
        let server = StubServer::start(vec![repos(), checked_out()]);
        checkout(&client(&server), args("acme/backend", None, false)).unwrap();
        assert!(!server.requests()[1].body.contains("branch"));

        let server = StubServer::start(vec![repos(), checked_out()]);
        checkout(&client(&server), args("acme/backend", Some("feat/x"), true)).unwrap();
        let body = &server.requests()[1].body;
        assert!(body.contains("feat/x"));
        assert!(body.contains("\"force\":true"));
    }

    #[test]
    fn an_unknown_repository_lists_the_ones_that_exist() {
        let server = StubServer::start(vec![repos()]);

        let error = checkout(&client(&server), args("acme/backendd", None, false)).unwrap_err();

        let rendered = format!("{error}");
        assert!(rendered.contains("no repository named \"backendd\""));
        assert!(rendered.contains("backend, web"));
    }

    #[test]
    fn a_target_that_is_not_slug_and_name_is_refused_before_any_request() {
        for target in ["backend", "acme/", "/backend", "acme/deep/name", ""] {
            let server = StubServer::start(vec![]);

            let error = checkout(&client(&server), args(target, None, false)).unwrap_err();

            assert!(format!("{error}").contains("is not <project-slug>/<repo-name>"));
            assert!(server.requests().is_empty(), "{target} reached the server");
        }
    }

    #[test]
    fn split_target_takes_only_one_slash() {
        assert_eq!(split_target("acme/backend").unwrap(), ("acme", "backend"));
        assert!(split_target("acme/a/b").is_err());
    }

    #[test]
    fn the_path_comes_first_and_the_commit_with_it() {
        let rendered = report(&json!({
            "path": "/srv/workspace/acme/backend/worktrees/main",
            "branch": "main",
            "commit": "1a2b3c4d5e6f7890abcd",
            "synced_at": "2026-08-29T10:00:00Z",
            "sync_error": null
        }));

        let mut lines = rendered.lines();
        assert_eq!(
            lines.next().unwrap(),
            "/srv/workspace/acme/backend/worktrees/main"
        );
        assert_eq!(
            lines.next().unwrap(),
            "branch=main  commit=1a2b3c4d5e6f  synced=2026-08-29T10:00:00Z"
        );
        assert!(lines.next().is_none());
    }

    #[test]
    fn a_copy_that_could_not_be_refreshed_says_so_loudly() {
        let rendered = report(&json!({
            "path": "/srv/workspace/acme/backend/worktrees/main",
            "branch": "main",
            "commit": "1a2b3c4d",
            "synced_at": "2026-08-20T10:00:00Z",
            "sync_error": "git fetch failed (exit 128): could not read from remote"
        }));

        assert!(rendered.contains("STALE:"));
        assert!(rendered.contains("could not read from remote"));
    }
}
