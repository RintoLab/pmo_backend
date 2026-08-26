use std::fmt::Write as _;

use clap::Args;
use serde_json::Value;

use crate::client::{self, Client};
use crate::config::Config;
use crate::error::Result;

/// Finding things by meaning, and getting back addresses rather than
/// descriptions.
///
/// The point of every line is its `rinto://` URI: it goes straight into a
/// document body as a Markdown link destination, or into `resolve`/`backlinks`
/// unchanged. Nothing here has to be assembled out of parts, which is what
/// makes this the discovery half of the reference system rather than a
/// separate feature.
#[derive(Args)]
pub struct SearchArgs {
    /// What to look for, in natural language
    query: String,

    /// Which kind of thing to search. Required: searching one kind while
    /// believing you searched everything is a wrong answer that looks right.
    ///
    /// `attachment` and `proposal` are addressable but not searchable -- an
    /// attachment's only text is its filename, and a proposal is reached
    /// through the document it is proposed against.
    #[arg(
        long,
        short = 't',
        value_parser = [
            "block", "document", "annotation", "task", "project", "conversation",
        ]
    )]
    r#type: String,

    /// Only things in this project
    #[arg(long)]
    project_id: Option<String>,

    /// Results to return
    #[arg(long)]
    limit: Option<u32>,

    /// Candidates the vector stage pulls for the reranker to read (default
    /// 100). This decides what *can* be found -- a result outside the candidate
    /// set is absent, not ranked low -- so raising `--limit` past it adds
    /// nothing. Vary it to measure retrieval depth.
    #[arg(long)]
    recall_limit: Option<u32>,

    /// Include archived content, which is left out by default
    #[arg(long)]
    include_archived: bool,
}

pub fn run(args: SearchArgs) -> Result<()> {
    let config = Config::load()?;
    let client = Client::new(config.api(), config.token()?)?;

    search(&client, args)
}

/// Takes the client rather than building one, so a test can point it at a
/// server and see what this actually asks for. Seven optional parameters go
/// into that query, and which of them reach the wire is the whole behaviour.
fn search(client: &Client, args: SearchArgs) -> Result<()> {
    let limit = args.limit.map(|value| value.to_string());
    let recall_limit = args.recall_limit.map(|value| value.to_string());
    let mut query: Vec<(&str, &str)> = vec![("q", &args.query), ("type", &args.r#type)];
    if let Some(project_id) = args.project_id.as_deref() {
        query.push(("project_id", project_id));
    }
    if let Some(limit) = limit.as_deref() {
        query.push(("limit", limit));
    }
    if let Some(recall_limit) = recall_limit.as_deref() {
        query.push(("recall_limit", recall_limit));
    }
    if args.include_archived {
        query.push(("include_archived", "true"));
    }

    let results = client::data(client.get("/search", &query)?)?;
    let results = results.as_array().map(Vec::as_slice).unwrap_or_default();

    if results.is_empty() {
        println!("no matches");
        return Ok(());
    }

    print!("{}", render(results));
    Ok(())
}

/// One line per hit, the URI first.
///
/// First because it is the only part a caller acts on: everything after it is
/// there to decide *which* line to act on. A model reading this copies a URI
/// and pastes it; it does not parse the rest.
fn render(results: &[Value]) -> String {
    let mut output = String::new();

    for result in results {
        let _ = writeln!(
            output,
            "{}{}  {}  {}",
            string(result, "uri", "?"),
            if result.get("archived") == Some(&Value::Bool(true)) {
                "  [archived]"
            } else {
                ""
            },
            score(result),
            label(result)
        );
    }

    output
}

/// Two decimals, because the reranker's scale is its own and the only thing a
/// reader does with it is compare two lines of the same response.
fn score(result: &Value) -> String {
    result
        .get("score")
        .and_then(Value::as_f64)
        .map(|value| format!("{value:.2}"))
        .unwrap_or_else(|| "?".to_string())
}

/// What the hit is called, and where it lives when that is somewhere else.
fn label(result: &Value) -> String {
    let title = result
        .get("title")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or("(untitled)");

    match result.get("document_title").and_then(Value::as_str) {
        Some(document) if !document.is_empty() && document != title => {
            format!("{title}  <- {document}")
        }
        _ => title.to_string(),
    }
}

fn string<'a>(value: &'a Value, field: &str, fallback: &'a str) -> &'a str {
    value.get(field).and_then(Value::as_str).unwrap_or(fallback)
}

#[cfg(test)]
mod tests {
    use super::{render, search, SearchArgs};
    use crate::testing::{client, Reply, StubServer};
    use serde_json::json;

    /// Every optional parameter is left out unless it was asked for, and the
    /// two required ones are always there.
    ///
    /// The query is a sentence, so the encoding matters: `ureq` writes a space
    /// as `+`, which Plug decodes back to a space. Pinned here because a
    /// natural-language search that arrived with a literal `+` in it would
    /// return nothing and look like a bad index.
    #[test]
    fn only_the_filters_that_were_given_reach_the_wire() {
        let server = StubServer::start(vec![
            Reply::json(200, json!({"data": []})),
            Reply::json(200, json!({"data": []})),
        ]);
        let client = client(&server);

        search(
            &client,
            SearchArgs {
                query: "vector search".to_string(),
                r#type: "task".to_string(),
                project_id: None,
                limit: None,
                recall_limit: None,
                include_archived: false,
            },
        )
        .unwrap();

        search(
            &client,
            SearchArgs {
                query: "vector search".to_string(),
                r#type: "block".to_string(),
                project_id: Some("project-1".to_string()),
                limit: Some(5),
                recall_limit: Some(200),
                include_archived: true,
            },
        )
        .unwrap();

        let requests = server.requests();
        assert_eq!(
            requests[0].target,
            "/api/v1/search?q=vector+search&type=task"
        );
        assert_eq!(
            requests[1].target,
            "/api/v1/search?q=vector+search&type=block&project_id=project-1\
             &limit=5&recall_limit=200&include_archived=true"
        );
    }

    #[test]
    fn the_uri_comes_first_because_it_is_the_part_that_gets_used() {
        let results = [json!({
            "uri": "rinto://block/0193",
            "type": "block",
            "title": "部署步骤",
            "score": 0.9345,
            "archived": false
        })];

        let rendered = render(&results);

        assert!(rendered.starts_with("rinto://block/0193"));
        assert!(rendered.contains("0.93"));
        assert!(rendered.contains("部署步骤"));
    }

    #[test]
    fn a_block_says_which_document_it_is_in() {
        let results = [json!({
            "uri": "rinto://block/0193",
            "title": "部署步骤",
            "document_title": "上线流程",
            "score": 0.9
        })];

        assert!(render(&results).contains("部署步骤  <- 上线流程"));
    }

    /// A document hit's title *is* its document title, and saying it twice
    /// would be noise on every line of the commonest search.
    #[test]
    fn a_document_does_not_repeat_its_own_title() {
        let results = [json!({
            "uri": "rinto://document/0193",
            "title": "上线流程",
            "document_title": "上线流程",
            "score": 0.9
        })];

        assert!(!render(&results).contains("<-"));
    }

    #[test]
    fn archived_hits_say_so() {
        let results = [json!({
            "uri": "rinto://block/0193",
            "title": "旧方案",
            "score": 0.5,
            "archived": true
        })];

        assert!(render(&results).contains("[archived]"));
    }

    #[test]
    fn a_hit_with_no_title_is_still_addressable() {
        let results = [json!({"uri": "rinto://block/0193", "score": 0.5})];
        let rendered = render(&results);

        assert!(rendered.starts_with("rinto://block/0193"));
        assert!(rendered.contains("(untitled)"));
    }
}
