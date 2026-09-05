use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    let manifest_dir =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let skills_dir = manifest_dir.join("../skills");
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));

    println!("cargo:rerun-if-changed={}", skills_dir.display());

    let bundles = discover(&skills_dir);
    let mut generated = String::from("pub const SKILLS: &[Skill] = &[\n");

    for skills in bundles.values() {
        for skill in skills {
            generated.push_str(&format!(
                "    Skill {{ name: {name:?}, body: include_str!(concat!(env!(\"CARGO_MANIFEST_DIR\"), \"/../skills/{bundle}/{name}/SKILL.md\")) }},\n",
                bundle = skill.bundle,
                name = skill.name
            ));
        }
    }

    generated.push_str("];\n");
    fs::write(out_dir.join("skills_registry.rs"), generated)
        .expect("write generated skill registry");
}

#[derive(Debug)]
struct DiscoveredSkill {
    bundle: String,
    name: String,
}

fn discover(root: &Path) -> BTreeMap<String, Vec<DiscoveredSkill>> {
    let mut bundles = BTreeMap::new();

    for bundle_dir in directories(root) {
        let bundle = file_name(&bundle_dir);
        validate_name("bundle", &bundle);
        let mut skills = Vec::new();

        for skill_dir in directories(&bundle_dir) {
            let name = file_name(&skill_dir);
            validate_name("skill", &name);
            let skill_file = skill_dir.join("SKILL.md");
            let body = fs::read_to_string(&skill_file)
                .unwrap_or_else(|err| panic!("could not read {}: {err}", skill_file.display()));
            let declared = frontmatter_name(&body)
                .unwrap_or_else(|| panic!("{} has no frontmatter name", skill_file.display()));

            assert_eq!(
                declared,
                name,
                "{} declares a name different from its directory",
                skill_file.display()
            );

            skills.push(DiscoveredSkill {
                bundle: bundle.clone(),
                name,
            });
        }

        assert!(!skills.is_empty(), "skill bundle {bundle} is empty");
        bundles.insert(bundle, skills);
    }

    let mut names = bundles
        .values()
        .flatten()
        .map(|skill| skill.name.as_str())
        .collect::<Vec<_>>();
    names.sort_unstable();
    assert!(
        names.windows(2).all(|pair| pair[0] != pair[1]),
        "skill names must be unique across bundles"
    );
    assert!(
        !bundles.is_empty(),
        "{} has no skill bundles",
        root.display()
    );

    bundles
}

fn directories(root: &Path) -> Vec<PathBuf> {
    let mut paths = fs::read_dir(root)
        .unwrap_or_else(|err| panic!("could not read {}: {err}", root.display()))
        .filter_map(|entry| {
            let entry = entry.unwrap_or_else(|err| panic!("could not read directory entry: {err}"));
            let file_type = entry.file_type().unwrap_or_else(|err| {
                panic!("could not inspect {}: {err}", entry.path().display())
            });
            (file_type.is_dir() && !entry.file_name().to_string_lossy().starts_with('.'))
                .then(|| entry.path())
        })
        .collect::<Vec<_>>();
    paths.sort();
    paths
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_else(|| panic!("{} has no UTF-8 file name", path.display()))
        .to_string()
}

fn validate_name(kind: &str, name: &str) {
    let valid = !name.is_empty()
        && !name.starts_with('-')
        && !name.ends_with('-')
        && !name.contains("--")
        && name.chars().all(|character| {
            character.is_ascii_lowercase() || character.is_ascii_digit() || character == '-'
        });
    assert!(valid, "invalid {kind} name {name:?}");
}

fn frontmatter_name(body: &str) -> Option<String> {
    body.lines()
        .skip(1)
        .take_while(|line| line.trim() != "---")
        .find_map(|line| line.strip_prefix("name:"))
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string)
}
