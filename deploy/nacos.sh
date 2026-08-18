#!/usr/bin/env bash
set -euo pipefail

: "${NACOS_URL:?NACOS_URL is required}"
: "${NACOS_USER:?NACOS_USER is required}"
: "${NACOS_PASS:?NACOS_PASS is required}"
: "${NACOS_NAMESPACE:?NACOS_NAMESPACE is required}"
NACOS_GROUP="${NACOS_GROUP:-PMO_BE}"
base="${NACOS_URL%/}"

case "${base}" in
  http://* | https://*) ;;
  *) echo "NACOS_URL has to start with http:// or https://" >&2; exit 64 ;;
esac
case "${base}" in
  */nacos) echo "NACOS_URL must not include the /nacos suffix" >&2; exit 64 ;;
esac

authenticate() {
  local body code
  body="$(mktemp)"
  code="$(curl -sS -o "${body}" -w '%{http_code}' -X POST "${base}/nacos/v1/auth/login" \
    --data-urlencode "username=${NACOS_USER}" \
    --data-urlencode "password=${NACOS_PASS}")" || code=000
  case "${code}" in
    200)
      token="$(sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p' "${body}")"
      rm -f "${body}"
      [ -n "${token}" ] || { echo "r-nacos accepted login but returned no accessToken" >&2; exit 1; }
      ;;
    404)
      token=""
      rm -f "${body}"
      ;;
    000)
      rm -f "${body}"
      echo "could not reach r-nacos at ${base}" >&2
      exit 1
      ;;
    *)
      rm -f "${body}"
      echo "r-nacos refused login (HTTP ${code}); check NACOSUSER and NACOSPASS" >&2
      exit 1
      ;;
  esac
}

nacos_args() {
  NACOS_ARGS=(--data-urlencode "dataId=$1" \
    --data-urlencode "group=${NACOS_GROUP}" \
    --data-urlencode "tenant=${NACOS_NAMESPACE}")
  [ -z "${token}" ] || NACOS_ARGS+=(--data-urlencode "accessToken=${token}")
}

get_config() {
  local data_id="$1" body code
  body="$(mktemp)"
  nacos_args "${data_id}"
  code="$(curl -sS -o "${body}" -w '%{http_code}' --get \
    "${base}/nacos/v1/cs/configs" "${NACOS_ARGS[@]}")" || code=000
  case "${code}" in
    200) cat "${body}"; rm -f "${body}" ;;
    404) rm -f "${body}"; exit 4 ;;
    000) rm -f "${body}"; echo "could not reach r-nacos while reading ${data_id}" >&2; exit 1 ;;
    *) rm -f "${body}"; echo "r-nacos returned HTTP ${code} while reading ${data_id}" >&2; exit 1 ;;
  esac
}

put_config() {
  local data_id="$1" content="$2" body code attempt
  nacos_args "${data_id}"
  for attempt in 1 2 3; do
    body="$(mktemp)"
    code="$(curl -sS -o "${body}" -w '%{http_code}' -X POST \
      "${base}/nacos/v1/cs/configs" "${NACOS_ARGS[@]}" \
      --data-urlencode "type=text" --data-urlencode "content=${content}")" || code=000
    if [ "${code}" = 200 ] && grep -qx 'true' "${body}"; then
      rm -f "${body}"
      return 0
    fi
    rm -f "${body}"
    [ "${attempt}" -eq 3 ] || sleep "${attempt}"
  done
  echo "r-nacos did not accept ${data_id} after 3 attempts (last HTTP ${code})" >&2
  exit 1
}

[ "$#" -ge 2 ] || { echo "usage: nacos.sh get <data-id> | put <data-id> <content>" >&2; exit 64; }
authenticate
case "$1" in
  get) [ "$#" -eq 2 ] || exit 64; get_config "$2" ;;
  put) [ "$#" -eq 3 ] || exit 64; put_config "$2" "$3" ;;
  *) echo "unknown nacos command: $1" >&2; exit 64 ;;
esac
