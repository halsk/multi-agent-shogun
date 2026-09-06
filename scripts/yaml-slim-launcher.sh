#!/usr/bin/env bash
# scripts/yaml-slim-launcher.sh — launchd ラッパー
#
# Keychain から HC_PING_URL_YAMLSLIM を注入して yaml_slim_weekly.sh を起動する。
# stall-watchdog-launcher.sh / console-stall-watchdog-launcher.sh 前例に倣った設計。
#
# 秘密の優先順位:
#   HC_PING_URL_YAMLSLIM: launchd global env (launchctl setenv) → Keychain
#
# Keychain 登録キー: hc-ping-url-yaml-slim
#
# 秘密値を echo/log/commit しないこと (set +x で trace 禁止)。

set -euo pipefail
set +x  # secret trace 禁止

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GET_SECRET="${SCRIPT_DIR}/get-secret.sh"

# タイムアウトバイナリ解決 (実測: Keychain miss 時 get-secret.sh の 1Password op
# フォールバックが非対話セッションで無期限に hang しうる。launchd は非対話ゆえ
# 本ジョブ自体が停止する事故になる — timeout でガードし、詰まっても回収本体は進める)
_YS_TIMEOUT_BIN=""
if command -v timeout &>/dev/null; then
    _YS_TIMEOUT_BIN="timeout"
elif command -v gtimeout &>/dev/null; then
    _YS_TIMEOUT_BIN="gtimeout"
fi

# HC ping URL 確保 (launchd global env → Keychain、5秒タイムアウト付き)
if [[ -z "${HC_PING_URL_YAMLSLIM:-}" ]]; then
    if [[ -f "$GET_SECRET" && -n "$_YS_TIMEOUT_BIN" ]]; then
        HC_PING_URL_YAMLSLIM="$("$_YS_TIMEOUT_BIN" 5 bash -c "source '$GET_SECRET'; get_secret 'hc-ping-url-yaml-slim'" 2>/dev/null)" || true
    fi
    if [[ -z "${HC_PING_URL_YAMLSLIM:-}" ]]; then
        echo "[yaml-slim-launcher] WARN: HC_PING_URL_YAMLSLIM not found in env/Keychain (or lookup timed out) — pings disabled" >&2
    fi
    export HC_PING_URL_YAMLSLIM
fi

exec bash "${SCRIPT_DIR}/yaml_slim_weekly.sh" "$@"
