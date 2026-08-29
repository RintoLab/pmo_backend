#!/usr/bin/env bash
# Phase two: validate the staged release, migrate with it, then swap and restart.
set -euo pipefail

version="${1:?usage: deploy.sh <version>}"
app_root="/apps/pmo_backend"
incoming="/apps/.pmo_backend.incoming"
previous="/apps/.pmo_backend.previous"
staging="/tmp/pmo_backend-deploy"
env_file="/etc/pmo_backend/env"
unit="pmo_backend.service"
swap_started=false
probe=""

say() { printf '\n=== %s\n' "$1"; }

cleanup() {
  status=$?
  trap - EXIT
  [ -z "${probe}" ] || rm -f "${probe}"
  rm -rf "${incoming}" "${staging}"
  if [ "${status}" -ne 0 ]; then
    if [ "${swap_started}" = true ]; then
      echo "the new release failed after the filesystem swap" >&2
      echo "the prior release files remain at ${previous} for explicit manual recovery" >&2
    else
      echo "the current release path ${app_root} was left untouched" >&2
    fi
    echo "database migrations and the installed environment/unit were not rolled back" >&2
    # provision_agent.sh runs before this script, so by the time anything here
    # can fail the agent side is already this attempt's. Named because it is the
    # one part of a failed deploy that answers requests: a topic's pi keeps
    # working, against whichever release ends up serving.
    echo "neither is the agent side -- provision_agent.sh ran first, so the CLI," >&2
    echo "its skill and ~deploy/.pi/agent/AGENTS.md are already this attempt's" >&2
  fi
  exit "${status}"
}
trap cleanup EXIT

test -r "${env_file}" || {
  echo "${env_file} is not readable; did prepare.sh run?" >&2
  exit 1
}
test -r "${staging}/validate_env.sh" || {
  echo "the environment validator did not arrive" >&2
  exit 1
}
bash "${staging}/validate_env.sh" "${env_file}" DATABASE_URL SECRET_KEY_BASE RINTO_TOKEN

# Export exactly the grammar accepted by validate_env.sh. Quoting the whole
# assignment preserves spaces and additional equals signs in values.
while IFS= read -r line || [ -n "${line}" ]; do
  case "${line}" in '' | \#*) continue ;; esac
  export "${line%%=*}=${line#*=}"
done < "${env_file}"

# Optional by design -- an installation without the inference service is a
# legitimate one -- and therefore the only variable whose absence nothing else
# would ever mention: the release starts, migrates, passes its health check, and
# then computes no vectors at all. An installation that lost the token by
# accident looks exactly the same, and only whoever reads this log can tell the
# two apart, so this says it rather than deciding.
if [ -z "${RINTO_AI_TOKEN:-}" ]; then
  say "note: RINTO_AI_TOKEN is not set in the r-nacos config"
  echo "nothing will be embedded, and GET /search will answer 503 ai_not_configured"
  echo "adding it later needs no backfill: rows with no vector are the queue"
fi

say "verifying what arrived"
cd "${staging}"
sha256sum -c release.tar.gz.sha256

say "unpacking ${version}"
rm -rf "${incoming}"
mkdir -p "${incoming}"
tar -xzf "${staging}/release.tar.gz" -C "${incoming}"
test -x "${incoming}/bin/pmo_backend" || {
  echo "the tarball has no bin/pmo_backend; refusing to install it" >&2
  exit 1
}

# Migrate and run setup from the incoming release while the prior release path
# remains untouched. A migration failure therefore needs no filesystem restore;
# it also deliberately does not claim to undo any database work already applied.
cd "${incoming}"
say "migrating"
if ! ./bin/pmo_backend eval 'RintoPMO.Release.migrate()'; then
  echo "" >&2
  echo "the migration did not run; checking whether the incoming release boots" >&2
  if ./bin/pmo_backend eval 'IO.puts("boot ok")'; then
    echo "it boots, so the failure is in the migration itself -- see above" >&2
  else
    echo "the incoming release does not boot; check its runtime environment" >&2
    sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/  \1/p' "${env_file}" >&2
  fi
  exit 1
fi

say "making sure there is somebody to answer as"
if ! ./bin/pmo_backend eval 'RintoPMO.Release.setup_human()'; then
  echo "setup_human failed; the prior release path remains in place" >&2
  exit 1
fi

# Only after migration and setup succeed do the on-disk paths change. Keep the
# old tree beside the new one until the new service passes its health check.
# Failures after this point deliberately require explicit operator recovery:
# migrations, the installed environment, and the unit are not rolled back.
say "installing it as ${app_root}"
rm -rf "${previous}"
mv -Tf "${app_root}" "${previous}"
swap_started=true
mv -Tf "${incoming}" "${app_root}"
cd "${app_root}"

say "restarting"
sudo -n systemctl restart "${unit}" || {
  echo "could not restart ${unit} without a password" >&2
  exit 1
}

say "waiting for it to answer"
url="http://127.0.0.1:${PORT:-4000}/api/v1/actors/me"
probe="$(mktemp)"
for _ in $(seq 1 30); do
  code="$(curl -so "${probe}" -w '%{http_code}' \
    -H "Authorization: Bearer ${RINTO_TOKEN}" "${url}" || echo 000)"
  case "${code}" in
    200)
      echo "serving as $(cat "${probe}")"
      rm -rf "${previous}" "${staging}"
      exit 0
      ;;
    401)
      echo "the new release is answering but rejected the configured token:" >&2
      cat "${probe}" >&2
      echo "" >&2
      exit 1
      ;;
  esac
  sleep 2
done

echo "the new release did not answer within 60s" >&2
systemctl status "${unit}" --no-pager >&2 || true
journalctl -u "${unit}" -n 50 --no-pager >&2 || true
exit 1
