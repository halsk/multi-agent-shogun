#!/usr/bin/env bash
# scripts/cr-retrigger-launcher.sh — launchd ラッパー(cmd_908 T1)
#
# cmd_880の3件の教訓を塞ぐ(設計§10.2):
#   1. PATHに/opt/homebrew/binが無くgh/timeoutが見つからず黙って素通り
#      → command -v gh timeoutを確かめ、無ければ/failを送って終える。
#   2. ping URLがKeychainに無いとWARNのみで動き続けた
#      → URLが取れなければexit 1で終える(投稿もしない)。
#   3. テストの隔離漏れで本番HCへping誤送
#      → ping URLはこのlauncherだけがKeychainから読み、環境変数
#        HC_PING_URL_CR_RETRIGGERでPythonへ渡す。テストはこの変数を
#        必ず空にし、偽URL(http://127.0.0.1:9/)だけを使う。
#
# Keychain登録キー: hc-ping-url-cr-retrigger(§10・命名は既存の
# hc-ping-url-deadman 等に揃える)。
# 秘密値をecho/log/commitしないこと(set +xでtrace禁止)。
#
# ★本番のKeychain登録・launchctl load はT2(家老)の範囲であり、
# このスクリプト自体はファイルを置くのみで実行・登録はしていない。

set -euo pipefail
set +x  # secret trace禁止

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GET_SECRET="${SCRIPT_DIR}/get-secret.sh"

# §10.3: launchd から届いた ping だと確かめる目印。
RUN_ID="$(TZ=UTC date -u +%Y%m%dT%H%M%SZ)-$$"

_hc_ping() {
  local url="$1" suffix="${2:-}" body="${3:-}"
  [[ -z "$url" ]] && return 0
  if [[ -n "$body" ]]; then
    curl -fsS -m 10 --retry 2 --data "$body" "${url}${suffix}" >/dev/null 2>&1 || true
  else
    curl -fsS -m 10 --retry 2 "${url}${suffix}" >/dev/null 2>&1 || true
  fi
}

# HC ping URL確保。Keychainのみから読む(§10.2の3: launchd global envは
# 使わない設計——本番専用の秘密をこのlauncher以外へ渡さない)。
HC_PING_URL_CR_RETRIGGER=""
if [[ -f "$GET_SECRET" ]]; then
  # shellcheck disable=SC1090
  source "$GET_SECRET" || true
  HC_PING_URL_CR_RETRIGGER="$(get_secret "hc-ping-url-cr-retrigger" 2>/dev/null)" || true
fi

if [[ -z "$HC_PING_URL_CR_RETRIGGER" ]]; then
  echo "[cr-retrigger-launcher] ERROR: hc-ping-url-cr-retrigger not found in Keychain — 投稿もpingも行わず終える" >&2
  exit 1
fi

_hc_ping "$HC_PING_URL_CR_RETRIGGER" "/start"

if ! command -v gh >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
  echo "[cr-retrigger-launcher] ERROR: gh または timeout が見つからない(PATH=$PATH)" >&2
  _hc_ping "$HC_PING_URL_CR_RETRIGGER" "/fail"
  exit 1
fi

export CR_RETRIGGER_RUNNER="${CR_RETRIGGER_RUNNER:-launchd}"
export HC_PING_URL_CR_RETRIGGER
export CR_RETRIGGER_RUN_ID="$RUN_ID"

set +e
OUTPUT="$(timeout 300 python3 "${SCRIPT_DIR}/cr_retrigger.py" \
  --config "${SCRIPT_DIR}/../config/cr_retrigger.yaml" \
  --state "${SCRIPT_DIR}/../state/cr_retrigger.json" \
  --stop-file "${SCRIPT_DIR}/../logs/cr_retrigger.stop" 2>&1)"
STATUS=$?
set -e

echo "$OUTPUT"

if [[ -f "${SCRIPT_DIR}/../logs/cr_retrigger.stop" ]]; then
  _hc_ping "$HC_PING_URL_CR_RETRIGGER" "" "stopped runner=launchd run_id=${RUN_ID}"
  exit 0
fi

if [[ $STATUS -ne 0 ]]; then
  _hc_ping "$HC_PING_URL_CR_RETRIGGER" "/fail" "runner=launchd run_id=${RUN_ID}"
  exit "$STATUS"
fi

_hc_ping "$HC_PING_URL_CR_RETRIGGER" "" "runner=launchd run_id=${RUN_ID}"
