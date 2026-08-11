use std::cmp::Ordering;
use std::io::Read;
use std::path::{Path, PathBuf};

use clap::Args;
use serde_json::Value;

use crate::error::{Error, Result};

const RELEASES_URL: &str =
    "https://api.github.com/repos/RintoLab/pmo_backend/releases?per_page=100";
const TAG_PREFIX: &str = "cli-v";
const USER_AGENT: &str = "rinto-pmo-cli-updater";
const MAX_BINARY_BYTES: u64 = 100 * 1024 * 1024;

#[derive(Args)]
pub struct UpdateArgs {
    /// Only report whether a newer CLI release exists
    #[arg(long)]
    check: bool,
}

pub fn run(args: UpdateArgs) -> Result<()> {
    let current = Version::parse(env!("CARGO_PKG_VERSION")).ok_or_else(|| {
        Error::Config(format!(
            "the compiled CLI version {:?} is not semantic x.y.z",
            env!("CARGO_PKG_VERSION")
        ))
    })?;
    let releases = github_json(RELEASES_URL)?;
    let (release, latest) = latest_cli_release(&releases)
        .ok_or_else(|| Error::Network("GitHub has no published CLI release".to_string()))?;

    if latest <= current {
        println!("already current: {current}");
        return Ok(());
    }

    let tag = release
        .get("tag_name")
        .and_then(Value::as_str)
        .unwrap_or("(unknown tag)");
    if args.check {
        println!("update available: {current} -> {latest} ({tag})");
        return Ok(());
    }

    let asset_name = target_asset()?;
    let asset = release
        .get("assets")
        .and_then(Value::as_array)
        .and_then(|assets| {
            assets
                .iter()
                .find(|asset| asset.get("name").and_then(Value::as_str) == Some(asset_name))
        })
        .ok_or_else(|| {
            Error::Network(format!(
                "release {tag} has no asset for this platform ({asset_name})"
            ))
        })?;
    let url = asset
        .get("browser_download_url")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Network(format!("release asset {asset_name} has no download URL")))?;
    let expected_size = asset.get("size").and_then(Value::as_u64);
    let binary = download(url, expected_size)?;
    install(&binary)?;

    println!("updated rinto-pmo from {current} to {latest}");
    Ok(())
}

fn github_json(url: &str) -> Result<Value> {
    let request = ureq::get(url)
        .set("Accept", "application/vnd.github+json")
        .set("User-Agent", USER_AGENT)
        .set("X-GitHub-Api-Version", "2022-11-28");

    match request.call() {
        Ok(response) => response.into_json::<Value>().map_err(|err| {
            Error::Network(format!("could not parse GitHub's release response: {err}"))
        }),
        Err(ureq::Error::Status(status, response)) => {
            let body = response.into_json::<Value>().unwrap_or(Value::Null);
            let message = body
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("no message supplied by GitHub");
            Err(Error::Network(format!(
                "GitHub returned {status} while listing releases: {message}"
            )))
        }
        Err(ureq::Error::Transport(err)) => {
            Err(Error::Network(format!("could not reach GitHub: {err}")))
        }
    }
}

fn latest_cli_release(releases: &Value) -> Option<(&Value, Version)> {
    releases
        .as_array()?
        .iter()
        .filter(|release| release.get("draft").and_then(Value::as_bool) != Some(true))
        .filter(|release| release.get("prerelease").and_then(Value::as_bool) != Some(true))
        .filter_map(|release| {
            let tag = release.get("tag_name")?.as_str()?;
            let version = Version::parse(tag.strip_prefix(TAG_PREFIX)?)?;
            Some((release, version))
        })
        .max_by_key(|(_release, version)| *version)
}

fn download(url: &str, expected_size: Option<u64>) -> Result<Vec<u8>> {
    let response = match ureq::get(url).set("User-Agent", USER_AGENT).call() {
        Ok(response) => response,
        Err(ureq::Error::Status(status, _response)) => {
            return Err(Error::Network(format!(
                "GitHub returned {status} while downloading the CLI"
            )))
        }
        Err(ureq::Error::Transport(err)) => {
            return Err(Error::Network(format!(
                "could not download the CLI from GitHub: {err}"
            )))
        }
    };

    let mut bytes = Vec::new();
    response
        .into_reader()
        .take(MAX_BINARY_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|err| Error::Network(format!("could not read the downloaded CLI: {err}")))?;

    if bytes.len() as u64 > MAX_BINARY_BYTES {
        return Err(Error::Network(format!(
            "the downloaded CLI exceeds the {MAX_BINARY_BYTES}-byte safety limit"
        )));
    }
    if bytes.is_empty() {
        return Err(Error::Network(
            "GitHub returned an empty CLI binary".to_string(),
        ));
    }
    match expected_size {
        Some(expected) if bytes.len() as u64 != expected => {
            return Err(Error::Network(format!(
                "the downloaded CLI was {} bytes, but GitHub reported {expected}",
                bytes.len()
            )));
        }
        _ => {}
    }

    Ok(bytes)
}

fn install(binary: &[u8]) -> Result<()> {
    let executable = std::env::current_exe()
        .map_err(|err| Error::Io(format!("could not locate the running executable: {err}")))?;
    install_at(&executable, binary)
}

fn install_at(executable: &Path, binary: &[u8]) -> Result<()> {
    let directory = executable.parent().ok_or_else(|| {
        Error::Io(format!(
            "the running executable {} has no parent directory",
            executable.display()
        ))
    })?;
    let temporary = temporary_path(directory);
    std::fs::write(&temporary, binary)
        .map_err(|err| Error::Io(format!("could not write {}: {err}", temporary.display())))?;
    make_executable(&temporary)?;

    if let Err(error) = replace_executable(&executable, &temporary) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    Ok(())
}

fn temporary_path(directory: &Path) -> PathBuf {
    directory.join(format!(".rinto-pmo-update-{}", std::process::id()))
}

fn replace_executable(executable: &Path, temporary: &Path) -> Result<()> {
    let backup = executable.with_extension("rinto-pmo-old");
    if backup.exists() {
        std::fs::remove_file(&backup)
            .map_err(|err| Error::Io(format!("could not remove {}: {err}", backup.display())))?;
    }

    std::fs::rename(executable, &backup).map_err(|err| {
        Error::Io(format!(
            "could not move the running executable {} aside: {err}",
            executable.display()
        ))
    })?;

    if let Err(err) = std::fs::rename(temporary, executable) {
        let rollback = std::fs::rename(&backup, executable);
        return Err(Error::Io(match rollback {
            Ok(()) => format!("could not install the downloaded CLI: {err}; the old CLI was restored"),
            Err(rollback_err) => format!(
                "could not install the downloaded CLI: {err}; restoring {} also failed: {rollback_err}",
                backup.display()
            ),
        }));
    }

    // Windows may keep the renamed, currently running image locked until this
    // process exits. Leaving one `.rinto-pmo-old` file is harmless; the next
    // update removes it before replacing the binary.
    let _ = std::fs::remove_file(backup);
    Ok(())
}

#[cfg(unix)]
fn make_executable(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let mut permissions = std::fs::metadata(path)
        .map_err(|err| Error::Io(format!("could not inspect {}: {err}", path.display())))?
        .permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(path, permissions).map_err(|err| {
        Error::Io(format!(
            "could not make {} executable: {err}",
            path.display()
        ))
    })
}

#[cfg(not(unix))]
fn make_executable(_path: &Path) -> Result<()> {
    Ok(())
}

fn target_asset() -> Result<&'static str> {
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        Ok("rinto-pmo-x86_64-unknown-linux-gnu")
    } else if cfg!(all(target_os = "linux", target_arch = "aarch64")) {
        Ok("rinto-pmo-aarch64-unknown-linux-gnu")
    } else if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Ok("rinto-pmo-aarch64-apple-darwin")
    } else if cfg!(all(target_os = "macos", target_arch = "x86_64")) {
        Ok("rinto-pmo-x86_64-apple-darwin")
    } else if cfg!(all(target_os = "windows", target_arch = "x86_64")) {
        Ok("rinto-pmo-x86_64-pc-windows-msvc.exe")
    } else {
        Err(Error::Input(format!(
            "self-update is not published for {}-{}; install this CLI manually",
            std::env::consts::ARCH,
            std::env::consts::OS
        )))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Version {
    major: u64,
    minor: u64,
    patch: u64,
}

impl Version {
    fn parse(value: &str) -> Option<Self> {
        let mut parts = value.split('.');
        let version = Self {
            major: parts.next()?.parse().ok()?,
            minor: parts.next()?.parse().ok()?,
            patch: parts.next()?.parse().ok()?,
        };
        if parts.next().is_some() {
            return None;
        }
        Some(version)
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.major, self.minor, self.patch).cmp(&(other.major, other.minor, other.patch))
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::{install_at, latest_cli_release, Version};
    use serde_json::json;

    #[test]
    fn semantic_versions_are_ordered_numerically() {
        assert!(Version::parse("1.10.0") > Version::parse("1.9.9"));
        assert!(Version::parse("1.2").is_none());
        assert!(Version::parse("1.2.3.4").is_none());
    }

    #[test]
    fn installs_a_download_over_the_existing_binary() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "rinto-pmo-update-test-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let executable = directory.join(if cfg!(windows) {
            "rinto-pmo.exe"
        } else {
            "rinto-pmo"
        });
        std::fs::write(&executable, b"old binary").unwrap();

        install_at(&executable, b"new binary").unwrap();

        assert_eq!(std::fs::read(&executable).unwrap(), b"new binary");
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn selects_the_newest_stable_cli_release_only() {
        let releases = json!([
            {"tag_name": "v99.0.0", "draft": false, "prerelease": false},
            {"tag_name": "cli-v1.2.0", "draft": false, "prerelease": false},
            {"tag_name": "cli-v2.0.0", "draft": false, "prerelease": true},
            {"tag_name": "cli-v1.10.0", "draft": false, "prerelease": false},
            {"tag_name": "cli-v3.0.0", "draft": true, "prerelease": false}
        ]);

        let (release, version) = latest_cli_release(&releases).unwrap();
        assert_eq!(release["tag_name"], "cli-v1.10.0");
        assert_eq!(version, Version::parse("1.10.0").unwrap());
    }
}
