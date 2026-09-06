#!/usr/bin/env bash
# lib/ledger_mismatch_detect.sh — report done なのに台帳 cmd が pending/in_progress
# のまま残っている「done未遷移」を機械的に検知する純関数ライブラリ
#
# cmd_766 第一層(発生源検知)。本日 cmd_763/764 が実際にこの型だった
# (完了報告済みで台帳が pending のまま残っていた・将軍指摘で是正)。
#
# 提供関数:
#   ledger_cmd_status <ledger_file> <cmd_id>
#     → shogun_to_karo.yaml 内の該当 cmd の status を1行で返す(無ければ空)
#
#   detect_ledger_mismatches <reports_dir> <ledger_file> <threshold_seconds>
#     → 各行 "cmd_id|report_file|ledger_status|age_seconds" で mismatch を列挙
#
# tmux/flock 非依存。単体テスト可能(source して直接呼べる)。

ledger_cmd_status() {
    local ledger_file="$1"
    local cmd_id="$2"
    [[ -f "$ledger_file" ]] || return 0

    awk -v id="$cmd_id" '
        $0 ~ ("^- id: " id "$") { found = 1; next }
        /^- id: / { found = 0 }
        found && /^  status:/ {
            val = $0
            sub(/^  status:[[:space:]]*/, "", val)
            gsub(/["'"'"']/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            print val
            exit
        }
    ' "$ledger_file"
}

# report yaml の先頭階層にある "parent_cmd:" / "status:" を1行抽出する
_lmd_report_field() {
    local file="$1" field="$2"
    grep -E "^${field}:" "$file" 2>/dev/null | head -1 \
        | sed -E "s/^${field}:[[:space:]]*//" \
        | tr -d '"' | tr -d "'"
}

_lmd_file_mtime_epoch() {
    local file="$1"
    stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null
}

detect_ledger_mismatches() {
    local reports_dir="$1"
    local ledger_file="$2"
    local threshold_sec="${3:-21600}"  # デフォルト6時間(gunshi設計の目安)

    [[ -d "$reports_dir" ]] || return 0

    local now
    now=$(date '+%s')

    local f parent_cmd report_status mtime age ledger_status
    for f in "$reports_dir"/*.yaml; do
        [[ -f "$f" ]] || continue

        parent_cmd=$(_lmd_report_field "$f" "parent_cmd")
        report_status=$(_lmd_report_field "$f" "status")

        [[ -z "$parent_cmd" ]] && continue
        [[ "$report_status" != "done" ]] && continue

        mtime=$(_lmd_file_mtime_epoch "$f")
        [[ -z "$mtime" ]] && continue
        age=$(( now - mtime ))
        [[ "$age" -lt "$threshold_sec" ]] && continue

        ledger_status=$(ledger_cmd_status "$ledger_file" "$parent_cmd")
        [[ -z "$ledger_status" ]] && continue
        [[ "$ledger_status" == "done" || "$ledger_status" == "cancelled" ]] && continue

        printf '%s|%s|%s|%s\n' "$parent_cmd" "$f" "$ledger_status" "$age"
    done
}
