#!/usr/bin/env bats
#
# tests/unit/test_start_task.bats
#
# cmd_914 T1: scripts/start_task.sh のユニットテスト。
# 真因(queue/reports/cmd914_status_update_gap.md §1): 足軽の正典
# (.claude/skills/inbox/SKILL.md)にstatusをin_progressへ書き換える段が
# 無く、今日7人全員でin_progress書き換えが0回だった。本スクリプトは
# その段を一つの操作にまとめる。
#
# START_TASK_AGENT_ID/START_TASK_TASKS_DIR/START_TASK_LOCK_WAIT_SECの
# 差し替え口を使い、本物のqueue/tasks・実tmuxに一切触れず隔離実行する。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SCRIPT="${PROJECT_ROOT}/scripts/start_task.sh"

  export TMP_DIR
  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/start_task.XXXXXX")"
  mkdir -p "$TMP_DIR/tasks"

  export START_TASK_TASKS_DIR="$TMP_DIR/tasks"
  export START_TASK_AGENT_ID="ashigaru9"
  export START_TASK_LOCK_WAIT_SEC=1
}

teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

_write_task() {
  # $1: status
  cat > "$TMP_DIR/tasks/ashigaru9.yaml" <<YAML
task:
  task_id: subtask_test_001
  status: $1
  report_to: gunshi
YAML
}

# ── T-ST-001: status=assigned → in_progressへ書き換える(正常系) ──
@test "T-ST-001: status=assignedならin_progressへ書き換える" {
  _write_task assigned
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "status: in_progress" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
  run grep -c "status: assigned" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 0 ]
  # 他のフィールドが失われていないこと
  run grep -c "task_id: subtask_test_001" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
}

# ── T-ST-002: status=in_progress(既に開始済み)→ 何もせず終了(冪等性) ──
@test "T-ST-002: status=in_progressなら書き換えず終了する(冪等性)" {
  _write_task in_progress
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "status: in_progress" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
}

# ── T-ST-003: status=done → 書き換えず終了(assigned以外は全て対象外) ──
@test "T-ST-003: status=doneなら書き換えず終了する" {
  _write_task done
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "status: done" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
}

# ── T-ST-004: agent_idが取得できない → 非0で終了・何も書き換えない ──
@test "T-ST-004: agent_idが取得できなければ非0で終了する" {
  _write_task assigned
  unset START_TASK_AGENT_ID
  # tmuxコマンド自体が見えない最小PATH(/usr/bin:/bin相当)で実行し、
  # tmux display-message失敗によりagent_idが空になるケースを再現する
  # (grep/sed/awk/mktemp/date/statは/usr/bin・/binに標準で入っている)。
  run env -u TMUX -u TMUX_PANE PATH="/usr/bin:/bin" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -c "status: in_progress" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 0 ]
}

# ── T-ST-005: task YAMLが存在しない → 非0で終了(失敗が失敗として現れる) ──
@test "T-ST-005: task YAMLが存在しなければ非0で終了する" {
  rm -f "$TMP_DIR/tasks/ashigaru9.yaml"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

# ── T-ST-006【並行実行】他プロセスがロックを保持中は書き換えず非0で終了する ──
#   scripts/lib/task_yaml_lock.shはflock(Linux/一部macOS)とmkdir(素のmacOS
#   ・GitHub Actions macos-latest)の両対応のため、テストも実行環境で実際に
#   使われる方式でロックを外側から握る。
@test "T-ST-006: 他プロセスがロックを保持中は待機の末に非0で終了し書き換えない" {
  _write_task assigned
  local lockfile="$TMP_DIR/tasks/ashigaru9.yaml.lock"
  if command -v flock &>/dev/null; then
    exec 9>"$lockfile"
    flock 9
  else
    mkdir "${lockfile}.d"
  fi

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -c "status: assigned" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]

  if command -v flock &>/dev/null; then
    flock -u 9
    exec 9>&-
  else
    rmdir "${lockfile}.d"
  fi
}
