#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_base="${TMPDIR:-/tmp}"
mkdir -p "${tmp_base}"
tmp="$(mktemp -d "${tmp_base%/}/lark-notify-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
mkdir "${tmp}/bin" "${tmp}/requests" "${tmp}/files"

cat > "${tmp}/bin/mktemp" <<'MOCK_TMP'
#!/usr/bin/env bash
exec /usr/bin/mktemp "${MOCK_TEMP_DIR}/file.XXXXXX"
MOCK_TMP
chmod +x "${tmp}/bin/mktemp"

cat > "${tmp}/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
method=GET
output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o|-w|-H) [ "$1" = -o ] && output="$2"; shift 2 ;;
    --data-binary) shift 2 ;;
    -sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
payload="$(cat)"
count_file="${MOCK_REQUEST_DIR}/count"
count=0
[ ! -f "${count_file}" ] || count="$(cat "${count_file}")"
count=$((count + 1))
printf '%s' "${count}" > "${count_file}"
printf '%s' "${method}" > "${MOCK_REQUEST_DIR}/${count}.method"
printf '%s' "${url}" > "${MOCK_REQUEST_DIR}/${count}.url"
printf '%s' "${payload}" > "${MOCK_REQUEST_DIR}/${count}.payload"
case "${url}" in
  */tenant_access_token/internal)
    printf '%s' '{"code":0,"tenant_access_token":"test-token"}' > "${output}"
    ;;
  *'/messages?receive_id_type=chat_id')
    printf '%s' '{"code":0,"data":{"message_id":"om_test_message"}}' > "${output}"
    ;;
  */messages/om_test_message)
    printf '%s' '{"code":0}' > "${output}"
    ;;
  *)
    printf '%s' '{"code":1}' > "${output}"
    ;;
esac
printf '200'
MOCK
chmod +x "${tmp}/bin/curl"

export PATH="${tmp}/bin:${PATH}"
export MOCK_REQUEST_DIR="${tmp}/requests"
export MOCK_TEMP_DIR="${tmp}/files"

missing_output="$(env -u LARK_APP_ID -u LARK_APP_SECRET -u LARK_CHAT_ID \
  "${root}/deploy/lark_notify.sh" start CLI 1.2.3 refs/heads/main abcdef1234567890 \
  planning https://gitea.invalid/run/missing 2>/dev/null)"
[ -z "${missing_output}" ]
[ ! -f "${tmp}/requests/count" ]

export LARK_APP_ID=test-app
export LARK_APP_SECRET=test-secret
export LARK_CHAT_ID=oc_test_chat
export LARK_API_BASE=https://feishu.invalid
export LARK_KEYWORD='Rinto 发布'

message_id="$("${root}/deploy/lark_notify.sh" start CLI 1.2.3 refs/heads/main abcdef1234567890 \
  'release planning in progress' https://gitea.invalid/run/42)"
[ "${message_id}" = om_test_message ]
[ "$(cat "${tmp}/requests/1.method")" = POST ]
[ "$(cat "${tmp}/requests/2.method")" = POST ]
grep -q '/auth/v3/tenant_access_token/internal$' "${tmp}/requests/1.url"
grep -q '/im/v1/messages?receive_id_type=chat_id$' "${tmp}/requests/2.url"
jq -e '.app_id == "test-app" and .app_secret == "test-secret"' \
  "${tmp}/requests/1.payload" >/dev/null
jq -e '.receive_id == "oc_test_chat" and .msg_type == "interactive" and
  ((.content | fromjson).config.update_multi == true) and
  ((.content | fromjson).header.template == "blue")' \
  "${tmp}/requests/2.payload" >/dev/null

"${root}/deploy/lark_notify.sh" finish "${message_id}" CLI success 1.2.3 refs/heads/main \
  abcdef1234567890 published https://gitea.invalid/run/42
[ "$(cat "${tmp}/requests/3.method")" = POST ]
[ "$(cat "${tmp}/requests/4.method")" = PATCH ]
grep -q '/im/v1/messages/om_test_message$' "${tmp}/requests/4.url"
jq -e 'has("msg_type") | not' "${tmp}/requests/4.payload" >/dev/null
jq -e '((.content | fromjson).config.update_multi == true) and
  ((.content | fromjson).header.template == "green")' \
  "${tmp}/requests/4.payload" >/dev/null

"${root}/deploy/lark_notify.sh" finish '' Server failure 1.2.3 refs/heads/main \
  abcdef1234567890 failed https://gitea.invalid/run/43
[ "$(cat "${tmp}/requests/5.method")" = POST ]
[ "$(cat "${tmp}/requests/6.method")" = POST ]
grep -q '/im/v1/messages?receive_id_type=chat_id$' "${tmp}/requests/6.url"
jq -e '(.content | fromjson).header.template == "red"' \
  "${tmp}/requests/6.payload" >/dev/null

"${root}/deploy/lark_notify.sh" finish '' Server skipped 1.2.3 refs/heads/main \
  abcdef1234567890 'already published' https://gitea.invalid/run/44
jq -e '(.content | fromjson).header.template == "grey"' \
  "${tmp}/requests/8.payload" >/dev/null

echo "Feishu lifecycle notification tests passed"
