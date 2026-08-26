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

/// What was actually worked, rather than what is planned.
///
/// The other half of the same subject, and a separate command for the reason
/// it is a separate endpoint: one is a forecast, the other is what the clocks
/// recorded, and printing them together would put two kinds of claim in one
/// table. `slip` is measured from the day the task was *first* planned, which
/// is why rescheduling it does not make the slip go away.
#[derive(Args)]
pub struct HistoryArgs {
    /// First day of the window; defaults to the Monday of this week
    #[arg(long, value_name = "YYYY-MM-DD")]
    from: Option<String>,

    /// Last day of the window; defaults to today
    #[arg(long, value_name = "YYYY-MM-DD")]
    to: Option<String>,

    /// Only this project's work
    #[arg(long, value_name = "UUID")]
    project_id: Option<String>,
}

pub fn run_history(args: HistoryArgs) -> Result<()> {
    let config = Config::load()?;
    let client = Client::new(config.api(), config.token()?)?;

    history(&client, args)
}

fn history(client: &Client, args: HistoryArgs) -> Result<()> {
    let mut query: Vec<(&str, &str)> = Vec::new();
    if let Some(from) = args.from.as_deref() {
        query.push(("from", from));
    }
    if let Some(to) = args.to.as_deref() {
        query.push(("to", to));
    }
    if let Some(project_id) = args.project_id.as_deref() {
        query.push(("project_id", project_id));
    }

    let records = client::data(client.get("/history", &query)?)?;
    let records = records.as_array().map(Vec::as_slice).unwrap_or_default();

    if records.is_empty() {
        println!("no work was started or in flight in that window");
        return Ok(());
    }

    print!("{}", render_history(records));
    Ok(())
}

fn render_history(records: &[Value]) -> String {
    let mut output = String::new();

    for record in records {
        let task = record.get("task").unwrap_or(&Value::Null);
        let _ = writeln!(
            output,
            "{} → {}  {}  {}  {}",
            string(record, "started_on", "?"),
            // Still in flight. Said as "open" rather than left blank, because
            // a blank column reads as missing data.
            string(record, "completed_on", "open"),
            minutes(record),
            slip(record),
            string(task, "title", "(untitled)")
        );
        let _ = writeln!(
            output,
            "    {}  {}",
            string(task, "id", "?"),
            string(task, "status", "?")
        );
    }

    output
}

/// Estimated against measured, and a gap is printed as a gap: a missing
/// estimate or a missing duration is not a zero, and filling one in would
/// invent the only number this view exists to check.
fn minutes(record: &Value) -> String {
    format!(
        "{}m planned / {}m actual",
        number(record, "expected_minutes"),
        number(record, "actual_minutes")
    )
}

fn slip(record: &Value) -> String {
    match record.get("slip_weeks").and_then(Value::as_i64) {
        None => "never planned".to_string(),
        Some(0) => "on time".to_string(),
        Some(weeks) if weeks > 0 => format!("+{weeks}w late"),
        Some(weeks) => format!("{weeks}w early"),
    }
}

/// What the estimates turned out to be worth.
///
/// Two tables, because there are two questions: is the week-to-week arithmetic
/// holding, and is the story-point ladder meaning anything. Neither prints a
/// ratio -- with a handful of tasks a week, one number without its sample size
/// is the difference between a signal and a coincidence, so the counts are
/// printed beside the minutes and the division is left to whoever is reading.
#[derive(Args)]
pub struct CalibrationArgs {
    /// First day of the window; defaults to twelve weeks back
    #[arg(long, value_name = "YYYY-MM-DD")]
    from: Option<String>,

    /// Last day of the window; defaults to today
    #[arg(long, value_name = "YYYY-MM-DD")]
    to: Option<String>,

    /// Only this project's finished work
    #[arg(long, value_name = "UUID")]
    project_id: Option<String>,
}

pub fn run_calibration(args: CalibrationArgs) -> Result<()> {
    let config = Config::load()?;
    let client = Client::new(config.api(), config.token()?)?;

    calibration(&client, args)
}

fn calibration(client: &Client, args: CalibrationArgs) -> Result<()> {
    let mut query: Vec<(&str, &str)> = Vec::new();
    if let Some(from) = args.from.as_deref() {
        query.push(("from", from));
    }
    if let Some(to) = args.to.as_deref() {
        query.push(("to", to));
    }
    if let Some(project_id) = args.project_id.as_deref() {
        query.push(("project_id", project_id));
    }

    let data = client::data(client.get("/calibration", &query)?)?;
    print!("{}", render_calibration(&data));
    Ok(())
}

fn render_calibration(data: &Value) -> String {
    let mut output = String::new();
    let _ = writeln!(output, "week        done  compared  planned/actual");

    for week in array(data, "weeks") {
        let _ = writeln!(
            output,
            "{}  {:>4}  {:>8}  {}m/{}m",
            string(week, "week", "?"),
            number(week, "completed"),
            number(week, "comparable"),
            number(week, "expected_minutes"),
            number(week, "actual_minutes")
        );

        // Said per week rather than once at the bottom: a week whose sums came
        // from two of nine finished tasks is not the same reading as one whose
        // sums came from all nine, and a total would hide which was which.
        let left_out = format!(
            "{} unestimated, {} unmeasured",
            number(week, "unestimated"),
            number(week, "unmeasured")
        );
        if !left_out.starts_with("0 unestimated, 0 unmeasured") {
            let _ = writeln!(output, "              left out: {left_out}");
        }
    }

    let _ = writeln!(output, "\npoints  tasks  measured  median actual");
    for rung in array(data, "difficulty") {
        let _ = writeln!(
            output,
            "{:>6}  {:>5}  {:>8}  {}",
            number(rung, "difficulty"),
            number(rung, "tasks"),
            number(rung, "measured"),
            match rung.get("median_actual_minutes").and_then(Value::as_i64) {
                // Not "0m". Nothing at this rung has been measured, which is
                // the first thing to know before trusting a number from it.
                None => "no data".to_string(),
                Some(minutes) => format!("{minutes}m"),
            }
        );
    }

    output
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

#[cfg(test)]
mod history_tests {
    use super::{history, render_history, HistoryArgs};
    use crate::testing::{client, Reply, StubServer};
    use serde_json::json;

    #[test]
    fn the_window_and_the_project_travel_as_query_parameters() {
        let server = StubServer::start(vec![
            Reply::json(200, json!({"data": []})),
            Reply::json(200, json!({"data": []})),
        ]);
        let client = client(&server);

        history(
            &client,
            HistoryArgs {
                from: None,
                to: None,
                project_id: None,
            },
        )
        .unwrap();

        history(
            &client,
            HistoryArgs {
                from: Some("2026-06-08".to_string()),
                to: Some("2026-06-14".to_string()),
                project_id: Some("project-1".to_string()),
            },
        )
        .unwrap();

        let requests = server.requests();
        assert_eq!(requests[0].target, "/api/v1/history");
        assert_eq!(
            requests[1].target,
            "/api/v1/history?from=2026-06-08&to=2026-06-14&project_id=project-1"
        );
    }

    #[test]
    fn a_record_shows_the_span_the_minutes_and_the_slip() {
        let rendered = render_history(&[json!({
            "task": {"id": "task-1", "title": "Wire the estimator", "status": "done"},
            "started_on": "2026-06-09",
            "completed_on": "2026-06-10",
            "slip_weeks": 3,
            "expected_minutes": 130,
            "actual_minutes": 300
        })]);

        assert!(rendered.contains("2026-06-09 → 2026-06-10"));
        assert!(rendered.contains("130m planned / 300m actual"));
        assert!(rendered.contains("+3w late"));
        assert!(rendered.contains("task-1  done"));
    }

    /// Three different absences, and none of them is a zero: still running,
    /// never planned, never measured.
    #[test]
    fn what_was_not_measured_is_not_printed_as_a_number() {
        let rendered = render_history(&[json!({
            "task": {"id": "task-2", "title": "Ship the board", "status": "in_progress"},
            "started_on": "2026-06-09",
            "completed_on": null,
            "slip_weeks": null,
            "expected_minutes": null,
            "actual_minutes": null
        })]);

        assert!(rendered.contains("2026-06-09 → open"));
        assert!(rendered.contains("?m planned / ?m actual"));
        assert!(rendered.contains("never planned"));
    }

    #[test]
    fn the_calibration_window_travels_the_same_way() {
        use super::{calibration, CalibrationArgs};

        let server = StubServer::start(vec![Reply::json(
            200,
            json!({"data": {"weeks": [], "difficulty": []}}),
        )]);

        calibration(
            &client(&server),
            CalibrationArgs {
                from: Some("2026-06-01".to_string()),
                to: None,
                project_id: Some("project-1".to_string()),
            },
        )
        .unwrap();

        assert_eq!(
            server.only_request()[0].target,
            "/api/v1/calibration?from=2026-06-01&project_id=project-1"
        );
    }

    #[test]
    fn calibration_prints_the_counts_beside_the_minutes() {
        use super::render_calibration;

        let rendered = render_calibration(&json!({
            "weeks": [
                {
                    "week": "2026-06-08", "completed": 4, "comparable": 2,
                    "expected_minutes": 180, "actual_minutes": 240,
                    "unestimated": 1, "unmeasured": 1
                },
                {
                    "week": "2026-06-15", "completed": 0, "comparable": 0,
                    "expected_minutes": 0, "actual_minutes": 0,
                    "unestimated": 0, "unmeasured": 0
                }
            ],
            "difficulty": [
                {"difficulty": 5, "tasks": 3, "measured": 3, "median_actual_minutes": 90},
                {"difficulty": 8, "tasks": 0, "measured": 0, "median_actual_minutes": null}
            ]
        }));

        assert!(rendered.contains("2026-06-08     4         2  180m/240m"));
        assert!(rendered.contains("left out: 1 unestimated, 1 unmeasured"));
        // A week that left nothing out says nothing about it.
        assert_eq!(rendered.matches("left out").count(), 1);
        assert!(rendered.contains("     5      3         3  90m"));
        // Never "0m": nothing at this rung was measured.
        assert!(rendered.contains("no data"));
    }

    #[test]
    fn on_time_says_so_rather_than_printing_a_zero() {
        let rendered = render_history(&[json!({
            "task": {"id": "task-3", "title": "On time", "status": "done"},
            "started_on": "2026-06-09",
            "completed_on": "2026-06-09",
            "slip_weeks": 0,
            "expected_minutes": 60,
            "actual_minutes": 60
        })]);

        assert!(rendered.contains("on time"));
    }
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
