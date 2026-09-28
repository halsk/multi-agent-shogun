#!/usr/bin/env bash
# scripts/start_task.sh — 足軽taskの「始める」操作を一つにまとめる(cmd_914 T1)
#
# 軍師設計(queue/reports/cmd914_status_update_gap.md §3.1「始める操作」)を
# 実装する。自分のtask YAMLのtask_idを確認し、statusがassignedの時だけ
# in_progressへ書き換える(flock・mtime確認・一時ファイル+rename)。
#
# 真因(同設計書§1): Claude Codeの足軽が正典とするinbox skillには
# statusをin_progressにする段が無く、instructions/ashigaru.md側にはあるが
# /clear後は読まれない。ゆえに今日7人全員でin_progress書き換えが0回だった。
#
# テスト用差し替え口(START_TASK_*)は本番動作を変えない(未設定時は実パス)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/task_yaml_lock.sh
source "$SCRIPT_DIR/scripts/lib/task_yaml_lock.sh"

AGENT_ID="${START_TASK_AGENT_ID:-}"
if [ -z "$AGENT_ID" ]; then
  AGENT_ID="$(tmux display-message -t "${TMUX_PANE:-}" -p '#{@agent_id}' 2>/dev/null)"
fi
if [ -z "$AGENT_ID" ]; then
  echo "[start_task] ERROR: agent_id が取得できない(tmux display-message失敗)" >&2
  exit 1
fi

TASKS_DIR="${START_TASK_TASKS_DIR:-$SCRIPT_DIR/queue/tasks}"
TASK_FILE="$TASKS_DIR/${AGENT_ID}.yaml"
LOCK_WAIT_SEC="${START_TASK_LOCK_WAIT_SEC:-5}"

if [ ! -f "$TASK_FILE" ]; then
  echo "[start_task] ERROR: task YAML が見当たらぬ: $TASK_FILE" >&2
  exit 1
fi

_read_status() {
  grep -E '^[[:space:]]*status:[[:space:]]*' "$TASK_FILE" | head -1 \
    | sed 's/.*status:[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d ' '
}

_mtime() {
  stat -c %Y "$TASK_FILE" 2>/dev/null || stat -f %m "$TASK_FILE" 2>/dev/null
}

status_before="$(_read_status)"
if [ "$status_before" != "assigned" ]; then
  echo "[start_task] SKIP: agent=$AGENT_ID status=${status_before:-不明}(assignedでないため書き換えず終了)"
  exit 0
fi

mtime_before="$(_mtime)"

TYL_LOCKFILE="${TASK_FILE}.lock"
if ! tyl_acquire_lock "$LOCK_WAIT_SEC"; then
  echo "[start_task] ERROR: ロック取得失敗(${LOCK_WAIT_SEC}秒待機): $TYL_LOCKFILE" >&2
  exit 1
fi

# ロック取得までに他プロセス(家老のaddendum追記等)がtask YAMLを書き換えて
# いないかをmtimeで確かめる(競合時は書き換えず終了・上書き事故を防ぐ)。
mtime_after_lock="$(_mtime)"
if [ "$mtime_before" != "$mtime_after_lock" ]; then
  echo "[start_task] ERROR: ロック取得までにtask YAMLが変更された(他プロセスと競合)。書き換えを中止した" >&2
  tyl_release_lock
  exit 1
fi

status_after_lock="$(_read_status)"
if [ "$status_after_lock" != "assigned" ]; then
  echo "[start_task] SKIP: agent=$AGENT_ID ロック取得後にstatusが変化していた(status=${status_after_lock:-不明})"
  tyl_release_lock
  exit 0
fi

tmp_file="$(mktemp "${TASK_FILE}.tmp.XXXXXX")"
if [ -z "$tmp_file" ]; then
  echo "[start_task] ERROR: mktemp に失敗した。書き換えを中止した" >&2
  tyl_release_lock
  exit 1
fi

if ! awk '
  !done && $0 ~ /^[[:space:]]*status:[[:space:]]*/ {
    match($0, /^[[:space:]]*/)
    indent = substr($0, RSTART, RLENGTH)
    print indent "status: in_progress"
    done = 1
    next
  }
  { print }
' "$TASK_FILE" > "$tmp_file"; then
  echo "[start_task] ERROR: status書換の生成に失敗した。書き換えを中止した" >&2
  rm -f "$tmp_file"
  tyl_release_lock
  exit 1
fi

if ! mv "$tmp_file" "$TASK_FILE"; then
  echo "[start_task] ERROR: task YAMLへのrenameに失敗した。書き換えを中止した" >&2
  rm -f "$tmp_file"
  tyl_release_lock
  exit 1
fi
tyl_release_lock

echo "[start_task] $(date '+%Y-%m-%dT%H:%M:%S') agent=$AGENT_ID task_file=$TASK_FILE status: assigned -> in_progress"
exit 0
