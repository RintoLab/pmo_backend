#!/usr/bin/env bash
# Notification is intentionally best-effort: a Feishu outage must not rewrite a release result.
set -uo pipefail

api_base="${LARK_API_BASE:-https://open.feishu.cn}"
app_id="${LARK_APP_ID:-}"
app_secret="${LARK_APP_SECRET:-}"
chat_id="${LARK_CHAT_ID:-}"
keyword="${LARK_KEYWORD:-Rinto 发布}"

warn() { echo "warning: $*" >&2; }

ready() {
  if [ -z "${app_id}" ] || [ -z "${app_secret}" ] || [ -z "${chat_id}" ]; then
    warn "LARK_APP_ID, LARK_APP_SECRET, and LARK_CHAT_ID are required; notification skipped"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    warn "curl and jq are required; Feishu notification skipped"
    return 1
  fi
}

request() {
  local method="$1" url="$2" payload="$3" output="$4" auth_header="${5:-}" code
  if [ -n "${auth_header}" ]; then
    code="$(printf '%s' "${payload}" | curl -sS -o "${output}" -w '%{http_code}' \
      -X "${method}" -H 'Content-Type: application/json' -H "@${auth_header}" \
      --data-binary @- "${url}")" || code=000
  else
    code="$(printf '%s' "${payload}" | curl -sS -o "${output}" -w '%{http_code}' \
      -X "${method}" -H 'Content-Type: application/json' \
      --data-binary @- "${url}")" || code=000
  fi
  [ "${code}" = 200 ] && jq -e '.code == 0' "${output}" >/dev/null 2>&1
}

tenant_token() {
  local payload body token
  payload="$(jq -cn --arg app_id "${app_id}" --arg app_secret "${app_secret}" \
    '{app_id:$app_id,app_secret:$app_secret}')"
  body="$(mktemp)"
  if ! request POST "${api_base%/}/open-apis/auth/v3/tenant_access_token/internal" \
    "${payload}" "${body}"; then
    warn "could not obtain a Feishu tenant access token"
    rm -f "${body}"
    return 1
  fi
  token="$(jq -r '.tenant_access_token // empty' "${body}")"
  rm -f "${body}"
  if [ -z "${token}" ]; then
    warn "Feishu returned no tenant access token"
    return 1
  fi
  printf '%s' "${token}"
}

card_json() {
  local component="$1" result="$2" version="$3" ref="$4" sha="$5" reason="$6" run_url="$7"
  local template label short_sha
  case "${result}" in
    running) template=blue; label=运行中 ;;
    success) template=green; label=成功 ;;
    failure) template=red; label=失败 ;;
    skipped) template=grey; label=已跳过 ;;
    *) template=grey; label="${result}" ;;
  esac
  short_sha="${sha:0:12}"
  jq -cn \
    --arg title "${keyword} · ${component} · ${label}" \
    --arg template "${template}" \
    --arg status "**状态**\n${label}" \
    --arg version "**版本**\n${version:-unknown}" \
    --arg ref "**Ref**\n${ref}" \
    --arg commit "**Commit**\n${short_sha}" \
    --arg reason "**说明**\n${reason}" \
    --arg run_url "${run_url}" \
    '{
      config:{wide_screen_mode:true,update_multi:true},
      header:{template:$template,title:{tag:"plain_text",content:$title}},
      elements:[
        {tag:"div",fields:[
          {is_short:true,text:{tag:"lark_md",content:$status}},
          {is_short:true,text:{tag:"lark_md",content:$version}},
          {is_short:true,text:{tag:"lark_md",content:$ref}},
          {is_short:true,text:{tag:"lark_md",content:$commit}}
        ]},
        {tag:"div",text:{tag:"lark_md",content:$reason}},
        {tag:"action",actions:[
          {tag:"button",type:"primary",text:{tag:"plain_text",content:"查看 Gitea 运行"},url:$run_url}
        ]}
      ]
    }'
}

auth_header_file() {
  local token="$1" file
  file="$(mktemp)"
  chmod 600 "${file}"
  printf 'Authorization: Bearer %s\n' "${token}" > "${file}"
  printf '%s' "${file}"
}

send_card() {
  local content="$1" token header payload body message_id
  token="$(tenant_token)" || return 1
  header="$(auth_header_file "${token}")"
  payload="$(jq -cn --arg receive_id "${chat_id}" --arg content "${content}" \
    '{receive_id:$receive_id,msg_type:"interactive",content:$content}')"
  body="$(mktemp)"
  if ! request POST \
    "${api_base%/}/open-apis/im/v1/messages?receive_id_type=chat_id" \
    "${payload}" "${body}" "${header}"; then
    warn "could not send the Feishu release card"
    rm -f "${body}" "${header}"
    return 1
  fi
  message_id="$(jq -r '.data.message_id // empty' "${body}")"
  rm -f "${body}" "${header}"
  if [ -z "${message_id}" ]; then
    warn "Feishu sent the card but returned no message_id"
    return 1
  fi
  printf '%s' "${message_id}"
}

update_card() {
  local message_id="$1" content="$2" token header payload body
  token="$(tenant_token)" || return 1
  header="$(auth_header_file "${token}")"
  payload="$(jq -cn --arg content "${content}" '{content:$content}')"
  body="$(mktemp)"
  if ! request PATCH \
    "${api_base%/}/open-apis/im/v1/messages/${message_id}" \
    "${payload}" "${body}" "${header}"; then
    warn "could not update Feishu release card ${message_id}"
    rm -f "${body}" "${header}"
    return 1
  fi
  rm -f "${body}" "${header}"
}

case "${1:-}" in
  start)
    if [ "$#" -ne 7 ]; then
      warn "lark_notify.sh start expects component version ref sha reason run-url"
      exit 0
    fi
    ready || exit 0
    content="$(card_json "$2" running "$3" "$4" "$5" "$6" "$7")" || exit 0
    send_card "${content}" || true
    ;;
  finish)
    if [ "$#" -ne 9 ]; then
      warn "lark_notify.sh finish expects message-id component result version ref sha reason run-url"
      exit 0
    fi
    ready || exit 0
    content="$(card_json "$3" "$4" "$5" "$6" "$7" "$8" "$9")" || exit 0
    if [ -n "$2" ]; then
      update_card "$2" "${content}" || true
    else
      # If the start call failed before returning an id, still send one useful final card.
      send_card "${content}" >/dev/null || true
    fi
    ;;
  *)
    warn "usage: lark_notify.sh start <component> <version> <ref> <sha> <reason> <run-url> | finish <message-id> <component> <result> <version> <ref> <sha> <reason> <run-url>"
    ;;
esac
exit 0
