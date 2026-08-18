#!/usr/bin/env bash
#
# Phase one of two. Runs on the runner machine, over ssh, as root.
#
#   prepare.sh
#
# Everything here touches a system directory and nothing here touches the
# release. It is idempotent and runs on every deploy, so a unit or a
# configuration change lands by pushing a tag rather than by hand.
#
# The release itself is installed by `deploy.sh`, as `deploy`. Keeping the two
# apart is not ceremony: a process that root starts and then drops to another
# user carries root's working directory, root's HOME and root's environment
# with it, and every one of those has to be corrected by hand. A process that
# arrives over ssh as `deploy` has all three right to begin with.
#
# Reads, from the staging directory the workflow uploaded:
#
#   pmo_backend.service
#   validate_env.sh
#   env                          from r-nacos
#
# Leaves behind:
#
#   /apps/pmo_backend/           empty and owned by deploy, if it was not there
#   /etc/systemd/system/pmo_backend.service
#   /etc/pmo_backend/env         root:deploy 640
#   /etc/sudoers.d/pmo-backend   root:root 440 -- deploy may (re)start the unit

set -euo pipefail

# Root-only input directory. The deploy user cannot replace scripts, unit, or
# environment between upload and this privileged execution.
staging="/tmp/pmo_backend-prepare"
app_root="/apps/pmo_backend"
env_file="/etc/pmo_backend/env"
# No dot and no tilde in the name: sudo skips files in /etc/sudoers.d with either.
sudoers_file="/etc/sudoers.d/pmo-backend"
unit="pmo_backend.service"
service_user="deploy"

say() { printf '\n=== %s\n' "$1"; }

test "$(id -u)" = 0 || { echo "prepare.sh has to run as root" >&2; exit 1; }
id "${service_user}" >/dev/null 2>&1 || {
  echo "there is no ${service_user} user for the service to run as" >&2
  exit 1
}

cd "${staging}"
test -s "${unit}" || { echo "the unit file did not arrive; refusing" >&2; exit 1; }
test -s env || { echo "the environment file is empty; refusing" >&2; exit 1; }

# This is the same validator deploy.sh runs immediately before exporting the
# values. Blank means truly empty, comments start with # in column one, and
# every other line is an exact KEY=value assignment.
say "checking the environment"
bash "${staging}/validate_env.sh" env DATABASE_URL SECRET_KEY_BASE RINTO_TOKEN

# Group-readable by `deploy`, which needs these to run the migration. That gives
# away nothing: the service runs as `deploy`, so the same values are in its own
# /proc/self/environ either way. Not world-readable, and not writable by it.
say "installing the environment as ${env_file}"
install -d -m 755 -o root -g root "$(dirname "${env_file}")"
install -m 640 -o root -g "${service_user}" env "${env_file}"

say "installing the unit"
install -m 644 -o root -g root "${unit}" "/etc/systemd/system/${unit}"

# `/apps` is shared with other projects, so its ownership is left alone; only
# this project's directory inside it is claimed. The swap `deploy.sh` does needs
# to create a sibling, so `/apps` itself has to be writable by `deploy` -- which
# is a property of the machine rather than something to take over here.
say "making room under ${app_root}"
test -d /apps || install -d -m 755 /apps
install -d -m 755 -o "${service_user}" -g "${service_user}" "${app_root}"
runuser -u "${service_user}" -- test -w /apps || {
  echo "/apps is not writable by ${service_user}, and the release swap needs that" >&2
  echo "  chown ${service_user} /apps   (or make it group-writable)" >&2
  exit 1
}

say "registering the service"
systemctl daemon-reload
systemctl enable "${unit}" >/dev/null

# `deploy.sh` restarts the service as `deploy`, and so does anybody maintaining
# it by hand. The path comes from this machine rather than from a guess: sudoers
# matches the command line literally, so a rule naming /bin/systemctl does not
# apply to the /usr/bin/systemctl a person actually runs.
say "allowing ${service_user} to control the service"
systemctl_path="$(command -v systemctl || true)"
test -n "${systemctl_path}" || { echo "no systemctl on PATH" >&2; exit 1; }
command -v visudo >/dev/null || {
  echo "no visudo, so the sudoers rule cannot be checked before installing it" >&2
  echo "install the sudo package, or write ${sudoers_file} by hand" >&2
  exit 1
}

sudoers_tmp="$(mktemp)"
trap 'rm -f "${sudoers_tmp}"' EXIT
cat > "${sudoers_tmp}" <<EOF
# Written by deploy/prepare.sh. Do not edit; it is replaced on every deploy.
#
# Both spellings of the unit name, because sudoers matches the command line
# literally: the deploy runs \`systemctl restart pmo_backend.service\` and a
# person types \`systemctl restart pmo_backend\`.
Cmnd_Alias PMO_BACKEND_CTL = ${systemctl_path} start pmo_backend, \\
                             ${systemctl_path} start pmo_backend.service, \\
                             ${systemctl_path} stop pmo_backend, \\
                             ${systemctl_path} stop pmo_backend.service, \\
                             ${systemctl_path} restart pmo_backend, \\
                             ${systemctl_path} restart pmo_backend.service

${service_user} ALL=(root) NOPASSWD: PMO_BACKEND_CTL
EOF

# Checked before it is installed. A file in /etc/sudoers.d that does not parse
# takes sudo down for the whole machine, and this one is written unattended.
visudo -c -f "${sudoers_tmp}" >/dev/null || {
  echo "the generated sudoers rule does not parse; not installing it:" >&2
  cat "${sudoers_tmp}" >&2
  exit 1
}
install -m 440 -o root -g root "${sudoers_tmp}" "${sudoers_file}"

# Parsing is not the same as taking effect: a file whose name sudo skips, or an
# /etc/sudoers with no includedir, both leave a perfectly valid rule doing
# nothing. Ask sudo what it now believes.
sudo -l -U "${service_user}" 2>/dev/null | grep -q 'pmo_backend' || {
  echo "${sudoers_file} installed, but sudo does not apply it to ${service_user}" >&2
  echo "check that /etc/sudoers has an includedir line for /etc/sudoers.d" >&2
  exit 1
}

echo "prepared"
