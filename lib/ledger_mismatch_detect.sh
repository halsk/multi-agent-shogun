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
    # GNU stat の -c を先に試す。逆順(-f を先)にすると、GNU stat上で
    # -f は「フォーマット指定」ではなく「ファイルシステム情報表示」を
    # 意味するため、失敗時にstderr抑制下でもstdoutへ無関係な情報が
    # 漏れ、mtime変数が汚染されて算術式が壊れる(CI macOS実測・
    # GNU coreutilsがPATH先頭に来る環境で顕在化)。BSD stat は -c 失敗時
    # stdoutを一切汚さないため、-c→-fの順にすれば両対応で安全。
    stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null
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

# ── cmd_766 第一層 相乗り: blocked/blocked_needs_decision なのに blocked_on/
# blocked_reason が空の「status が実態を語っていない」ケースを検知する
# (2026-09-06 同日中に ashigaru4→ashigaru5 で2度実測された欠陥への対応)
#
# 通常の依存待ち(blocked_by あり)は対象外——それは「実態不明」ではなく
# 正常な依存待ちのため誤検知としない。
#
# 提供関数:
#   detect_blocked_reason_gaps <tasks_dir>
#     → queue/tasks/ashigaru*.yaml, gunshi*.yaml を走査し、各行
#       "file_name|status" で gap を列挙

# task: 直下(2スペースインデント)のフィールドを1行抽出する
_lmd_task_field() {
    local file="$1" field="$2"
    grep -E "^  ${field}:" "$file" 2>/dev/null | head -1 \
        | sed -E "s/^  ${field}:[[:space:]]*//" \
        | tr -d '"' | tr -d "'" \
        | sed -E 's/[[:space:]]+$//'
}

detect_blocked_reason_gaps() {
    local tasks_dir="$1"
    [[ -d "$tasks_dir" ]] || return 0

    local f status blocked_by blocked_on blocked_reason
    for f in "$tasks_dir"/ashigaru*.yaml "$tasks_dir"/gunshi*.yaml; do
        [[ -f "$f" ]] || continue

        status=$(_lmd_task_field "$f" "status")
        [[ "$status" == "blocked" || "$status" == "blocked_needs_decision" ]] || continue

        blocked_by=$(_lmd_task_field "$f" "blocked_by")
        [[ -n "$blocked_by" ]] && continue

        blocked_on=$(_lmd_task_field "$f" "blocked_on")
        blocked_reason=$(_lmd_task_field "$f" "blocked_reason")

        if [[ -z "$blocked_on" || -z "$blocked_reason" ]]; then
            printf '%s|%s\n' "${f##*/}" "$status"
        fi
    done
}

# ── cmd_771 fix_c 相乗り: 孤児cmd検知(idle足軽+台帳の未完了cmdが誰にも
# 割り当てられていない状態)。maybe_nudge_idle は agent 自身の assigned
# タスク前提で動くため、台帳に残った未完了cmdが誰の task YAML の
# parent_cmd にも現れない場合に検知漏れとなる(2026-09-06 殿が2度、
# swarmより先に気づいた主犯)。
#
# 提供関数:
#   detect_orphan_cmds <ledger_file> <tasks_dir> [all_ashigaru_idle]
#     → 各行 "cmd_id|status" で孤児cmdを列挙
#
#   孤児判定:
#     ledger status が pending/in_progress かつ
#     (a) どの task YAML の parent_cmd にも現れない(未割当) または
#     (b) 現れているが all_ashigaru_idle=true (全員idleで誰も手を
#         付けていない=割当があっても実質孤児)

# ledger_file の全 "- id: X" エントリを "id|status" で1行ずつ列挙する
_lmd_all_ledger_cmd_statuses() {
    local ledger_file="$1"
    [[ -f "$ledger_file" ]] || return 0

    awk '
        /^- id: / {
            if (id != "") print id "|" status
            id = $0
            sub(/^- id: /, "", id)
            status = ""
            next
        }
        /^  status:/ {
            val = $0
            sub(/^  status:[[:space:]]*/, "", val)
            gsub(/["'"'"']/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            status = val
        }
        END { if (id != "") print id "|" status }
    ' "$ledger_file"
}

# tasks_dir 内の全 task YAML の parent_cmd を集合として返す(1行1id)
_lmd_assigned_parent_cmds() {
    local tasks_dir="$1"
    local f
    for f in "$tasks_dir"/ashigaru*.yaml "$tasks_dir"/gunshi*.yaml; do
        [[ -f "$f" ]] || continue
        local pc
        pc=$(_lmd_task_field "$f" "parent_cmd")
        [[ -n "$pc" ]] && printf '%s\n' "$pc"
    done
}

detect_orphan_cmds() {
    local ledger_file="$1"
    local tasks_dir="$2"
    local all_ashigaru_idle="${3:-false}"

    [[ -f "$ledger_file" ]] || return 0

    local assigned_cmds
    assigned_cmds=$(_lmd_assigned_parent_cmds "$tasks_dir")

    local cmd_id status
    while IFS='|' read -r cmd_id status; do
        [[ -z "$cmd_id" ]] && continue
        [[ "$status" == "pending" || "$status" == "in_progress" ]] || continue

        if printf '%s\n' "$assigned_cmds" | grep -qxF "$cmd_id"; then
            # 割当あり → 全員idleの時のみ孤児扱い(実質誰も手を付けていない)
            [[ "$all_ashigaru_idle" == "true" ]] || continue
        fi

        printf '%s|%s\n' "$cmd_id" "$status"
    done < <(_lmd_all_ledger_cmd_statuses "$ledger_file")
}
