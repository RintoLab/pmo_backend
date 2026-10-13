use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::{json, Value};

const NAME: &str = "rinto-requirements";
const BODY: &str = include_str!("../../skills/server/rinto-requirements/SKILL.md");
const OLD_HASH: &str = "cba06b5736faf67e54b07b561eae94395e774c517a7d910a54369e1263ccfbd4";

struct Sandbox(PathBuf);

impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "rinto-skills-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        let sandbox = Self(path.canonicalize().unwrap());
        sandbox.dir("home");
        sandbox.dir("project");
        sandbox
    }

    fn dir(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn config(&self) -> PathBuf {
        self.0.join("config/skills.json")
    }

    fn command(&self, program: &str, cwd: &Path) -> Command {
        let mut command = Command::new(program);
        command
            .current_dir(cwd)
            .env("HOME", self.0.join("home"))
            .env("XDG_CONFIG_HOME", self.0.join("home/.config"))
            .env("RINTO_CONFIG", self.0.join("config/cli.json"))
            .env_remove("RINTO_API")
            .env_remove("RINTO_TOKEN")
            .env_remove("RINTO_CONVERSATION_ID");
        command
    }

    fn run(&self, cwd: &Path, args: &[&str]) -> Output {
        self.command(env!("CARGO_BIN_EXE_rinto-pmo"), cwd)
            .arg("skill")
            .args(args)
            .output()
            .unwrap()
    }

    fn ok(&self, cwd: &Path, args: &[&str]) -> String {
        let output = self.run(cwd, args);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }

    fn git(&self, cwd: &Path, args: &[&str]) {
        let output = self
            .command("git", cwd)
            .args([
                "-c",
                "user.name=Skill Tests",
                "-c",
                "user.email=skills@example.test",
                "-c",
                "core.hooksPath=/dev/null",
            ])
            .args(args)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn skill(root: &Path, directory: &str) -> PathBuf {
    root.join(directory).join(NAME).join("SKILL.md")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn write_json(path: &Path, value: &Value) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, serde_json::to_vec_pretty(value).unwrap()).unwrap();
}

fn make_old(state: &Path, file: &Path) {
    fs::write(file, "old").unwrap();
    let mut value = read_json(state);
    value["installed"][0]["sha256"] = json!(OLD_HASH);
    // Legacy records did not have a version or an agent.
    value["installed"][0]
        .as_object_mut()
        .unwrap()
        .remove("version");
    value["installed"][0]
        .as_object_mut()
        .unwrap()
        .remove("agent");
    write_json(state, &value);
}

fn bundled_skills() -> Vec<(String, String)> {
    let mut skills = Vec::new();
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../skills");
    for bundle in fs::read_dir(root).unwrap() {
        let bundle = bundle.unwrap().path();
        if !bundle.is_dir() {
            continue;
        }
        for entry in fs::read_dir(bundle).unwrap() {
            let directory = entry.unwrap().path();
            let file = directory.join("SKILL.md");
            if file.is_file() {
                skills.push((
                    directory.file_name().unwrap().to_str().unwrap().to_owned(),
                    fs::read_to_string(file).unwrap(),
                ));
            }
        }
    }
    assert!(skills.len() > 1);
    skills
}

#[test]
fn install_all_into_custom_subdirectories_is_recorded_and_repeatable() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    let custom = project.join("custom skills/nested");
    let skills = bundled_skills();
    let args = ["install", "--all", "--dir", custom.to_str().unwrap()];
    sandbox.ok(&project, &args);
    let state = read_json(&sandbox.config());
    let records = state["installed"].as_array().unwrap();
    assert_eq!(records.len(), skills.len());
    assert_eq!(fs::read_dir(&custom).unwrap().count(), skills.len());
    for (name, body) in &skills {
        let file = custom.join(name).join("SKILL.md");
        assert_eq!(fs::read_to_string(&file).unwrap(), *body);
        assert!(records
            .iter()
            .any(|record| { record["name"] == *name && record["path"] == file.to_str().unwrap() }));
    }
    let output = sandbox.ok(&project, &args);
    assert_eq!(output.matches("already current:").count(), skills.len());
    assert_eq!(read_json(&sandbox.config()), state);
    assert!(sandbox
        .ok(&project, &["sync"])
        .contains("skills already current"));
    assert!(!sandbox.0.join("home/.agents").exists());
    assert!(!sandbox.0.join("home/.pi").exists());
    assert!(!project.join(".rinto").exists());
}

#[test]
fn install_all_checks_the_whole_batch_before_writing_and_supports_force() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    let custom = sandbox.dir("custom");
    let edited = custom.join(NAME).join("SKILL.md");
    fs::create_dir_all(edited.parent().unwrap()).unwrap();
    fs::write(&edited, "local edits").unwrap();
    let args = ["install", "--all", "--dir", custom.to_str().unwrap()];
    let output = sandbox.run(&project, &args);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("--force"));
    assert_eq!(fs::read_dir(&custom).unwrap().count(), 1);
    assert_eq!(fs::read_to_string(&edited).unwrap(), "local edits");
    assert!(!sandbox.config().exists());
    let mut forced = args.to_vec();
    forced.push("--force");
    sandbox.ok(&project, &forced);
    for (name, body) in bundled_skills() {
        assert_eq!(
            fs::read_to_string(custom.join(name).join("SKILL.md")).unwrap(),
            body
        );
    }
}

#[test]
fn install_all_supports_default_agents_global_and_project_scopes() {
    let skills = bundled_skills();
    for (flags, roots, project_scope) in [
        (
            vec![],
            vec!["home/.pi/agent/skills", "home/.agents/skills"],
            false,
        ),
        (
            vec!["--global", "--agent", "opencode"],
            vec!["home/.config/opencode/skills"],
            false,
        ),
        (
            vec!["--project", "--agent", "pi,codex", "--agent", "pi"],
            vec!["project/.pi/skills", "project/.agents/skills"],
            true,
        ),
        (
            vec!["--project", "project", "--agent", "opencode"],
            vec!["project/.opencode/skills"],
            true,
        ),
    ] {
        let sandbox = Sandbox::new();
        let mut args = vec!["install", "--all"];
        args.extend(flags);
        // The explicit relative project path is resolved from this directory.
        let cwd = if args.contains(&"project") {
            &sandbox.0
        } else {
            &sandbox.0.join("project")
        };
        sandbox.ok(cwd, &args);
        for root in &roots {
            for (name, body) in &skills {
                let file = sandbox.0.join(root).join(name).join("SKILL.md");
                assert_eq!(fs::read_to_string(file).unwrap(), *body);
            }
        }
        let state = if project_scope {
            sandbox.0.join("project/.rinto/skills.json")
        } else {
            sandbox.config()
        };
        assert_eq!(
            read_json(&state)["installed"].as_array().unwrap().len(),
            skills.len() * roots.len()
        );
        if project_scope {
            assert!(!sandbox.config().exists());
        } else {
            assert!(!sandbox.0.join("project/.rinto").exists());
        }
    }
}

#[test]
fn install_requires_exactly_one_of_name_and_all() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    for args in [
        vec!["install"],
        vec!["install", NAME, "--all"],
        vec!["install", "unknown-skill"],
        vec!["install", "--all", "--dir", "skills", "--project"],
        vec!["install", "--all", "--dir", "skills", "--agent", "pi"],
        vec!["install", "--all", "--dir", "skills", "--global"],
    ] {
        assert!(!sandbox.run(&project, &args).status.success(), "{args:?}");
    }
    assert!(!sandbox.config().exists());
    assert!(!project.join("skills").exists());
}

#[test]
fn default_install_and_custom_directory_remain_compatible() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    let home = sandbox.dir("home");
    sandbox.ok(&project, &["install", NAME]);
    assert_eq!(
        fs::read_to_string(skill(&home, ".pi/agent/skills")).unwrap(),
        BODY
    );
    assert_eq!(
        fs::read_to_string(skill(&home, ".agents/skills")).unwrap(),
        BODY
    );
    assert!(!home.join(".config/opencode").exists());
    assert!(!project.join(".rinto").exists());
    assert_eq!(
        read_json(&sandbox.config())["installed"]
            .as_array()
            .unwrap()
            .len(),
        2
    );

    let custom = sandbox.dir("custom skills");
    sandbox.ok(
        &project,
        &["install", NAME, "--dir", custom.to_str().unwrap()],
    );
    assert_eq!(
        read_json(&sandbox.config())["installed"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    assert_eq!(
        fs::read_to_string(custom.join(NAME).join("SKILL.md")).unwrap(),
        BODY
    );
    sandbox.ok(&project, &["sync"]);
}

#[test]
fn scopes_are_isolated_and_old_global_records_still_sync() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    let global = skill(&sandbox.dir("home"), ".config/opencode/skills");
    let local = skill(&project, ".opencode/skills");
    let state = project.join(".rinto/skills.json");
    sandbox.ok(
        &project,
        &["install", NAME, "--agent", "opencode", "--global"],
    );
    sandbox.ok(
        &project,
        &["install", NAME, "--agent", "opencode", "--project"],
    );
    let entry = read_json(&state)["installed"][0].clone();
    assert_eq!(entry["path"], format!(".opencode/skills/{NAME}/SKILL.md"));
    assert_eq!(entry["agent"], "opencode");
    make_old(&sandbox.config(), &global);
    make_old(&state, &local);

    sandbox.ok(&project, &["sync"]);
    assert_eq!(fs::read_to_string(&global).unwrap(), BODY);
    assert_eq!(fs::read_to_string(&local).unwrap(), "old");
    let global_state = fs::read(sandbox.config()).unwrap();
    let listing = sandbox.ok(&project, &["list", "--project"]);
    assert!(listing.contains("out of date"));
    assert!(!listing.contains(global.to_str().unwrap()));
    sandbox.ok(&project, &["sync", "--project"]);
    assert_eq!(fs::read_to_string(&local).unwrap(), BODY);
    assert_eq!(fs::read(sandbox.config()).unwrap(), global_state);
}

#[test]
fn project_records_survive_a_move_and_protect_edits_and_deletions() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    sandbox.ok(
        &project,
        &["install", NAME, "--agent", "opencode", "--project"],
    );
    let moved = sandbox.0.join("moved 'project");
    fs::rename(&project, &moved).unwrap();
    let file = skill(&moved, ".opencode/skills");
    let state = moved.join(".rinto/skills.json");
    make_old(&state, &file);
    sandbox.ok(&sandbox.0, &["sync", "--project", moved.to_str().unwrap()]);
    assert_eq!(fs::read_to_string(&file).unwrap(), BODY);
    fs::write(&file, "my edits").unwrap();
    let output = sandbox.ok(&moved, &["sync", "--project"]);
    assert!(output.contains("edited since install"));
    assert!(output.contains("--project '") && output.contains("'\\''"));
    assert_eq!(fs::read_to_string(&file).unwrap(), "my edits");
    assert!(!sandbox
        .run(
            &moved,
            &["install", NAME, "--agent", "opencode", "--project"]
        )
        .status
        .success());
    sandbox.ok(&moved, &["sync", "--project", "--force"]);
    assert_eq!(fs::read_to_string(&file).unwrap(), BODY);
    fs::remove_file(&file).unwrap();
    sandbox.ok(&moved, &["sync", "--project"]);
    assert!(!file.exists());
    assert!(read_json(&state)["installed"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(!sandbox.config().exists());
}

#[test]
fn project_agent_selection_defaults_and_preflight() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    let codex = skill(&project, ".agents/skills");
    fs::create_dir_all(codex.parent().unwrap()).unwrap();
    fs::write(&codex, "edited").unwrap();
    assert!(!sandbox
        .run(&project, &["install", NAME, "--project"])
        .status
        .success());
    assert!(!project.join(".pi").exists());
    assert!(!project.join(".rinto").exists());
    sandbox.ok(&project, &["install", NAME, "--project", "--force"]);
    assert_eq!(
        fs::read_to_string(skill(&project, ".pi/skills")).unwrap(),
        BODY
    );
    assert_eq!(fs::read_to_string(&codex).unwrap(), BODY);
    assert!(!project.join(".opencode").exists());
    sandbox.ok(
        &project,
        &[
            "install",
            NAME,
            "--project",
            "--agent",
            "pi,opencode",
            "--agent",
            "opencode",
        ],
    );
    let state = read_json(&project.join(".rinto/skills.json"));
    assert_eq!(state["installed"].as_array().unwrap().len(), 3);
    let listing = sandbox.ok(&project, &["list", "--project"]);
    for directory in [".pi/skills", ".agents/skills", ".opencode/skills"] {
        assert!(listing.contains(skill(&project, directory).to_str().unwrap()));
    }
}

#[test]
fn project_discovery_uses_worktree_root_but_explicit_paths_are_exact() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    sandbox.git(&project, &["init"]);
    sandbox.git(&project, &["commit", "--allow-empty", "-m", "test"]);
    let worktree = sandbox.0.join("worktree");
    sandbox.git(
        &project,
        &[
            "worktree",
            "add",
            "-b",
            "skills-test",
            worktree.to_str().unwrap(),
        ],
    );
    let nested = sandbox.dir("worktree/nested");
    sandbox.ok(
        &nested,
        &["install", NAME, "--agent", "opencode", "--project"],
    );
    assert!(skill(&worktree, ".opencode/skills").exists());
    assert!(!project.join(".opencode").exists());
    assert!(!nested.join(".opencode").exists());
    sandbox.ok(
        &nested,
        &["install", NAME, "--agent", "opencode", "--project", "."],
    );
    assert!(skill(&nested, ".opencode/skills").exists());
}

#[test]
fn unrecorded_copies_are_reported_or_adopted_only_in_selected_scope() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    let file = skill(&project, ".opencode/skills");
    let state = project.join(".rinto/skills.json");
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, "unknown edits").unwrap();
    let listing = sandbox.ok(&project, &["list", "--project"]);
    assert!(listing.contains("not in this CLI's record"));
    assert!(!state.exists());
    let output = sandbox.ok(&project, &["sync", "--project", "--force"]);
    assert!(output.contains("--agent opencode --project"));
    assert_eq!(fs::read_to_string(&file).unwrap(), "unknown edits");
    sandbox.ok(
        &project,
        &[
            "install",
            NAME,
            "--agent",
            "opencode",
            "--project",
            "--force",
        ],
    );
    fs::remove_file(&state).unwrap();
    sandbox.ok(&project, &["sync", "--project"]);
    assert_eq!(read_json(&state)["installed"][0]["agent"], "opencode");
    assert!(!sandbox.config().exists());
}

#[test]
fn conflicting_flags_and_invalid_projects_fail_before_writes() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    for args in [
        vec!["install", NAME, "--project", "--global"],
        vec!["list", "--project", "--global"],
        vec!["sync", "--project", "--global"],
        vec!["install", NAME, "--dir", "skills", "--project"],
        vec!["install", NAME, "--dir", "skills", "--global"],
        vec!["install", NAME, "--dir", "skills", "--agent", "opencode"],
        vec!["install", NAME, "--project", "missing"],
    ] {
        assert!(!sandbox.run(&project, &args).status.success(), "{args:?}");
    }
    assert!(!project.join(".rinto").exists());
    assert!(!sandbox.config().exists());
}

#[test]
fn project_commands_need_no_home_or_global_config_and_legacy_list_still_works() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    fs::create_dir_all(sandbox.config().parent().unwrap()).unwrap();
    fs::write(sandbox.config(), "invalid JSON").unwrap();
    assert!(sandbox.ok(&project, &["list"]).contains(NAME));
    for args in [
        vec!["install", NAME, "--project", "--agent", "opencode"],
        vec!["list", "--project"],
        vec!["sync", "--project"],
    ] {
        let output = sandbox
            .command(env!("CARGO_BIN_EXE_rinto-pmo"), &project)
            .env_remove("HOME")
            .arg("skill")
            .args(args)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    assert_eq!(
        fs::read_to_string(sandbox.config()).unwrap(),
        "invalid JSON"
    );

    // The old --dir path is still maintained without an agent home directory.
    fs::remove_file(sandbox.config()).unwrap();
    let custom = sandbox.dir("custom");
    sandbox.ok(
        &project,
        &["install", NAME, "--dir", custom.to_str().unwrap()],
    );
    let file = custom.join(NAME).join("SKILL.md");
    make_old(&sandbox.config(), &file);
    let output = sandbox
        .command(env!("CARGO_BIN_EXE_rinto-pmo"), &project)
        .env_remove("HOME")
        .args(["skill", "sync"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(fs::read_to_string(file).unwrap(), BODY);
}

#[test]
fn project_records_reject_absolute_paths_and_traversal_before_syncing() {
    let sandbox = Sandbox::new();
    let project = sandbox.dir("project");
    sandbox.ok(
        &project,
        &["install", NAME, "--project", "--agent", "opencode"],
    );
    let local = skill(&project, ".opencode/skills");
    let state = project.join(".rinto/skills.json");
    make_old(&state, &local);
    let original = read_json(&state);
    let outside = sandbox.0.join("outside.md");
    fs::write(&outside, "old").unwrap();
    for path in ["../outside.md", outside.to_str().unwrap()] {
        let mut value = original.clone();
        let mut extra = value["installed"][0].clone();
        extra["path"] = json!(path);
        value["installed"].as_array_mut().unwrap().push(extra);
        write_json(&state, &value);
        for command in ["list", "sync"] {
            let output = sandbox.run(&project, &[command, "--project"]);
            assert!(!output.status.success());
            assert!(String::from_utf8_lossy(&output.stderr).contains("must be relative"));
        }
        assert_eq!(fs::read_to_string(&local).unwrap(), "old");
        assert_eq!(fs::read_to_string(&outside).unwrap(), "old");
        assert_eq!(read_json(&state), value);
    }
}

#[cfg(unix)]
#[test]
fn project_symlinks_cannot_escape_via_skill_or_state_paths() {
    use std::os::unix::fs::symlink;

    let sandbox = Sandbox::new();
    let outside = sandbox.dir("outside");
    for component in [".opencode", ".rinto"] {
        let project = sandbox.dir(&format!("project-{component}"));
        symlink(&outside, project.join(component)).unwrap();
        let output = sandbox.run(
            &project,
            &["install", NAME, "--agent", "opencode", "--project"],
        );
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("outside the project"));
        assert!(!skill(&outside, "skills").exists());
        assert!(!outside.join("skills.json").exists());
        assert!(!skill(&project, ".opencode/skills").exists());
    }
    let project = sandbox.dir("project");
    sandbox.ok(
        &project,
        &["install", NAME, "--agent", "opencode", "--project"],
    );
    let local = skill(&project, ".opencode/skills");
    let external = outside.join("SKILL.md");
    fs::write(&external, "my edits").unwrap();
    fs::remove_file(&local).unwrap();
    symlink(&external, &local).unwrap();
    assert!(!sandbox
        .run(&project, &["sync", "--project", "--force"])
        .status
        .success());
    assert_eq!(fs::read_to_string(&external).unwrap(), "my edits");
}
