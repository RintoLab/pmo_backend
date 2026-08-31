# Rinto PMO CLI

The CLI is designed for local coding agents that execute work from Rinto.

## Install

Published binaries are available for Linux amd64 and macOS Apple Silicon. The
package assets include the platform in their filename, but this command downloads
the selected asset to a temporary file and atomically installs it as the stable
command `~/.local/bin/rinto-pmo`:

```sh
CLI_VERSION=0.2.1 # keep this aligned with cli/VERSION
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

`repo checkout` belongs to the second one only. The path it prints is the
server's own, and the directory behind it is **read-only**: the agent reading a
project's code is not the developer changing it, and the next checkout throws
away anything written there. On a developer's machine the repository to be in is
`project show`'s business, and the checkout is the developer's own.

| Group | Commands |
|---|---|
| `config` | `init`, `show` |
| `project` | `list`, `show` -- repositories, directory names, git URLs |
| `repo` | `checkout` -- puts a branch on the *server's* disk and says where; only useful there |
| `task` | `list`, `show`, `stats`, `schema`, `create`, `update`, `assign`, `claim`, `release`, `split`, `start`, `complete`, `cancel`, `reopen`, `delete` |
| `schedule` | one command; what each week holds and what did not fit in it |
| `history` | one command; what was actually worked, with the plan beside it |
| `calibration` | one command; what the estimates turned out to be worth |
| `doc` | `create`, `show`, `list`, `propose`, `proposals`, `annotations`, `annotation`, `backlinks`, `contentions`, `rebase` |
| `search` | one command; finds things by meaning and answers with `rinto://` addresses |
| `skill` | `list`, `install`, `sync` -- see "Skills" below |
| `update` | self-update from the Gitea package registry |

Seven things are worth knowing before writing anything:

**The pool is not a project's.** `task list` takes a project slug, and without
one it lists every project at once -- which is the right question, because
capacity is one pool spanning everything a person works on. `--sort plan` puts
it in the board's own order (priority, then the day it was selected for, then
age), so the first row is what the plan would reach next. `--scheduled false`
is the backlog: work that is in no week at all. `rinto-pmo schedule` shows the
other side of it -- what each week holds, what overflowed, and what is blocked
waiting on something that overflowed. `rinto-pmo history` shows the past
instead: what was actually worked, how long it took against what was estimated,
and how far it slipped from the week it was *first* planned for.


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

**What people wrote about a document is not in the document.** An annotation is
somebody pointing at a paragraph and saying it is wrong, and neither `doc show`
nor `--working` carries one. `doc annotations <id> --unconfirmed` lists the ones
nobody has marked as settled, with the block each is anchored to; `doc
annotation <id> <annotation-id>` reads one thread in full. The thread is where
it matters -- what a discussion landed on is at the bottom of it, and is often
not what the opening objection asked for. Changing a document without reading
these re-argues settled points, or silently overwrites the thing somebody
objected to.

An annotation has two states and nothing derives them: confirmed, or not.
Replies come from people and, when somebody clicks for one, from the AI; this
binary does not distinguish them, because who said a thing does not change
whether it is right.

**A decision recorded in one document is quoted in others.** `doc backlinks
<id>` lists everything whose text points at a document -- other documents, task
descriptions, annotations -- with the words each of them used for it. That label
is the part that goes stale: a citation reading "the three-state lifecycle"
starts lying the moment the third state goes, while the address it carries still
resolves, so nothing about link health would show it. `search` cannot answer
this either -- it finds text by meaning, not the ones that wrote this document's
address down. There is no outbound counterpart, deliberately: what a document
points at is in its own text, which `doc show` already prints.

**A skill's version is this binary's version.** `skill list` says which version
it carries, and for anything installed, which version wrote the copy on disk and
whether that copy is still current -- without writing anything. Before, the only
way to find out was `skill sync`, which writes. Nothing declares a version: the
skills are compiled into the binary and describe its own commands, so a
`version:` in each `SKILL.md` would be a second number to keep in step and the
first edit that forgot to bump it would make it wrong. "written by 0.1.0 --
current" is a real state and means the text did not change between those
releases; nobody maintained a number to say so.

**Committing and deciding are not here, on purpose.** An agent proposes; a
person commits the proposal, settles arguments between competing ones, and
confirms annotations. There is no CLI verb for any of those, and that is the
point of the proposal flow rather than a gap in this binary.

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

`.gitea/workflows/release.yml` builds locked optimized binaries on the `amd64`
and `darwin-arm64` runners, executes each native binary and checks its
version/architecture, stages it under a run-and-attempt-specific identity, and
publishes binaries, `SHA256SUMS`, and `manifest.json` (last) under the version
from `cli/VERSION`. The published package is linked to this repository, so it is
listed under the repository's Packages tab rather than only the org's.

It then republishes that same `manifest.json` under the mutable `latest` pointer
version, which is what `rinto-pmo update` reads. The pointer is written after the
versioned assets, so it never advertises a partial publication, and the pointer
name is kept in step with `POINTER_VERSION` in `cli/src/update.rs`.

The Server release lives in the same workflow and waits on the CLI, because the
deploy installs the CLI onto the server's own host. A push that leaves
`cli/VERSION` alone skips every CLI job and the Server still releases; a CLI job
that *fails* holds the Server back, since `latest` would still be the previous
CLI.
