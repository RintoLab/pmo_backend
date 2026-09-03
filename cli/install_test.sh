#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
installer_shell="${INSTALLER_SHELL:-sh}"
tmp="$(mktemp -d /tmp/rinto-cli-install-test.XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT
package="${tmp}/package"
release="${package}/1.2.3"
channel="${package}/latest"
mkdir -p "${release}" "${channel}"
printf '%s\n' '{"version":"1.2.3"}' > "${channel}/manifest.json"

write_asset() {
  local name="$1" version="$2"
  cat > "${release}/${name}" <<EOF
#!/bin/sh
printf '%s\n' 'rinto-pmo ${version}'
EOF
  chmod 0755 "${release}/${name}"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

write_checksums() {
  printf '%s  %s\n' "$(sha256_of "${release}/rinto-pmo-linux-amd64")" rinto-pmo-linux-amd64 > "${release}/SHA256SUMS"
  printf '%s  %s\n' "$(sha256_of "${release}/rinto-pmo-darwin-arm64")" rinto-pmo-darwin-arm64 >> "${release}/SHA256SUMS"
}

write_asset rinto-pmo-linux-amd64 test-linux
write_asset rinto-pmo-darwin-arm64 test-darwin
write_checksums

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64|Linux/amd64)
    detected_version=test-linux
    other_platform=darwin-arm64
    other_version=test-darwin
    ;;
  Darwin/arm64|Darwin/aarch64)
    detected_version=test-darwin
    other_platform=linux-amd64
    other_version=test-linux
    ;;
  *)
    echo "installer test is running on an unsupported platform" >&2
    exit 1
    ;;
esac

install_dir="${tmp}/local bin ' \$(printf unsafe)"
output="$(
  RINTO_PACKAGE_BASE_URL="file://${package}" \
  RINTO_INSTALL_DIR="${install_dir}" \
  "${installer_shell}" "${root}/install.sh" 2>&1
)"
grep -F "installed rinto-pmo ${detected_version} to ${install_dir}/rinto-pmo" <<< "${output}" >/dev/null
grep -F "${install_dir} is not on PATH" <<< "${output}" >/dev/null
path_command="$(grep -F 'Add this to your shell profile: ' <<< "${output}")"
path_command="${path_command#Add this to your shell profile: }"
original_path="${PATH}"
eval "${path_command}"
test "${PATH%%:*}" = "${install_dir}"
PATH="${original_path}"
test -x "${install_dir}/rinto-pmo"
test ! -e "${install_dir}/rinto-pmo-linux-amd64"
test ! -e "${install_dir}/rinto-pmo-darwin-arm64"
test "$("${install_dir}/rinto-pmo" --version)" = "rinto-pmo ${detected_version}"

RINTO_PACKAGE_BASE_URL="file://${package}" \
RINTO_INSTALL_DIR="${install_dir}" \
RINTO_PLATFORM="${other_platform}" \
RINTO_VERSION=1.2.3 \
PATH="${install_dir}:${PATH}" \
"${installer_shell}" "${root}/install.sh" >/dev/null
test "$("${install_dir}/rinto-pmo" --version)" = "rinto-pmo ${other_version}"

if RINTO_PACKAGE_BASE_URL="file://${package}" \
  RINTO_INSTALL_DIR="${install_dir}" \
  RINTO_PLATFORM=windows-amd64 \
  "${installer_shell}" "${root}/install.sh" >/dev/null 2>&1; then
  echo "installer accepted an unsupported platform" >&2
  exit 1
fi

if RINTO_PACKAGE_BASE_URL="file://${package}" \
  RINTO_INSTALL_DIR="${install_dir}" \
  RINTO_PLATFORM=linux-amd64 \
  RINTO_VERSION=../../latest \
  "${installer_shell}" "${root}/install.sh" >/dev/null 2>&1; then
  echo "installer accepted an invalid release version" >&2
  exit 1
fi

# A failed verification must leave the previously installed executable intact.
printf '%064d  %s\n' 0 rinto-pmo-linux-amd64 > "${release}/SHA256SUMS"
if RINTO_PACKAGE_BASE_URL="file://${package}" \
  RINTO_INSTALL_DIR="${install_dir}" \
  RINTO_PLATFORM=linux-amd64 \
  "${installer_shell}" "${root}/install.sh" >/dev/null 2>&1; then
  echo "installer accepted a bad checksum" >&2
  exit 1
fi
test "$("${install_dir}/rinto-pmo" --version)" = "rinto-pmo ${other_version}"

if find "${install_dir}" -maxdepth 1 -name '.rinto-pmo.install.*' -print -quit | grep -q .; then
  echo "installer left a temporary directory behind" >&2
  exit 1
fi

printf 'CLI installer tests passed\n'
