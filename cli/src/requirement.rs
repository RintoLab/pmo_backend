use std::fmt::Write as _;
use std::path::PathBuf;

use clap::{Args, Subcommand};
use serde_json::{json, Map, Value};

use crate::client::{self, Client};
use crate::config::Config;
use crate::error::{Error, Result};

#[derive(Subcommand)]
pub enum RequirementCommand {
    /// List unarchived roots across projects, or browse one project's hierarchy
    List(ListArgs),
    /// Read a requirement's description, ownership, child count and document summaries
    Show(RequirementArgs),
    /// Create a draft, optionally under another requirement in the same project
    Create(CreateArgs),
    /// Edit draft metadata or reprioritize an open requirement
    Update(UpdateArgs),
    /// Fill missing task estimates under one or more requirements, including descendants
    Estimate(EstimateArgs),
    /// Let AI set this requirement's priority directly; correct it with update --priority
    Prioritize(PrioritizeArgs),
}

#[derive(Args)]
pub struct PrioritizeArgs {
    /// Requirement UUID; does not include children
    id: String,
    /// Wait for the update and show the resulting requirement
    #[arg(long)]
    wait: bool,
}

#[derive(Args)]
pub struct EstimateArgs {
    /// Requirement UUIDs; parent/child overlaps are deduplicated on the server
    #[arg(required = true, num_args = 1..=100)]
    ids: Vec<String>,
    /// Wait for queued jobs to finish; reports failures without automatically retrying
    #[arg(long)]
    wait: bool,
}

#[derive(Args)]
pub struct ListArgs {
    /// Project slug; omit to list roots across projects, including archived projects
    #[arg(long, value_name = "SLUG")]
    project: Option<String>,

    /// UUID for direct children, none for roots, all for every level
    #[arg(long, value_name = "UUID|none|all")]
    parent_id: Option<String>,
}

#[derive(Args)]
pub struct RequirementArgs {
    /// Requirement UUID
    id: String,
}

#[derive(Args)]
pub struct CreateArgs {
    /// Project slug for a root requirement; a child inherits its parent's project
    #[arg(
        long,
        value_name = "SLUG",
        required_unless_present = "parent_id",
        conflicts_with = "parent_id"
    )]
    project: Option<String>,

    /// Requirement title
    #[arg(long)]
    title: String,

    /// Requirement priority: 1 highest, 3 normal (default); inherited by its tasks
    #[arg(long, value_parser = clap::value_parser!(u8).range(1..=5))]
    priority: Option<u8>,

    /// UTF-8 Markdown description; omit for an empty description
    #[arg(long, value_name = "FILE")]
    body: Option<PathBuf>,

    /// Create a child of this open requirement, inheriting its project
    #[arg(long, value_name = "UUID")]
    parent_id: Option<String>,
}

#[derive(Args)]
pub struct UpdateArgs {
    #[command(flatten)]
    requirement: RequirementArgs,

    /// Replacement title; omit to preserve it
    #[arg(long, required_unless_present_any = ["body", "priority"])]
    title: Option<String>,

    /// Set priority for the requirement and all its tasks: 1 highest, 5 lowest
    #[arg(long, value_parser = clap::value_parser!(u8).range(1..=5))]
    priority: Option<u8>,

    /// Replacement description; an empty file clears it, omission preserves it
    #[arg(long, value_name = "FILE")]
    body: Option<PathBuf>,
}

pub fn run(command: RequirementCommand) -> Result<()> {
    let config = Config::load()?;
    let client = &Client::new(config.api(), config.token()?)?;

    match command {
        RequirementCommand::List(args) => list(client, args),
        RequirementCommand::Show(args) => show(client, args),
        RequirementCommand::Create(args) => create(client, args),
        RequirementCommand::Update(args) => update(client, args),
        RequirementCommand::Estimate(args) => estimate(client, args),
        RequirementCommand::Prioritize(args) => prioritize(client, args),
    }
}

fn prioritize(client: &Client, args: PrioritizeArgs) -> Result<()> {
    let job = client::data(client.post(
        &format!("/requirements/{}/prioritize", segment(&args.id)),
        json!({}),
    )?)?;
    let id = job
        .get("id")
        .and_then(Value::as_u64)
        .ok_or_else(|| Error::Network("missing priority job id".into()))?;
    println!("{}  job:{id}", args.id);
    if args.wait {
        wait_for_jobs(client, vec![id])?;
        show(client, RequirementArgs { id: args.id })?;
    }
    Ok(())
}

fn list(client: &Client, args: ListArgs) -> Result<()> {
    let path = args
        .project
        .as_deref()
        .map(collection_path)
        .unwrap_or_else(|| "/requirements".to_string());
    let mut query = Vec::new();
    if let Some(parent) = args.parent_id.as_deref() {
        query.push(("parent_id", parent));
    }
    let requirements = client::data(client.get(&path, &query)?)?;
    let requirements = requirements
        .as_array()
        .ok_or_else(|| Error::Network("requirement list response was not an array".to_string()))?;

    if requirements.is_empty() {
        println!("no requirements");
    }
    for requirement in requirements {
        let slug = args.project.as_deref().unwrap_or_else(|| {
            requirement
                .get("project")
                .and_then(|project| project.get("slug"))
                .and_then(Value::as_str)
                .unwrap_or("?")
        });
        println!("{}", summary(requirement, slug));
    }
    Ok(())
}

fn show(client: &Client, args: RequirementArgs) -> Result<()> {
    let requirement = client::data(client.get(&requirement_path(&args.id), &[])?)?;
    print!("{}", detail(&requirement));
    Ok(())
}

fn create(client: &Client, args: CreateArgs) -> Result<()> {
    let mut body = metadata_body(Some(args.title), args.body, args.priority)?;
    match (args.project, args.parent_id) {
        (Some(project), None) => {
            body.insert("project_slug".to_string(), json!(project));
        }
        (None, Some(parent)) => {
            body.insert("parent_id".to_string(), json!(parent));
        }
        _ => {
            return Err(Error::Input(
                "pass exactly one of --project or --parent-id".to_string(),
            ))
        }
    }
    let requirement = client::data(client.post("/requirements", Value::Object(body))?)?;
    println!(
        "created {}",
        summary(&requirement, project_slug(&requirement))
    );
    Ok(())
}

fn update(client: &Client, args: UpdateArgs) -> Result<()> {
    let body = metadata_body(args.title, args.body, args.priority)?;
    let requirement =
        client::data(client.patch(&requirement_path(&args.requirement.id), Value::Object(body))?)?;
    println!(
        "updated {}",
        summary(&requirement, project_slug(&requirement))
    );
    Ok(())
}

fn estimate(client: &Client, args: EstimateArgs) -> Result<()> {
    let response = client::data(client.post(
        "/requirements/estimate",
        json!({"requirement_ids": args.ids}),
    )?)?;
    let entries = response
        .as_array()
        .ok_or_else(|| Error::Network("estimation response was not an array".into()))?;
    if entries.is_empty() {
        println!("no open leaf requirements to estimate");
    }
    let mut jobs = Vec::new();
    for entry in entries {
        if let Some(id) = entry
            .get("job")
            .and_then(|job| job.get("id"))
            .and_then(Value::as_u64)
        {
            println!(
                "{}  job:{}  {}",
                string(entry, "requirement_id", "?"),
                id,
                string(entry, "title", "")
            );
            jobs.push(id);
        } else {
            println!(
                "{}  skipped:{}  {}",
                string(entry, "requirement_id", "?"),
                string(entry, "reason", "unknown"),
                string(entry, "title", "")
            );
        }
    }
    if args.wait {
        wait_for_jobs(client, jobs)?;
    }
    Ok(())
}

fn wait_for_jobs(client: &Client, mut jobs: Vec<u64>) -> Result<()> {
    let mut failed = false;
    while !jobs.is_empty() {
        let mut pending = Vec::new();
        for id in jobs {
            let response = match client.get(&format!("/jobs/{id}"), &[]) {
                Ok(response) => response,
                Err(Error::Api { status: 404, .. }) => {
                    println!("job:{id} pruned; re-read the requirement");
                    continue;
                }
                Err(error) => return Err(error),
            };
            let job = client::data(response)?;
            match string(&job, "status", "unknown") {
                "running" => pending.push(id),
                "succeeded" => println!("job:{id} succeeded"),
                "failed" => {
                    failed = true;
                    eprintln!(
                        "job:{id} failed: {}",
                        string(&job, "error", "unknown error")
                    );
                }
                _ => return Err(Error::Network("invalid job status".into())),
            }
        }
        jobs = pending;
        if !jobs.is_empty() {
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
    }
    if failed {
        return Err(Error::Input(
            "some jobs failed; inspect the requirements before retrying".into(),
        ));
    }
    Ok(())
}

fn metadata_body(
    title: Option<String>,
    body: Option<PathBuf>,
    priority: Option<u8>,
) -> Result<Map<String, Value>> {
    let mut payload = Map::new();
    if let Some(title) = title {
        payload.insert("title".to_string(), json!(title));
    }
    if let Some(path) = body {
        let description = std::fs::read_to_string(&path)
            .map_err(|err| Error::Io(format!("could not read {}: {err}", path.display())))?;
        payload.insert("description".to_string(), json!(description));
    }
    if let Some(priority) = priority {
        payload.insert("priority".to_string(), json!(priority));
    }
    if payload.is_empty() {
        return Err(Error::Input(
            "pass --title, --body or --priority to update a requirement".to_string(),
        ));
    }
    Ok(payload)
}

fn collection_path(project: &str) -> String {
    format!("/projects/{}/requirements", segment(project))
}

fn requirement_path(id: &str) -> String {
    format!("/requirements/{}", segment(id))
}

fn project_slug(requirement: &Value) -> &str {
    requirement
        .get("project")
        .map(|project| string(project, "slug", "?"))
        .unwrap_or("?")
}

fn segment(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            encoded.push(byte as char);
        } else {
            let _ = write!(encoded, "%{byte:02X}");
        }
    }
    encoded
}

fn summary(requirement: &Value, project: &str) -> String {
    format!(
        "{}  [{}]  priority:{}  project:{}  parent:{}  children:{}  {}",
        string(requirement, "id", "?"),
        string(requirement, "status", "?"),
        requirement.get("priority").unwrap_or(&Value::Null),
        project,
        string(requirement, "parent_id", "none"),
        requirement
            .get("child_count")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        string(requirement, "title", "(untitled)")
    )
}

fn detail(requirement: &Value) -> String {
    let mut output = format!("project: {}\n", project_slug(requirement));
    for field in [
        "id",
        "project_id",
        "parent_id",
        "title",
        "status",
        "archived_at",
    ] {
        let _ = writeln!(output, "{field}: {}", string(requirement, field, "none"));
    }
    let _ = writeln!(
        output,
        "child_count: {}",
        requirement.get("child_count").unwrap_or(&Value::Null)
    );
    let _ = writeln!(
        output,
        "priority: {}",
        requirement.get("priority").unwrap_or(&Value::Null)
    );
    if let Some(workload) = requirement.get("workload") {
        let _ = writeln!(
            output,
            "workload (minutes; estimates exclude unestimated work):\n{}",
            serde_json::to_string_pretty(workload).unwrap_or_default()
        );
    }
    let documents = requirement.get("documents").and_then(Value::as_array);
    match documents {
        Some(documents) if !documents.is_empty() => {
            let _ = writeln!(output, "\ndocuments:");
            for document in documents {
                let title = document
                    .get("latest_revision")
                    .map(|revision| string(revision, "title", "(untitled)"))
                    .unwrap_or("(untitled)");
                let _ = writeln!(
                    output,
                    "  {}  [{}]  [{}]  {}",
                    string(document, "id", "?"),
                    string(document, "kind", "?"),
                    string(document, "status", "?"),
                    title
                );
            }
        }
        _ => {
            let _ = writeln!(output, "\ndocuments: none");
        }
    }
    let _ = writeln!(
        output,
        "\ndescription:\n{}",
        string(requirement, "description", "")
    );
    output
}

fn string<'a>(value: &'a Value, field: &str, fallback: &'a str) -> &'a str {
    value.get(field).and_then(Value::as_str).unwrap_or(fallback)
}

#[cfg(test)]
mod tests {
    #[test]
    fn prioritization_updates_one_requirement_and_waits_through_generic_jobs() {
        let server = StubServer::start(vec![
            Reply::json(202, json!({"data": {"id": 15, "status": "running"}})),
            Reply::json(200, json!({"data": {"id": 15, "status": "succeeded"}})),
            Reply::json(200, json!({"data": {"id": "req-id", "priority": 2}})),
        ]);
        prioritize(
            &client(&server),
            PrioritizeArgs {
                id: "req-id".into(),
                wait: true,
            },
        )
        .unwrap();
        let requests = server.requests();
        assert_eq!(requests.len(), 3);
        assert_eq!(requests[0].target, "/api/v1/requirements/req-id/prioritize");
        assert_eq!(requests[0].json(), json!({}));
        assert_eq!(requests[1].target, "/api/v1/jobs/15");
        assert_eq!(requests[2].target, "/api/v1/requirements/req-id");
    }

    #[test]
    fn failed_prioritization_does_not_retry_or_report_success() {
        let server = StubServer::start(vec![
            Reply::json(202, json!({"data": {"id": 15, "status": "running"}})),
            Reply::json(
                200,
                json!({"data": {"id": 15, "status": "failed", "error": "Requirement changed"}}),
            ),
        ]);
        assert!(matches!(
            prioritize(
                &client(&server),
                PrioritizeArgs {
                    id: "req-id".into(),
                    wait: true
                }
            ),
            Err(Error::Input(_))
        ));
        assert_eq!(server.requests().len(), 2);
    }

    use super::*;
    use crate::testing::{client, text_file, Reply, StubServer};
    use crate::{Cli, Command};
    use clap::Parser;

    #[test]
    fn bulk_estimation_uses_only_requirement_ids_and_waits_for_failures() {
        let server = StubServer::start(vec![
            Reply::json(
                202,
                json!({"data": [{"requirement_id": "a", "title": "A", "job": {"id": 9}, "reason": null}, {"requirement_id": "b", "job": null, "reason": "no_tasks"}]}),
            ),
            Reply::json(
                200,
                json!({"data": {"id": 9, "status": "failed", "error": "scope changed"}}),
            ),
        ]);
        assert!(estimate(
            &client(&server),
            EstimateArgs {
                ids: vec!["a".into(), "b".into()],
                wait: true
            }
        )
        .is_err());
        let requests = server.requests();
        assert_eq!(requests[0].target, "/api/v1/requirements/estimate");
        assert_eq!(requests[0].json(), json!({"requirement_ids": ["a", "b"]}));
        assert_eq!(requests[1].target, "/api/v1/jobs/9");
        assert!(
            Cli::try_parse_from(["rinto-pmo", "requirement", "estimate", "a", "b", "--wait"])
                .is_ok()
        );
        assert!(Cli::try_parse_from(["rinto-pmo", "requirement", "estimate"]).is_err());
        assert!(Cli::try_parse_from([
            "rinto-pmo",
            "requirement",
            "estimate",
            "a",
            "--project",
            "pmo"
        ])
        .is_err());
    }

    fn scope() -> RequirementArgs {
        RequirementArgs {
            id: "req-id".to_string(),
        }
    }

    #[test]
    fn global_and_project_hierarchy_lists_use_their_own_endpoints() {
        let server = StubServer::start(vec![
            Reply::json(
                200,
                json!({"data": [{"id": "req", "project": {"slug": "archived-system"}}]}),
            ),
            Reply::json(200, json!({"data": []})),
            Reply::json(200, json!({"data": []})),
        ]);
        let client = client(&server);
        list(
            &client,
            ListArgs {
                project: None,
                parent_id: None,
            },
        )
        .unwrap();
        list(
            &client,
            ListArgs {
                project: None,
                parent_id: Some("parent/id".into()),
            },
        )
        .unwrap();
        list(
            &client,
            ListArgs {
                project: Some("pmo".into()),
                parent_id: Some("all".into()),
            },
        )
        .unwrap();
        let requests = server.requests();
        assert_eq!(requests[0].target, "/api/v1/requirements");
        assert_eq!(
            requests[1].target,
            "/api/v1/requirements?parent_id=parent%2Fid"
        );
        assert_eq!(
            requests[2].target,
            "/api/v1/projects/pmo/requirements?parent_id=all"
        );
    }

    #[test]
    fn cli_requires_exactly_one_creation_scope_and_only_mutable_update_fields() {
        for args in [
            vec!["rinto-pmo", "requirement", "create", "--title", "Login"],
            vec![
                "rinto-pmo",
                "requirement",
                "create",
                "--project",
                "pmo",
                "--parent-id",
                "parent",
                "--title",
                "Login",
            ],
            vec!["rinto-pmo", "requirement", "documents", "req-id"],
            vec![
                "rinto-pmo",
                "requirement",
                "show",
                "req-id",
                "--project",
                "pmo",
            ],
            vec!["rinto-pmo", "requirement", "update", "req-id"],
            vec![
                "rinto-pmo",
                "requirement",
                "update",
                "req-id",
                "--parent-id",
                "other",
            ],
            vec![
                "rinto-pmo",
                "requirement",
                "create",
                "--project",
                "pmo",
                "--title",
                "Login",
                "--status",
                "active",
            ],
        ] {
            assert!(Cli::try_parse_from(args).is_err());
        }
        for args in [
            vec!["rinto-pmo", "requirement", "list", "--parent-id", "parent"],
            vec!["rinto-pmo", "requirement", "show", "req-id"],
            vec![
                "rinto-pmo",
                "requirement",
                "create",
                "--project",
                "pmo",
                "--title",
                "Login",
            ],
            vec![
                "rinto-pmo",
                "requirement",
                "create",
                "--parent-id",
                "parent",
                "--title",
                "Login",
            ],
        ] {
            assert!(Cli::try_parse_from(args).is_ok());
        }
        let parsed = Cli::try_parse_from([
            "rinto-pmo",
            "requirement",
            "update",
            "req-id",
            "--body",
            "description.md",
        ])
        .unwrap();
        assert!(matches!(
            parsed.command,
            Command::Requirement(RequirementCommand::Update(_))
        ));
    }

    #[test]
    fn creation_preserves_markdown_and_only_sends_parent_on_child_creation() {
        let server = StubServer::start(vec![
            Reply::json(201, json!({"data": {"id": "root"}})),
            Reply::json(201, json!({"data": {"id": "child"}})),
        ]);
        let client = client(&server);
        create(
            &client,
            CreateArgs {
                priority: None,
                project: Some("pmo".into()),
                title: "Login".into(),
                body: None,
                parent_id: None,
            },
        )
        .unwrap();
        let markdown = "## 目标\n\n保留 `quotes`、$变量和换行。\n";
        create(
            &client,
            CreateArgs {
                priority: None,
                project: None,
                title: "SMS".into(),
                body: Some(text_file(markdown)),
                parent_id: Some("root".into()),
            },
        )
        .unwrap();
        let requests = server.requests();
        assert_eq!(requests[0].method, "POST");
        assert_eq!(requests[0].target, "/api/v1/requirements");
        assert_eq!(requests[1].target, "/api/v1/requirements");
        assert_eq!(
            requests[0].json(),
            json!({"project_slug": "pmo", "title": "Login"})
        );
        assert_eq!(
            requests[1].json(),
            json!({"title": "SMS", "description": markdown, "parent_id": "root"})
        );
    }

    #[test]
    fn priority_only_updates_are_valid_and_sent_without_changing_content() {
        let parsed = Cli::try_parse_from([
            "rinto-pmo",
            "requirement",
            "update",
            "req-id",
            "--priority",
            "1",
        ])
        .unwrap();
        let Command::Requirement(RequirementCommand::Update(args)) = parsed.command else {
            panic!("unexpected command")
        };
        let server = StubServer::start(vec![Reply::json(
            200,
            json!({"data": {"id": "req-id", "priority": 1}}),
        )]);
        update(&client(&server), args).unwrap();
        assert_eq!(server.requests()[0].json(), json!({"priority": 1}));
        for value in ["0", "6", "normal"] {
            assert!(Cli::try_parse_from([
                "rinto-pmo",
                "requirement",
                "update",
                "req-id",
                "--priority",
                value
            ])
            .is_err());
        }
    }

    #[test]
    fn updates_distinguish_an_omitted_description_from_an_explicit_empty_file() {
        let server = StubServer::start(vec![
            Reply::json(200, json!({"data": {"id": "req-id"}})),
            Reply::json(200, json!({"data": {"id": "req-id"}})),
        ]);
        let client = client(&server);
        update(
            &client,
            UpdateArgs {
                priority: None,
                requirement: scope(),
                title: Some("New title".into()),
                body: None,
            },
        )
        .unwrap();
        update(
            &client,
            UpdateArgs {
                priority: None,
                requirement: scope(),
                title: None,
                body: Some(text_file("")),
            },
        )
        .unwrap();
        let requests = server.requests();
        assert_eq!(requests[0].method, "PATCH");
        assert_eq!(requests[0].target, "/api/v1/requirements/req-id");
        assert_eq!(requests[0].json(), json!({"title": "New title"}));
        assert_eq!(requests[1].json(), json!({"description": ""}));
    }

    #[test]
    fn unreadable_files_and_empty_updates_fail_before_any_request() {
        let server = StubServer::start(vec![]);
        let client = client(&server);
        let directory = std::env::temp_dir();
        assert!(matches!(
            create(
                &client,
                CreateArgs {
                    priority: None,
                    project: Some("pmo".into()),
                    title: "Login".into(),
                    body: Some(directory),
                    parent_id: None
                }
            ),
            Err(Error::Io(_))
        ));
        assert!(matches!(
            update(
                &client,
                UpdateArgs {
                    priority: None,
                    requirement: scope(),
                    title: None,
                    body: None
                }
            ),
            Err(Error::Input(_))
        ));
        assert!(server.requests().is_empty());
    }

    #[test]
    fn show_includes_all_document_summaries_without_fetching_document_content() {
        let documents: Vec<_> = ["general", "rfc", "spec", "plan", "task"].iter().map(|kind|
            json!({"id": format!("doc-{kind}"), "kind": kind, "status": "draft", "latest_revision": {"title": format!("Title {kind}")}})
        ).collect();
        let requirement =
            json!({"id": "req-id", "documents": documents, "project": {"slug": "pmo"}});
        let server = StubServer::start(vec![Reply::json(200, json!({"data": requirement}))]);
        show(&client(&server), scope()).unwrap();
        assert_eq!(server.requests().len(), 1);
        assert_eq!(server.requests()[0].target, "/api/v1/requirements/req-id");
        let rendered = detail(&requirement);
        for kind in ["general", "rfc", "spec", "plan", "task"] {
            assert!(rendered.contains(&format!("doc-{kind}  [{kind}]  [draft]  Title {kind}")));
        }
        assert!(detail(&json!({"documents": []})).contains("documents: none"));
    }

    #[test]
    fn missing_requirements_and_edit_refusals_are_not_retried_or_hidden() {
        let server = StubServer::start(vec![Reply::json(
            404,
            json!({"error": "not_found", "message": "Not found"}),
        )]);
        assert!(matches!(
            show(&client(&server), scope()),
            Err(Error::Api { status: 404, .. })
        ));
        assert_eq!(server.requests().len(), 1);

        let server = StubServer::start(vec![Reply::json(
            422,
            json!({"error": "validation_error", "message": "Invalid", "details": {"status": ["only unarchived drafts can be edited"]}}),
        )]);
        let error = update(
            &client(&server),
            UpdateArgs {
                priority: None,
                requirement: scope(),
                title: Some("Change".into()),
                body: None,
            },
        )
        .unwrap_err();
        assert!(error
            .to_string()
            .contains("only unarchived drafts can be edited"));
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn show_escapes_path_segments_and_keeps_archive_and_description_context() {
        let server = StubServer::start(vec![Reply::json(200, json!({"data": {}}))]);
        show(
            &client(&server),
            RequirementArgs {
                id: "id/with?query".into(),
            },
        )
        .unwrap();
        assert_eq!(
            server.requests()[0].target,
            "/api/v1/requirements/id%2Fwith%3Fquery"
        );
        let rendered = detail(
            &json!({"id": "req-id", "project": {"slug": "pmo"}, "parent_id": "parent", "status": "draft", "archived_at": "2026-10-05T00:00:00Z", "child_count": 2, "description": "## 目标\n\n正文\n"}),
        );
        assert!(rendered.contains("project: pmo\n"));
        assert!(rendered.contains("parent_id: parent\n"));
        assert!(rendered.contains("archived_at: 2026-10-05T00:00:00Z\n"));
        assert!(rendered.contains("child_count: 2\n"));
        assert!(rendered.contains("## 目标\n\n正文\n"));
    }
}
