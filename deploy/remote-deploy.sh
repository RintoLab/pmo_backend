#!/usr/bin/env bash
#
# Runs on the runner machine, over ssh, as root.
#
#   remote-deploy.sh <version>
#
# There is no one-time setup to do by hand: this installs the unit and the
# environment file, creates the release directory and enables the service, all
# idempotently. Root is what makes that possible -- the same ssh key logs in as
# root and as `deploy`, so this path needs no sudoers entry of its own.
#
# (A human maintaining the service as `deploy` still wants one, for
# `systemctl start|stop|restart`. That is a separate concern from this script;
# see docs/deployment.md.)
#
# Only the *transport* is root. The service runs as `deploy` (see the unit), and
# the release directory is handed over to it.
#
# What it expects to already be there, uploaded by the workflow:
#
#   /tmp/pmo_backend-deploy/release.tar.gz
#   /tmp/pmo_backend-deploy/release.tar.gz.sha256
#   /tmp/pmo_backend-deploy/env                 from r-nacos, mode 600
#   /tmp/pmo_backend-deploy/pmo_backend.service
#
# What it leaves behind:
#
#   /apps/pmo_backend/                       the release, owned by deploy
#   /etc/systemd/system/pmo_backend.service
#   /etc/pmo_backend/env                     root, 600 -- the unit's EnvironmentFile

set -euo pipefail

version="${1:?usage: remote-deploy.sh <version>}"

root="/apps/pmo_backend"
incoming="/apps/.pmo_backend.incoming"
staging="/tmp/pmo_backend-deploy"
env_file="/etc/pmo_backend/env"
unit="pmo_backend.service"
service_user="deploy"

say() { printf '\n=== %s\n' "$1"; }

# The one-off `eval` processes below are not started by systemd, so nothing reads
# the unit's EnvironmentFile for them -- and `config/runtime.exs` refuses to boot
# without DATABASE_URL. They get the same values, out of the same file.
#
# Handed over explicitly rather than exported and inherited: `runuser` sets up a
# PAM session for the target user, and what survives that is not something to bet
# a deploy on. Each KEY=value is its own argv element, so a value with a space in
# it stays one value. HOME is included because runuser leaves root's, and `deploy`
# cannot read /root.
as_service() {
  runuser -u "${service_user}" -- env "${service_env[@]}" "$@"
}

test "$(id -u)" = 0 || { echo "this has to run as root" >&2; exit 1; }
id "${service_user}" >/dev/null 2>&1 || {
  echo "there is no ${service_user} user for the service to run as" >&2
  exit 1
}
service_home="$(getent passwd "${service_user}" | cut -d: -f6)"
test -n "${service_home}" -a -d "${service_home}" || {
  echo "${service_user} has no home directory (${service_home:-unset}); the VM needs one" >&2
  exit 1
}

say "verifying what arrived"
cd "${staging}"
sha256sum -c release.tar.gz.sha256
test -s env || { echo "the environment file is empty; refusing" >&2; exit 1; }
test -s "${unit}" || { echo "the unit file did not arrive; refusing" >&2; exit 1; }

# Neither systemd nor this script runs a shell over that file, so a line that is
# not KEY=value is a variable the application silently will not have.
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

# Two readers of one file. `service_env` is what gets handed to the `eval`
# processes; `load_env` puts the same values in this script's own environment,
# which the health check needs for PORT and RINTO_TOKEN.
#
# `export "K=V"` rather than `. env`: a value with a space in it is fine for
# systemd and fatal for a shell sourcing the same file.
service_env=("HOME=${service_home}")
while IFS= read -r line || [ -n "${line}" ]; do
  case "${line}" in '' | \#*) continue ;; esac
  service_env+=("${line}")
done < "${staging}/env"

load_env() {
  local line key value
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in '' | \#*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    export "${key}=${value}"
  done < "${staging}/env"
}

# Unpacked next to the release rather than over it, and on the same filesystem,
# so the swap is a rename: a tarball that turns out to be broken never reaches
# the path systemd starts from.
say "unpacking ${version}"
rm -rf "${incoming}"
mkdir -p "${incoming}"
tar -xzf "${staging}/release.tar.gz" -C "${incoming}"
test -x "${incoming}/bin/pmo_backend" || {
  echo "the tarball has no bin/pmo_backend; refusing to install it" >&2
  exit 1
}
# The service runs as `deploy`, and a release writes into its own directory --
# RELEASE_TMP defaults to there.
chown -R "${service_user}:${service_user}" "${incoming}"

say "installing it as ${root}"
rm -rf "${root}"
mv -Tf "${incoming}" "${root}"

say "installing the unit"
install -m 644 -o root -g root "${staging}/${unit}" "/etc/systemd/system/${unit}"

# Copied rather than rendered. systemd parses this format itself, so a value with
# a space, a quote or a percent sign in it needs no escaping -- which is a whole
# class of bug not to have. Root-owned and 600: systemd reads it as root before
# dropping to `deploy`, so `deploy` never needs to.
say "installing the environment as ${env_file}"
install -d -m 755 -o root -g root "$(dirname "${env_file}")"
install -m 600 -o root -g root "${staging}/env" "${env_file}"

# Run by the new release and before the restart: a migration that fails has to
# stop the deployment while the previous version is still serving. Creating the
# database is not done here -- it is done once, by hand, so that the role this
# connects with never needs CREATEDB.
say "migrating"
load_env
if ! as_service "${root}/bin/pmo_backend" eval 'RintoPMO.Release.migrate()'; then
  # A `config/runtime.exs` that raises does so before the logger is up, so what
  # gets printed is a cascade about `code_server` and `persistent_term` rather
  # than the actual message. Booting the release with a trivial expression tells
  # the two apart, and naming the variables it was handed is usually the answer.
  echo "" >&2
  echo "the migration did not run; checking whether the release boots at all" >&2
  if as_service "${root}/bin/pmo_backend" eval 'IO.puts("boot ok")'; then
    echo "it boots, so the failure is in the migration itself -- see above" >&2
  else
    echo "it does not boot: config/runtime.exs raised. Anything above about" >&2
    echo "code_server or persistent_term is the logger failing to report that," >&2
    echo "not the problem. It was handed these variables:" >&2
    printf '  %s\n' "${service_env[@]%%=*}" >&2
  fi
  exit 1
fi

# Idempotent, and run on every deploy rather than once by hand: an existing
# human and an existing default project are both reported and left alone. It
# earns its place by being self-healing -- a database that has lost either of
# them answers nothing, and this puts it back.
#
# No name is passed in. `RintoPMO.Setup.default_name/0` reads RINTO_OWNER_NAME
# from the environment, which is already loaded, so no shell has to interpolate
# a name into an Elixir string literal.
say "making sure there is somebody to answer as"
as_service "${root}/bin/pmo_backend" eval 'RintoPMO.Release.setup_human()'

say "restarting"
systemctl daemon-reload
systemctl enable "${unit}" >/dev/null
systemctl restart "${unit}"

# The deploy is done when this machine's own service answers. What happens
# between the reverse proxy and the outside is not this script's business.
say "waiting for it to answer"
url="http://127.0.0.1:${PORT:-4000}/api/v1/actors/me"
probe="$(mktemp)"
trap 'rm -f "${probe}"' EXIT
for _ in $(seq 1 30); do
  code="$(curl -so "${probe}" -w '%{http_code}' \
    -H "Authorization: Bearer ${RINTO_TOKEN}" "${url}" || echo 000)"
  case "${code}" in
    200)
      echo "serving as $(cat "${probe}")"
      rm -rf "${staging}"
      exit 0
      ;;
    401)
      # `human_actor_missing` should be impossible here -- setup_human ran a few
      # lines ago. So this is the token: what the environment file gave the
      # service is not what this check just sent, which means the restart did not
      # pick the new file up.
      echo "it is answering, but not as anybody:" >&2
      cat "${probe}" >&2
      echo "" >&2
      echo "compare what the service got with what r-nacos holds:" >&2
      echo "  ${env_file}" >&2
      exit 1
      ;;
  esac
  sleep 2
done

echo "did not answer within 60s" >&2
systemctl status "${unit}" --no-pager >&2 || true
journalctl -u "${unit}" -n 50 --no-pager >&2 || true
exit 1
