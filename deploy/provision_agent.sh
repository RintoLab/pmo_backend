#!/usr/bin/env bash
#
# The agent side of a release. Runs on the server as `deploy`, over ssh.
#
#   provision_agent.sh <cli-version>
#
# A topic's pi is three things this repository owns and the release tarball does
# not carry:
#
#   the CLI          how it reads and writes anything in Rinto
#   the skills       how to call that CLI -- shipped inside the binary itself
#   AGENTS.md        what it is, before any of the above is loaded
#
# and one thing it only checks for, because a package manager owns it: git,
# which the workspace subsystem shells out to for every clone and fetch.
#
# `docs/ai-document-cli.md` already required the first two and said why they
# must not be done by hand: "换台机器、重建容器，skill 和二进制静默消失，表现出来
# 是「AI 突然不会写文档了」—— 这种问题很难查". They were done by hand anyway.
# This is that step, plus the third.
#
# Runs *before* `deploy.sh`, so a failure here leaves the running release
# untouched -- the same bargain deploy.sh strikes with its own swap. The cost is
# that a provision which succeeds and a deploy which then fails leaves a newer
# CLI against the older backend, which is the ordinary skew between two
# separately released artifacts and not a new one.
#
# Idempotent, and unconditionally overwriting rather than comparing first. The
# copies here are deploy artifacts: nobody edits them on this machine, so there
# is nothing a comparison could protect, and "install it" has no second branch
# to get wrong.
#
# Reads, from the staging directory the workflow uploaded:
#
#   rinto-pmo-linux-amd64          resolved and verified on the runner
#   rinto-pmo-linux-amd64.sha256
#   agent/AGENTS.md
#
# Leaves behind:
#
#   ~/.local/bin/rinto-pmo         on the unit's PATH -- see pmo_backend.service
#   ~/.pi/agent/skills/rinto-document-authoring/SKILL.md
#   ~/.pi/agent/skills/rinto-project-code/SKILL.md
#   ~/.pi/agent/AGENTS.md

set -euo pipefail

cli_version="${1:?usage: provision_agent.sh <cli-version>}"
staging="/tmp/pmo_backend-deploy"
bin_dir="${HOME}/.local/bin"
cli="${bin_dir}/rinto-pmo"
agent_dir="${HOME}/.pi/agent"
context_file="${agent_dir}/AGENTS.md"

# These two, and not the others. `rinto-docs-reference` is the development-side
# loop -- claim a task, change code, report back -- and `rinto-backlog-cleanup`
# opens by requiring that a human confirm every cancellation one at a time,
# which is not a person this process has in front of it. `skill install`
# deliberately refuses to install everything by default for exactly this reason;
# installing the wrong ones here would work around that on the one machine it
# matters most.
#
# `rinto-project-code` is separate from `rinto-document-authoring` rather than a
# section inside it: that one's description triggers on "write this up", and
# reading a project's code usually happens *before* anybody has decided there is
# a document to write. Folded in, it would be discovered too late to be used.
skills="rinto-document-authoring rinto-project-code"

say() { printf '\n=== %s\n' "$1"; }

cd "${staging}"
test -s rinto-pmo-linux-amd64 || {
  echo "the CLI binary did not arrive in ${staging}" >&2
  exit 1
}
test -s agent/AGENTS.md || {
  echo "the agent context file did not arrive in ${staging}" >&2
  exit 1
}

# The workspace subsystem shells out to git for every clone, fetch and worktree.
# Without it a release starts, serves everything else, and answers `503
# repo_unavailable` the first time anybody asks about a project's code -- which
# reads as a broken repository rather than a machine missing a package.
say "checking git is installed"
command -v git >/dev/null || {
  echo "git is not installed; the agent will not be able to read any project's code" >&2
  exit 1
}
git --version

say "verifying the CLI that arrived"
sha256sum -c rinto-pmo-linux-amd64.sha256

say "installing rinto-pmo ${cli_version} as ${cli}"
install -d -m 755 "${bin_dir}"
# Not `install` onto the live path: a running pi holding that binary open would
# get ETXTBSY. Write beside it and rename, which is atomic and replaces the
# inode rather than the bytes.
install -m 755 rinto-pmo-linux-amd64 "${cli}.incoming"
mv -f "${cli}.incoming" "${cli}"

# The unit hands pi a compiled-in PATH plus what pmo_backend.service sets, and
# the CLI is useless to a topic that cannot find it. Asked of a login shell
# rather than of this script's own PATH, which ssh may have set differently.
test -x "${cli}" || { echo "${cli} is not executable" >&2; exit 1; }
installed="$("${cli}" --version)"
test "${installed}" = "rinto-pmo ${cli_version}" || {
  echo "installed binary reports '${installed}', expected 'rinto-pmo ${cli_version}'" >&2
  exit 1
}

# `--force` rather than plain install: the skill is baked into the binary with
# `include_str!`, so replacing the binary is exactly when the copy on disk goes
# stale. Without it every deploy after the first would refuse on differing
# content, and the machine would sit on a skill describing commands the CLI no
# longer has -- the drift `include_str!` exists to prevent, arriving late.
say "installing the agent skills"
for skill in ${skills}; do
  "${cli}" skill install "${skill}" --force
done

# Global context, loaded by pi for every process on this machine regardless of
# cwd, of `--system-prompt`, and of whether any skill is triggered
# (`core/resource-loader.js`, `loadProjectContextFiles`). It says what this pi
# is; how to call the CLI is the skill's business and how a persona speaks is
# the actor's, so neither belongs here.
say "installing the global agent context"
install -d -m 755 "${agent_dir}"
install -m 644 agent/AGENTS.md "${context_file}"

# Installed is not the same as in effect. pi walks from cwd to the root
# collecting AGENTS.md and CLAUDE.md on the way, so a file left in the release
# directory or anywhere above it is loaded silently alongside this one. The
# release tarball carries no such file today; this reports one rather than
# letting it sit in every prompt unnoticed.
say "checking for context files that would layer on top"
found=false
dir="/apps/pmo_backend"
while :; do
  for name in AGENTS.override.md AGENTS.md AGENTS.MD CLAUDE.md CLAUDE.MD; do
    if [ -f "${dir}/${name}" ]; then
      echo "note: ${dir}/${name} will also be loaded into every prompt" >&2
      found=true
      break
    fi
  done
  parent="$(dirname "${dir}")"
  [ "${parent}" = "${dir}" ] && break
  dir="${parent}"
done
if [ "${found}" = false ]; then
  echo "none -- ${context_file} is the only one"
fi

say "provisioned"
"${cli}" skill list
