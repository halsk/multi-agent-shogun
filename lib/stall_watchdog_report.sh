#!/usr/bin/env bash
# lib/stall_watchdog_report.sh — cmd_771 ④ 24時間計数報告の純関数ライブラリ
#
# stall_watchdog.log を24時間窓でタグ別に集計し、「0件かつ稼働N>0の場合のみ
# 送信」を機械的に判定する。実際の停止検知は各checkが既にリアルタイムで
# dashboard+ntfy済みのため、本報告は「本当に何も起きなかった」ことの
# 正直な確認のみを担う(二重通知回避・稼働0件の"0件"は無意味という軍師指摘)。
#
# 提供関数:
#   count_tag_in_window <log_file> <tag> <cutoff_iso>
#     → cutoff_iso 以降 (ISO8601文字列は語彙順=時系列順のため文字列比較で
#       窓判定できる) の行数を tag 一致で数える
#
#   should_send_24h_report <total_stops> <activity>
#     → "true"/"false" (0件かつ稼働>0の時のみ true)
#
#   report_due <last_report_epoch> <now_epoch> <window_seconds>
#     → "true"/"false" (前回報告からwindow_seconds経過していれば true。
#        last_report_epoch=0 は「未報告」として true 扱い)

count_tag_in_window() {
    local log_file="$1"
    local tag="$2"
    local cutoff="$3"
    [[ -f "$log_file" ]] || { echo 0; return; }
    awk -v tag="$tag" -v cutoff="$cutoff" '
        {
            ts = substr($0, 2, 19)
            if (ts >= cutoff && index($0, tag) > 0) count++
        }
        END { print count+0 }
    ' "$log_file"
}

should_send_24h_report() {
    local total_stops="$1"
    local activity="$2"
    if [[ "$total_stops" -eq 0 && "$activity" -gt 0 ]]; then
        echo "true"
    else
        echo "false"
    fi
}

report_due() {
    local last_report_epoch="$1"
    local now_epoch_val="$2"
    local window_seconds="$3"
    if [[ "$last_report_epoch" -eq 0 ]]; then
        echo "true"
        return
    fi
    if [[ $(( now_epoch_val - last_report_epoch )) -ge "$window_seconds" ]]; then
        echo "true"
    else
        echo "false"
    fi
}
