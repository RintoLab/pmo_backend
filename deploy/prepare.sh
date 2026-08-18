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
#   env                          from r-nacos
#
# Leaves behind:
#
#   /apps/pmo_backend/           empty and owned by deploy, if it was not there
#   /etc/systemd/system/pmo_backend.service
#   /etc/pmo_backend/env         root:deploy 640

set -euo pipefail

staging="/tmp/pmo_backend-deploy"
app_root="/apps/pmo_backend"
env_file="/etc/pmo_backend/env"
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

# Checked here, where it is installed. Neither systemd nor `deploy.sh` runs a
# shell over this file, so a line that is not KEY=value is a variable the
# application silently will not have.
say "checking the environment"
if grep -vE '^\s*(#|$)' env | grep -vqE '^[A-Za-z_][A-Za-z0-9_]*='; then
  echo "the environment file has lines that are not KEY=value:" >&2
  grep -vE '^\s*(#|$)' env | grep -vE '^[A-Za-z_][A-Za-z0-9_]*=' | sed 's/=.*/=.../' >&2
  exit 1
fi
for required in DATABASE_URL SECRET_KEY_BASE RINTO_TOKEN; do
  grep -qE "^${required}=." env || {
    echo "${required} is missing or empty in the r-nacos config" >&2
    exit 1
  }
done

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

echo "prepared"
