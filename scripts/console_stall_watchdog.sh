#!/usr/bin/env bash
# scripts/console_stall_watchdog.sh — Console Stall Watchdog (cmd_725第三段)
#
# geonicdb-console という「仕事」が止まっていないかを検知する。
# ★既存 scripts/stall_watchdog.sh (エージェントの無音固着検知) とは別物・独立ジョブ。
#   既存ジョブのファイル・挙動は一切変更しない。
#
# 判定基準: commit / PR更新 / console関連subtaskの状態変化のいずれもが
#           stall_threshold_hours (既定4h) 動いていなければ「停滞」とみなす。
#
# 夜間(night_start_hour〜night_end_hour)に到達した停滞は通知を溜め、
# 昼間に入った最初の実行でまとめて一通にして送る。
#
# 通知には必ず区分(a〜e)と「殿に何をしていただきたいか(または不要な旨)」を含める。
#
# フラグ:
#   --dry-run     : 実際の inbox_write/ntfy/dashboard 追記を行わず、ログにのみ出す。
#   --sample-all  : 実状態を見ず、区分a〜eそれぞれの通知文言サンプルを出力して終了する
#                   (Iron Law 1 実行コンテキスト検証の一環・報告書添付用)。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=../lib/console_stall_detect.sh
source "$SCRIPT_DIR/lib/console_stall_detect.sh"

SETTINGS="$SCRIPT_DIR/config/settings.yaml"
STATE_DIR="$SCRIPT_DIR/queue/console_stall_watchdog"
LOG_FILE="$SCRIPT_DIR/logs/console_stall_watchdog.log"
STATE_FILE="$STATE_DIR/state.yaml"

# ── フラグ解析 ────────────────────────────────────────────────────────────────
DRY_RUN=false
SAMPLE_ALL=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --sample-all) SAMPLE_ALL=true ;;
    esac
done

mkdir -p "$STATE_DIR" logs

log() {
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# console_stall_watchdog: セクション配下の値を読む (settings.yaml はネスト2階層のシンプルYAML前提)
load_console_setting() {
    local key="$1" default="$2"
    local val
    val=$(awk -v k="$key" '
        /^console_stall_watchdog:/ { in_section=1; next }
        in_section && /^[^ ]/ { in_section=0 }
        in_section && $0 ~ "^  "k":" {
            sub("^  "k":[[:space:]]*", "");
            gsub(/#.*/, "");
            gsub(/^[[:space:]]+|[[:space:]]+$/, "");
            print;
            exit
        }
    ' "$SETTINGS")
    if [[ -z "$val" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

now_epoch() { date '+%s'; }
now_hour()  { date '+%-H' 2>/dev/null || date '+%H' | sed 's/^0//'; }
now_date()  { date '+%Y-%m-%d'; }

file_mtime_epoch() {
    local f="$1"
    stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0
}

iso_to_epoch() {
    local iso="$1"
    date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null \
        || date -d "$iso" '+%s' 2>/dev/null \
        || echo 0
}

state_get() {
    local field="$1" default="${2:-}"
    [[ -f "$STATE_FILE" ]] || { echo "$default"; return; }
    grep -E "^${field}:" "$STATE_FILE" | head -1 | sed "s/^${field}:[[:space:]]*//" | tr -d '"' \
        || echo "$default"
}

state_set() {
    local field="$1" value="$2"
    [[ -f "$STATE_FILE" ]] || printf 'created: %s\n' "$(now_date)" > "$STATE_FILE"
    if grep -qE "^${field}:" "$STATE_FILE" 2>/dev/null; then
        sed -i '' "s|^${field}:.*|${field}: ${value}|" "$STATE_FILE"
    else
        printf '%s: %s\n' "$field" "$value" >> "$STATE_FILE"
    fi
}

# ── 最終活動時刻の収集 (副作用あり・テストでは max_epoch 単体を直接検証) ──────

console_commit_epoch() {
    local repo_path
    repo_path=$(load_console_setting "repo_path" "")
    [[ -d "$repo_path/.git" ]] || { echo 0; return; }
    git -C "$repo_path" log -1 --format=%ct 2>/dev/null || echo 0
}

console_pr_epoch() {
    local repo_slug
    repo_slug=$(load_console_setting "repo_slug" "")
    [[ -n "$repo_slug" ]] || { echo 0; return; }
    command -v gh >/dev/null 2>&1 || { echo 0; return; }
    local updated_iso
    updated_iso=$(GH_TOKEN='' gh pr list -R "$repo_slug" --state open --json updatedAt \
        --jq 'map(.updatedAt) | sort | last' 2>/dev/null || echo "")
    [[ -n "$updated_iso" && "$updated_iso" != "null" ]] || { echo 0; return; }
    iso_to_epoch "$updated_iso"
}

console_subtask_epoch() {
    local max=0
    local f mt
    for f in "$SCRIPT_DIR"/queue/tasks/ashigaru*.yaml; do
        [[ -f "$f" ]] || continue
        grep -q '^\s*project:\s*geonicdb-console' "$f" 2>/dev/null || continue
        mt=$(file_mtime_epoch "$f")
        [[ "$mt" -gt "$max" ]] && max="$mt"
    done
    for f in "$SCRIPT_DIR"/queue/reports/ashigaru*_report.yaml; do
        [[ -f "$f" ]] || continue
        grep -qiE 'geonicdb-console' "$f" 2>/dev/null || continue
        mt=$(file_mtime_epoch "$f")
        [[ "$mt" -gt "$max" ]] && max="$mt"
    done
    echo "$max"
}

# 現在の🚨要対応セクション本文 (ストライクスルー済み=解決済みの行は除外)
dashboard_urgent_text() {
    local dashboard="$SCRIPT_DIR/dashboard.md"
    [[ -f "$dashboard" ]] || { echo ""; return; }
    awk '
        /^## 🚨 要対応/ { in_section=1; next }
        in_section && /^## / { in_section=0 }
        in_section { print }
    ' "$dashboard" | grep -v '~~' || true
}

# console関連subtask/reportの直近本文 (b/d判定用)
console_reports_text() {
    local f
    for f in "$SCRIPT_DIR"/queue/tasks/ashigaru*.yaml; do
        [[ -f "$f" ]] || continue
        grep -q '^\s*project:\s*geonicdb-console' "$f" 2>/dev/null && cat "$f"
    done
    for f in "$SCRIPT_DIR"/queue/reports/ashigaru*_report.yaml; do
        [[ -f "$f" ]] || continue
        grep -qiE 'geonicdb-console' "$f" 2>/dev/null && cat "$f"
    done
    true
}

console_task_status_and_reason() {
    local f status reason
    for f in "$SCRIPT_DIR"/queue/tasks/ashigaru*.yaml; do
        [[ -f "$f" ]] || continue
        grep -q '^\s*project:\s*geonicdb-console' "$f" 2>/dev/null || continue
        status=$(grep -E '^\s*status:\s*' "$f" | head -1 | sed 's/.*status:[[:space:]]*//' | tr -d '"' | tr -d ' ')
        if [[ "$status" == "blocked" ]]; then
            reason=$(grep -E '^\s*(blocked_reason|risk_reason):\s*' "$f" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"')
            echo "blocked|$reason"
            return
        fi
    done
    echo "none|"
}

# ── 通知送信 ──────────────────────────────────────────────────────────────────

notify_dashboard() {
    local body="$1"
    local ts entry dashboard
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    entry="- 🚨 [console_stall_watchdog] geonicdb-consoleが停滞 @ $ts\n  $(echo "$body" | tr '\n' ' ')"
    if $DRY_RUN; then
        log "[DRY-RUN] dashboard 🚨追記: $entry"
        return
    fi
    dashboard="$SCRIPT_DIR/dashboard.md"
    if [[ -f "$dashboard" ]] && grep -q '## 🚨 要対応' "$dashboard"; then
        sed -i '' "/## 🚨 要対応/a\\
$entry
" "$dashboard"
    else
        printf '\n%b\n' "$entry" >> "$dashboard"
    fi
}

send_ntfy() {
    local body="$1"
    if $DRY_RUN; then
        log "[DRY-RUN] ntfy.sh push: $(echo "$body" | tr '\n' ' ')"
        return
    fi
    bash "$SCRIPT_DIR/scripts/ntfy.sh" "console_stall_watchdog: $body"
}

# ── --sample-all: 状態を見ず5区分のサンプル文言のみ出す ──────────────────────
if $SAMPLE_ALL; then
    echo "=== console_stall_watchdog --sample-all: 区分a〜eサンプル ==="
    echo ""
    echo "--- 区分a ---"
    notification_body "a" "PR#999のmerge裁可(CSP設定変更を含む)"
    echo ""
    echo "--- 区分b ---"
    notification_body "b" "1Password Touch ID認証でテナントアドミン資格情報を取得する操作"
    echo ""
    echo "--- 区分c ---"
    notification_body "c" "SpaHashedAssets LambdaのOOM原因は特定済みだがメモリ増強の妥当値が未確定。選択肢=512MiB/1024MiB"
    echo ""
    echo "--- 区分d ---"
    notification_body "d" "backend側のAPIキー管理エンドポイント実装が要る(#105)"
    echo ""
    echo "--- 区分e ---"
    notification_body "e" "順序表(context/geonicdb-console-issue-order.md)の次位Issueが単に未着手のまま(担当者の手が空かなかった)"
    exit 0
fi

# ── source ガード (テストは関数のみ利用) ─────────────────────────────────────
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

# ── flock 単一起動 ────────────────────────────────────────────────────────────
LOCK_FILE="/tmp/console_stall_watchdog.lock"
exec 8>"$LOCK_FILE"
if ! flock -n 8; then
    echo "[console_stall_watchdog] already running (lock held). exiting." >&2
    exit 0
fi

# ── cmd_767 第一層(心拍): 本ジョブ自身の実行(生死)を last-run.json に記録する。
# ★これは console_stall_watchdog.sh が「監視している対象(console)の停滞」とは
# 別物——本ジョブ自体が launchd から30分毎に起動され続けているか、という
# メタな心拍である。meeting-link-sweepと同じ共通規約(lib/run_log.sh)に相乗り。
# shellcheck source=../lib/run_log.sh
source "$SCRIPT_DIR/lib/run_log.sh"

RUN_LOG_DIR="$SCRIPT_DIR/logs/console-stall-watchdog"
RUN_STATUS_FILE="$SCRIPT_DIR/logs/console-stall-watchdog-last-run.json"
RUN_ID="$(run_log_new_id)"
RUN_START_EPOCH="$(date '+%s')"
RUN_START_ISO="$(date '+%Y-%m-%dT%H:%M:%S%z')"
RUN_LOG_FILE="$(run_log_start "${RUN_LOG_DIR}" "${RUN_ID}" "console-stall-watchdog")"

_cswd_on_exit() {
  local exit_code=$?
  local duration end_iso
  duration="$(run_log_end "${RUN_LOG_FILE}" "${RUN_ID}" "${RUN_START_EPOCH}" "${exit_code}")"
  end_iso="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  run_log_write_last_run "${RUN_STATUS_FILE}" "${RUN_ID}" "${RUN_START_ISO}" "${end_iso}" "${duration}" "${exit_code}"
  run_log_rotate "${RUN_LOG_DIR}" 96
}
trap _cswd_on_exit EXIT

# ── メイン ────────────────────────────────────────────────────────────────────

log "[START] console_stall_watchdog dry_run=$DRY_RUN"

THRESHOLD_H=$(load_console_setting "stall_threshold_hours" "4")
NIGHT_START=$(load_console_setting "night_start_hour" "22")
NIGHT_END=$(load_console_setting "night_end_hour" "8")
THROTTLE_H=$(load_console_setting "throttle_hours" "6")

commit_epoch=$(console_commit_epoch)
pr_epoch=$(console_pr_epoch)
subtask_epoch=$(console_subtask_epoch)
last_activity=$(max_epoch "$commit_epoch" "$pr_epoch" "$subtask_epoch")

now=$(now_epoch)
elapsed=$(( now - last_activity ))
threshold_sec=$(( THRESHOLD_H * 3600 ))

log "[CHECK] commit=$commit_epoch pr=$pr_epoch subtask=$subtask_epoch last_activity=$last_activity elapsed=${elapsed}s threshold=${threshold_sec}s"

if [[ "$last_activity" -eq 0 || "$elapsed" -lt "$threshold_sec" ]]; then
    log "[OK] consoleは${THRESHOLD_H}h以内に活動あり。停滞なし。"
    state_set "pending" "false"
    log "[DONE] console_stall_watchdog scan complete"
    exit 0
fi

# ── 停滞検知 → 区分判定 ──────────────────────────────────────────────────────
dash_text=$(dashboard_urgent_text)
reports_text=$(console_reports_text)
status_and_reason=$(console_task_status_and_reason)
task_status="${status_and_reason%%|*}"
task_reason="${status_and_reason#*|}"

category=$(classify_stall_reason "$dash_text" "$reports_text" "$task_status" "$task_reason")
detail="elapsed=${elapsed}s (閾値${THRESHOLD_H}h超) / task_status=${task_status}"
[[ -n "$task_reason" ]] && detail="$detail / reason=${task_reason}"

body=$(notification_body "$category" "$detail")
log "[STALL] category=$category detail=$detail"

hour=$(now_hour)
today=$(now_date)

if in_night_window "$hour" "$NIGHT_START" "$NIGHT_END"; then
    # 夜間 → 溜める。送らない。
    state_set "pending" "true"
    state_set "pending_category" "$category"
    state_set "pending_body" "$(echo "$body" | tr '\n' ' ' | tr ' ' '_')"
    pending_since=$(state_get "pending_since" "")
    [[ -z "$pending_since" ]] && state_set "pending_since" "$(date '+%Y-%m-%dT%H:%M:%S')"
    log "[NIGHT-DEFER] 夜間帯(${hour}時)ゆえ通知を翌${NIGHT_END}時へ集約。category=$category"
    log "[DONE] console_stall_watchdog scan complete"
    exit 0
fi

pending=$(state_get "pending" "false")
last_flush_date=$(state_get "last_flush_date" "")

if [[ "$pending" == "true" && "$last_flush_date" != "$today" ]]; then
    log "[FLUSH] 夜間に溜まった停滞通知を一通にまとめて送信 (${NIGHT_END}時以降の最初の実行)"
    notify_dashboard "$body"
    send_ntfy "$body"
    state_set "pending" "false"
    state_set "last_flush_date" "$today"
    state_set "last_notified_ts" "$now"
    state_set "last_notified_category" "$category"
    log "[DONE] console_stall_watchdog scan complete"
    exit 0
fi

# 昼間・通常フロー → throttle確認
last_notified_ts=$(state_get "last_notified_ts" "0")
throttle_sec=$(( THROTTLE_H * 3600 ))
since_last=$(( now - last_notified_ts ))

if [[ "$last_notified_ts" != "0" && "$since_last" -lt "$throttle_sec" ]]; then
    log "[THROTTLE] 前回通知から${since_last}s(<${throttle_sec}s)ゆえ抑制。category=$category"
    log "[DONE] console_stall_watchdog scan complete"
    exit 0
fi

log "[NOTIFY] category=$category → dashboard + ntfy"
notify_dashboard "$body"
send_ntfy "$body"
state_set "last_notified_ts" "$now"
state_set "last_notified_category" "$category"

log "[DONE] console_stall_watchdog scan complete"
