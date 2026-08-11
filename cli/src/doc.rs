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
}

pub fn run(command: DocCommand) -> Result<()> {
    let config = Config::load()?;
    let client = &Client::new(config.api())?;

    match command {
        DocCommand::Create(args) => create(client, config.actor_id(), args),
        DocCommand::Show(args) => show(client, args),
        DocCommand::List(args) => list(client, args),
    }
}

fn create(client: &Client, actor_id: &str, args: CreateArgs) -> Result<()> {
    let markdown = read(&args.body)?;

    if args.dry_run {
        return dry_run(client, &args.title, markdown);
    }

    let mut payload = Map::new();
    payload.insert("title".to_string(), json!(args.title));
    payload.insert("actor_id".to_string(), json!(actor_id));
    payload.insert("markdown".to_string(), json!(markdown));
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

    println!("created document {id}");
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

fn content_of(block: &Value) -> &str {
    block.get("content").and_then(Value::as_str).unwrap_or("")
}

fn list(client: &Client, args: ListArgs) -> Result<()> {
    let query: Vec<(&str, &str)> = match args.project_id.as_deref() {
        Some(project_id) => vec![("project_id", project_id)],
        None => vec![],
    };

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

        println!("{id}  {title}");
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
