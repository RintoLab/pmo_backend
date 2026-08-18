#!/usr/bin/env bash
#
# Phase two of two. Runs on the runner machine, over ssh, as `deploy`.
#
#   deploy.sh <version>
#
# Nothing here needs root. The release directory belongs to `deploy`, the
# migration runs as the same user the service runs as, and restarting is the one
# privileged act -- through the sudoers entry that exists for maintaining this
# service by hand anyway.
#
# Because this arrives over ssh as `deploy`, the working directory, HOME and
# environment are already that user's. `prepare.sh` deliberately does not start
# this and drop privileges to it: that would carry root's versions of all three
# in, and each would have to be corrected.
#
# Expects `prepare.sh` to have run first: the unit registered, /etc/pmo_backend/env
# installed, /apps/pmo_backend owned by this user.

set -euo pipefail

version="${1:?usage: deploy.sh <version>}"

app_root="/apps/pmo_backend"
incoming="/apps/.pmo_backend.incoming"
staging="/tmp/pmo_backend-deploy"
env_file="/etc/pmo_backend/env"
unit="pmo_backend.service"

say() { printf '\n=== %s\n' "$1"; }

test -r "${env_file}" || {
  echo "${env_file} is not readable; did prepare.sh run?" >&2
  exit 1
}

# The same values systemd will hand the service, read the same way it reads them.
# `export "K=V"` rather than `. ${env_file}`: that file is systemd's format, and a
# value with a space in it would have a shell trying to run the second word.
while IFS= read -r line || [ -n "${line}" ]; do
  case "${line}" in '' | \#*) continue ;; esac
  export "${line%%=*}=${line#*=}"
done < "${env_file}"

say "verifying what arrived"
cd "${staging}"
sha256sum -c release.tar.gz.sha256

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

say "installing it as ${app_root}"
rm -rf "${app_root}"
mv -Tf "${incoming}" "${app_root}"

# From the release directory, which this user owns. Run by the new release and
# before the restart: a migration that fails has to stop the deployment while the
# previous version is still serving. Creating the database is not done here -- it
# is done once, by hand, so the role this connects with never needs CREATEDB.
cd "${app_root}"

say "migrating"
if ! ./bin/pmo_backend eval 'RintoPMO.Release.migrate()'; then
  # A failure during boot is reported by a logger that is not up yet, so what
  # gets printed can be a cascade about `code_server` and `persistent_term` that
  # says nothing about the real cause. Booting with a trivial expression tells a
  # broken environment apart from a broken migration.
  echo "" >&2
  echo "the migration did not run; checking whether the release boots at all" >&2
  if ./bin/pmo_backend eval 'IO.puts("boot ok")'; then
    echo "it boots, so the failure is in the migration itself -- see above" >&2
  else
    echo "it does not boot at all, so this is the environment rather than the" >&2
    echo "migration. It ran as $(id -un) from $(pwd) with these variables:" >&2
    sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/  \1/p' "${env_file}" >&2
  fi
  exit 1
fi

# Idempotent, and run on every deploy rather than once by hand: an existing human
# and an existing default project are both reported and left alone. It earns its
# place by being self-healing -- a database that has lost either of them answers
# nothing, and this puts it back.
say "making sure there is somebody to answer as"
./bin/pmo_backend eval 'RintoPMO.Release.setup_human()'

# The one privileged act. `daemon-reload` and `enable` were prepare.sh's job, so
# the sudoers entry this needs is the same one a person needs to maintain the
# service by hand.
say "restarting"
sudo -n systemctl restart "${unit}" || {
  echo "could not restart ${unit} without a password. /etc/sudoers.d needs:" >&2
  echo "  $(id -un) ALL=(root) NOPASSWD: $(command -v systemctl) restart ${unit}" >&2
  exit 1
}

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
      echo "compare what the service got with what r-nacos holds: ${env_file}" >&2
      exit 1
      ;;
  esac
  sleep 2
done

echo "did not answer within 60s" >&2
systemctl status "${unit}" --no-pager >&2 || true
journalctl -u "${unit}" -n 50 --no-pager >&2 || true
exit 1
