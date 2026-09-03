#!/usr/bin/env bash
set -euo pipefail

: "${PACKAGE_BASE_URL:?PACKAGE_BASE_URL is required}"
: "${PACKAGE_OWNER:?PACKAGE_OWNER is required}"
: "${PACKAGE_PUBLISH_USER:?PACKAGE_PUBLISH_USER is required}"
: "${PACKAGE_PUBLISH_TOKEN:?PACKAGE_PUBLISH_TOKEN is required}"
base="${PACKAGE_BASE_URL%/}"
host="${base#*://}"
host="${host%%/*}"
temporary_file() { mktemp "${TMPDIR:-/tmp}/rinto-package-registry.XXXXXX"; }
netrc="$(temporary_file)"
chmod 600 "${netrc}"
printf 'machine %s\nlogin %s\npassword %s\n' "${host}" "${PACKAGE_PUBLISH_USER}" "${PACKAGE_PUBLISH_TOKEN}" > "${netrc}"

restore_active=false
restore_package=""
restore_version=""
restore_name=""
restore_existing=""
cleanup_registry() {
  status=$?
  trap - EXIT HUP INT TERM
  set +e
  if [ "${restore_active}" = true ]; then
    echo "restoring ${restore_package}/${restore_version}/${restore_name} after failed or interrupted replacement" >&2
    if delete_file "${restore_package}" "${restore_version}" "${restore_name}"; then
      put_file "${restore_package}" "${restore_version}" "${restore_existing}" "${restore_name}" || \
        echo "warning: could not restore ${restore_package}/${restore_version}/${restore_name}" >&2
    else
      echo "warning: could not clear failed ${restore_package}/${restore_version}/${restore_name}" >&2
    fi
  fi
  [ -z "${restore_existing}" ] || rm -f "${restore_existing}"
  rm -f "${netrc}"
  exit "${status}"
}
trap cleanup_registry EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

url() { printf '%s/api/packages/%s/generic/%s/%s%s' "${base}" "${PACKAGE_OWNER}" "$1" "$2" "${3:-}"; }

# The upload endpoint lives under /api/packages; package administration lives
# under the regular /api/v1 surface.
admin_url() { printf '%s/api/v1/packages/%s/generic/%s%s' "${base}" "${PACKAGE_OWNER}" "$1" "$2"; }

put_file() {
  local package="$1" version="$2" file="$3" name="$4" endpoint code existing
  endpoint="$(url "${package}" "${version}" "/${name}")"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --netrc-file "${netrc}" --upload-file "${file}" "${endpoint}")" || code=000
  case "${code}" in
    201) ;;
    409)
      existing="$(temporary_file)"
      curl -fsS --netrc-file "${netrc}" "${endpoint}" -o "${existing}"
      if ! cmp -s "${file}" "${existing}"; then
        rm -f "${existing}"
        echo "${package}/${version}/${name} exists with different content" >&2
        return 1
      fi
      rm -f "${existing}"
      ;;
    *) echo "package upload failed for ${name} (HTTP ${code})" >&2; return 1 ;;
  esac
}

get_file() {
  curl -fsS --netrc-file "${netrc}" "$(url "$1" "$2" "/$3")" -o "$4"
}

delete_version() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --netrc-file "${netrc}" -X DELETE "$(url "$1" "$2")")" || code=000
  case "${code}" in 204|404) ;; *) echo "package delete failed (HTTP ${code})" >&2; return 1 ;; esac
}

delete_file() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --netrc-file "${netrc}" \
    -X DELETE "$(url "$1" "$2" "/$3")")" || code=000
  case "${code}" in
    204|404) ;;
    *) echo "package file delete failed for $3 (HTTP ${code})" >&2; return 1 ;;
  esac
}

# Replace one mutable-channel file without risking the previous file on an
# upload failure. Immutable semantic versions never call this operation.
replace_file() {
  local package="$1" version="$2" file="$3" name="$4" endpoint existing code had_old=false
  endpoint="$(url "${package}" "${version}" "/${name}")"
  existing="$(temporary_file)"
  code="$(curl -sS -o "${existing}" -w '%{http_code}' --netrc-file "${netrc}" "${endpoint}")" || code=000
  case "${code}" in
    200)
      if cmp -s "${file}" "${existing}"; then
        rm -f "${existing}"
        return 0
      fi
      had_old=true
      restore_active=true
      restore_package="${package}"
      restore_version="${version}"
      restore_name="${name}"
      restore_existing="${existing}"
      delete_file "${package}" "${version}" "${name}" || return 1
      ;;
    404) ;;
    *)
      echo "could not inspect ${package}/${version}/${name} (HTTP ${code})" >&2
      rm -f "${existing}"
      return 1
      ;;
  esac

  if put_file "${package}" "${version}" "${file}" "${name}"; then
    restore_active=false
    restore_existing=""
    rm -f "${existing}"
    return 0
  fi

  # When an old file existed, the EXIT trap restores it for ordinary errors and
  # HUP/INT/TERM, including termination between delete and upload. A first-ever
  # file has nothing to restore and is simply retried by the next release.
  if [ "${had_old}" = false ]; then
    rm -f "${existing}"
  fi
  return 1
}

# Whichever repository the registry currently says the package belongs to, or
# empty when it belongs to none and when the question cannot be answered.
#
# Read from the package listing rather than from a version endpoint: the link
# belongs to the package, and the caller that needs this has a package name but
# no version in hand. The listing is per version, so every version of the
# package repeats the same link and the first one that carries it answers. `q`
# is a substring match -- it narrows the page, and the exact name is selected
# here rather than trusted from the query.
linked_repo() {
  local package="$1" listing status link
  listing="$(temporary_file)"
  set +e
  curl -fsS --netrc-file "${netrc}" \
    "${base}/api/v1/packages/${PACKAGE_OWNER}?type=generic&q=${package}&limit=50" -o "${listing}"
  status=$?
  set -e
  if [ "${status}" -ne 0 ]; then
    rm -f "${listing}"
    return
  fi
  link="$(jq -r --arg name "${package}" \
    'map(select(.name == $name and .repository != null))
     | .[0].repository.name // ""' "${listing}")" || link=""
  rm -f "${listing}"
  printf '%s' "${link}"
}

# A generic package belongs to the owner, not to a repository, so without this
# it is only reachable through the org's Packages tab. The link is stored once
# per package rather than per version, so one call covers immutable versions and
# the rolling `latest` channel.
#
# It is not idempotent, which is the trap: Gitea refuses to move a link that
# already exists, so a package linked by an earlier release answers 400 here
# forever after. It answers 400 for a repository under another owner too, and
# the status alone does not say which happened -- so on 400 we ask what the
# package is actually linked to and let that decide. Already ours is the
# ordinary case on every release after the first; anything else is still a
# failure. A repository that does not exist under PACKAGE_OWNER answers 404.
link_repo() {
  local package="$1" repo="$2" body code linked
  body="$(temporary_file)"
  code="$(curl -sS -o "${body}" -w '%{http_code}' --netrc-file "${netrc}" \
    -X POST "$(admin_url "${package}" "/-/link/${repo}")")" || code=000
  case "${code}" in
    201)
      rm -f "${body}"
      ;;
    400)
      rm -f "${body}"
      linked="$(linked_repo "${package}")"
      if [ "${linked}" = "${repo}" ]; then
        echo "${package} is already linked to ${repo}"
      else
        echo "package link failed for ${package} -> ${repo} (HTTP 400); the registry says it is linked to ${linked:-nothing}" >&2
        exit 1
      fi
      ;;
    *)
      echo "package link failed for ${package} -> ${repo} (HTTP ${code}): $(tr -d '\n' < "${body}")" >&2
      rm -f "${body}"
      exit 1
      ;;
  esac
}

case "${1:-}" in
  put) [ "$#" -eq 5 ] || exit 64; put_file "$2" "$3" "$4" "$5" ;;
  get) [ "$#" -eq 5 ] || exit 64; get_file "$2" "$3" "$4" "$5" ;;
  replace) [ "$#" -eq 5 ] || exit 64; replace_file "$2" "$3" "$4" "$5" ;;
  delete) [ "$#" -eq 3 ] || exit 64; delete_version "$2" "$3" ;;
  link) [ "$#" -eq 3 ] || exit 64; link_repo "$2" "$3" ;;
  *) echo "usage: package_registry.sh put <package> <version> <file> <name> | replace <package> <version> <file> <name> | get <package> <version> <name> <output> | delete <package> <version> | link <package> <repo>" >&2; exit 64 ;;
esac
