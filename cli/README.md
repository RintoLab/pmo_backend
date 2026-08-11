# Rinto PMO CLI

The CLI is designed for local coding agents that execute work from Rinto.

## Configure

```sh
rinto-pmo config init --api https://pmo-api.kenton.wang/api/v1
rinto-pmo config show
```

Configuration is stored at `~/.config/rinto-pmo/config.json`. Set
`RINTO_CONFIG` to use a different path.

## Update

```sh
rinto-pmo update --check
rinto-pmo update
```

The updater selects the newest stable `cli-v*` release from
`RintoLab/pmo_backend`, downloads the asset for the current OS and architecture,
and replaces the running executable. The installation directory must be
writable by the current user.

## Publish a release

1. Set `version` in `cli/Cargo.toml` and update `cli/Cargo.lock` if needed.
2. Commit the version change.
3. Tag that commit with the matching CLI tag and push it:

   ```sh
   git tag cli-v0.2.0
   git push origin cli-v0.2.0
   ```

`.github/workflows/release-cli.yml` builds locked, optimized binaries for Linux
(x86_64 and arm64), macOS (Intel and Apple Silicon), and Windows x86_64. It
publishes the binaries and `SHA256SUMS` to the GitHub Release.
