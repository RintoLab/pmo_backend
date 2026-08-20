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

case "${1:-}" in
  put) [ "$#" -eq 5 ] || exit 64; put_file "$2" "$3" "$4" "$5" ;;
  get) [ "$#" -eq 5 ] || exit 64; get_file "$2" "$3" "$4" "$5" ;;
  pointer) [ "$#" -eq 5 ] || exit 64; publish_pointer "$2" "$3" "$4" "$5" ;;
  delete) [ "$#" -eq 3 ] || exit 64; delete_version "$2" "$3" ;;
  *) echo "usage: package_registry.sh put <package> <version> <file> <name> | get <package> <version> <name> <output> | pointer <package> <pointer> <file> <name> | delete <package> <version>" >&2; exit 64 ;;
esac
