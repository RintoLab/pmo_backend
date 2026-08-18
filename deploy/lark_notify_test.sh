#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_base="${TMPDIR:-/tmp}"
mkdir -p "${tmp_base}"
tmp="$(mktemp -d "${tmp_base%/}/lark-notify-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
mkdir "${tmp}/bin" "${tmp}/requests" "${tmp}/notify-tmp"

cat > "${tmp}/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
method=
output=
write_format=
url=
headers=
saw_data=false
saw_silent=false
saw_connect_timeout=false
saw_max_time=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -sS)
      saw_silent=true
      shift
      ;;
    --connect-timeout)
      [ "$#" -ge 2 ] && [ "$2" = 5 ] || { echo "unexpected connect timeout" >&2; exit 90; }
      saw_connect_timeout=true
      shift 2
      ;;
    --max-time)
      [ "$#" -ge 2 ] && [ "$2" = 15 ] || { echo "unexpected max time" >&2; exit 90; }
      saw_max_time=true
      shift 2
      ;;
    -o)
      [ "$#" -ge 2 ] || exit 90
      output="$2"
      shift 2
      ;;
    -w)
      [ "$#" -ge 2 ] && [ "$2" = '%{http_code}' ] || { echo "unexpected write format" >&2; exit 90; }
      write_format="$2"
      shift 2
      ;;
    -X)
      [ "$#" -ge 2 ] || exit 90
      method="$2"
      shift 2
      ;;
    -H)
      [ "$#" -ge 2 ] || exit 90
      header="$2"
      case "${header}" in
        @*)
          header_file="${header#@}"
          [ -f "${header_file}" ] || { echo "missing header file" >&2; exit 90; }
          headers="${headers}$(cat "${header_file}")"$'\n'
          ;;
        *) headers="${headers}${header}"$'\n' ;;
      esac
      shift 2
      ;;
    --data-binary)
      [ "$#" -ge 2 ] && [ "$2" = @- ] || { echo "unexpected data source" >&2; exit 90; }
      saw_data=true
      shift 2
      ;;
    -*)
      echo "unexpected curl option: $1" >&2
      exit 90
      ;;
    *)
      [ -z "${url}" ] || { echo "multiple curl URLs" >&2; exit 90; }
      url="$1"
      shift
      ;;
  esac
done
[ "${saw_silent}" = true ]
[ "${saw_connect_timeout}" = true ]
[ "${saw_max_time}" = true ]
[ "${saw_data}" = true ]
[ -n "${method}" ] && [ -n "${output}" ] && [ -n "${write_format}" ]
case "${url}" in https://*) ;; *) echo "non-HTTPS mock request: ${url}" >&2; exit 90 ;; esac

payload="$(cat)"
count_file="${MOCK_REQUEST_DIR}/count"
count=0
[ ! -f "${count_file}" ] || count="$(cat "${count_file}")"
count=$((count + 1))
printf '%s' "${count}" > "${count_file}"
printf '%s' "${method}" > "${MOCK_REQUEST_DIR}/${count}.method"
printf '%s' "${url}" > "${MOCK_REQUEST_DIR}/${count}.url"
printf '%s' "${payload}" > "${MOCK_REQUEST_DIR}/${count}.payload"
printf '%s' "${headers}" > "${MOCK_REQUEST_DIR}/${count}.headers"
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
export TMPDIR="${tmp}/notify-tmp"

missing_output="$(env -u LARK_APP_ID -u LARK_APP_SECRET -u LARK_CHAT_ID \
  "${root}/deploy/lark_notify.sh" start CLI 1.2.3 refs/heads/main abcdef1234567890 \
  planning https://gitea.invalid/run/missing 2>/dev/null)"
[ -z "${missing_output}" ]
[ ! -f "${tmp}/requests/count" ]

export LARK_APP_ID=test-app
export LARK_APP_SECRET=test-secret
export LARK_CHAT_ID=oc_test_chat
export LARK_KEYWORD='Rinto 发布'

insecure_output="$(LARK_API_BASE=http://feishu.invalid \
  "${root}/deploy/lark_notify.sh" start CLI 1.2.3 refs/heads/main abcdef1234567890 \
  planning https://gitea.invalid/run/insecure 2>/dev/null)"
[ -z "${insecure_output}" ]
[ ! -f "${tmp}/requests/count" ]

export LARK_API_BASE=https://feishu.invalid
message_id="$("${root}/deploy/lark_notify.sh" start CLI 1.2.3 refs/heads/main abcdef1234567890 \
  'release planning in progress' https://gitea.invalid/run/42)"
[ "${message_id}" = om_test_message ]
[ -z "$(find "${TMPDIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]
[ "$(cat "${tmp}/requests/1.method")" = POST ]
[ "$(cat "${tmp}/requests/2.method")" = POST ]
grep -q '/auth/v3/tenant_access_token/internal$' "${tmp}/requests/1.url"
grep -q '/im/v1/messages?receive_id_type=chat_id$' "${tmp}/requests/2.url"
grep -Fxq 'Content-Type: application/json' "${tmp}/requests/2.headers"
grep -Fxq 'Authorization: Bearer test-token' "${tmp}/requests/2.headers"
jq -e '.app_id == "test-app" and .app_secret == "test-secret"' \
  "${tmp}/requests/1.payload" >/dev/null
jq -e '.receive_id == "oc_test_chat" and .msg_type == "interactive" and
  ((.content | fromjson).config.update_multi == true) and
  ((.content | fromjson).header.template == "blue")' \
  "${tmp}/requests/2.payload" >/dev/null

"${root}/deploy/lark_notify.sh" finish "${message_id}" CLI success 1.2.3 refs/heads/main \
  abcdef1234567890 published https://gitea.invalid/run/42
[ -z "$(find "${TMPDIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]
[ "$(cat "${tmp}/requests/3.method")" = POST ]
[ "$(cat "${tmp}/requests/4.method")" = PATCH ]
grep -q '/im/v1/messages/om_test_message$' "${tmp}/requests/4.url"
grep -Fxq 'Authorization: Bearer test-token' "${tmp}/requests/4.headers"
jq -e 'has("msg_type") | not' "${tmp}/requests/4.payload" >/dev/null
jq -e '((.content | fromjson).config.update_multi == true) and
  ((.content | fromjson).header.template == "green")' \
  "${tmp}/requests/4.payload" >/dev/null

"${root}/deploy/lark_notify.sh" finish '' Server failure 1.2.3 refs/heads/main \
  abcdef1234567890 failed https://gitea.invalid/run/43
[ "$(cat "${tmp}/requests/5.method")" = POST ]
[ "$(cat "${tmp}/requests/6.method")" = POST ]
grep -q '/im/v1/messages?receive_id_type=chat_id$' "${tmp}/requests/6.url"
grep -Fxq 'Authorization: Bearer test-token' "${tmp}/requests/6.headers"
jq -e '(.content | fromjson).header.template == "red"' \
  "${tmp}/requests/6.payload" >/dev/null

"${root}/deploy/lark_notify.sh" finish '' Server skipped 1.2.3 refs/heads/main \
  abcdef1234567890 'already published' https://gitea.invalid/run/44
jq -e '(.content | fromjson).header.template == "grey"' \
  "${tmp}/requests/8.payload" >/dev/null
[ -z "$(find "${TMPDIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]

echo "Feishu lifecycle notification tests passed"
