#!/usr/bin/env bash
# scripts/console-stall-watchdog-launcher.sh — launchd ラッパー
#
# stall-watchdog-launcher.sh の前例に倣った薄いラッパー。
# console_stall_watchdog.sh は現状 Keychain 秘密を必要としないが、
# 将来 HC ping 等を追加する際の差し込み点として launcher 構成を揃えておく。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec bash "${SCRIPT_DIR}/console_stall_watchdog.sh" "$@"
