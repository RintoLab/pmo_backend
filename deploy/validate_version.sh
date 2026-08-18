#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: validate_version.sh <version>" >&2; exit 64; }
version="$1"
if [[ ! "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "version must be canonical stable semantic x.y.z without leading zeroes: ${version}" >&2
  exit 1
fi
