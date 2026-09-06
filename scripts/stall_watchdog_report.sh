#!/usr/bin/env bash
# scripts/stall_watchdog_report.sh — cmd_771 ④ 24時間計数報告
#
# stall_watchdog.sh の毎回(5分周期)から呼ばれるが、前回報告から24時間
# 経過していなければ何もしない(新規launchdジョブを作らず既存周期に相乗り)。
# 24時間窓で型別停止件数+稼働件数を集計し、0件かつ稼働N>0の場合のみ
# 将軍へ ntfy 送信する(稼働0件の"0件"は無意味という軍師指摘を反映・
# 実際の停止は各checkが既にリアルタイムでdashboard+ntfy済みのため
# 二重通知はしない)。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/stall_watchdog_report.sh
source "$SCRIPT_DIR/lib/stall_watchdog_report.sh"

LOG_FILE="$SCRIPT_DIR/logs/stall_watchdog.log"
STATE_DIR="$SCRIPT_DIR/queue/stall_watchdog"
REPORT_STATE_FILE="$STATE_DIR/_daily_report.yaml"
WINDOW_SECONDS=$((24 * 60 * 60))

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

now_epoch() {
    date '+%s'
}

now_iso() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

iso_to_epoch() {
    local iso="$1"
    date -j -f '%Y-%m-%dT%H:%M:%S' "${iso%%+*}" '+%s' 2>/dev/null \
        || date -d "$iso" '+%s' 2>/dev/null \
        || echo "0"
}

# ── テスト用 source ガード ────────────────────────────────────────────────────
# source して関数だけ使う場合はここでリターン (実行本体はスキップ)
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

last_report_ts=""
if [[ -f "$REPORT_STATE_FILE" ]]; then
    last_report_ts=$(grep -E '^last_report_ts:' "$REPORT_STATE_FILE" | head -1 \
        | sed 's/^last_report_ts:[[:space:]]*//' | tr -d '"' | tr -d "'")
fi

last_report_epoch=0
[[ -n "$last_report_ts" ]] && last_report_epoch=$(iso_to_epoch "$last_report_ts")

now=$(now_epoch)
if [[ "$(report_due "$last_report_epoch" "$now" "$WINDOW_SECONDS")" != "true" ]]; then
    exit 0
fi

cutoff_iso=$(date -v-24H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '-24 hours' '+%Y-%m-%dT%H:%M:%S')

ledger_mismatch=$(count_tag_in_window "$LOG_FILE" "[LEDGER-MISMATCH]" "$cutoff_iso")
blocked_reason_gap=$(count_tag_in_window "$LOG_FILE" "[BLOCKED-REASON-GAP]" "$cutoff_iso")
orphan_cmd=$(count_tag_in_window "$LOG_FILE" "[ORPHAN-CMD]" "$cutoff_iso")
e4_limit=$(count_tag_in_window "$LOG_FILE" "[E4-LIMIT]" "$cutoff_iso")
p1=$(count_tag_in_window "$LOG_FILE" "[P1]" "$cutoff_iso")
p2=$(count_tag_in_window "$LOG_FILE" "[P2]" "$cutoff_iso")
p3=$(count_tag_in_window "$LOG_FILE" "[P3]" "$cutoff_iso")
activity=$(count_tag_in_window "$LOG_FILE" "[STALL]" "$cutoff_iso")

total_stops=$(( ledger_mismatch + blocked_reason_gap + orphan_cmd + e4_limit + p1 + p2 + p3 ))

echo "[$(now_iso)] [REPORT-24H] ledger_mismatch=$ledger_mismatch blocked_reason_gap=$blocked_reason_gap orphan_cmd=$orphan_cmd e4_limit=$e4_limit p1=$p1 p2=$p2 p3=$p3 activity=$activity total_stops=$total_stops" | tee -a "$LOG_FILE"

if [[ "$(should_send_24h_report "$total_stops" "$activity")" == "true" ]]; then
    bash "$SCRIPT_DIR/scripts/ntfy.sh" "stall_watchdog 24h観測: 停止0件(稼働${activity}件)。異常なし。"
elif [[ "$total_stops" -eq 0 ]]; then
    echo "[$(now_iso)] [REPORT-24H-SKIP] 稼働0件のため0件報告はスキップ(稼働0件の0件は無意味)" | tee -a "$LOG_FILE"
else
    echo "[$(now_iso)] [REPORT-24H-SKIP] 停止${total_stops}件検知済(既にリアルタイム通知済のため集計報告は送らない)" | tee -a "$LOG_FILE"
fi

printf 'last_report_ts: %s\n' "$(now_iso)" > "$REPORT_STATE_FILE"
