use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use serde_json::{json, Map, Value};

use crate::client::{self, Client};
use crate::config::Config;
use crate::error::{Error, Result};

#[derive(Subcommand)]
pub enum DocCommand {
    /// Create a document from a Markdown file
    Create(CreateArgs),
    /// Print a document's latest content
    Show(ShowArgs),
    /// List documents that have not been archived
    List(ListArgs),
    /// Propose a change to a document, for a person to review
    Propose(ProposeArgs),
}

#[derive(Args)]
pub struct CreateArgs {
    /// Document title; supplied separately, never inside the body
    #[arg(long)]
    title: String,

    /// Markdown file holding the body; the server splits it into blocks at `#`, `##` and `###` headings
    #[arg(long, value_name = "FILE")]
    body: PathBuf,

    /// Project to file the document under; omit to leave it unassigned
    #[arg(long, value_name = "UUID")]
    project_id: Option<String>,

    /// What this document records, for the revision log
    #[arg(long, value_name = "TEXT")]
    change_summary: Option<String>,

    /// Show how the body splits into blocks without creating anything
    #[arg(long)]
    dry_run: bool,
}

/// A change put up for review, never applied.
///
/// Three shapes, and which one this is follows from what is passed:
///
///   * `--body` alone rewrites the whole document. The only shape that can
///     split a section, merge two, add one or drop one -- the server works out
///     the operations from the new body, and blocks whose text is unchanged keep
///     their identity, so annotations on them survive.
///   * `--body` with `--block` changes one block and nothing else.
///   * `--title` renames the document. A title is a field of its own and is
///     never read out of the body, so it cannot travel inside one.
#[derive(Args)]
pub struct ProposeArgs {
    /// Document id
    document_id: String,

    /// Markdown file holding the new text: the whole document, or one block with `--block`
    #[arg(long, value_name = "FILE", conflicts_with = "title")]
    body: Option<PathBuf>,

    /// Change only this block; omit to rewrite the whole document
    #[arg(long, value_name = "BLOCK_ID", requires = "body")]
    block: Option<String>,

    /// Propose this as the document's title
    #[arg(long, value_name = "TEXT")]
    title: Option<String>,

    /// What this change does, shown to whoever reviews it
    #[arg(long, value_name = "TEXT")]
    change_summary: Option<String>,
}

#[derive(Args)]
pub struct ShowArgs {
    /// Document id
    document_id: String,

    /// Prefix each block with its id
    #[arg(long)]
    with_block_ids: bool,
}

#[derive(Args)]
pub struct ListArgs {
    /// Only documents in this project; pass `none` for unassigned ones
    #[arg(long, value_name = "UUID|none")]
    project_id: Option<String>,

    /// true for scratch documents, false for adopted ones; omit for both
    #[arg(long, value_name = "BOOL")]
    fleeting: Option<bool>,
}

pub fn run(command: DocCommand) -> Result<()> {
    let config = Config::load()?;
    let client = &Client::new(config.api())?;

    match command {
        DocCommand::Create(args) => create(client, &config, args),
        DocCommand::Show(args) => show(client, args),
        DocCommand::List(args) => list(client, args),
        DocCommand::Propose(args) => propose(client, &config, args),
    }
}

fn create(client: &Client, config: &Config, args: CreateArgs) -> Result<()> {
    let markdown = read(&args.body)?;

    if args.dry_run {
        return dry_run(client, &args.title, markdown);
    }

    let mut payload = Map::new();
    payload.insert("title".to_string(), json!(args.title));
    payload.insert("markdown".to_string(), json!(markdown));
    attribute(&mut payload, config)?;
    if let Some(project_id) = args.project_id {
        payload.insert("project_id".to_string(), json!(project_id));
    }
    if let Some(change_summary) = args.change_summary {
        payload.insert("change_summary".to_string(), json!(change_summary));
    }
    let document = client::data(client.post("/documents", Value::Object(payload))?)?;
    let id = document
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("(no id returned)");

    // Said every time, because the caller is usually a model about to report
    // what it just did, and "created a document" overstates it: nobody has
    // adopted this yet, and only a person can.
    println!("created fleeting document {id}");
    Ok(())
}

/// Reports how the body would be split, without creating anything.
///
/// Exists because block granularity is an authoring decision the author cannot
/// otherwise check: without a preview the only way to see the split is to
/// create a real document and then have to clean it up.
///
/// It asks the server rather than splitting locally. The server owns the rule,
/// and a preview computed by a rule of this binary's own would be a forecast of
/// what an old CLI thinks -- worse than no preview, because it looks right.
fn dry_run(client: &Client, title: &str, markdown: String) -> Result<()> {
    let preview =
        client::data(client.post("/documents/preview_blocks", json!({ "markdown": markdown }))?)?;

    let blocks = preview
        .get("blocks")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();

    println!("title: {title}");
    println!("{} block(s), nothing created:", blocks.len());
    for (index, block) in blocks.iter().enumerate() {
        let content = content_of(block);
        let opening = content.lines().next().unwrap_or("").trim();
        println!(
            "  {:>2}. {opening}  ({} chars)",
            index + 1,
            content.chars().count()
        );
    }

    Ok(())
}

fn show(client: &Client, args: ShowArgs) -> Result<()> {
    let path = format!("/documents/{}", args.document_id);
    let document = client::data(client.get(&path, &[])?)?;

    let revision = document
        .get("latest_revision")
        .ok_or_else(|| Error::Network("document had no latest_revision".to_string()))?;

    if let Some(title) = revision.get("title").and_then(Value::as_str) {
        println!("# {title}\n");
    }

    let blocks = revision
        .get("blocks")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();

    for (index, block) in blocks.iter().enumerate() {
        if index > 0 {
            println!();
        }
        if args.with_block_ids {
            let block_id = block
                .get("block_id")
                .and_then(Value::as_str)
                .unwrap_or("(no id)");
            println!("[{block_id}]");
        }
        println!("{}", content_of(block));
    }

    Ok(())
}

/// Puts a change up for review.
///
/// A proposal belongs to a topic -- that is what makes it one topic's opinion
/// rather than an edit -- so this only works inside one. Outside a topic there
/// is nothing to attach it to and no assistant to attribute it to, and saying so
/// is more use than a validation error from the server.
fn propose(client: &Client, config: &Config, args: ProposeArgs) -> Result<()> {
    let conversation_id = config.conversation_id().ok_or_else(|| {
        Error::Input(
            "a proposal belongs to a topic, and this is not running inside one; \
             a change made outside a topic is a revision, not a proposal"
                .to_string(),
        )
    })?;

    let mut payload = Map::new();
    payload.insert("conversation_id".to_string(), json!(conversation_id));
    payload.insert("scope".to_string(), json!(scope(&args)?));
    payload.insert("content".to_string(), json!(content(&args)?));

    if let Some(block_id) = &args.block {
        payload.insert("block_id".to_string(), json!(block_id));
    }
    if let Some(change_summary) = &args.change_summary {
        payload.insert("change_summary".to_string(), json!(change_summary));
    }

    let path = format!("/documents/{}/proposals", args.document_id);
    let answer = client.post(&path, Value::Object(payload))?;
    report(&answer)
}

/// Which of the three shapes this is. `--body` alone means the whole document.
fn scope(args: &ProposeArgs) -> Result<&'static str> {
    match (&args.title, &args.body, &args.block) {
        (Some(_title), None, None) => Ok("title"),
        (None, Some(_body), Some(_block)) => Ok("block"),
        (None, Some(_body), None) => Ok("document"),
        _nothing_to_propose => Err(Error::Input(
            "nothing to propose: pass --body to rewrite the document, \
             --body with --block to change one block, or --title to rename it"
                .to_string(),
        )),
    }
}

fn content(args: &ProposeArgs) -> Result<String> {
    match (&args.title, &args.body) {
        (Some(title), _none) => Ok(title.clone()),
        (None, Some(body)) => read(body),
        (None, None) => Err(Error::Input("nothing to propose".to_string())),
    }
}

/// What the server made of it.
///
/// The contention count is the part worth printing: it says somebody else is
/// also changing this, which the model should know before building further on
/// the assumption that its version is the one that will land. The operations are
/// summarised rather than listed -- the shape of the change is the useful part,
/// and the diff itself is for whoever reviews it.
fn report(answer: &Value) -> Result<()> {
    let proposal = client::data(answer.clone())?;
    let id = proposal.get("id").and_then(Value::as_str).unwrap_or("?");
    let scope = proposal.get("scope").and_then(Value::as_str).unwrap_or("?");

    println!("proposed {scope} change {id}, awaiting review");

    if let Some(operations) = proposal.get("block_ops").and_then(Value::as_array) {
        let mut updated = 0;
        let mut inserted = 0;
        let mut deleted = 0;

        for operation in operations {
            match operation.get("op").and_then(Value::as_str) {
                Some("update") => updated += 1,
                Some("insert_after") => inserted += 1,
                Some("delete") => deleted += 1,
                _other => {}
            }
        }

        println!("  {updated} changed, {inserted} added, {deleted} removed");
    }

    let live = answer
        .get("live_proposals")
        .and_then(Value::as_u64)
        .unwrap_or(1);

    if live > 1 {
        println!("  {live} topics have a change standing here; a person decides between them");
    }

    Ok(())
}

/// Says who is writing, in the only way this program is allowed to.
///
/// Inside a topic it names the topic and nothing else: the author is that
/// topic's assistant and the server derives it, so a caller that also named an
/// actor could name the wrong one. Outside a topic there is nobody to derive
/// from, and the configured human is the author.
fn attribute(payload: &mut Map<String, Value>, config: &Config) -> Result<()> {
    match config.conversation_id() {
        Some(conversation_id) => {
            payload.insert("conversation_id".to_string(), json!(conversation_id));
        }
        None => {
            payload.insert("actor_id".to_string(), json!(config.actor_id()?));
        }
    }

    Ok(())
}

fn content_of(block: &Value) -> &str {
    block.get("content").and_then(Value::as_str).unwrap_or("")
}

fn list_query(args: &ListArgs) -> Vec<(&str, &str)> {
    let mut query = Vec::new();

    if let Some(project_id) = args.project_id.as_deref() {
        query.push(("project_id", project_id));
    }

    if let Some(fleeting) = args.fleeting {
        query.push(("fleeting", if fleeting { "true" } else { "false" }));
    }

    query
}

fn list(client: &Client, args: ListArgs) -> Result<()> {
    let query = list_query(&args);
    let documents = client::data(client.get("/documents", &query)?)?;
    let documents = documents.as_array().map(Vec::as_slice).unwrap_or_default();

    if documents.is_empty() {
        println!("no documents");
        return Ok(());
    }

    for document in documents {
        let id = document.get("id").and_then(Value::as_str).unwrap_or("?");
        let title = document
            .get("latest_revision")
            .and_then(|revision| revision.get("title"))
            .and_then(Value::as_str)
            .unwrap_or("(untitled)");

        // The adopted ones carry the mark. Everything is created fleeting, so
        // marking those would mark almost every row and say nothing.
        if document.get("fleeting").and_then(Value::as_bool) == Some(false) {
            println!("{id}  {title}  (formal)");
        } else {
            println!("{id}  {title}");
        }
    }

    Ok(())
}

/// Reads the body, refusing an empty one here rather than shipping it.
///
/// The one check this binary makes about content, and it is not a structural
/// one: a body with nothing in it is a mistake at the keyboard -- a path typo,
/// a file the model never wrote -- and the server cannot tell that apart from
/// someone deliberately creating an empty document.
fn read(path: &Path) -> Result<String> {
    let source = std::fs::read_to_string(path)
        .map_err(|err| Error::Io(format!("could not read {}: {err}", path.display())))?;

    if source.trim().is_empty() {
        return Err(Error::Input(format!(
            "{} has no content to write",
            path.display()
        )));
    }

    Ok(source)
}

#[cfg(test)]
mod tests {
    use super::{list_query, scope, ListArgs, ProposeArgs};
    use std::path::PathBuf;

    fn list_args(project_id: Option<&str>, fleeting: Option<bool>) -> ListArgs {
        ListArgs {
            project_id: project_id.map(str::to_string),
            fleeting,
        }
    }

    // Absent means "both kinds", not "the adopted ones" -- a scratch document
    // somebody is looking for has to be findable without knowing to ask.
    #[test]
    fn an_omitted_filter_is_not_sent_at_all() {
        assert_eq!(list_query(&list_args(None, None)), vec![]);
    }

    #[test]
    fn list_passes_the_project_and_fleeting_filters_using_the_api_names() {
        assert_eq!(
            list_query(&list_args(Some("project-1"), Some(true))),
            vec![("project_id", "project-1"), ("fleeting", "true")]
        );

        assert_eq!(
            list_query(&list_args(None, Some(false))),
            vec![("fleeting", "false")]
        );
    }

    fn args(body: Option<&str>, block: Option<&str>, title: Option<&str>) -> ProposeArgs {
        ProposeArgs {
            document_id: "doc-1".to_string(),
            body: body.map(PathBuf::from),
            block: block.map(str::to_string),
            title: title.map(str::to_string),
            change_summary: None,
        }
    }

    // A body on its own is the whole document, which is the shape that can
    // restructure it. Naming a block narrows it to that block.
    #[test]
    fn a_body_alone_rewrites_the_document() {
        assert_eq!(
            scope(&args(Some("body.md"), None, None)).unwrap(),
            "document"
        );
    }

    #[test]
    fn a_body_with_a_block_changes_that_block() {
        assert_eq!(
            scope(&args(Some("body.md"), Some("block-1"), None)).unwrap(),
            "block"
        );
    }

    #[test]
    fn a_title_renames_the_document() {
        assert_eq!(scope(&args(None, None, Some("Renamed"))).unwrap(), "title");
    }

    // Better here than as a validation error from the server: the fix is in the
    // command line, so the message should be about the command line.
    #[test]
    fn nothing_at_all_is_refused_with_the_shapes_named() {
        let error = scope(&args(None, None, None)).unwrap_err().to_string();

        assert!(error.contains("--body"), "{error}");
        assert!(error.contains("--title"), "{error}");
    }
}
