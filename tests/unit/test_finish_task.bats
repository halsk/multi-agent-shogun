#!/usr/bin/env bats
#
# tests/unit/test_finish_task.bats
#
# cmd_914 T1: scripts/finish_task.sh(+ scripts/finish_task_validate.py)の
# ユニットテスト。軍師設計(queue/reports/cmd914_status_update_gap.md §3.1
# 「終える操作」)の6段のうち、③report検めで一つでも条件を欠けば非0で止まり
# ④以降(task YAML書換・inbox_write・ログ)が一切実行されないことを実証する。
#
# FINISH_TASK_*の差し替え口を使い、本物のqueue/tasks・queue/reports・実
# inbox_write.shに一切触れず隔離実行する(inbox_write.shは呼出を記録する
# だけのスタブに差し替える・tests/unit/test_deadman_switch.bats慣習と同型)。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SCRIPT="${PROJECT_ROOT}/scripts/finish_task.sh"
  export FIXTURES_DIR="${PROJECT_ROOT}/tests/fixtures/cmd914"

  export TMP_DIR
  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/finish_task.XXXXXX")"
  mkdir -p "$TMP_DIR/tasks" "$TMP_DIR/reports"

  export INBOX_CALLS_LOG
  INBOX_CALLS_LOG="$(mktemp "$BATS_TMPDIR/finish_task_inbox_calls.XXXXXX")"
  export INBOX_WRITE_STUB="$TMP_DIR/inbox_write_stub.sh"
  cat > "$INBOX_WRITE_STUB" << STUB
#!/usr/bin/env bash
echo "INBOX_WRITE_CALLED: \$*" >> "${INBOX_CALLS_LOG}"
STUB
  chmod +x "$INBOX_WRITE_STUB"

  export FINISH_TASK_AGENT_ID="ashigaru9"
  export FINISH_TASK_TASKS_DIR="$TMP_DIR/tasks"
  export FINISH_TASK_REPORTS_DIR="$TMP_DIR/reports"
  export FINISH_TASK_INBOX_WRITE_SCRIPT="$INBOX_WRITE_STUB"
  export FINISH_TASK_LOG_FILE="$TMP_DIR/finish_task.log"
  export FINISH_TASK_LOCK_WAIT_SEC=1
  export FINISH_TASK_PYTHON3="python3"
}

teardown() {
  rm -rf "$TMP_DIR" "$INBOX_CALLS_LOG" 2>/dev/null || true
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

_write_report() {
  # $1: report body(全文)
  printf '%s' "$1" > "$TMP_DIR/reports/ashigaru9_report.yaml"
}

_compliant_report() {
  # $1: status
  cat <<YAML
worker_id: ashigaru9
task_id: subtask_test_001
parent_cmd: cmd_test
status: $1
timestamp: "2026-09-28T20:00:00"
result: |
  テスト用の報告本文でござる。
skill_candidate:
  found: false
YAML
}

# ── T-FT-001【正常系】task_id一致・status一致・report新しい・必須欄そろう
#   → statusが書き換わり、report_toへinbox_writeされ、ログに残る ──
@test "T-FT-001: 正常系はstatusを書き換えinbox_writeし、ログに残す" {
  _write_task assigned
  touch -t 202609281950.00 "$TMP_DIR/tasks/ashigaru9.yaml"
  _write_report "$(_compliant_report done)"
  touch -t 202609282000.00 "$TMP_DIR/reports/ashigaru9_report.yaml"

  run bash "$SCRIPT" --status done
  [ "$status" -eq 0 ]

  run grep -c "status: done" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]

  [ -s "$INBOX_CALLS_LOG" ]
  run grep -c "gunshi" "$INBOX_CALLS_LOG"
  [ "$output" -ge 1 ]
  run grep -c "report_received" "$INBOX_CALLS_LOG"
  [ "$output" -ge 1 ]

  [ -f "$FINISH_TASK_LOG_FILE" ]
  run grep -c "subtask_test_001" "$FINISH_TASK_LOG_FILE"
  [ "$output" -ge 1 ]
}

# ── T-FT-002【異常系: task_id不一致】拒否し、task/inbox共に無変化 ──
@test "T-FT-002: task_id不一致なら拒否しstatusを書き換えずinbox_writeもしない" {
  _write_task assigned
  touch -t 202609281950.00 "$TMP_DIR/tasks/ashigaru9.yaml"
  report="$(_compliant_report done)"
  report="${report/subtask_test_001/subtask_OTHER_TASK}"
  _write_report "$report"
  touch -t 202609282000.00 "$TMP_DIR/reports/ashigaru9_report.yaml"

  run bash "$SCRIPT" --status done
  [ "$status" -ne 0 ]

  run grep -c "status: assigned" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
  [ ! -s "$INBOX_CALLS_LOG" ]
  [ ! -f "$FINISH_TASK_LOG_FILE" ]
}

# ── T-FT-003【異常系: 報告がtaskより古い】拒否し、task/inbox共に無変化 ──
@test "T-FT-003: 報告のmtimeがtaskより古ければ拒否する" {
  _write_task assigned
  touch -t 202609282000.00 "$TMP_DIR/tasks/ashigaru9.yaml"
  _write_report "$(_compliant_report done)"
  touch -t 202609281950.00 "$TMP_DIR/reports/ashigaru9_report.yaml"

  run bash "$SCRIPT" --status done
  [ "$status" -ne 0 ]

  run grep -c "status: assigned" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
  [ ! -s "$INBOX_CALLS_LOG" ]
}

# ── T-FT-004【異常系: 複数文書】`---`区切りの複数文書を拒否する ──
@test "T-FT-004: 報告が複数文書(---区切り)なら拒否する" {
  _write_task assigned
  touch -t 202609281950.00 "$TMP_DIR/tasks/ashigaru9.yaml"
  {
    _compliant_report done
    echo "---"
    _compliant_report done
  } > "$TMP_DIR/reports/ashigaru9_report.yaml"
  touch -t 202609282000.00 "$TMP_DIR/reports/ashigaru9_report.yaml"

  run bash "$SCRIPT" --status done
  [ "$status" -ne 0 ]
  run grep -c "status: assigned" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
  [ ! -s "$INBOX_CALLS_LOG" ]
}

# ── T-FT-005【異常系: 重複キー】拒否する(cmd_900と同型の事故の再発防止) ──
@test "T-FT-005: 報告に重複キーがあれば拒否する" {
  _write_task assigned
  touch -t 202609281950.00 "$TMP_DIR/tasks/ashigaru9.yaml"
  cat > "$TMP_DIR/reports/ashigaru9_report.yaml" <<'YAML'
worker_id: ashigaru9
task_id: subtask_test_001
task_id: subtask_test_001_duplicate
parent_cmd: cmd_test
status: done
timestamp: "2026-09-28T20:00:00"
result: |
  重複キーを含む報告でござる。
skill_candidate:
  found: false
YAML
  touch -t 202609282000.00 "$TMP_DIR/reports/ashigaru9_report.yaml"

  run bash "$SCRIPT" --status done
  [ "$status" -ne 0 ]
  run grep -c "status: assigned" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
  [ ! -s "$INBOX_CALLS_LOG" ]
}

# ── T-FT-006【異常系: 必須欄欠落】skill_candidateが無ければ拒否する ──
@test "T-FT-006: 必須欄(skill_candidate)が欠ければ拒否する" {
  _write_task assigned
  touch -t 202609281950.00 "$TMP_DIR/tasks/ashigaru9.yaml"
  cat > "$TMP_DIR/reports/ashigaru9_report.yaml" <<'YAML'
worker_id: ashigaru9
task_id: subtask_test_001
parent_cmd: cmd_test
status: done
timestamp: "2026-09-28T20:00:00"
result: |
  skill_candidateを書き忘れた報告でござる。
YAML
  touch -t 202609282000.00 "$TMP_DIR/reports/ashigaru9_report.yaml"

  run bash "$SCRIPT" --status done
  [ "$status" -ne 0 ]
  run grep -c "status: assigned" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
}

# ── T-FT-007【異常系: --statusと報告内statusの不一致】拒否する ──
@test "T-FT-007: --statusと報告内のstatusが食い違えば拒否する" {
  _write_task assigned
  touch -t 202609281950.00 "$TMP_DIR/tasks/ashigaru9.yaml"
  _write_report "$(_compliant_report blocked)"
  touch -t 202609282000.00 "$TMP_DIR/reports/ashigaru9_report.yaml"

  run bash "$SCRIPT" --status done
  [ "$status" -ne 0 ]
  run grep -c "status: assigned" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
}

# ── T-FT-008: --status blockedでも正常に動作する ──
@test "T-FT-008: --status blockedの正常系も動作する" {
  _write_task assigned
  touch -t 202609281950.00 "$TMP_DIR/tasks/ashigaru9.yaml"
  _write_report "$(_compliant_report blocked)"
  touch -t 202609282000.00 "$TMP_DIR/reports/ashigaru9_report.yaml"

  run bash "$SCRIPT" --status blocked
  [ "$status" -eq 0 ]
  run grep -c "status: blocked" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
  [ -s "$INBOX_CALLS_LOG" ]
}

# ── T-FT-009【冪等性】同じ報告で二度目を呼ぶと、一度目の書換でtaskの
#   mtimeが「今」に進むため「報告が新しくない」として拒否される(安全側に
#   倒れる)。★一度目の書換後、taskのmtimeは実行時刻(壁時計)そのものになる
#   ため、report側は固定の過去日付でなく実行時刻基準の相対時刻(now-秒)で
#   touchする——固定日付同士の比較では実行時刻によって偶然新しく見え
#   flakyになる(実測で発覚)。 ──
@test "T-FT-009: 同じ報告で二度目を呼ぶと安全側(拒否)に倒れる" {
  _write_task assigned
  now_epoch=$(date +%s)
  task_ts=$(date -r $((now_epoch - 20)) '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$((now_epoch - 20))" '+%Y%m%d%H%M.%S')
  report_ts=$(date -r $((now_epoch - 10)) '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$((now_epoch - 10))" '+%Y%m%d%H%M.%S')
  touch -t "$task_ts" "$TMP_DIR/tasks/ashigaru9.yaml"
  _write_report "$(_compliant_report done)"
  touch -t "$report_ts" "$TMP_DIR/reports/ashigaru9_report.yaml"

  run bash "$SCRIPT" --status done
  [ "$status" -eq 0 ]
  run wc -l < "$INBOX_CALLS_LOG"
  [ "$output" -eq 1 ]

  # 二度目: taskのmtimeは一度目の書換で「今」に進んでいるため、report
  # (実行開始10秒前の固定時刻)はもう新しくない → 拒否される
  run bash "$SCRIPT" --status done
  [ "$status" -ne 0 ]
  run wc -l < "$INBOX_CALLS_LOG"
  [ "$output" -eq 1 ]
}

# ── T-FT-010【並行実行】他プロセスがロックを保持中は書き換えず非0で終了する ──
@test "T-FT-010: 他プロセスがロックを保持中は待機の末に非0で終了し書き換えない" {
  _write_task assigned
  touch -t 202609281950.00 "$TMP_DIR/tasks/ashigaru9.yaml"
  _write_report "$(_compliant_report done)"
  touch -t 202609282000.00 "$TMP_DIR/reports/ashigaru9_report.yaml"

  local lockfile="$TMP_DIR/tasks/ashigaru9.yaml.lock"
  if command -v flock &>/dev/null; then
    exec 9>"$lockfile"
    flock 9
  else
    mkdir "${lockfile}.d"
  fi

  run bash "$SCRIPT" --status done
  [ "$status" -ne 0 ]
  run grep -c "status: assigned" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
  [ ! -s "$INBOX_CALLS_LOG" ]

  if command -v flock &>/dev/null; then
    flock -u 9
    exec 9>&-
  else
    rmdir "${lockfile}.d"
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# cmd_914 RED→GREEN実証: 実物のashigaru1食い違いfixture(tests/fixtures/cmd914/)
# ══════════════════════════════════════════════════════════════════════════

# ── T-FT-RED: fixtureがそのまま「task=assigned・report=done」の
#   食い違いを保存していることの記録(是正前の実際の穴の証跡) ──
@test "T-FT-RED: fixtureはtask=assigned・report=done(同一task_id)の食い違いを保存している" {
  run grep -c "status: assigned" "$FIXTURES_DIR/ashigaru1_task_cmd911_e1_e2_vault_write.yaml"
  [ "$output" -eq 1 ]
  run grep -c "status: done" "$FIXTURES_DIR/ashigaru1_report_cmd911_e1_e2_vault_write.yaml"
  [ "$output" -eq 1 ]
  run grep -c "subtask_cmd911_e1_e2_vault_write" "$FIXTURES_DIR/ashigaru1_task_cmd911_e1_e2_vault_write.yaml"
  [ "$output" -ge 1 ]
  run grep -c "subtask_cmd911_e1_e2_vault_write" "$FIXTURES_DIR/ashigaru1_report_cmd911_e1_e2_vault_write.yaml"
  [ "$output" -ge 1 ]
}

# ── T-FT-GREEN: 同じfixtureのコピーに対しfinish_task.shを実行すると、
#   実際にstatusがdoneへ書き換わる(実物の穴が塞がれることの実証) ──
@test "T-FT-GREEN: 実物fixtureのコピーに対しfinish_task.shを実行するとstatusがdoneになる" {
  cp "$FIXTURES_DIR/ashigaru1_task_cmd911_e1_e2_vault_write.yaml" "$TMP_DIR/tasks/ashigaru9.yaml"
  cp "$FIXTURES_DIR/ashigaru1_report_cmd911_e1_e2_vault_write.yaml" "$TMP_DIR/reports/ashigaru9_report.yaml"
  touch -t 202609281950.00 "$TMP_DIR/tasks/ashigaru9.yaml"
  touch -t 202609282000.00 "$TMP_DIR/reports/ashigaru9_report.yaml"

  run bash "$SCRIPT" --status done
  [ "$status" -eq 0 ]
  run grep -c "status: done" "$TMP_DIR/tasks/ashigaru9.yaml"
  [ "$output" -eq 1 ]
  [ -s "$INBOX_CALLS_LOG" ]
}
