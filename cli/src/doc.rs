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
    /// Print a document's latest content, or this topic's working copy
    Show(ShowArgs),
    /// List documents that have not been archived
    List(ListArgs),
    /// Propose a change to a document, for a person to review
    Propose(ProposeArgs),
    /// List the changes standing on a document, awaiting review
    Proposals(ProposalsArgs),
    /// Show where two topics want the same text to say different things
    Contentions(ContentionsArgs),
    /// Carry a whole-document proposal across the revisions that landed under it
    Rebase(RebaseArgs),
}

#[derive(Args)]
pub struct CreateArgs {
    /// Document title; supplied separately, never inside the body
    #[arg(long)]
    title: String,

    /// Markdown file holding the body; the server splits it into blocks at `#`, `##` and `###` headings
    #[arg(long, value_name = "FILE")]
    body: PathBuf,

    /// Project to file the document under; omit to use the default project
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

    /// Read the document as this topic sees it, with its own standing proposals
    /// in place of the text they would replace
    #[arg(long)]
    working: bool,
}

#[derive(Args)]
pub struct ProposalsArgs {
    /// Document id
    document_id: String,

    /// Only this topic's proposals
    #[arg(long)]
    mine: bool,

    /// Only proposals in this state; omit for every state
    #[arg(long, value_name = "live|accepted|rejected|superseded")]
    status: Option<String>,

    /// Only proposals on this block
    #[arg(long, value_name = "BLOCK_ID")]
    block: Option<String>,
}

#[derive(Args)]
pub struct ContentionsArgs {
    /// Document id
    document_id: String,
}

#[derive(Args)]
pub struct RebaseArgs {
    /// Document id
    document_id: String,

    /// The whole-document proposal to carry forward
    proposal_id: String,
}

#[derive(Args)]
pub struct ListArgs {
    /// Only documents in this project; pass `none` for unassigned ones
    #[arg(long, value_name = "UUID|none")]
    project_id: Option<String>,

    /// Only documents in this state; omit for every state
    #[arg(long, value_name = "draft|formal|applied")]
    status: Option<String>,
}

pub fn run(command: DocCommand) -> Result<()> {
    let config = Config::load()?;
    let client = &Client::new(config.api(), config.token()?)?;

    match command {
        DocCommand::Create(args) => create(client, &config, args),
        DocCommand::Show(args) if args.working => working(client, &config, args),
        DocCommand::Show(args) => show(client, args),
        DocCommand::List(args) => list(client, args),
        DocCommand::Propose(args) => propose(client, &config, args),
        DocCommand::Proposals(args) => proposals(client, &config, args),
        DocCommand::Contentions(args) => contentions(client, args),
        DocCommand::Rebase(args) => rebase(client, args),
    }
}

/// The topic this run is happening inside, or a refusal that says why it matters.
///
/// Shared by everything scoped to a topic. The wording matters more than usual:
/// the caller is a model, and "no conversation id" would send it looking for a
/// flag to pass rather than telling it that this question only has an answer
/// inside a topic.
fn topic(config: &Config, doing: &str) -> Result<String> {
    config.conversation_id().map(str::to_string).ok_or_else(|| {
        Error::Input(format!(
            "{doing} belongs to a topic, and this is not running inside one; \
                 outside a topic there are no proposals, only revisions"
        ))
    })
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
    println!("created draft document {id}");
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

/// Reads the document as this topic currently intends it.
///
/// The reason this exists: `show` prints the latest revision, and a proposal is
/// not in a revision until a person commits it. So a topic that changed a block
/// yesterday and reads the document today sees the text it replaced, not its own
/// version -- and proposing again from what it read **overwrites** the earlier
/// proposal in place, because a topic holds one live proposal per block and the
/// server reads a second one as the same intent iterating. The earlier work goes
/// silently. Reading through here before changing a document again is what stops
/// that.
///
/// A whole-document rewrite is reported by the server alongside the blocks
/// rather than folded into them -- it has no block ids to hang on -- and when
/// one is standing, the block list is explicitly *not* what this topic intends.
/// So it replaces the listing rather than annotating it.
fn working(client: &Client, config: &Config, args: ShowArgs) -> Result<()> {
    let conversation_id = topic(config, "a working copy")?;
    let path = format!(
        "/documents/{}/conversations/{}/blocks",
        args.document_id, conversation_id
    );
    let answer = client.get(&path, &[])?;

    if let Some(proposal) = answer.get("document_proposal").filter(|it| !it.is_null()) {
        return whole_document(proposal);
    }

    let blocks = client::data(answer)?;
    let blocks = blocks.as_array().map(Vec::as_slice).unwrap_or_default();

    for (index, block) in blocks.iter().enumerate() {
        if index > 0 {
            println!();
        }
        print!("{}", marks(block, args.with_block_ids));
        println!("{}", content_of(block));
    }

    // The title is a slot of its own and is not in this answer, so saying where
    // it lives beats printing the committed one -- a stale title inside a view
    // that promises "as this topic sees it" is the very mistake being fixed.
    // Spelled with the real id so it can be run as printed.
    println!(
        "\n(this topic's title proposals are not shown above: \
         rinto-pmo doc proposals {} --mine --status live)",
        args.document_id
    );

    Ok(())
}

/// The block id, and what is standing on this block, as leading lines.
///
/// `proposed` says the text above is this topic's own change rather than the
/// committed text -- without it a working copy reads exactly like `show` and the
/// distinction that matters is invisible. `other_proposals` is a count and never
/// the text: reconciling versions is a person's decision, and this is only here
/// so a topic knows it is not alone in the block.
fn marks(block: &Value, with_block_ids: bool) -> String {
    let mut marks = String::new();

    if with_block_ids {
        let block_id = block
            .get("block_id")
            .and_then(Value::as_str)
            .unwrap_or("(no id)");
        marks.push_str(&format!("[{block_id}]\n"));
    }

    if block.get("proposed").and_then(Value::as_bool) == Some(true) {
        marks.push_str("* your topic's proposal, not the committed text\n");
    }

    match block.get("other_proposals").and_then(Value::as_u64) {
        Some(0) | None => {}
        Some(other) => marks.push_str(&format!(
            "! {other} other topic(s) also want this block changed\n"
        )),
    }

    marks
}

/// What a standing whole-document rewrite says, in place of the block list.
fn whole_document(proposal: &Value) -> Result<()> {
    let id = proposal.get("id").and_then(Value::as_str).unwrap_or("?");

    println!("* your topic has a whole-document rewrite standing ({id}).");
    println!("  The committed block list is not what it intends. That rewrite reads:\n");
    println!("{}", content_of(proposal));

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

/// Which filters this asks for, using the server's own parameter names.
///
/// No hidden default, the same rule `list_query` follows: absent means every
/// state, and a caller after the ones still awaiting review says `--status live`
/// rather than relying on this to guess.
fn proposals_query<'a>(
    args: &'a ProposalsArgs,
    conversation_id: Option<&'a str>,
) -> Vec<(&'a str, &'a str)> {
    let mut query = Vec::new();

    if let Some(conversation_id) = conversation_id {
        query.push(("conversation_id", conversation_id));
    }

    // Passed through as written, like `doc list --status`: which states exist is
    // the server's to say, and a copy of the list kept here would drift.
    if let Some(status) = args.status.as_deref() {
        query.push(("status", status));
    }

    if let Some(block) = args.block.as_deref() {
        query.push(("block_id", block));
    }

    query
}

fn proposals(client: &Client, config: &Config, args: ProposalsArgs) -> Result<()> {
    let conversation_id = if args.mine {
        Some(topic(config, "`--mine`")?)
    } else {
        None
    };

    let path = format!("/documents/{}/proposals", args.document_id);
    let query = proposals_query(&args, conversation_id.as_deref());
    let proposals = client::data(client.get(&path, &query)?)?;
    let proposals = proposals.as_array().map(Vec::as_slice).unwrap_or_default();

    if proposals.is_empty() {
        println!("no proposals");
        return Ok(());
    }

    for proposal in proposals {
        println!("{}", proposal_summary(proposal));
    }

    Ok(())
}

/// One line per proposal: what it claims, whose it is, and whether it is still
/// standing. The content is deliberately not printed -- a document's worth of
/// proposals would bury the list, and `doc show --working` is where a topic
/// reads its own text back.
fn proposal_summary(proposal: &Value) -> String {
    let id = string(proposal, "id", "?");
    let scope = string(proposal, "scope", "?");
    let status = string(proposal, "status", "?");
    let slot = match scope {
        "block" => format!("block {}", string(proposal, "block_id", "?")),
        other => other.to_string(),
    };
    let summary = proposal
        .get("change_summary")
        .and_then(Value::as_str)
        .unwrap_or("(no summary)");

    format!("{id}  {status}  {slot}  {summary}")
}

/// Where two topics want the same text to say different things.
///
/// Needs no topic of its own: an argument is a fact about the document, and a
/// topic reading this is finding out that its version may not be the one that
/// lands. Unlike `doc show --working`, the competing text *is* printed -- the
/// count alone says there is a disagreement without saying what about.
fn contentions(client: &Client, args: ContentionsArgs) -> Result<()> {
    let path = format!("/documents/{}/contentions", args.document_id);
    let answer = client.get(&path, &[])?;

    let blocks = client::data(answer.clone())?;
    let blocks = blocks.as_array().map(Vec::as_slice).unwrap_or_default();

    // Kept apart the way the server keeps them apart: a block contention is
    // settled on its block, and these have no block to be settled on, so no
    // per-block decision would resolve one.
    let scopes = answer
        .get("document_scopes")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();

    if blocks.is_empty() && scopes.is_empty() {
        println!("no contentions; every standing proposal is the only one in its slot");
        return Ok(());
    }

    for block in blocks {
        println!("block {}", string(block, "block_id", "?"));
        print_competitors(block);
    }

    for scope in scopes {
        println!(
            "{} (whole document; no per-block decision settles this)",
            string(scope, "scope", "?")
        );
        print_competitors(scope);
    }

    Ok(())
}

fn print_competitors(contention: &Value) {
    let proposals = contention
        .get("proposals")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();

    for proposal in proposals {
        println!(
            "  {}  topic {}",
            string(proposal, "id", "?"),
            string(proposal, "conversation_id", "?")
        );
        for line in content_of(proposal).lines() {
            println!("    {line}");
        }
    }
}

/// Recompiles a whole-document proposal against the revision that is there now.
///
/// A whole-document rewrite is compiled against the revision it was written on.
/// Commit anything under it and the rewrite goes stale, because applying it
/// would revert what landed. This carries it across instead of throwing it away
/// and asking the model to write it again.
///
/// Asked unconditionally: the server answers an already-current proposal
/// unchanged, so working out whether it is needed would be a check the caller
/// cannot do better than the server it would have to ask anyway.
fn rebase(client: &Client, args: RebaseArgs) -> Result<()> {
    let path = format!(
        "/documents/{}/proposals/{}/rebase",
        args.document_id, args.proposal_id
    );
    let proposal = client::data(client.post(&path, json!({}))?)?;

    println!("{}", proposal_summary(&proposal));
    println!(
        "compiled against revision {}",
        string(&proposal, "base_revision_id", "?")
    );

    Ok(())
}

fn string<'a>(value: &'a Value, field: &str, fallback: &'a str) -> &'a str {
    value.get(field).and_then(Value::as_str).unwrap_or(fallback)
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

    // Passed through as written. Which states exist is the server's to say, so
    // a value this binary does not recognise earns a 400 rather than a guess
    // from a copy of the list that would drift.
    if let Some(status) = args.status.as_deref() {
        query.push(("status", status));
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

        // Anything past draft carries its state. Everything is created draft,
        // so marking those would mark almost every row and say nothing.
        match document.get("status").and_then(Value::as_str) {
            Some("draft") | None => println!("{id}  {title}"),
            Some(status) => println!("{id}  {title}  ({status})"),
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
    use super::{
        list_query, marks, proposal_summary, proposals_query, scope, ListArgs, ProposalsArgs,
        ProposeArgs,
    };
    use serde_json::json;
    use std::path::PathBuf;

    fn list_args(project_id: Option<&str>, status: Option<&str>) -> ListArgs {
        ListArgs {
            project_id: project_id.map(str::to_string),
            status: status.map(str::to_string),
        }
    }

    // Absent means "every state", not "the adopted ones" -- a draft somebody is
    // looking for has to be findable without knowing to ask.
    #[test]
    fn an_omitted_filter_is_not_sent_at_all() {
        assert_eq!(list_query(&list_args(None, None)), vec![]);
    }

    #[test]
    fn list_passes_the_project_and_status_filters_using_the_api_names() {
        assert_eq!(
            list_query(&list_args(Some("project-1"), Some("draft"))),
            vec![("project_id", "project-1"), ("status", "draft")]
        );

        assert_eq!(
            list_query(&list_args(None, Some("applied"))),
            vec![("status", "applied")]
        );
    }

    // The server owns the set of states, so an unknown one travels and comes
    // back as a 400 rather than being second-guessed here.
    #[test]
    fn an_unrecognised_status_is_still_sent() {
        assert_eq!(
            list_query(&list_args(None, Some("maybe"))),
            vec![("status", "maybe")]
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

    fn proposals_args(mine: bool, status: Option<&str>, block: Option<&str>) -> ProposalsArgs {
        ProposalsArgs {
            document_id: "doc-1".to_string(),
            mine,
            status: status.map(str::to_string),
            block: block.map(str::to_string),
        }
    }

    // `--mine` is the only filter that needs to know which topic this is, and
    // the resolved id arrives separately so that asking for it stays the
    // caller's decision -- the same shape `task list --mine` uses.
    #[test]
    fn mine_filters_by_the_topic_this_runs_inside() {
        assert_eq!(
            proposals_query(&proposals_args(true, Some("live"), None), Some("topic-1")),
            vec![("conversation_id", "topic-1"), ("status", "live")]
        );
    }

    // No hidden default: without `--status` the server is asked for every state,
    // so a superseded proposal somebody is looking for is still findable.
    #[test]
    fn proposals_without_filters_asks_for_everything() {
        assert_eq!(
            proposals_query(&proposals_args(false, None, None), None),
            vec![]
        );
    }

    #[test]
    fn proposals_passes_the_block_filter_using_the_api_name() {
        assert_eq!(
            proposals_query(&proposals_args(false, None, Some("block-1")), None),
            vec![("block_id", "block-1")]
        );
    }

    // The distinction the whole working copy exists for: without the mark, a
    // block carrying this topic's uncommitted proposal reads exactly like the
    // committed text, and the next rewrite is made from the wrong baseline.
    #[test]
    fn a_proposed_block_says_it_is_not_the_committed_text() {
        let block = json!({
            "block_id": "block-1",
            "content": "New wording",
            "proposed": true,
            "other_proposals": 0
        });

        let marks = marks(&block, false);

        assert!(marks.contains("your topic's proposal"), "{marks}");
        assert!(!marks.contains("other topic"), "{marks}");
    }

    #[test]
    fn a_contended_block_says_how_many_others_want_it_changed() {
        let block = json!({
            "block_id": "block-1",
            "content": "Committed wording",
            "proposed": false,
            "other_proposals": 2
        });

        let marks = marks(&block, true);

        assert!(marks.contains("[block-1]"), "{marks}");
        assert!(marks.contains("2 other topic(s)"), "{marks}");
        assert!(!marks.contains("your topic's proposal"), "{marks}");
    }

    // An untouched block carries nothing at all, so a working copy of a document
    // this topic has not changed reads exactly like `doc show`.
    #[test]
    fn an_untouched_block_is_unmarked() {
        let block = json!({
            "block_id": "block-1",
            "content": "Committed wording",
            "proposed": false,
            "other_proposals": 0
        });

        assert_eq!(marks(&block, false), "");
    }

    #[test]
    fn a_proposal_line_names_its_slot_and_state() {
        let proposal = json!({
            "id": "proposal-1",
            "scope": "block",
            "block_id": "block-1",
            "status": "live",
            "change_summary": "Tighten the rollback steps"
        });

        assert_eq!(
            proposal_summary(&proposal),
            "proposal-1  live  block block-1  Tighten the rollback steps"
        );
    }

    // A whole-document rewrite has no block to name, so the scope stands in for
    // one rather than printing `block (no id)`.
    #[test]
    fn a_whole_document_proposal_line_names_the_scope_instead_of_a_block() {
        let proposal = json!({
            "id": "proposal-2",
            "scope": "document",
            "block_id": null,
            "status": "live"
        });

        assert_eq!(
            proposal_summary(&proposal),
            "proposal-2  live  document  (no summary)"
        );
    }
}
