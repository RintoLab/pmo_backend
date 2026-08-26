use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use serde_json::{json, Value};

use crate::client::{self, Client};
use crate::config::Config;
use crate::error::{Error, Result};

#[derive(Subcommand)]
pub enum TaskCommand {
    /// List tasks, one project's or every project's, oldest first
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
    /// Move an in_progress task to done, optionally recording what it took
    Complete(CompleteArgs),
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
    /// Project slug; omit to list every project's tasks as one pool
    project_slug: Option<String>,

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

    /// Only work at this priority, 1 highest
    #[arg(long, value_name = "1-5")]
    priority: Option<u8>,

    /// true for work selected into a week, false for the backlog
    #[arg(long, value_name = "BOOL")]
    scheduled: Option<bool>,

    /// `plan` is the order the board fills a week in; `oldest` is the default
    #[arg(long, value_name = "oldest|plan")]
    sort: Option<String>,
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

#[derive(Args)]
pub struct CompleteArgs {
    /// Task id
    task_id: String,

    /// How long the work actually took, in minutes; omit to leave it as it is
    #[arg(long, value_name = "MINUTES")]
    actual_minutes: Option<u32>,
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
        TaskCommand::Complete(args) => complete(client, args),
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
    // No slug is the whole pool. A person's capacity spans every project they
    // work in, so "what is there to pick up" is a question about all of them,
    // and asking it project by project would leave the merge order here.
    let path = match args.project_slug.as_deref() {
        Some(project_slug) => format!("/projects/{project_slug}/tasks"),
        None => "/tasks".to_string(),
    };
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
    if let Some(priority) = args.priority {
        query.push(("priority".to_string(), priority.to_string()));
    }
    push_query(
        &mut query,
        "scheduled",
        args.scheduled
            .map(|value| if value { "true" } else { "false" }),
    );
    push_query(&mut query, "sort", args.sort.as_deref());
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

/// Finishing and saying what it took are one act.
///
/// The number is the only thing an executor produces that this system consumes
/// -- it is what a later estimate is calibrated against -- and requiring a JSON
/// file and a second call to record it is how it ends up never being recorded.
/// Absent leaves whatever was already stored, so a caller that does not know
/// simply does not say.
fn complete(client: &Client, args: CompleteArgs) -> Result<()> {
    let path = format!("/tasks/{}/complete", args.task_id);
    let task = client::data(client.post(&path, complete_body(args.actual_minutes))?)?;
    print_result("completed", &task);
    Ok(())
}

fn complete_body(actual_minutes: Option<u32>) -> Value {
    match actual_minutes {
        Some(minutes) => json!({"actual_minutes": minutes}),
        None => json!({}),
    }
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
    use super::{complete_body, list_query, select_shape, task_detail, task_summary, ListArgs};
    use serde_json::json;

    /// An empty body means "leave what is stored", which is not the same as
    /// sending null -- somebody may have recorded the minutes already.
    #[test]
    fn completing_without_a_duration_says_nothing_about_one() {
        assert_eq!(complete_body(None), json!({}));
        assert_eq!(complete_body(Some(90)), json!({"actual_minutes": 90}));
    }

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

    /// Every filter off, so a test names only what it is about.
    fn no_filters() -> ListArgs {
        ListArgs {
            project_slug: Some("demo".to_string()),
            kind: None,
            status: None,
            parent_id: None,
            assignee_id: None,
            mine: false,
            document_id: None,
            live: None,
            overdue: None,
            priority: None,
            scheduled: None,
            sort: None,
        }
    }

    #[test]
    fn list_passes_every_filter_using_the_api_names() {
        let args = ListArgs {
            kind: Some("work".to_string()),
            status: Some("open".to_string()),
            parent_id: Some("none".to_string()),
            assignee_id: Some("none".to_string()),
            document_id: Some("doc-id".to_string()),
            live: Some(true),
            overdue: Some(false),
            priority: Some(2),
            scheduled: Some(false),
            sort: Some("plan".to_string()),
            ..no_filters()
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
                ("priority".to_string(), "2".to_string()),
                ("scheduled".to_string(), "false".to_string()),
                ("sort".to_string(), "plan".to_string()),
            ]
        );
    }

    /// The environment that has no `actor_id` at all: an unfiltered list must
    /// come out as a query that never mentions one.
    #[test]
    fn a_list_without_mine_asks_about_no_actor() {
        let args = ListArgs {
            status: Some("open".to_string()),
            ..no_filters()
        };

        assert_eq!(
            list_query(&args, None),
            vec![("status".to_string(), "open".to_string())]
        );
    }

    #[test]
    fn mine_uses_the_configured_human_actor() {
        let args = ListArgs {
            kind: Some("work".to_string()),
            mine: true,
            live: Some(true),
            ..no_filters()
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

    /// What each command actually puts on the wire.
    ///
    /// These are the tests the CLI did not have: every command below was
    /// reachable only by running the binary against a live server, so a wrong
    /// path or a body the API does not accept was something a person found out
    /// in production. The stub server is real HTTP -- see `crate::testing`.
    mod api {
        use super::super::{
            assign, claim, complete, create, delete, list, release, schema, split, stats,
            transition, update, AssignArgs, CompleteArgs, CreateArgs, ListArgs, ProjectArgs,
            SchemaArgs, SplitArgs, TaskIdArgs, UpdateArgs,
        };
        use crate::config::Config;
        use crate::testing::{client, json_file, Reply, StubServer};
        use serde_json::json;

        fn task_reply() -> Reply {
            Reply::json(200, json!({"data": {"id": "task-id", "status": "open"}}))
        }

        fn task_id(id: &str) -> TaskIdArgs {
            TaskIdArgs {
                task_id: id.to_string(),
            }
        }

        fn empty_list_args(project: Option<&str>) -> ListArgs {
            ListArgs {
                project_slug: project.map(str::to_string),
                ..super::no_filters()
            }
        }

        /// The §4.1 fix, seen from the wire: `--mine` resolves the configured
        /// human and nothing else asks about an actor.
        #[test]
        fn mine_filters_by_the_configured_actor() {
            let server = StubServer::start(vec![Reply::json(200, json!({"data": []}))]);
            let config = Config::for_test(server.base_url(), Some("human-id"), None);
            let args = ListArgs {
                mine: true,
                live: Some(true),
                ..empty_list_args(Some("demo"))
            };

            list(&client(&server), &config, args).unwrap();

            assert_eq!(
                server.only_request()[0].target,
                "/api/v1/projects/demo/tasks?assignee_id=human-id&live=true"
            );
        }

        /// No slug is the pool across every project, which is where "what can
        /// I pick up" is answered -- capacity spans all of them.
        #[test]
        fn no_project_asks_the_cross_project_endpoint() {
            let server = StubServer::start(vec![Reply::json(200, json!({"data": []}))]);
            let config = Config::for_test(server.base_url(), None, None);
            let args = ListArgs {
                assignee_id: Some("none".to_string()),
                live: Some(true),
                sort: Some("plan".to_string()),
                ..empty_list_args(None)
            };

            list(&client(&server), &config, args).unwrap();

            assert_eq!(
                server.only_request()[0].target,
                "/api/v1/tasks?assignee_id=none&live=true&sort=plan"
            );
        }

        #[test]
        fn the_backlog_is_a_filter_rather_than_a_status() {
            let server = StubServer::start(vec![Reply::json(200, json!({"data": []}))]);
            let config = Config::for_test(server.base_url(), None, None);
            let args = ListArgs {
                scheduled: Some(false),
                priority: Some(1),
                ..empty_list_args(None)
            };

            list(&client(&server), &config, args).unwrap();

            assert_eq!(
                server.only_request()[0].target,
                "/api/v1/tasks?priority=1&scheduled=false"
            );
        }

        /// The environment with no `actor_id` at all -- an unfiltered list has
        /// to reach the server rather than fail before it.
        #[test]
        fn a_plain_list_works_without_a_configured_actor() {
            let server = StubServer::start(vec![Reply::json(200, json!({"data": []}))]);
            let config = Config::for_test(server.base_url(), None, Some("conversation-id"));

            list(&client(&server), &config, empty_list_args(Some("demo"))).unwrap();

            assert_eq!(
                server.only_request()[0].target,
                "/api/v1/projects/demo/tasks"
            );
        }

        #[test]
        fn stats_are_scoped_to_a_project() {
            let server = StubServer::start(vec![Reply::json(200, json!({"data": {"total": 0}}))]);

            stats(
                &client(&server),
                ProjectArgs {
                    project_slug: "demo".to_string(),
                },
            )
            .unwrap();

            assert_eq!(
                server.only_request()[0].target,
                "/api/v1/projects/demo/tasks/stats"
            );
        }

        #[test]
        fn the_schema_is_fetched_rather_than_printed_from_here() {
            let server = StubServer::start(vec![Reply::json(
                200,
                json!({"data": {"create": {"title": "TaskCreateInput"}}}),
            )]);

            schema(
                &client(&server),
                SchemaArgs {
                    shape: Some("create".to_string()),
                },
            )
            .unwrap();

            let requests = server.only_request();
            assert_eq!(requests[0].method, "GET");
            assert_eq!(requests[0].target, "/api/v1/tasks/schema");
        }

        #[test]
        fn create_posts_the_file_under_the_project() {
            let server = StubServer::start(vec![Reply::json(201, json!({"data": {"id": "new"}}))]);
            let input = json_file(json!({"title": "Wire it up", "priority": 2}));

            create(
                &client(&server),
                CreateArgs {
                    project_slug: "demo".to_string(),
                    input,
                },
            )
            .unwrap();

            let requests = server.only_request();
            assert_eq!(requests[0].method, "POST");
            assert_eq!(requests[0].target, "/api/v1/projects/demo/tasks");
            assert_eq!(
                requests[0].json(),
                json!({"title": "Wire it up", "priority": 2})
            );
        }

        #[test]
        fn update_patches_the_task_itself() {
            let server = StubServer::start(vec![task_reply()]);
            let input = json_file(json!({"planned_start_on": null}));

            update(
                &client(&server),
                UpdateArgs {
                    task_id: "task-id".to_string(),
                    input,
                },
            )
            .unwrap();

            let requests = server.only_request();
            assert_eq!(requests[0].method, "PATCH");
            assert_eq!(requests[0].target, "/api/v1/tasks/task-id");
            assert_eq!(requests[0].json(), json!({"planned_start_on": null}));
        }

        /// Claiming names nobody: the server credits the token's owner, and a
        /// body carrying an actor would be the client deciding instead.
        #[test]
        fn claim_sends_an_empty_body_and_assign_names_a_target() {
            let server = StubServer::start(vec![task_reply(), task_reply(), task_reply()]);
            let client = client(&server);

            claim(&client, task_id("task-id")).unwrap();
            release(&client, task_id("task-id")).unwrap();
            assign(
                &client,
                AssignArgs {
                    task_id: "task-id".to_string(),
                    actor_id: "other-actor".to_string(),
                },
            )
            .unwrap();

            let requests = server.requests();
            assert_eq!(requests[0].target, "/api/v1/tasks/task-id/claim");
            assert_eq!(requests[0].json(), json!({}));
            assert_eq!(requests[1].target, "/api/v1/tasks/task-id/release");
            assert_eq!(requests[2].target, "/api/v1/tasks/task-id/assign");
            assert_eq!(requests[2].json(), json!({"actor_id": "other-actor"}));
        }

        #[test]
        fn every_event_posts_to_its_own_endpoint() {
            let server = StubServer::start(vec![task_reply(), task_reply(), task_reply()]);
            let client = client(&server);

            transition(&client, task_id("task-id"), "start", "started").unwrap();
            transition(&client, task_id("task-id"), "cancel", "cancelled").unwrap();
            transition(&client, task_id("task-id"), "reopen", "reopened").unwrap();

            let requests = server.requests();
            let targets: Vec<&str> = requests
                .iter()
                .map(|request| request.target.as_str())
                .collect();

            assert_eq!(
                targets,
                vec![
                    "/api/v1/tasks/task-id/start",
                    "/api/v1/tasks/task-id/cancel",
                    "/api/v1/tasks/task-id/reopen"
                ]
            );
        }

        #[test]
        fn completing_carries_the_recorded_minutes_when_there_are_any() {
            let server = StubServer::start(vec![task_reply(), task_reply()]);
            let client = client(&server);

            complete(
                &client,
                CompleteArgs {
                    task_id: "task-id".to_string(),
                    actual_minutes: Some(90),
                },
            )
            .unwrap();
            complete(
                &client,
                CompleteArgs {
                    task_id: "task-id".to_string(),
                    actual_minutes: None,
                },
            )
            .unwrap();

            let requests = server.requests();
            assert_eq!(requests[0].target, "/api/v1/tasks/task-id/complete");
            assert_eq!(requests[0].json(), json!({"actual_minutes": 90}));
            assert_eq!(requests[1].json(), json!({}));
        }

        #[test]
        fn split_sends_the_children_or_nothing_at_all() {
            let server = StubServer::start(vec![
                Reply::json(
                    200,
                    json!({"data": {"id": "task-id"}, "children": [{"id": "child", "title": "One"}]}),
                ),
                Reply::json(200, json!({"data": {"id": "task-id"}, "children": []})),
            ]);
            let client = client(&server);

            split(
                &client,
                SplitArgs {
                    task_id: "task-id".to_string(),
                    input: Some(json_file(json!({"children": [{"title": "One"}]}))),
                },
            )
            .unwrap();
            split(
                &client,
                SplitArgs {
                    task_id: "task-id".to_string(),
                    input: None,
                },
            )
            .unwrap();

            let requests = server.requests();
            assert_eq!(requests[0].target, "/api/v1/tasks/task-id/split");
            assert_eq!(requests[0].json(), json!({"children": [{"title": "One"}]}));
            assert_eq!(requests[1].json(), json!({}));
        }

        #[test]
        fn delete_uses_the_method_rather_than_a_body() {
            let server = StubServer::start(vec![Reply::empty(204)]);

            delete(&client(&server), task_id("task-id")).unwrap();

            let requests = server.only_request();
            assert_eq!(requests[0].method, "DELETE");
            assert_eq!(requests[0].target, "/api/v1/tasks/task-id");
            assert!(requests[0].body.is_empty());
        }

        /// A refusal reaches the caller as the server wrote it. `start` is the
        /// one that can answer 403, and the agent skills route on that code.
        #[test]
        fn a_refused_start_reports_the_servers_own_code() {
            let server = StubServer::start(vec![Reply::json(
                403,
                json!({
                    "error": "task_not_yours",
                    "message": "This task belongs to somebody else.",
                    "details": {"assignee_id": "other-actor"}
                }),
            )]);

            let error =
                transition(&client(&server), task_id("task-id"), "start", "started").unwrap_err();

            assert!(error.to_string().contains("403 (task_not_yours)"));
            assert!(error.to_string().contains("assignee_id: other-actor"));
        }

        /// An input file that is not JSON must fail before anything is sent:
        /// a half-written body reaching the API is how a task gets created
        /// with a title nobody meant.
        #[test]
        fn a_malformed_input_file_never_reaches_the_server() {
            let server = StubServer::start(vec![task_reply()]);
            let path =
                std::env::temp_dir().join(format!("rinto-cli-bad-{}.json", std::process::id()));
            std::fs::write(&path, "{not json").unwrap();

            let error = create(
                &client(&server),
                CreateArgs {
                    project_slug: "demo".to_string(),
                    input: path,
                },
            )
            .unwrap_err();

            assert!(error.to_string().contains("is not valid JSON"));
            assert!(server.requests().is_empty());
        }
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
