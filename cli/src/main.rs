//! Rinto PMO command line client.
//!
//! Primary caller is an AI agent, which shapes three things:
//!
//! * long text arrives as a file path, never as an argument -- shell quoting
//!   eats newlines and quotes silently, and a half-written document that exits
//!   zero is worse than a failure
//! * success prints one line; the point of a CLI over a tool protocol is that
//!   it stays out of the context window
//! * conflicts and validation errors are relayed verbatim and never retried
//!
//! See `docs/ai-document-cli.md` for the reasoning behind all three.

mod client;
mod doc;
mod error;
mod markdown;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "rinto-pmo", version, about = "Rinto PMO command line client")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Read and write documents
    #[command(subcommand)]
    Doc(doc::DocCommand),
}

fn main() {
    let cli = Cli::parse();

    let outcome = match cli.command {
        Command::Doc(command) => doc::run(command),
    };

    if let Err(error) = outcome {
        eprintln!("{error}");
        std::process::exit(error.exit_code());
    }
}
