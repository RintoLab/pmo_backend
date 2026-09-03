#!/bin/sh
set -eu

PACKAGE_BASE_URL="${RINTO_PACKAGE_BASE_URL:-https://gitea.kenton.wang/api/packages/Rinto/generic/rinto-pmo}"
CHANNEL_VERSION=latest

fail() {
  printf 'rinto-pmo install: %s\n' "$*" >&2
  exit 1
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

valid_version() {
  case "${1:-}" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  old_ifs="${IFS}"
  IFS=.
  set -- $1
  IFS="${old_ifs}"
  [ "$#" -eq 3 ] || return 1
  for part in "$@"; do
    case "${part}" in
      ''|*[!0-9]*) return 1 ;;
      0|[1-9]*) ;;
      *) return 1 ;;
    esac
  done
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v mktemp >/dev/null 2>&1 || fail "mktemp is required"

if [ -n "${RINTO_PLATFORM:-}" ]; then
  platform="${RINTO_PLATFORM}"
else
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}/${arch}" in
    Linux/x86_64|Linux/amd64) platform=linux-amd64 ;;
    Darwin/arm64|Darwin/aarch64) platform=darwin-arm64 ;;
    *) fail "unsupported platform: ${os}/${arch}" ;;
  esac
fi

case "${platform}" in
  linux-amd64) asset=rinto-pmo-linux-amd64 ;;
  darwin-arm64) asset=rinto-pmo-darwin-arm64 ;;
  *) fail "unsupported platform: ${platform}" ;;
esac

if [ -n "${RINTO_INSTALL_DIR:-}" ]; then
  install_dir="${RINTO_INSTALL_DIR}"
else
  [ -n "${HOME:-}" ] || fail "HOME is not set; set RINTO_INSTALL_DIR explicitly"
  install_dir="${HOME}/.local/bin"
fi

destination="${install_dir}/rinto-pmo"

mkdir -p "${install_dir}" || fail "could not create ${install_dir}"
[ -d "${install_dir}" ] || fail "${install_dir} is not a directory"
[ -w "${install_dir}" ] || fail "${install_dir} is not writable"

work_dir="$(mktemp -d "${install_dir}/.rinto-pmo.install.XXXXXX")" || \
  fail "could not create a temporary directory in ${install_dir}"
temporary="${work_dir}/rinto-pmo"
checksums="${work_dir}/SHA256SUMS"
manifest="${work_dir}/manifest.json"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${RINTO_VERSION:-}" ]; then
  package_version="${RINTO_VERSION}"
else
  channel="${PACKAGE_BASE_URL%/}/${CHANNEL_VERSION}"
  curl -fsSL "${channel}/manifest.json" -o "${manifest}" || \
    fail "could not download ${channel}/manifest.json"
  package_version="$(awk -F '"' '/"version"[[:space:]]*:/ { print $4; exit }' "${manifest}")"
fi
valid_version "${package_version}" || fail "invalid release version: ${package_version:-empty}"
base="${PACKAGE_BASE_URL%/}/${package_version}"

curl -fsSL "${base}/${asset}" -o "${temporary}" || \
  fail "could not download ${base}/${asset}"
curl -fsSL "${base}/SHA256SUMS" -o "${checksums}" || \
  fail "could not download ${base}/SHA256SUMS"

expected="$(awk -v file="${asset}" '$2 == file || $2 == "*" file { print $1; exit }' "${checksums}")"
[ "${#expected}" -eq 64 ] || fail "SHA256SUMS has no valid entry for ${asset}"
case "${expected}" in
  *[!0-9a-fA-F]*) fail "SHA256SUMS has no valid entry for ${asset}" ;;
esac
expected="$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]')"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${temporary}" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "${temporary}" | awk '{ print $1 }')"
else
  fail "sha256sum or shasum is required to verify the download"
fi

[ "${actual}" = "${expected}" ] || fail "SHA-256 verification failed for ${asset}"
chmod 0755 "${temporary}" || fail "could not make the downloaded CLI executable"
mv -f "${temporary}" "${destination}" || fail "could not install ${destination}"

installed="$("${destination}" --version)" || fail "the installed CLI could not start"
printf 'installed %s to %s\n' "${installed}" "${destination}"

case ":${PATH:-}:" in
  *:"${install_dir}":*) ;;
  *)
    quoted_install_dir="$(shell_quote "${install_dir}")"
    printf '%s\n' "${install_dir} is not on PATH." >&2
    printf 'Add this to your shell profile: export PATH=%s:"$PATH"\n' \
      "${quoted_install_dir}" >&2
    ;;
esac
