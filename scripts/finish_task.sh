#!/usr/bin/env bash
# scripts/finish_task.sh — 足軽taskの「終える」操作を一つにまとめる(cmd_914 T1)
#
# 軍師設計(queue/reports/cmd914_status_update_gap.md §3.1「終える操作」)を
# 実装する。以下の6段を順に行い、一つでも欠ければ非0で止まり何も書き換えない:
#   ①agent_id読取 ②task_id読取 ③report検め(scripts/finish_task_validate.py)
#   ④task YAMLのstatus行書換(flock・mtime確認・一時ファイル+rename)
#   ⑤report_toへinbox_write(type=report_received) ⑥ログ出力
#
# Usage: bash scripts/finish_task.sh [--status done|blocked|failed] [--message "..."]
#
# テスト用差し替え口(FINISH_TASK_*)は本番動作を変えない(未設定時は実パス)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/task_yaml_lock.sh
source "$SCRIPT_DIR/scripts/lib/task_yaml_lock.sh"

STATUS="done"
MESSAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --status)
      STATUS="${2:-}"
      shift 2
      ;;
    --message)
      MESSAGE="${2:-}"
      shift 2
      ;;
    *)
      echo "[finish_task] ERROR: 不明な引数: $1" >&2
      exit 1
      ;;
  esac
done

case "$STATUS" in
  done | blocked | failed) ;;
  *)
    echo "[finish_task] ERROR: --status は done|blocked|failed のいずれか(指定: $STATUS)" >&2
    exit 1
    ;;
esac

# ①agent_id読取
AGENT_ID="${FINISH_TASK_AGENT_ID:-}"
if [ -z "$AGENT_ID" ]; then
  AGENT_ID="$(tmux display-message -t "${TMUX_PANE:-}" -p '#{@agent_id}' 2>/dev/null)"
fi
if [ -z "$AGENT_ID" ]; then
  echo "[finish_task] ERROR: agent_id が取得できない(tmux display-message失敗)" >&2
  exit 1
fi

TASKS_DIR="${FINISH_TASK_TASKS_DIR:-$SCRIPT_DIR/queue/tasks}"
REPORTS_DIR="${FINISH_TASK_REPORTS_DIR:-$SCRIPT_DIR/queue/reports}"
TASK_FILE="$TASKS_DIR/${AGENT_ID}.yaml"
REPORT_FILE="$REPORTS_DIR/${AGENT_ID}_report.yaml"
PYTHON3_BIN="${FINISH_TASK_PYTHON3:-python3}"
VALIDATOR="${FINISH_TASK_VALIDATOR:-$SCRIPT_DIR/scripts/finish_task_validate.py}"
INBOX_WRITE_SCRIPT="${FINISH_TASK_INBOX_WRITE_SCRIPT:-$SCRIPT_DIR/scripts/inbox_write.sh}"
LOG_FILE="${FINISH_TASK_LOG_FILE:-$SCRIPT_DIR/logs/finish_task.log}"
LOCK_WAIT_SEC="${FINISH_TASK_LOCK_WAIT_SEC:-5}"

if [ ! -f "$TASK_FILE" ]; then
  echo "[finish_task] ERROR: task YAML が見当たらぬ: $TASK_FILE" >&2
  exit 1
fi

# ②task_id読取(実物は`task_id:`、writing-task-yaml手本記載の`id:`もフォールバックで拾う)
TASK_ID="$(grep -E '^[[:space:]]*task_id:[[:space:]]*' "$TASK_FILE" | head -1 | sed 's/.*task_id:[[:space:]]*//' | tr -d '"' | tr -d "'")"
if [ -z "$TASK_ID" ]; then
  TASK_ID="$(grep -E '^[[:space:]]*id:[[:space:]]*' "$TASK_FILE" | head -1 | sed 's/.*id:[[:space:]]*//' | tr -d '"' | tr -d "'")"
fi
if [ -z "$TASK_ID" ]; then
  echo "[finish_task] ERROR: task_id が task YAML から読めない: $TASK_FILE" >&2
  exit 1
fi

REPORT_TO="$(grep -E '^[[:space:]]*report_to:[[:space:]]*' "$TASK_FILE" | head -1 | sed 's/.*report_to:[[:space:]]*//' | tr -d '"' | tr -d "'")"

TASK_MTIME="$(stat -c %Y "$TASK_FILE" 2>/dev/null || stat -f %m "$TASK_FILE" 2>/dev/null)"
if [ -z "$TASK_MTIME" ]; then
  echo "[finish_task] ERROR: task YAML の mtime が取得できない" >&2
  exit 1
fi

# ③report検め — 一つでも条件を欠けば非0。ここで止まれば以降(④⑤⑥)は一切実行しない。
VALIDATION_OUTPUT="$("$PYTHON3_BIN" "$VALIDATOR" --report "$REPORT_FILE" --task-id "$TASK_ID" --status "$STATUS" --task-mtime "$TASK_MTIME" 2>&1)"
VALIDATION_RC=$?
if [ "$VALIDATION_RC" -ne 0 ]; then
  echo "[finish_task] REJECTED: agent=$AGENT_ID task_id=$TASK_ID — $VALIDATION_OUTPUT" >&2
  exit 1
fi

# ④task YAMLのstatus行書換(flock・mtime確認・一時ファイル+rename)
TYL_LOCKFILE="${TASK_FILE}.lock"
if ! tyl_acquire_lock "$LOCK_WAIT_SEC"; then
  echo "[finish_task] ERROR: ロック取得失敗(${LOCK_WAIT_SEC}秒待機): $TYL_LOCKFILE" >&2
  exit 1
fi

mtime_after_lock="$(stat -c %Y "$TASK_FILE" 2>/dev/null || stat -f %m "$TASK_FILE" 2>/dev/null)"
if [ "$mtime_after_lock" != "$TASK_MTIME" ]; then
  echo "[finish_task] ERROR: ロック取得までにtask YAMLが変更された(他プロセスと競合)。書き換えを中止した" >&2
  tyl_release_lock
  exit 1
fi

tmp_file="$(mktemp "${TASK_FILE}.tmp.XXXXXX")"
if [ -z "$tmp_file" ]; then
  echo "[finish_task] ERROR: mktemp に失敗した。書き換えを中止した" >&2
  tyl_release_lock
  exit 1
fi

if ! awk -v newval="$STATUS" '
  !done && $0 ~ /^[[:space:]]*status:[[:space:]]*/ {
    match($0, /^[[:space:]]*/)
    indent = substr($0, RSTART, RLENGTH)
    print indent "status: " newval
    done = 1
    next
  }
  { print }
' "$TASK_FILE" > "$tmp_file"; then
  echo "[finish_task] ERROR: status書換の生成に失敗した。書き換えを中止した" >&2
  rm -f "$tmp_file"
  tyl_release_lock
  exit 1
fi

if ! mv "$tmp_file" "$TASK_FILE"; then
  echo "[finish_task] ERROR: task YAMLへのrenameに失敗した。書き換えを中止した" >&2
  rm -f "$tmp_file"
  tyl_release_lock
  exit 1
fi
tyl_release_lock

# ⑤report_toへinbox_write(既読化はinbox skill Step 1で足軽自身が行う・従来通り)
if [ -n "$REPORT_TO" ]; then
  if [ -z "$MESSAGE" ]; then
    case "$STATUS" in
      done)
        MESSAGE="${AGENT_ID}号、${TASK_ID}の任務完了でござる。品質チェックを仰ぎたし。"
        ;;
      blocked)
        MESSAGE="${AGENT_ID}号、${TASK_ID}は手番待ちによりblockedでござる。ご確認願いたし。"
        ;;
      failed)
        MESSAGE="${AGENT_ID}号、${TASK_ID}は失敗に終わったでござる。ご確認願いたし。"
        ;;
    esac
  fi
  bash "$INBOX_WRITE_SCRIPT" "$REPORT_TO" "$MESSAGE" report_received "$AGENT_ID"
fi

# ⑥ログ出力
mkdir -p "$(dirname "$LOG_FILE")"
now_iso="$(date '+%Y-%m-%dT%H:%M:%S')"
log_line="[finish_task] $now_iso agent=$AGENT_ID task_id=$TASK_ID status -> $STATUS report_to=${REPORT_TO:-<none>}"
echo "$log_line"
echo "$log_line" >> "$LOG_FILE"

exit 0
