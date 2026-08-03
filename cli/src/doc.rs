use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use serde_json::{json, Map, Value};

use crate::client::{self, Client};
use crate::error::{Error, Result};
use crate::markdown;

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
    /// Document title
    #[arg(long)]
    title: String,

    /// Markdown file holding the body; split into blocks at `##` and `###` headings
    #[arg(long, value_name = "FILE", required_unless_present = "blocks")]
    body: Option<PathBuf>,

    /// JSON array of blocks, for content heading splitting cannot express
    #[arg(long, value_name = "FILE", conflicts_with = "body")]
    blocks: Option<PathBuf>,

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
    match command {
        // Built inside each arm rather than up front: `create --dry-run`
        // touches nothing but the local file, so it must not fail on an
        // unconfigured environment.
        DocCommand::Create(args) => create(args),
        DocCommand::Show(args) => show(&Client::from_env()?, args),
        DocCommand::List(args) => list(&Client::from_env()?, args),
    }
}

fn create(args: CreateArgs) -> Result<()> {
    if args.dry_run {
        return dry_run(&args);
    }

    let client = &Client::from_env()?;

    let blocks = match (&args.body, &args.blocks) {
        (Some(path), _) => blocks_from_markdown(path, client.actor_id())?,
        (None, Some(path)) => blocks_from_json(path, client.actor_id())?,
        // clap's `required_unless_present` already rejects this.
        (None, None) => unreachable!("clap guarantees one of --body or --blocks"),
    };

    let mut payload = Map::new();
    payload.insert("title".to_string(), json!(args.title));
    payload.insert("blocks".to_string(), Value::Array(blocks));
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
fn dry_run(args: &CreateArgs) -> Result<()> {
    let blocks: Vec<String> = match (&args.body, &args.blocks) {
        (Some(path), _) => markdown::split_into_blocks(&read(path)?),
        (None, Some(path)) => blocks_from_json(path, "")?
            .iter()
            .map(|block| content_of(block).to_string())
            .collect(),
        (None, None) => unreachable!("clap guarantees one of --body or --blocks"),
    };

    if blocks.is_empty() {
        return Err(Error::Input("there is no content to write".to_string()));
    }

    println!("{} block(s), nothing created:", blocks.len());
    for (index, block) in blocks.iter().enumerate() {
        let opening = block.lines().next().unwrap_or("").trim();
        println!(
            "  {:>2}. {opening}  ({} chars)",
            index + 1,
            block.chars().count()
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

fn blocks_from_markdown(path: &Path, actor_id: &str) -> Result<Vec<Value>> {
    let source = read(path)?;
    let blocks = markdown::split_into_blocks(&source);

    if blocks.is_empty() {
        return Err(Error::Input(format!(
            "{} has no content to write",
            path.display()
        )));
    }

    Ok(blocks
        .into_iter()
        .map(|content| json!({ "actor_id": actor_id, "content": content }))
        .collect())
}

/// Passes author-supplied block objects through untouched apart from stamping
/// `actor_id`, which is this process's business and never the caller's.
fn blocks_from_json(path: &Path, actor_id: &str) -> Result<Vec<Value>> {
    let source = read(path)?;

    let parsed: Value = serde_json::from_str(&source)
        .map_err(|err| Error::Input(format!("{} is not valid JSON: {err}", path.display())))?;

    let entries = match parsed {
        Value::Array(entries) => entries,
        _ => {
            return Err(Error::Input(format!(
                "{} must hold a JSON array of blocks",
                path.display()
            )))
        }
    };

    entries
        .into_iter()
        .enumerate()
        .map(|(index, entry)| match entry {
            Value::Object(mut block) => {
                block.entry("actor_id").or_insert_with(|| json!(actor_id));
                Ok(Value::Object(block))
            }
            _ => Err(Error::Input(format!(
                "block {index} in {} is not an object",
                path.display()
            ))),
        })
        .collect()
}

fn read(path: &Path) -> Result<String> {
    std::fs::read_to_string(path)
        .map_err(|err| Error::Io(format!("could not read {}: {err}", path.display())))
}
