#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
script="${root}/release_decision.sh"

assert_decision() {
  expected="$1"; shift
  actual="$(${script} "$@")"
  [ "${actual%%$'\t'*}" = "${expected}" ] || {
    echo "expected ${expected}, got ${actual}" >&2
    exit 1
  }
}

assert_decision skip push branch 1.0.0 new-sha 1.0.0 old-sha
assert_decision publish push branch 1.0.1 new-sha 1.0.0 old-sha
assert_decision skip push tag 1.0.0 same-sha 1.0.0 same-sha
assert_decision publish push tag 1.0.0 new-sha 1.0.0 old-sha
assert_decision publish push tag 1.0.1 same-sha 1.0.0 same-sha
assert_decision publish workflow_dispatch branch 1.0.0 same-sha 1.0.0 same-sha

for valid in 0.0.0 1.2.3 10.20.30; do
  "${root}/validate_version.sh" "${valid}"
done
for invalid in 01.2.3 1.02.3 1.2.03 1.2 1.2.3-rc.1; do
  if "${root}/validate_version.sh" "${invalid}" >/dev/null 2>&1; then
    echo "accepted non-canonical version: ${invalid}" >&2
    exit 1
  fi
done
printf 'release decision and version tests passed\n'
