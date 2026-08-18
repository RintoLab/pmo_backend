#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
tmp="${root}/.validate-env-test-$$"
rm -rf "${tmp}"
mkdir -m 700 "${tmp}"
trap 'rm -rf "${tmp}"' EXIT

cat > "${tmp}/valid" <<'EOF'
# exact comment

DATABASE_URL=ecto://user:pass@db/app
SECRET_KEY_BASE=with spaces and = signs
RINTO_TOKEN=token
EOF
bash "${root}/validate_env.sh" "${tmp}/valid" DATABASE_URL SECRET_KEY_BASE RINTO_TOKEN

for invalid in leading-space-comment whitespace-only export missing-equals bad-key; do
  case "${invalid}" in
    leading-space-comment) printf ' #comment\n' ;;
    whitespace-only) printf '  \n' ;;
    export) printf 'export KEY=value\n' ;;
    missing-equals) printf 'KEY\n' ;;
    bad-key) printf '1KEY=value\n' ;;
  esac > "${tmp}/${invalid}"
  if bash "${root}/validate_env.sh" "${tmp}/${invalid}" >/dev/null 2>&1; then
    echo "accepted invalid environment case: ${invalid}" >&2
    exit 1
  fi
done

cat > "${tmp}/duplicate-empty" <<'EOF'
DATABASE_URL=first
DATABASE_URL=
SECRET_KEY_BASE=secret
RINTO_TOKEN=token
EOF
if bash "${root}/validate_env.sh" "${tmp}/duplicate-empty" DATABASE_URL SECRET_KEY_BASE RINTO_TOKEN >/dev/null 2>&1; then
  echo "accepted a required key whose final value is empty" >&2
  exit 1
fi

echo "environment validation tests passed"
