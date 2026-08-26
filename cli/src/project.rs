use std::fmt::Write as _;

use clap::{Args, Subcommand};
use serde_json::Value;

use crate::client::{self, Client};
use crate::config::Config;
use crate::error::Result;

#[derive(Subcommand)]
pub enum ProjectCommand {
    /// List active projects
    List,
    /// Show a project and its repositories
    Show(ShowArgs),
}

#[derive(Args)]
pub struct ShowArgs {
    /// Project slug
    slug: String,
}

pub fn run(command: ProjectCommand) -> Result<()> {
    let config = Config::load()?;
    let client = &Client::new(config.api(), config.token()?)?;

    match command {
        ProjectCommand::List => list(client),
        ProjectCommand::Show(args) => show(client, args),
    }
}

fn list(client: &Client) -> Result<()> {
    let projects = client::data(client.get("/projects", &[])?)?;
    let projects = projects.as_array().map(Vec::as_slice).unwrap_or_default();

    if projects.is_empty() {
        println!("no projects");
        return Ok(());
    }

    for project in projects {
        println!("{}", summary(project));
    }
    Ok(())
}

fn show(client: &Client, args: ShowArgs) -> Result<()> {
    let path = format!("/projects/{}", args.slug);
    let project = client::data(client.get(&path, &[])?)?;
    print!("{}", detail(&project));
    Ok(())
}

fn summary(project: &Value) -> String {
    format!(
        "{}  {}  {}",
        string(project, "slug", "?"),
        string(project, "status", "?"),
        string(project, "name", "(unnamed)")
    )
}

fn detail(project: &Value) -> String {
    let mut output = String::new();
    for (label, value) in [
        ("id", string(project, "id", "?")),
        ("slug", string(project, "slug", "?")),
        ("name", string(project, "name", "(unnamed)")),
        ("status", string(project, "status", "?")),
    ] {
        let _ = writeln!(output, "{label}: {value}");
    }

    let description = project
        .get("description")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or("none");
    let _ = writeln!(output, "description:\n{description}");

    let repos = project
        .get("repos")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    if repos.is_empty() {
        let _ = writeln!(output, "repositories: none");
    } else {
        let _ = writeln!(output, "repositories:");
        for repo in repos {
            let _ = writeln!(
                output,
                "  {}  branch={}  {}",
                string(repo, "name", "(unnamed)"),
                string(repo, "branch", "?"),
                string(repo, "git_url", "?")
            );
        }
    }

    output
}

fn string<'a>(value: &'a Value, field: &str, fallback: &'a str) -> &'a str {
    value.get(field).and_then(Value::as_str).unwrap_or(fallback)
}

#[cfg(test)]
mod tests {
    use super::{detail, list, show, summary, ShowArgs};
    use crate::testing::{client, Reply, StubServer};
    use serde_json::json;

    #[test]
    fn projects_are_listed_and_shown_by_slug() {
        let server = StubServer::start(vec![
            Reply::json(200, json!({"data": []})),
            Reply::json(200, json!({"data": {"slug": "pmo", "name": "Rinto PMO"}})),
        ]);
        let client = client(&server);

        list(&client).unwrap();
        show(
            &client,
            ShowArgs {
                slug: "pmo".to_string(),
            },
        )
        .unwrap();

        let requests = server.requests();
        assert_eq!(requests[0].target, "/api/v1/projects");
        assert_eq!(requests[1].target, "/api/v1/projects/pmo");
    }

    #[test]
    fn summary_is_compact_and_addressable_by_slug() {
        let project = json!({"slug": "pmo", "status": "active", "name": "Rinto PMO"});

        assert_eq!(summary(&project), "pmo  active  Rinto PMO");
    }

    #[test]
    fn detail_includes_repositories_needed_to_find_the_worktree() {
        let project = json!({
            "id": "project-id",
            "slug": "pmo",
            "name": "Rinto PMO",
            "status": "active",
            "description": "Project management",
            "repos": [{
                "name": "backend",
                "branch": "main",
                "git_url": "https://github.com/RintoLab/pmo_backend.git"
            }]
        });
        let rendered = detail(&project);

        assert!(rendered.contains("slug: pmo"));
        assert!(rendered.contains("backend  branch=main"));
        assert!(rendered.contains("https://github.com/RintoLab/pmo_backend.git"));
    }
}
