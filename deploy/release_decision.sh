#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: release_decision.sh <event> <ref-type> <source-version> <sha> <published-version> <published-commit>" >&2
  exit 64
}

[ "$#" -eq 6 ] || usage
event="$1"
ref_type="$2"
source_version="$3"
sha="$4"
published_version="$5"
published_commit="$6"

case "${event}:${ref_type}" in
  workflow_dispatch:*)
    printf 'publish\tmanual dispatch always publishes\n'
    ;;
  push:branch)
    if [ "${source_version}" = "${published_version}" ]; then
      printf 'skip\tsource version already published\n'
    else
      printf 'publish\tsource version differs from published version\n'
    fi
    ;;
  push:tag)
    if [ "${source_version}" = "${published_version}" ] && [ "${sha}" = "${published_commit}" ]; then
      printf 'skip\tthis version and commit were already published\n'
    else
      printf 'publish\ttag points at a version or commit not yet published\n'
    fi
    ;;
  *)
    echo "unsupported release trigger: event=${event}, ref_type=${ref_type}" >&2
    exit 65
    ;;
esac
