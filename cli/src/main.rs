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
mod config;
mod doc;
mod error;
mod project;
mod schedule;
mod search;
mod skill;
mod task;
mod update;

// A real HTTP server for the tests that exercise the wire. Test-only, so it
// costs the shipped binary nothing.
#[cfg(test)]
mod testing;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "rinto-pmo", version, about = "Rinto PMO command line client")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Configure the API and discover the human user
    #[command(subcommand)]
    Config(config::ConfigCommand),
    /// Read and write documents
    #[command(subcommand)]
    Doc(doc::DocCommand),
    /// Discover projects and their repositories
    #[command(subcommand)]
    Project(project::ProjectCommand),
    /// Find, claim, and update project tasks
    #[command(subcommand)]
    Task(task::TaskCommand),
    /// Show what each week holds and what did not fit in it
    Schedule(schedule::ScheduleArgs),
    /// Find things by meaning, and get back rinto:// addresses
    Search(search::SearchArgs),
    /// Install the agent skills this binary carries
    #[command(subcommand)]
    Skill(skill::SkillCommand),
    /// Update this binary from the latest Gitea Package
    Update(update::UpdateArgs),
}

fn main() {
    let cli = Cli::parse();

    let outcome = match cli.command {
        Command::Config(command) => config::run(command),
        Command::Doc(command) => doc::run(command),
        Command::Project(command) => project::run(command),
        Command::Task(command) => task::run(command),
        Command::Schedule(args) => schedule::run(args),
        Command::Search(args) => search::run(args),
        Command::Skill(command) => skill::run(command),
        Command::Update(args) => update::run(args),
    };

    if let Err(error) = outcome {
        eprintln!("{error}");
        std::process::exit(error.exit_code());
    }
}
