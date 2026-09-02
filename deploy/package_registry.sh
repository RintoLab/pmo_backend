#!/usr/bin/env bash
set -euo pipefail

: "${PACKAGE_BASE_URL:?PACKAGE_BASE_URL is required}"
: "${PACKAGE_OWNER:?PACKAGE_OWNER is required}"
: "${PACKAGE_PUBLISH_USER:?PACKAGE_PUBLISH_USER is required}"
: "${PACKAGE_PUBLISH_TOKEN:?PACKAGE_PUBLISH_TOKEN is required}"
base="${PACKAGE_BASE_URL%/}"
host="${base#*://}"
host="${host%%/*}"
netrc="$(mktemp)"
trap 'rm -f "${netrc}"' EXIT
chmod 600 "${netrc}"
printf 'machine %s\nlogin %s\npassword %s\n' "${host}" "${PACKAGE_PUBLISH_USER}" "${PACKAGE_PUBLISH_TOKEN}" > "${netrc}"

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
      existing="$(mktemp)"
      curl -fsS --netrc-file "${netrc}" "${endpoint}" -o "${existing}"
      if ! cmp -s "${file}" "${existing}"; then
        rm -f "${existing}"
        echo "${package}/${version}/${name} exists with different content" >&2
        exit 1
      fi
      rm -f "${existing}"
      ;;
    *) echo "package upload failed for ${name} (HTTP ${code})" >&2; exit 1 ;;
  esac
}

get_file() {
  curl -fsS --netrc-file "${netrc}" "$(url "$1" "$2" "/$3")" -o "$4"
}

delete_version() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --netrc-file "${netrc}" -X DELETE "$(url "$1" "$2")")" || code=000
  case "${code}" in 204|404) ;; *) echo "package delete failed (HTTP ${code})" >&2; exit 1 ;; esac
}

# A pointer version is mutable by design, so it is replaced rather than kept:
# generic packages reject a second upload of the same file name.
publish_pointer() {
  delete_version "$1" "$2"
  put_file "$1" "$2" "$3" "$4"
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
  listing="$(mktemp)"
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
# per package rather than per version, so one call covers every version
# including the `latest` pointer.
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
  body="$(mktemp)"
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
  pointer) [ "$#" -eq 5 ] || exit 64; publish_pointer "$2" "$3" "$4" "$5" ;;
  delete) [ "$#" -eq 3 ] || exit 64; delete_version "$2" "$3" ;;
  link) [ "$#" -eq 3 ] || exit 64; link_repo "$2" "$3" ;;
  *) echo "usage: package_registry.sh put <package> <version> <file> <name> | get <package> <version> <name> <output> | pointer <package> <pointer> <file> <name> | delete <package> <version> | link <package> <repo>" >&2; exit 64 ;;
esac
