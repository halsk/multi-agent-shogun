#!/usr/bin/env bash
# scripts/finish_task.sh — 足軽taskの「終える」操作を一つにまとめる(cmd_914 T1)
#
# 軍師設計(queue/reports/cmd914_status_update_gap.md §3.1「終える操作」)を
# 実装する。以下の段を順に行い、一つでも欠ければ非0で止まり何も書き換えない:
#   ①agent_id読取 ②task_id読取・report_to欄の存在確認(cmd_914 T1続き
#   軍師QC medium F2是正) ③report検め(scripts/finish_task_validate.py)
#   ④report_toへinbox_write(type=report_received) ⑤task YAMLのstatus行
#   書換(flock・mtime確認・一時ファイル+rename) ⑥ログ出力
#
# ★段④⑤の順序(cmd_914 T1続き・軍師QC high F1是正): status書換より
# ★先に★inbox_writeを試み、実際に送れた(exit 0)ことを確認できた場合に
# 限り次のstatus書換へ進む(設計b案採用)。旧実装はstatus書換を先に行い
# inbox_writeの失敗を検知していなかった(「失敗が失敗として現れぬ」欠陥)。
#
# Usage: bash scripts/finish_task.sh [--status done|blocked|failed] [--message "..."]
#
# テスト用差し替え口(FINISH_TASK_*)は本番動作を変えない(未設定時は実パス)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/task_yaml_lock.sh
source "$SCRIPT_DIR/scripts/lib/task_yaml_lock.sh"

# ★PyYAMLをimportできるpython3を実際に確かめてから選ぶ(cmd908 T2・
# scripts/cr-retrigger-launcher.shの_select_python3と同じ教訓の適用)。
# 「python3」という裸のコマンド名は環境によってPyYAMLを持たない場合が
# ある(実測: GitHub Actions macos-latestランナーのbare python3はPyYAML
# 無し・CI「Setup Python venv with PyYAML」ステップが用意する.venv/bin/
# python3にのみ入っている)。候補列から実際にimport yamlできるものを選ぶ。
_select_python3() {
  local candidates=()
  if [[ -n "${FINISH_TASK_PYTHON3_CANDIDATES:-}" ]]; then
    local IFS=':'
    read -r -a candidates <<< "$FINISH_TASK_PYTHON3_CANDIDATES"
  else
    candidates=(
      "${SCRIPT_DIR}/.venv/bin/python3"
      "python3"
      "/opt/homebrew/bin/python3"
      "/usr/local/bin/python3"
      "/usr/bin/python3"
      "${HOME}/.pyenv/shims/python3"
    )
  fi
  local c
  for c in "${candidates[@]}"; do
    [[ -z "$c" ]] && continue
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "import yaml" >/dev/null 2>&1; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

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
if [[ -n "${FINISH_TASK_PYTHON3:-}" ]]; then
  PYTHON3_BIN="$FINISH_TASK_PYTHON3"
else
  PYTHON3_BIN="$(_select_python3)" || {
    echo "[finish_task] ERROR: PyYAMLをimportできるpython3が見つからない" >&2
    exit 1
  }
fi
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
if [ -z "$REPORT_TO" ]; then
  echo "[finish_task] ERROR: task YAMLにreport_to欄が無い(通知先が確定できないため中止した): $TASK_FILE" >&2
  exit 1
fi

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

# ④report_toへinbox_write(既読化はinbox skill Step 1で足軽自身が行う・従来通り)
#
# ★是正(cmd_914 T1続き・軍師QC high F1): 旧実装はstatus書換(旧④)を
# 先に行い、その後にinbox_write(旧⑤)を無条件に呼んでいたため、
# inbox_writeが失敗しても(set -eも掛けていなかったため)検知されず
# exit 0で正常終了していた——task YAMLはdoneに書き換わったのに
# 軍師への報せが実際には届かない「失敗が失敗として現れぬ」欠陥。
# ★対策として順序を入れ替える(設計b案採用): status書換より★先に★
# inbox_writeを試み、実際に送れた(exit 0)ことを確認できた場合に限り
# 次のstatus書換へ進む。inbox_writeが失敗した場合はここで非0で終了し、
# task YAMLには一切触れない——status書換前なら再実行はそのまま
# 冪等に安全(何も変わっていないので同じコマンドを再度呼べばよい)。
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
if ! bash "$INBOX_WRITE_SCRIPT" "$REPORT_TO" "$MESSAGE" report_received "$AGENT_ID"; then
  echo "[finish_task] ERROR: inbox_write.shが失敗した(report_to=$REPORT_TO)。task YAMLのstatusは書き換えていない" >&2
  exit 1
fi

# ⑤task YAMLのstatus行書換(flock・mtime確認・一時ファイル+rename)
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

# ⑥ログ出力
mkdir -p "$(dirname "$LOG_FILE")"
now_iso="$(date '+%Y-%m-%dT%H:%M:%S')"
log_line="[finish_task] $now_iso agent=$AGENT_ID task_id=$TASK_ID status -> $STATUS report_to=${REPORT_TO:-<none>}"
echo "$log_line"
echo "$log_line" >> "$LOG_FILE"

exit 0
