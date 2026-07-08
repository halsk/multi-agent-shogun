#!/usr/bin/env bash
# scripts/stall-watchdog-launcher.sh — launchd ラッパー
#
# Keychain から HC_PING_URL_STALL_WATCHDOG を注入して stall_watchdog.sh を起動する。
# ANTHROPIC_API_KEY の run-daily-launcher.sh 前例に倣った設計。
#
# 秘密の優先順位:
#   HC_PING_URL_STALL_WATCHDOG: launchd global env (launchctl setenv) → Keychain
#
# Keychain 登録キー: hc-ping-url-stall-watchdog
#
# 秘密値を echo/log/commit しないこと (set +x で trace 禁止)。

set -euo pipefail
set +x  # secret trace 禁止

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GET_SECRET="${SCRIPT_DIR}/get-secret.sh"

# HC ping URL 確保 (launchd global env → Keychain)
if [[ -z "${HC_PING_URL_STALL_WATCHDOG:-}" ]]; then
    if [[ -f "$GET_SECRET" ]]; then
        # shellcheck disable=SC1090
        source "$GET_SECRET" || true
        HC_PING_URL_STALL_WATCHDOG="$(get_secret "hc-ping-url-stall-watchdog" 2>/dev/null)" || true
    fi
    if [[ -z "${HC_PING_URL_STALL_WATCHDOG:-}" ]]; then
        echo "[stall-watchdog-launcher] WARN: HC_PING_URL_STALL_WATCHDOG not found in env or Keychain — pings disabled" >&2
    fi
    export HC_PING_URL_STALL_WATCHDOG
fi

exec bash "${SCRIPT_DIR}/stall_watchdog.sh" "$@"
