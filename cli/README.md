# Rinto PMO CLI

The CLI is designed for local coding agents that execute work from Rinto.

## Install

Published binaries are available for Linux amd64 and macOS Apple Silicon. The
package assets include the platform in their filename, but this command downloads
the selected asset to a temporary file and atomically installs it as the stable
command `~/.local/bin/rinto-pmo`:

```sh
CLI_VERSION=0.1.0 # keep this aligned with cli/VERSION
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

## Update

```sh
rinto-pmo update --check
rinto-pmo update
```

The updater paginates the public Gitea package-versions API at
`https://gitea.kenton.wang` for `Rinto/rinto-pmo` with a bounded safety cap,
ignores versions without a final manifest, downloads the current platform asset,
verifies its size and SHA-256,
and atomically replaces the running executable at its existing path. The downloaded
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
