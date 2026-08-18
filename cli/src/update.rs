use std::cmp::Ordering;
use std::io::Read;
use std::path::{Path, PathBuf};

use clap::Args;
use serde_json::Value;

use crate::error::{Error, Result};

const GITEA_BASE_URL: &str = "https://gitea.kenton.wang";
const PACKAGE_OWNER: &str = "Rinto";
const PACKAGE_NAME: &str = "rinto-pmo";
const USER_AGENT: &str = "rinto-pmo-cli-updater";
const MAX_BINARY_BYTES: u64 = 100 * 1024 * 1024;
const MAX_JSON_BYTES: u64 = 1024 * 1024;
const PACKAGE_PAGE_SIZE: usize = 50;
const MAX_PACKAGE_PAGES: usize = 20;

#[derive(Args)]
pub struct UpdateArgs {
    /// Only report whether a newer CLI package exists
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

    let versions = list_package_versions()?;
    let (latest, manifest) = newest_finalized(versions)?
        .ok_or_else(|| Error::Network("Gitea has no finalized CLI package".to_string()))?;

    if latest < current {
        println!("already current: {current}");
        return Ok(());
    }

    let target = target_asset();
    if latest == current && target.is_err() {
        println!("already current: {current}");
        return Ok(());
    }
    let (platform, expected_name) = target?;
    let asset = manifest_asset(&manifest, platform, expected_name)?;
    let refresh = latest == current;

    if refresh {
        let executable = std::env::current_exe()
            .map_err(|err| Error::Io(format!("could not locate the running executable: {err}")))?;
        if executable_matches_manifest(&executable, &asset)? {
            println!("already current: {current}");
            return Ok(());
        }
        if args.check {
            println!("refresh available: {current} package content changed");
            return Ok(());
        }
    } else if args.check {
        println!("update available: {current} -> {latest}");
        return Ok(());
    }

    let url = package_file_url(latest, &asset.name);
    let binary = download(&url, asset.size)?;
    verify_sha256(&binary, &asset.sha256)?;
    install(&binary)?;

    if refresh {
        println!("refreshed rinto-pmo {current}");
    } else {
        println!("updated rinto-pmo from {current} to {latest}");
    }
    Ok(())
}

fn package_file_url(version: Version, name: &str) -> String {
    format!("{GITEA_BASE_URL}/api/packages/{PACKAGE_OWNER}/generic/{PACKAGE_NAME}/{version}/{name}")
}

fn newest_finalized(versions: Vec<Version>) -> Result<Option<(Version, Value)>> {
    for version in versions.into_iter().rev() {
        let url = package_file_url(version, "manifest.json");
        if let Some(manifest) = get_json_optional(&url)? {
            let declared = manifest
                .get("version")
                .and_then(Value::as_str)
                .and_then(Version::parse)
                .ok_or_else(|| {
                    Error::Network(format!("package {version} has an invalid manifest version"))
                })?;
            if declared != version {
                return Err(Error::Network(format!(
                    "package {version} manifest declares version {declared}"
                )));
            }
            return Ok(Some((version, manifest)));
        }
    }
    Ok(None)
}

fn list_package_versions() -> Result<Vec<Version>> {
    let mut versions = Vec::new();
    for page in 1..=MAX_PACKAGE_PAGES {
        let payload = get_json(&format!(
            "{GITEA_BASE_URL}/api/v1/packages/{PACKAGE_OWNER}/generic/{PACKAGE_NAME}?page={page}&limit={PACKAGE_PAGE_SIZE}"
        ))?;
        let count = append_package_page(&mut versions, &payload)?;
        if count < PACKAGE_PAGE_SIZE {
            versions.sort_unstable();
            versions.dedup();
            return Ok(versions);
        }
    }
    Err(Error::Network(format!(
        "Gitea returned at least {} CLI package versions; refusing to exceed the pagination safety cap",
        PACKAGE_PAGE_SIZE * MAX_PACKAGE_PAGES
    )))
}

fn append_package_page(versions: &mut Vec<Version>, packages: &Value) -> Result<usize> {
    let (mut page_versions, count) = package_versions(packages)?;
    versions.append(&mut page_versions);
    Ok(count)
}

fn package_versions(packages: &Value) -> Result<(Vec<Version>, usize)> {
    let packages = packages.as_array().ok_or_else(|| {
        Error::Network("Gitea package versions response is not an array".to_string())
    })?;
    let versions = packages
        .iter()
        .filter(|package| package.get("type").and_then(Value::as_str) == Some("generic"))
        .filter(|package| package.get("name").and_then(Value::as_str) == Some(PACKAGE_NAME))
        .filter_map(|package| package.get("version").and_then(Value::as_str))
        .filter_map(Version::parse)
        .collect();
    Ok((versions, packages.len()))
}

struct ManifestAsset {
    name: String,
    sha256: String,
    size: u64,
}

fn manifest_asset(manifest: &Value, platform: &str, expected_name: &str) -> Result<ManifestAsset> {
    let asset = manifest
        .get("files")
        .and_then(|files| files.get(platform))
        .ok_or_else(|| Error::Network(format!("package manifest has no asset for {platform}")))?;
    let name = asset
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::Network(format!("package manifest asset {platform} has no name")))?;
    if name != expected_name {
        return Err(Error::Network(format!(
            "package manifest names {name} for {platform}, expected {expected_name}"
        )));
    }
    let sha256 = asset
        .get("sha256")
        .and_then(Value::as_str)
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or_else(|| {
            Error::Network(format!(
                "package manifest asset {platform} has an invalid SHA-256"
            ))
        })?;
    let size = asset
        .get("size")
        .and_then(Value::as_u64)
        .filter(|size| *size > 0 && *size <= MAX_BINARY_BYTES)
        .ok_or_else(|| {
            Error::Network(format!(
                "package manifest asset {platform} has an invalid size"
            ))
        })?;

    Ok(ManifestAsset {
        name: name.to_string(),
        sha256: sha256.to_ascii_lowercase(),
        size,
    })
}

fn get_json(url: &str) -> Result<Value> {
    let response = request(url)?;
    parse_json_response(response, url)
}

fn get_json_optional(url: &str) -> Result<Option<Value>> {
    match ureq::get(url).set("User-Agent", USER_AGENT).call() {
        Ok(response) => parse_json_response(response, url).map(Some),
        Err(ureq::Error::Status(404, _)) => Ok(None),
        Err(ureq::Error::Status(status, _)) => {
            Err(Error::Network(format!("Gitea returned {status} for {url}")))
        }
        Err(ureq::Error::Transport(err)) => {
            Err(Error::Network(format!("could not reach Gitea: {err}")))
        }
    }
}

fn request(url: &str) -> Result<ureq::Response> {
    match ureq::get(url).set("User-Agent", USER_AGENT).call() {
        Ok(response) => Ok(response),
        Err(ureq::Error::Status(status, _)) => {
            Err(Error::Network(format!("Gitea returned {status} for {url}")))
        }
        Err(ureq::Error::Transport(err)) => {
            Err(Error::Network(format!("could not reach Gitea: {err}")))
        }
    }
}

fn parse_json_response(response: ureq::Response, url: &str) -> Result<Value> {
    let bytes = read_limited(
        response.into_reader(),
        MAX_JSON_BYTES,
        "Gitea JSON response",
    )?;
    serde_json::from_slice(&bytes)
        .map_err(|err| Error::Network(format!("could not parse Gitea response from {url}: {err}")))
}

fn download(url: &str, expected_size: u64) -> Result<Vec<u8>> {
    let response = request(url)?;
    let bytes = read_limited(response.into_reader(), MAX_BINARY_BYTES, "downloaded CLI")?;
    if bytes.is_empty() {
        return Err(Error::Network(
            "Gitea returned an empty CLI binary".to_string(),
        ));
    }
    if bytes.len() as u64 != expected_size {
        return Err(Error::Network(format!(
            "the downloaded CLI was {} bytes, but the manifest declares {expected_size}",
            bytes.len()
        )));
    }
    Ok(bytes)
}

fn read_limited(mut reader: impl Read, limit: u64, label: &str) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader
        .by_ref()
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|err| Error::Network(format!("could not read {label}: {err}")))?;
    if bytes.len() as u64 > limit {
        return Err(Error::Network(format!(
            "{label} exceeds the {limit}-byte safety limit"
        )));
    }
    Ok(bytes)
}

fn executable_matches_manifest(path: &Path, asset: &ManifestAsset) -> Result<bool> {
    let metadata = std::fs::metadata(path)
        .map_err(|err| Error::Io(format!("could not inspect {}: {err}", path.display())))?;
    if metadata.len() != asset.size {
        return Ok(false);
    }
    let bytes = std::fs::read(path)
        .map_err(|err| Error::Io(format!("could not read {}: {err}", path.display())))?;
    Ok(sha256_hex(&bytes) == asset.sha256)
}

fn verify_sha256(bytes: &[u8], expected: &str) -> Result<()> {
    let actual = sha256_hex(bytes);
    if actual != expected.to_ascii_lowercase() {
        return Err(Error::Network(format!(
            "downloaded CLI SHA-256 mismatch: expected {expected}, got {actual}"
        )));
    }
    Ok(())
}

// Kept local so the updater's integrity check does not add a dependency to the
// binary whose dependency graph it is protecting.
fn sha256_hex(bytes: &[u8]) -> String {
    const INITIAL: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];

    let bit_len = (bytes.len() as u64).wrapping_mul(8);
    let mut padded = bytes.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());

    let mut hash = INITIAL;
    for chunk in padded.chunks_exact(64) {
        let mut words = [0u32; 64];
        for (index, word) in words.iter_mut().take(16).enumerate() {
            let offset = index * 4;
            *word = u32::from_be_bytes(chunk[offset..offset + 4].try_into().unwrap());
        }
        for index in 16..64 {
            let s0 = words[index - 15].rotate_right(7)
                ^ words[index - 15].rotate_right(18)
                ^ (words[index - 15] >> 3);
            let s1 = words[index - 2].rotate_right(17)
                ^ words[index - 2].rotate_right(19)
                ^ (words[index - 2] >> 10);
            words[index] = words[index - 16]
                .wrapping_add(s0)
                .wrapping_add(words[index - 7])
                .wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = hash;
        for index in 0..64 {
            let sum1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choice = (e & f) ^ ((!e) & g);
            let temp1 = h
                .wrapping_add(sum1)
                .wrapping_add(choice)
                .wrapping_add(K[index])
                .wrapping_add(words[index]);
            let sum0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = sum0.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        for (slot, value) in hash.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *slot = slot.wrapping_add(value);
        }
    }
    hash.iter().map(|word| format!("{word:08x}")).collect()
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

    if let Err(error) = replace_executable(executable, &temporary) {
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

fn target_asset() -> Result<(&'static str, &'static str)> {
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        Ok(("linux-amd64", "rinto-pmo-linux-amd64"))
    } else if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Ok(("darwin-arm64", "rinto-pmo-darwin-arm64"))
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
        if parts.next().is_some() || version.to_string() != value {
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

    use serde_json::{json, Value};

    use super::{
        append_package_page, executable_matches_manifest, install_at, manifest_asset,
        package_versions, sha256_hex, verify_sha256, ManifestAsset, Version, PACKAGE_PAGE_SIZE,
    };

    #[test]
    fn semantic_versions_are_ordered_numerically() {
        assert!(Version::parse("1.10.0") > Version::parse("1.9.9"));
        assert!(Version::parse("1.2").is_none());
        assert!(Version::parse("1.2.3.4").is_none());
        assert!(Version::parse("1.2.3-rc.1").is_none());
        assert!(Version::parse("01.2.3").is_none());
        assert!(Version::parse("1.02.3").is_none());
        assert!(Version::parse("1.2.03").is_none());
    }

    #[test]
    fn selects_generic_versions_for_this_package() {
        let packages = json!([
            {"type": "generic", "name": "rinto-pmo", "version": "1.2.0"},
            {"type": "generic", "name": "other", "version": "99.0.0"},
            {"type": "cargo", "name": "rinto-pmo", "version": "98.0.0"},
            {"type": "generic", "name": "rinto-pmo", "version": "1.10.0"},
            {"type": "generic", "name": "rinto-pmo", "version": "2.0.0-rc.1"},
            {"type": "generic", "name": "rinto-pmo", "version": "01.11.0"}
        ]);
        let (versions, count) = package_versions(&packages).unwrap();
        assert_eq!(count, 6);
        assert_eq!(
            versions,
            vec![
                Version::parse("1.2.0").unwrap(),
                Version::parse("1.10.0").unwrap()
            ]
        );
    }

    #[test]
    fn appends_full_and_final_short_package_pages() {
        let mut first = Vec::new();
        first.push(json!({"type":"generic", "name":"rinto-pmo", "version":"1.0.0"}));
        for index in 1..PACKAGE_PAGE_SIZE {
            first.push(json!({"type":"generic", "name":"other", "version":format!("1.0.{index}")}));
        }
        let second = json!([
            {"type":"generic", "name":"rinto-pmo", "version":"2.0.0"}
        ]);
        let mut versions = Vec::new();
        assert_eq!(
            append_package_page(&mut versions, &Value::Array(first)).unwrap(),
            PACKAGE_PAGE_SIZE
        );
        assert_eq!(append_package_page(&mut versions, &second).unwrap(), 1);
        versions.sort_unstable();
        assert_eq!(
            versions,
            vec![
                Version::parse("1.0.0").unwrap(),
                Version::parse("2.0.0").unwrap()
            ]
        );
    }

    #[test]
    fn validates_manifest_asset_name_hash_and_size() {
        let manifest = json!({
            "files": {
                "linux-amd64": {
                    "name": "rinto-pmo-linux-amd64",
                    "sha256": "00".repeat(32),
                    "size": 42
                }
            }
        });
        let asset = manifest_asset(&manifest, "linux-amd64", "rinto-pmo-linux-amd64").unwrap();
        assert_eq!(asset.size, 42);
        assert_eq!(asset.sha256, "00".repeat(32));
        assert!(manifest_asset(&manifest, "darwin-arm64", "rinto-pmo-darwin-arm64").is_err());
    }

    #[test]
    fn computes_and_checks_sha256() {
        let expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
        assert_eq!(sha256_hex(b"hello"), expected);
        assert!(verify_sha256(b"different", expected).is_err());
        assert!(verify_sha256(b"hello", expected).is_ok());
    }

    #[test]
    fn detects_same_version_binary_content_replacement() {
        let directory =
            std::env::temp_dir().join(format!("rinto-pmo-refresh-test-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let executable = directory.join("rinto-pmo");
        std::fs::write(&executable, b"current binary").unwrap();
        let matching = ManifestAsset {
            name: "rinto-pmo".to_string(),
            sha256: sha256_hex(b"current binary"),
            size: 14,
        };
        assert!(executable_matches_manifest(&executable, &matching).unwrap());
        let replacement = ManifestAsset {
            name: "rinto-pmo".to_string(),
            sha256: sha256_hex(b"forced replacement"),
            size: 18,
        };
        assert!(!executable_matches_manifest(&executable, &replacement).unwrap());
        std::fs::remove_dir_all(directory).unwrap();
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
        let executable = directory.join("rinto-pmo");
        std::fs::write(&executable, b"old binary").unwrap();
        install_at(&executable, b"new binary").unwrap();
        assert_eq!(std::fs::read(&executable).unwrap(), b"new binary");
        std::fs::remove_dir_all(directory).unwrap();
    }
}
