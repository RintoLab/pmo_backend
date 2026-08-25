# Rinto PMO CLI

The CLI is designed for local coding agents that execute work from Rinto.

## Install

Published binaries are available for Linux amd64 and macOS Apple Silicon. The
package assets include the platform in their filename, but this command downloads
the selected asset to a temporary file and atomically installs it as the stable
command `~/.local/bin/rinto-pmo`:

```sh
CLI_VERSION=0.1.1 # keep this aligned with cli/VERSION
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) asset=rinto-pmo-linux-amd64 ;;
  Darwin/arm64) asset=rinto-pmo-darwin-arm64 ;;
  *) echo "unsupported platform: $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac
mkdir -p "$HOME/.local/bin"
tmp="$HOME/.local/bin/.rinto-pmo.install.$$"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "https://gitea.kenton.wang/api/packages/Rinto/generic/rinto-pmo/$CLI_VERSION/$asset" -o "$tmp"
chmod 0755 "$tmp"
mv -f "$tmp" "$HOME/.local/bin/rinto-pmo"
trap - EXIT
"$HOME/.local/bin/rinto-pmo" --version
```

Add `$HOME/.local/bin` to `PATH` if it is not already there. For example, add
`export PATH="$HOME/.local/bin:$PATH"` to your shell profile, then verify with
`rinto-pmo --version`.

## Configure

```sh
rinto-pmo config init
rinto-pmo config show
```

`config init` asks for the API URL and the token, reading the token without
echoing it. The URL defaults to `https://pmo-api.kenton.wang/api/v1`, so
pressing enter is the right answer unless you are pointing at a local server;
`RINTO_API` and whatever was configured last time both take precedence over
that default.

The token is agreed in advance -- it is the value the server was started with
as `RINTO_TOKEN` -- so ask whoever deployed it; nothing prints one and no
endpoint hands one out. `--api` and `--token` skip the corresponding question,
for scripts.

Configuration is stored at `~/.config/rinto-pmo/config.json`. Set
`RINTO_CONFIG` to use a different path.

## What it can do

`rinto-pmo <group> --help` lists a group's commands and every flag; this is the
map, not the reference. Two environments run this binary and they can do
different things:

* **Outside a topic** -- a coding agent on a developer's machine, configured by
  `config init`. Writes are credited to the configured human.
* **Inside a topic** -- spawned by the server with `RINTO_CONVERSATION_ID` in the
  environment and no config file. Writes are credited to that topic's assistant,
  and changes to documents can only be *proposed*, never committed.

| Group | Commands |
|---|---|
| `config` | `init`, `show` |
| `project` | `list`, `show` -- repositories, directory names, default branches |
| `task` | `list`, `show`, `stats`, `schema`, `create`, `update`, `assign`, `claim`, `release`, `split`, `start`, `complete`, `cancel`, `reopen`, `delete` |
| `doc` | `create`, `show`, `list`, `propose`, `proposals`, `contentions`, `rebase` |
| `search` | one command; finds things by meaning and answers with `rinto://` addresses |
| `skill` | `list`, `install`, `sync` |
| `update` | self-update from the Gitea package registry |

Three things are worth knowing before writing anything:

**Ask what a task write looks like; do not guess.** `task create`, `task update`
and `task split` each read a JSON file, and `task schema [create|update|split]`
prints the shape of one -- every field, the enums, the estimate ceiling, and a
worked example. It is fetched from the server rather than kept in here, so it is
what that server will accept and not what was true when this binary was built.
Two things it will save you: the flat `estimate_optimistic` / `estimate_likely`
/ `estimate_pessimistic` columns are not writable at all, and a key the update
shape does not list is *ignored* rather than refused -- a PATCH carrying
`status` answers 200 and changes nothing.


**Documents are read two ways.** `doc show` prints what has been committed.
`doc show --working` prints the document as the current topic sees it, with that
topic's own standing proposals in place of the text they would replace. A topic
that changed a document and then reads it back with plain `doc show` sees the
text it replaced -- and proposing again from that overwrites its earlier
proposal, because a topic holds one live proposal per block. Read `--working`
before changing the same document twice.

**Committing and deciding are not here, on purpose.** An agent proposes; a
person commits the proposal and settles arguments between competing ones. There
is no CLI verb for either, and that is the point of the proposal flow rather
than a gap in this binary.

## Update

```sh
rinto-pmo update --check
rinto-pmo update
```

The updater reads `manifest.json` from the `latest` pointer version of the
`Rinto/rinto-pmo` generic package at `https://gitea.kenton.wang`, then downloads
the current platform asset from the concrete version that manifest declares,
verifies its size and SHA-256,
and atomically replaces the running executable at its existing path. Discovery
deliberately avoids the `/api/v1/packages` versions API: that one requires a
signed-in Gitea user and answers `401` to the CLI, while package *contents* are
anonymously readable. The downloaded
asset name is never used as the installed filename, so an installation named
`rinto-pmo` remains `rinto-pmo` after every update. If a forced publication replaces
the same semantic version, the updater compares its own executable to the final
manifest and offers a same-version refresh when the bytes differ. Automatic
updates are published for Linux amd64 and macOS Apple Silicon only.

## Publish a release

The CLI release workflow uses `cli/VERSION` as its source of truth, requires a
canonical stable `x.y.z` without leading zeroes, and checks that
`cli/Cargo.toml` has the same version.

- A push to `main` publishes only when `cli/VERSION` differs from the
  `CLI_VERSION` state in r-nacos.
- Every tag starts the workflow. It skips only if both the version and commit
  already match `CLI_VERSION` and `CLI_COMMIT`; otherwise it force-publishes.
- A manual dispatch always force-publishes.

After publication, the workflow writes `CLI_COMMIT` and then `CLI_VERSION`;
VERSION is the main-branch completion marker, so a partial state write retries.
Tag names do not supply or validate the CLI version.

`.gitea/workflows/release-cli.yml` serializes CLI releases without blocking the
independent Server release group. It builds locked optimized binaries on the
`amd64` and `darwin-arm64` runners, executes each native binary and checks its
version/architecture, stages it under a run-and-attempt-specific identity, and
publishes binaries, `SHA256SUMS`, and `manifest.json` (last) under the version
from `cli/VERSION`.

It then republishes that same `manifest.json` under the mutable `latest` pointer
version, which is what `rinto-pmo update` reads. The pointer is written after the
versioned assets, so it never advertises a partial publication, and the pointer
name is kept in step with `POINTER_VERSION` in `cli/src/update.rs`.
