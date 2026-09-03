#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
script="${root}/package_registry.sh"
tmp="$(mktemp -d /tmp/rinto-package-registry-test.XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/registry"

cat > "${tmp}/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

output=""
write_code=""
upload=""
method=GET
fail_http=false
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) write_code="$2"; shift 2 ;;
    --netrc-file) shift 2 ;;
    --upload-file) upload="$2"; method=PUT; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -*f*) fail_http=true; shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done

relative="${url#https://gitea.kenton.wang/api/packages/Rinto/generic/}"
path="${FAKE_REGISTRY}/${relative}"
status=500
case "${method}" in
  GET)
    if [ -f "${path}" ]; then
      status=200
      [ -z "${output}" ] || cp "${path}" "${output}"
    else
      status=404
      [ -z "${output}" ] || : > "${output}"
    fi
    ;;
  PUT)
    if [ "${FAKE_FAIL_ONCE_NAME:-}" = "$(basename "${path}")" ] && \
       [ ! -e "${FAKE_REGISTRY}/.failed" ]; then
      : > "${FAKE_REGISTRY}/.failed"
      status=500
    elif [ -e "${path}" ]; then
      status=409
    else
      mkdir -p "$(dirname "${path}")"
      cp "${upload}" "${path}"
      status=201
    fi
    ;;
  DELETE)
    if [ -e "${path}" ]; then
      rm -rf "${path}"
      status=204
      if [ "${FAKE_TERM_AFTER_DELETE_NAME:-}" = "$(basename "${path}")" ] && \
         [ ! -e "${FAKE_REGISTRY}/.terminated" ]; then
        : > "${FAKE_REGISTRY}/.terminated"
        kill -TERM "${PPID}"
      fi
    else
      status=404
    fi
    ;;
esac

[ -z "${write_code}" ] || printf '%s' "${status}"
if [ "${fail_http}" = true ] && [ "${status}" -ge 400 ]; then
  exit 22
fi
FAKE_CURL
chmod 0755 "${tmp}/bin/curl"

registry() {
  env \
    PATH="${tmp}/bin:${PATH}" \
    TMPDIR=/tmp \
    FAKE_REGISTRY="${tmp}/registry" \
    FAKE_FAIL_ONCE_NAME="${FAKE_FAIL_ONCE_NAME:-}" \
    FAKE_TERM_AFTER_DELETE_NAME="${FAKE_TERM_AFTER_DELETE_NAME:-}" \
    PACKAGE_BASE_URL=https://gitea.kenton.wang \
    PACKAGE_OWNER=Rinto \
    PACKAGE_PUBLISH_USER=test \
    PACKAGE_PUBLISH_TOKEN=test \
    "${script}" "$@"
}

printf old > "${tmp}/old"
printf new > "${tmp}/new"
printf newer > "${tmp}/newer"

registry put rinto-pmo latest "${tmp}/old" artifact
registry replace rinto-pmo latest "${tmp}/new" artifact
cmp -s "${tmp}/new" "${tmp}/registry/rinto-pmo/latest/artifact"
registry replace rinto-pmo latest "${tmp}/new" artifact

# Failed replacement restores the previous complete file.
export FAKE_FAIL_ONCE_NAME=artifact
if registry replace rinto-pmo latest "${tmp}/newer" artifact; then
  echo "replace unexpectedly succeeded during the injected upload failure" >&2
  exit 1
fi
unset FAKE_FAIL_ONCE_NAME
cmp -s "${tmp}/new" "${tmp}/registry/rinto-pmo/latest/artifact"

# Termination after deletion also runs the EXIT restoration before returning.
export FAKE_TERM_AFTER_DELETE_NAME=artifact
if registry replace rinto-pmo latest "${tmp}/newer" artifact; then
  echo "replace unexpectedly survived termination after delete" >&2
  exit 1
fi
unset FAKE_TERM_AFTER_DELETE_NAME
cmp -s "${tmp}/new" "${tmp}/registry/rinto-pmo/latest/artifact"

# Immutable publication refuses different content under an existing name.
if registry put rinto-pmo 1.2.3 "${tmp}/old" artifact && \
   registry put rinto-pmo 1.2.3 "${tmp}/new" artifact; then
  echo "put replaced immutable package content" >&2
  exit 1
fi
cmp -s "${tmp}/old" "${tmp}/registry/rinto-pmo/1.2.3/artifact"

printf 'package registry tests passed\n'
