use std::fmt::Write as _;

use clap::Args;
use serde_json::Value;

use crate::client::{self, Client};
use crate::config::Config;
use crate::error::Result;

/// What each week holds, and what did not fit in it.
///
/// Not scoped to a project, and it cannot be: a week's minutes are one pool
/// spanning everything a person works on, so packing a single project would
/// hand it the whole week and overstate what fits.
///
/// The point of reading this before claiming work is `overflow`. A task in
/// there was selected for the week and did not make it, which is the answer to
/// "is this plan realistic" -- and a task absent from the whole listing was
/// never selected at all: it sits in the backlog, and starting it is a choice
/// to work outside the plan rather than a step in it.
#[derive(Args)]
pub struct ScheduleArgs {
    /// First week to plan, as any date inside it; defaults to today
    #[arg(long, value_name = "YYYY-MM-DD")]
    from: Option<String>,

    /// Last week to plan, as any date inside it; defaults to `--from`
    #[arg(long, value_name = "YYYY-MM-DD")]
    to: Option<String>,
}

pub fn run(args: ScheduleArgs) -> Result<()> {
    let config = Config::load()?;
    let client = Client::new(config.api(), config.token()?)?;

    schedule(&client, args)
}

fn schedule(client: &Client, args: ScheduleArgs) -> Result<()> {
    let mut query: Vec<(&str, &str)> = Vec::new();
    if let Some(from) = args.from.as_deref() {
        query.push(("from", from));
    }
    if let Some(to) = args.to.as_deref() {
        query.push(("to", to));
    }

    let weeks = client::data(client.get("/schedule", &query)?)?;
    let weeks = weeks.as_array().map(Vec::as_slice).unwrap_or_default();

    if weeks.is_empty() {
        println!(
            "no weeks planned; the plan does not run backwards, so ask about this week or later"
        );
        return Ok(());
    }

    print!("{}", render(weeks));
    Ok(())
}

fn render(weeks: &[Value]) -> String {
    let mut output = String::new();

    for week in weeks {
        let _ = writeln!(
            output,
            "week of {}  {}/{} minutes{}",
            string(week, "week", "?"),
            number(week, "allocated"),
            number(week, "capacity"),
            // A week whose year was never imported is planned on the weekend
            // rule alone, which in China turns Spring Festival into five
            // ordinary working days. Printing the capacity without saying so
            // would present a guess as a fact.
            if week.get("calendar_known") == Some(&Value::Bool(false)) {
                "  [holidays unknown for this year]"
            } else {
                ""
            }
        );

        for day in array(week, "days") {
            let _ = writeln!(
                output,
                "  {}  {}/{}",
                string(day, "day", "?"),
                number(day, "allocated"),
                number(day, "capacity")
            );

            for allocation in array(day, "tasks") {
                let task = allocation.get("task").unwrap_or(&Value::Null);
                let _ = writeln!(
                    output,
                    "    {:>4}m  {}  {}",
                    number(allocation, "minutes"),
                    string(task, "id", "?"),
                    string(task, "title", "(untitled)")
                );
            }
        }

        section(&mut output, week, "overflow", "did not fit");
        section(
            &mut output,
            week,
            "blocked",
            "waiting on work that did not fit",
        );
    }

    output
}

/// `overflow` and `blocked` stay apart, the way the server keeps them apart:
/// overflow means the week is too full and the answer is to cut work, blocked
/// means something upstream did not happen and cutting work here fixes nothing.
fn section(output: &mut String, week: &Value, field: &str, meaning: &str) {
    let tasks = array(week, field);
    if tasks.is_empty() {
        return;
    }

    let _ = writeln!(output, "  {field} ({meaning}):");
    for task in tasks {
        let _ = writeln!(
            output,
            "    {}  p{}  {}",
            string(task, "id", "?"),
            number(task, "priority"),
            string(task, "title", "(untitled)")
        );
    }
}

fn array<'a>(value: &'a Value, field: &str) -> &'a [Value] {
    value
        .get(field)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
}

fn number(value: &Value, field: &str) -> String {
    value
        .get(field)
        .and_then(Value::as_i64)
        .map(|number| number.to_string())
        .unwrap_or_else(|| "?".to_string())
}

fn string<'a>(value: &'a Value, field: &str, fallback: &'a str) -> &'a str {
    value.get(field).and_then(Value::as_str).unwrap_or(fallback)
}

#[cfg(test)]
mod tests {
    use super::{render, schedule, ScheduleArgs};
    use crate::testing::{client, Reply, StubServer};
    use serde_json::json;

    #[test]
    fn the_week_range_travels_as_two_dates() {
        let server = StubServer::start(vec![
            Reply::json(200, json!({"data": []})),
            Reply::json(200, json!({"data": []})),
        ]);
        let client = client(&server);

        schedule(
            &client,
            ScheduleArgs {
                from: None,
                to: None,
            },
        )
        .unwrap();

        schedule(
            &client,
            ScheduleArgs {
                from: Some("2026-09-07".to_string()),
                to: Some("2026-09-21".to_string()),
            },
        )
        .unwrap();

        let requests = server.requests();
        assert_eq!(requests[0].target, "/api/v1/schedule");
        assert_eq!(
            requests[1].target,
            "/api/v1/schedule?from=2026-09-07&to=2026-09-21"
        );
    }

    fn week() -> serde_json::Value {
        json!({
            "week": "2026-09-07",
            "capacity": 2400,
            "allocated": 720,
            "calendar_known": true,
            "days": [{
                "day": "2026-09-07",
                "allocated": 720,
                "capacity": 480,
                "tasks": [{"minutes": 720, "task": {"id": "task-1", "title": "Wire the estimator"}}]
            }],
            "overflow": [{"id": "task-2", "title": "Backfill embeddings", "priority": 4}],
            "blocked": [{"id": "task-3", "title": "Ship the board", "priority": 2}]
        })
    }

    #[test]
    fn a_week_prints_its_load_its_days_and_what_missed_out() {
        let rendered = render(&[week()]);

        assert!(rendered.contains("week of 2026-09-07  720/2400 minutes"));
        assert!(rendered.contains("720m  task-1  Wire the estimator"));
        assert!(rendered.contains("overflow (did not fit):"));
        assert!(rendered.contains("task-2  p4  Backfill embeddings"));
        assert!(rendered.contains("blocked (waiting on work that did not fit):"));
    }

    /// Two different facts with two different answers, so they are never one
    /// list: cutting work does nothing about a blocked task.
    #[test]
    fn a_week_with_nothing_left_over_prints_neither_section() {
        let mut week = week();
        week["overflow"] = json!([]);
        week["blocked"] = json!([]);

        let rendered = render(&[week]);

        assert!(!rendered.contains("overflow"));
        assert!(!rendered.contains("blocked"));
    }

    /// A capacity built from the weekend rule alone is a guess, and a reader
    /// who cannot tell will plan a holiday week as five working days.
    #[test]
    fn an_unimported_year_says_so_next_to_the_capacity() {
        let mut week = week();
        week["calendar_known"] = json!(false);

        assert!(render(&[week]).contains("[holidays unknown for this year]"));
    }
}
