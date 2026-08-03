//! Splits an authored Markdown file into document blocks at `##` and `###`
//! headings.
//!
//! This is the one place the CLI is not a dumb pipe, and the exception is
//! deliberate (see `docs/ai-document-cli.md`): the split is mechanical
//! formatting, not validation. `Documents.BlockOps` on the server remains the
//! only authority on whether the result is acceptable.
//!
//! It exists so a model never has to escape a long Markdown body into a JSON
//! string -- among the operations models get wrong most often, and one whose
//! failures are silent.
//!
//! H3 splits as well as H2 because contention detection is per block, and
//! `docs/document-working-session.md` warns that coarse blocks make two topics
//! collide on one block routinely, most of them false conflicts. Real documents
//! put several H3 subsections under one H2, so splitting at H2 alone yields
//! blocks far larger than the paragraph-ish grain that design assumes. H4 and
//! deeper stay with their parent: past H3 the fragments stop being independently
//! reviewable.

/// Splits `source` at every H2 or H3 heading that is not inside a fenced code
/// block.
///
/// Text preceding the first heading becomes its own leading block. Blocks that
/// are blank after trimming are dropped, so trailing newlines and runs of blank
/// lines between sections cost nothing.
pub fn split_into_blocks(source: &str) -> Vec<String> {
    let mut blocks = Vec::new();
    let mut current = String::new();
    let mut open_fence: Option<(char, usize)> = None;

    for line in source.lines() {
        match fence_marker(line) {
            Some((character, length)) => match open_fence {
                None => open_fence = Some((character, length)),
                // A fence closes only on the same character and at least the
                // opening length; anything else is content.
                Some((open_character, open_length))
                    if character == open_character && length >= open_length =>
                {
                    open_fence = None
                }
                Some(_) => {}
            },
            None => {
                if open_fence.is_none() && is_split_heading(line) {
                    flush(&mut blocks, &mut current);
                }
            }
        }

        current.push_str(line);
        current.push('\n');
    }

    flush(&mut blocks, &mut current);
    blocks
}

fn flush(blocks: &mut Vec<String>, current: &mut String) {
    let block = current.trim();
    if !block.is_empty() {
        blocks.push(block.to_string());
    }
    current.clear();
}

/// Recognises a ``` or ~~~ fence, allowing the CommonMark indent of up to three
/// spaces.
fn fence_marker(line: &str) -> Option<(char, usize)> {
    let line = strip_indent(line);
    let character = line.chars().next()?;
    if character != '`' && character != '~' {
        return None;
    }

    let length = line.chars().take_while(|c| *c == character).count();
    (length >= 3).then_some((character, length))
}

/// True for `## Heading` and `### Heading`; false for `#`, `#### Heading`, and
/// for a hash run with no space after it (`##inline`).
fn is_split_heading(line: &str) -> bool {
    let line = strip_indent(line);
    let hashes = line.chars().take_while(|c| *c == '#').count();

    if !(2..=3).contains(&hashes) {
        return false;
    }

    let rest = &line[hashes..];
    rest.is_empty() || rest.starts_with(char::is_whitespace)
}

fn strip_indent(line: &str) -> &str {
    let indent = line.len() - line.trim_start_matches(' ').len();
    &line[indent.min(3)..]
}

#[cfg(test)]
mod tests {
    use super::split_into_blocks;

    #[test]
    fn splits_at_h2_headings() {
        let blocks = split_into_blocks("## One\n\nfirst\n\n## Two\n\nsecond\n");

        assert_eq!(blocks, vec!["## One\n\nfirst", "## Two\n\nsecond"]);
    }

    #[test]
    fn text_before_the_first_heading_becomes_its_own_block() {
        let blocks = split_into_blocks("preamble\n\n## One\n\nfirst\n");

        assert_eq!(blocks, vec!["preamble", "## One\n\nfirst"]);
    }

    #[test]
    fn splits_at_h3_headings_too() {
        let blocks = split_into_blocks("## One\n\nlead\n\n### Deeper\n\ntext\n");

        assert_eq!(blocks, vec!["## One\n\nlead", "### Deeper\n\ntext"]);
    }

    #[test]
    fn keeps_h4_and_deeper_with_their_section() {
        let blocks = split_into_blocks("### Three\n\n#### Four\n\ntext\n");

        assert_eq!(blocks, vec!["### Three\n\n#### Four\n\ntext"]);
    }

    #[test]
    fn keeps_h1_with_what_follows() {
        let blocks = split_into_blocks("# Title\n\nintro\n\n## One\n\ntext\n");

        assert_eq!(blocks, vec!["# Title\n\nintro", "## One\n\ntext"]);
    }

    #[test]
    fn ignores_headings_inside_fenced_code() {
        let source = "## One\n\n```\n## not a heading\n```\n\ntail\n";

        assert_eq!(
            split_into_blocks(source),
            vec!["## One\n\n```\n## not a heading\n```\n\ntail"]
        );
    }

    #[test]
    fn ignores_headings_inside_tilde_fences() {
        let source = "## One\n\n~~~md\n## not a heading\n~~~\n";

        assert_eq!(
            split_into_blocks(source),
            vec!["## One\n\n~~~md\n## not a heading\n~~~"]
        );
    }

    #[test]
    fn a_shorter_run_does_not_close_a_longer_fence() {
        let source = "## One\n\n````\n```\n## still code\n````\n";

        assert_eq!(
            split_into_blocks(source),
            vec!["## One\n\n````\n```\n## still code\n````"]
        );
    }

    #[test]
    fn drops_blank_blocks() {
        assert!(split_into_blocks("\n\n   \n").is_empty());
    }

    #[test]
    fn does_not_split_on_a_hash_run_without_a_space() {
        let blocks = split_into_blocks("## One\n\n##inline\n");

        assert_eq!(blocks, vec!["## One\n\n##inline"]);
    }
}
