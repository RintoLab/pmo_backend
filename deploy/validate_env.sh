#!/usr/bin/env bash
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: validate_env.sh <file> [required-key ...]" >&2; exit 64; }
file="$1"
shift
[ -s "${file}" ] || { echo "the environment file is empty" >&2; exit 1; }

line_number=0
while IFS= read -r line || [ -n "${line}" ]; do
  line_number=$((line_number + 1))
  case "${line}" in
    '' | \#*) continue ;;
  esac
  if [[ ! "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
    echo "environment line ${line_number} is not an exact KEY=value, blank line, or #comment" >&2
    exit 1
  fi
done < "${file}"

for required in "$@"; do
  value=""
  seen=false
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      "${required}"=*) value="${line#*=}"; seen=true ;;
    esac
  done < "${file}"
  if [ "${seen}" != true ] || [ -z "${value}" ]; then
    echo "${required} is missing or empty in the r-nacos config" >&2
    exit 1
  fi
done
