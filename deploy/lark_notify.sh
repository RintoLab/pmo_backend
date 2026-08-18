#!/usr/bin/env bash
# Notification is intentionally best-effort: a Lark outage must not rewrite a release result.
set -uo pipefail

if [ "$#" -ne 7 ]; then
  echo "warning: lark_notify.sh expects component result version ref sha reason run-url" >&2
  exit 0
fi
component="$1" result="$2" version="$3" ref="$4" sha="$5" reason="$6" run_url="$7"
webhook="${LARK_WEBHOOK_URL:-}"
secret="${LARK_SIGNING_SECRET:-}"
keyword="${LARK_KEYWORD:-Rinto 发布}"

if [ -z "${webhook}" ]; then
  echo "warning: LARK_WEBHOOK_URL is not configured; notification skipped" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "warning: jq is unavailable; Lark notification skipped" >&2
  exit 0
fi

printf -v text '%s\n组件: %s\n结果: %s\n版本: %s\nRef: %s\nCommit: %s\n原因: %s\n运行: %s' \
  "${keyword}" "${component}" "${result}" "${version:-unknown}" "${ref}" "${sha}" "${reason}" "${run_url}"

if [ -n "${secret}" ]; then
  timestamp="$(date +%s)"
  signing_key="$(printf '%s\n%s' "${timestamp}" "${secret}")"
  sign="$(printf '' | openssl dgst -sha256 -hmac "${signing_key}" -binary 2>/dev/null | base64 | tr -d '\r\n')"
  payload="$(jq -cn --arg timestamp "${timestamp}" --arg sign "${sign}" --arg text "${text}" \
    '{timestamp:$timestamp,sign:$sign,msg_type:"text",content:{text:$text}}')"
else
  payload="$(jq -cn --arg text "${text}" '{msg_type:"text",content:{text:$text}}')"
fi

body="$(mktemp)"
code="$(curl -sS -o "${body}" -w '%{http_code}' -H 'Content-Type: application/json' \
  -d "${payload}" "${webhook}")" || code=000
if [ "${code}" != 200 ] || ! jq -e '(.code == 0) or (.StatusCode == 0)' "${body}" >/dev/null 2>&1; then
  echo "warning: Lark notification failed (HTTP ${code})" >&2
fi
rm -f "${body}"
exit 0
