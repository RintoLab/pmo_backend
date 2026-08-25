use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use serde_json::{json, Value};

use crate::client::{self, Client};
use crate::config::Config;
use crate::error::{Error, Result};

#[derive(Subcommand)]
pub enum TaskCommand {
    /// List a project's tasks, oldest first
    List(ListArgs),
    /// Show all fields of one task
    Show(TaskIdArgs),
    /// Show a project's task counts and estimates
    Stats(ProjectArgs),
    /// Print the JSON shape that create, update and split read
    Schema(SchemaArgs),
    /// Create a task from an API-shaped JSON object
    Create(CreateArgs),
    /// Update a task from an API-shaped JSON object
    Update(UpdateArgs),
    /// Assign a task to an actor, replacing its current assignee
    Assign(AssignArgs),
    /// Claim an unassigned task as the configured human user
    Claim(TaskIdArgs),
    /// Return a task to the unassigned pool without changing its status
    Release(TaskIdArgs),
    /// Turn a work task into a summary, optionally creating children
    Split(SplitArgs),
    /// Move an assigned open task to in_progress
    Start(TaskIdArgs),
    /// Move an in_progress task to done
    Complete(TaskIdArgs),
    /// Cancel outstanding work while retaining its record
    Cancel(TaskIdArgs),
    /// Return a done or cancelled task to open
    Reopen(TaskIdArgs),
    /// Permanently delete a task that should never have existed
    Delete(TaskIdArgs),
}

#[derive(Args)]
pub struct ProjectArgs {
    /// Project slug
    project_slug: String,
}

#[derive(Args)]
pub struct TaskIdArgs {
    /// Task id
    task_id: String,
}

#[derive(Args)]
pub struct ListArgs {
    /// Project slug
    project_slug: String,

    /// Only work or summary nodes
    #[arg(long, value_name = "work|summary")]
    kind: Option<String>,

    /// Only one status
    #[arg(long, value_name = "open|in_progress|done|cancelled")]
    status: Option<String>,

    /// Only children of this task; pass `none` for WBS roots
    #[arg(long, value_name = "UUID|none")]
    parent_id: Option<String>,

    /// Only tasks owned by this actor; pass `none` for unassigned tasks
    #[arg(long, value_name = "UUID|none", conflicts_with = "mine")]
    assignee_id: Option<String>,

    /// Only tasks owned by the human actor in this CLI's configuration
    #[arg(long)]
    mine: bool,

    /// Only tasks implementing this document
    #[arg(long, value_name = "UUID")]
    document_id: Option<String>,

    /// true for outstanding work, false for finished work
    #[arg(long, value_name = "BOOL")]
    live: Option<bool>,

    /// true for overdue outstanding work
    #[arg(long, value_name = "BOOL")]
    overdue: Option<bool>,
}

#[derive(Args)]
pub struct SchemaArgs {
    /// Which write to describe: create, update or split; omit for all of them
    #[arg(value_name = "SHAPE")]
    shape: Option<String>,
}

#[derive(Args)]
pub struct CreateArgs {
    /// Project slug
    project_slug: String,

    /// JSON object; run `task schema create` for its fields and an example
    #[arg(long, value_name = "FILE")]
    input: PathBuf,
}

#[derive(Args)]
pub struct UpdateArgs {
    /// Task id
    task_id: String,

    /// JSON object; run `task schema update` for its fields and an example
    #[arg(long, value_name = "FILE")]
    input: PathBuf,
}

#[derive(Args)]
pub struct AssignArgs {
    /// Task id
    task_id: String,

    /// Actor who should own the task
    #[arg(long, value_name = "UUID")]
    actor_id: String,
}

#[derive(Args)]
pub struct SplitArgs {
    /// Task id
    task_id: String,

    /// JSON object shaped as {"children": [...]}; omit to create an empty summary.
    /// Run `task schema split` for the fields a child takes
    #[arg(long, value_name = "FILE")]
    input: Option<PathBuf>,
}

pub fn run(command: TaskCommand) -> Result<()> {
    let config = Config::load()?;
    let client = &Client::new(config.api(), config.token()?)?;

    match command {
        TaskCommand::List(args) => list(client, &config, args),
        TaskCommand::Show(args) => show(client, args),
        TaskCommand::Stats(args) => stats(client, args),
        TaskCommand::Schema(args) => schema(client, args),
        TaskCommand::Create(args) => create(client, args),
        TaskCommand::Update(args) => update(client, args),
        TaskCommand::Assign(args) => assign(client, args),
        TaskCommand::Claim(args) => claim(client, args),
        TaskCommand::Release(args) => release(client, args),
        TaskCommand::Split(args) => split(client, args),
        TaskCommand::Start(args) => transition(client, args, "start", "started"),
        TaskCommand::Complete(args) => transition(client, args, "complete", "completed"),
        TaskCommand::Cancel(args) => transition(client, args, "cancel", "cancelled"),
        TaskCommand::Reopen(args) => transition(client, args, "reopen", "reopened"),
        TaskCommand::Delete(args) => delete(client, args),
    }
}

/// Reading the backlog asks nothing about who is reading it.
///
/// `--mine` is the one filter that does, and it is resolved here rather than
/// at dispatch so that the question is only put when it was asked. The agent
/// inside a topic has a token and no `actor_id` -- the backend spawns it with
/// an environment and never writes it a config file -- so demanding one up
/// front made every list, filtered or not, refuse in the environment that has
/// the most reason to read the backlog.
fn list(client: &Client, config: &Config, args: ListArgs) -> Result<()> {
    let mine = if args.mine {
        Some(config.actor_id()?)
    } else {
        None
    };
    let path = format!("/projects/{}/tasks", args.project_slug);
    let query = list_query(&args, mine);
    let query_refs: Vec<(&str, &str)> = query
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect();
    let tasks = client::data(client.get(&path, &query_refs)?)?;
    let tasks = tasks.as_array().map(Vec::as_slice).unwrap_or_default();

    if tasks.is_empty() {
        println!("no tasks");
        return Ok(());
    }

    for task in tasks {
        println!("{}", task_summary(task));
    }

    Ok(())
}

/// `mine` is the actor `--mine` resolved to, and `None` when it was not passed.
/// It arrives already resolved because working out whether to ask for it is the
/// caller's job -- see `list`. The two are mutually exclusive at the parser
/// (`conflicts_with`), so at most one of them ever fills `assignee_id`.
fn list_query(args: &ListArgs, mine: Option<&str>) -> Vec<(String, String)> {
    let mut query = Vec::new();
    push_query(&mut query, "kind", args.kind.as_deref());
    push_query(&mut query, "status", args.status.as_deref());
    push_query(&mut query, "parent_id", args.parent_id.as_deref());
    push_query(
        &mut query,
        "assignee_id",
        mine.or(args.assignee_id.as_deref()),
    );
    push_query(&mut query, "document_id", args.document_id.as_deref());
    push_query(
        &mut query,
        "live",
        args.live.map(|value| if value { "true" } else { "false" }),
    );
    push_query(
        &mut query,
        "overdue",
        args.overdue
            .map(|value| if value { "true" } else { "false" }),
    );
    query
}

fn push_query(query: &mut Vec<(String, String)>, key: &str, value: Option<&str>) {
    if let Some(value) = value {
        query.push((key.to_string(), value.to_string()));
    }
}

fn show(client: &Client, args: TaskIdArgs) -> Result<()> {
    let task = get_task(client, &args.task_id)?;
    print!("{}", task_detail(&task));
    Ok(())
}

fn stats(client: &Client, args: ProjectArgs) -> Result<()> {
    let path = format!("/projects/{}/tasks/stats", args.project_slug);
    let stats = client::data(client.get(&path, &[])?)?;
    let rendered = serde_json::to_string_pretty(&stats)
        .map_err(|err| Error::Network(format!("could not render task stats: {err}")))?;
    println!("{rendered}");
    Ok(())
}

/// What `--input` has to contain, asked rather than remembered.
///
/// The three write commands each read a JSON file, and nothing in this binary
/// says what belongs in one -- the shape lives in the server's `Task` module,
/// with the enums, the estimate ceiling and the fields that look writable and
/// are not. Printing a copy from here would be printing whatever was true when
/// this binary was built, which is not the same thing as what the server across
/// the wire will accept.
fn schema(client: &Client, args: SchemaArgs) -> Result<()> {
    let schemas = client::data(client.get("/tasks/schema", &[])?)?;
    let selected = select_shape(&schemas, args.shape.as_deref())?;
    let rendered = serde_json::to_string_pretty(selected)
        .map_err(|err| Error::Network(format!("could not render the task schema: {err}")))?;
    println!("{rendered}");
    Ok(())
}

/// Which shapes exist is the server's answer too, so an unknown name is
/// refused with the list the response actually carried rather than one
/// compiled in here -- a shape the server learns tomorrow is then reachable by
/// a binary built today.
fn select_shape<'a>(schemas: &'a Value, shape: Option<&str>) -> Result<&'a Value> {
    let Some(shape) = shape else {
        return Ok(schemas);
    };

    schemas.get(shape).ok_or_else(|| {
        Error::Input(format!(
            "no shape named \"{shape}\"; the server describes: {}",
            shape_names(schemas)
        ))
    })
}

fn shape_names(schemas: &Value) -> String {
    schemas
        .as_object()
        .map(|shapes| shapes.keys().cloned().collect::<Vec<_>>().join(", "))
        .unwrap_or_default()
}

fn create(client: &Client, args: CreateArgs) -> Result<()> {
    let payload = read_object(&args.input)?;
    let path = format!("/projects/{}/tasks", args.project_slug);
    let task = client::data(client.post(&path, payload)?)?;
    print_result("created", &task);
    Ok(())
}

fn update(client: &Client, args: UpdateArgs) -> Result<()> {
    let payload = read_object(&args.input)?;
    let path = format!("/tasks/{}", args.task_id);
    let task = client::data(client.patch(&path, payload)?)?;
    print_result("updated", &task);
    Ok(())
}

fn assign(client: &Client, args: AssignArgs) -> Result<()> {
    let path = format!("/tasks/{}/assign", args.task_id);
    let task = client::data(client.post(&path, json!({"actor_id": args.actor_id}))?)?;
    print_result("assigned", &task);
    Ok(())
}

/// Claiming names nobody: the server credits it to whoever the token belongs
/// to. `assign` still names a target, because it hands work to somebody else.
fn claim(client: &Client, args: TaskIdArgs) -> Result<()> {
    let path = format!("/tasks/{}/claim", args.task_id);
    let task = client::data(client.post(&path, json!({}))?)?;
    print_result("claimed", &task);
    Ok(())
}

fn release(client: &Client, args: TaskIdArgs) -> Result<()> {
    let path = format!("/tasks/{}/release", args.task_id);
    let task = client::data(client.post(&path, json!({}))?)?;
    print_result("released", &task);
    Ok(())
}

fn split(client: &Client, args: SplitArgs) -> Result<()> {
    let payload = match args.input {
        Some(path) => read_object(&path)?,
        None => json!({}),
    };
    let path = format!("/tasks/{}/split", args.task_id);
    let response = client.post(&path, payload)?;
    let task = response
        .get("data")
        .ok_or_else(|| Error::Network("response had no \"data\" field".to_string()))?;
    let children = response
        .get("children")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();

    println!(
        "split task {} into {} child task(s)",
        string(task, "id", "?"),
        children.len()
    );
    for child in children {
        println!(
            "  {}  {}",
            string(child, "id", "?"),
            string(child, "title", "(untitled)")
        );
    }
    Ok(())
}

fn transition(client: &Client, args: TaskIdArgs, event: &str, past_tense: &str) -> Result<()> {
    let path = format!("/tasks/{}/{event}", args.task_id);
    let task = client::data(client.post(&path, json!({}))?)?;
    print_result(past_tense, &task);
    Ok(())
}

fn delete(client: &Client, args: TaskIdArgs) -> Result<()> {
    let path = format!("/tasks/{}", args.task_id);
    client.delete(&path)?;
    println!("deleted task {}", args.task_id);
    Ok(())
}

fn get_task(client: &Client, task_id: &str) -> Result<Value> {
    let path = format!("/tasks/{task_id}");
    client::data(client.get(&path, &[])?)
}

fn read_object(path: &Path) -> Result<Value> {
    let source = std::fs::read_to_string(path)
        .map_err(|err| Error::Io(format!("could not read {}: {err}", path.display())))?;
    let payload: Value = serde_json::from_str(&source)
        .map_err(|err| Error::Input(format!("{} is not valid JSON: {err}", path.display())))?;

    if !payload.is_object() {
        return Err(Error::Input(format!(
            "{} must contain a JSON object",
            path.display()
        )));
    }

    Ok(payload)
}

fn print_result(verb: &str, task: &Value) {
    println!(
        "{verb} task {} ({})",
        string(task, "id", "?"),
        string(task, "status", "unknown status")
    );
}

fn task_summary(task: &Value) -> String {
    format!(
        "{}  {}/{}  assignee={}  {}",
        string(task, "id", "?"),
        string(task, "kind", "?"),
        string(task, "status", "?"),
        nullable_string(task, "assignee_id"),
        string(task, "title", "(untitled)")
    )
}

fn task_detail(task: &Value) -> String {
    let mut output = String::new();
    let fields = [
        ("id", string(task, "id", "?")),
        ("title", string(task, "title", "(untitled)")),
        ("project_id", string(task, "project_id", "?")),
        ("kind", string(task, "kind", "?")),
        ("status", string(task, "status", "?")),
        ("assignee_id", nullable_string(task, "assignee_id")),
        ("parent_id", nullable_string(task, "parent_id")),
        ("document_id", nullable_string(task, "document_id")),
        ("due_on", nullable_string(task, "due_on")),
        ("assigned_at", nullable_string(task, "assigned_at")),
        ("started_at", nullable_string(task, "started_at")),
        ("completed_at", nullable_string(task, "completed_at")),
        ("inserted_at", nullable_string(task, "inserted_at")),
        ("updated_at", nullable_string(task, "updated_at")),
    ];

    for (label, value) in fields {
        let _ = writeln!(output, "{label}: {value}");
    }

    let unestimated_tasks = task
        .get("unestimated_tasks")
        .filter(|value| !value.is_null())
        .map(Value::to_string)
        .unwrap_or_else(|| "none".to_string());
    let _ = writeln!(output, "estimate: {}", estimate(task));
    let _ = writeln!(output, "unestimated_tasks: {unestimated_tasks}");
    let description = task
        .get("description")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or("none");
    let _ = writeln!(output, "description:\n{description}");
    output
}

fn estimate(task: &Value) -> String {
    let Some(estimate) = task.get("estimate").and_then(Value::as_object) else {
        return "none".to_string();
    };

    format!(
        "optimistic={} likely={} pessimistic={} expected={} minutes",
        estimate
            .get("optimistic")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        estimate.get("likely").and_then(Value::as_u64).unwrap_or(0),
        estimate
            .get("pessimistic")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        estimate
            .get("expected")
            .and_then(Value::as_u64)
            .unwrap_or(0)
    )
}

fn string<'a>(value: &'a Value, field: &str, fallback: &'a str) -> &'a str {
    value.get(field).and_then(Value::as_str).unwrap_or(fallback)
}

fn nullable_string<'a>(value: &'a Value, field: &str) -> &'a str {
    string(value, field, "none")
}

#[cfg(test)]
mod tests {
    use super::{list_query, select_shape, task_detail, task_summary, ListArgs};
    use serde_json::json;

    #[test]
    fn a_named_shape_is_printed_on_its_own() {
        let schemas = json!({"create": {"title": "TaskCreateInput"}, "update": {}});

        assert_eq!(
            select_shape(&schemas, Some("create")).unwrap(),
            &json!({"title": "TaskCreateInput"})
        );
    }

    #[test]
    fn no_shape_prints_every_one_of_them() {
        let schemas = json!({"create": {}, "update": {}, "split": {}});

        assert_eq!(select_shape(&schemas, None).unwrap(), &schemas);
    }

    /// The names come out of the response, so a server that grows a fourth
    /// shape can be asked for it without a new binary.
    #[test]
    fn an_unknown_shape_answers_with_the_ones_the_server_sent() {
        let schemas = json!({"create": {}, "update": {}, "split": {}});
        let error = select_shape(&schemas, Some("complete")).unwrap_err();

        assert!(error.to_string().contains("create, split, update"));
    }

    #[test]
    fn list_passes_every_filter_using_the_api_names() {
        let args = ListArgs {
            project_slug: "demo".to_string(),
            kind: Some("work".to_string()),
            status: Some("open".to_string()),
            parent_id: Some("none".to_string()),
            assignee_id: Some("none".to_string()),
            mine: false,
            document_id: Some("doc-id".to_string()),
            live: Some(true),
            overdue: Some(false),
        };

        assert_eq!(
            list_query(&args, None),
            vec![
                ("kind".to_string(), "work".to_string()),
                ("status".to_string(), "open".to_string()),
                ("parent_id".to_string(), "none".to_string()),
                ("assignee_id".to_string(), "none".to_string()),
                ("document_id".to_string(), "doc-id".to_string()),
                ("live".to_string(), "true".to_string()),
                ("overdue".to_string(), "false".to_string()),
            ]
        );
    }

    /// The environment that has no `actor_id` at all: an unfiltered list must
    /// come out as a query that never mentions one.
    #[test]
    fn a_list_without_mine_asks_about_no_actor() {
        let args = ListArgs {
            project_slug: "demo".to_string(),
            kind: None,
            status: Some("open".to_string()),
            parent_id: None,
            assignee_id: None,
            mine: false,
            document_id: None,
            live: None,
            overdue: None,
        };

        assert_eq!(
            list_query(&args, None),
            vec![("status".to_string(), "open".to_string())]
        );
    }

    #[test]
    fn mine_uses_the_configured_human_actor() {
        let args = ListArgs {
            project_slug: "demo".to_string(),
            kind: Some("work".to_string()),
            status: None,
            parent_id: None,
            assignee_id: None,
            mine: true,
            document_id: None,
            live: Some(true),
            overdue: None,
        };

        assert_eq!(
            list_query(&args, Some("human-id")),
            vec![
                ("kind".to_string(), "work".to_string()),
                ("assignee_id".to_string(), "human-id".to_string()),
                ("live".to_string(), "true".to_string())
            ]
        );
    }

    #[test]
    fn summary_is_compact_but_keeps_claiming_fields() {
        let task = json!({
            "id": "task-id",
            "kind": "work",
            "status": "open",
            "assignee_id": null,
            "title": "Implement login"
        });

        assert_eq!(
            task_summary(&task),
            "task-id  work/open  assignee=none  Implement login"
        );
    }

    #[test]
    fn detail_exposes_the_document_pointer_and_description() {
        let task = json!({
            "id": "task-id",
            "project_id": "project-id",
            "kind": "work",
            "status": "open",
            "title": "Implement login",
            "document_id": "document-id",
            "description": "Follow the login spec"
        });
        let detail = task_detail(&task);

        assert!(detail.contains("document_id: document-id"));
        assert!(detail.contains("description:\nFollow the login spec"));
    }
}
