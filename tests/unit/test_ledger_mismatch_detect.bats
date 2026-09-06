#!/usr/bin/env bats
#
# tests/unit/test_ledger_mismatch_detect.bats
#
# cmd_766 第一層: report が完了 (status: done) を示しているのに、対応する
# 台帳 (shogun_to_karo.yaml) の cmd が pending/in_progress のまま N 時間
# 経過している状態を機械的に検知する純関数のユニットテスト。
#
# 本日 cmd_763/cmd_764 が実際にこの型だった(完了報告済みで pending のまま
# 残っていた・将軍指摘で是正)——このテストはその再現ケースを含む。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/ledger_mismatch_detect.sh"

  export TMP_DIR
  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/ledger_mismatch.XXXXXX")"
  mkdir -p "$TMP_DIR/reports"
}

teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

seed_ledger() {
  printf '%s\n' "$1" > "$TMP_DIR/ledger.yaml"
}

seed_report() {
  local name="$1" content="$2" age_hours="${3:-0}"
  printf '%s\n' "$content" > "$TMP_DIR/reports/$name"
  if [[ "$age_hours" -gt 0 ]]; then
    local ts
    ts=$(date -v-"${age_hours}"H '+%Y%m%d%H%M' 2>/dev/null || date -d "-${age_hours} hours" '+%Y%m%d%H%M')
    touch -t "$ts" "$TMP_DIR/reports/$name"
  fi
}

# ── T-LM-001: report done + ledger pending + 経過 N 時間 → mismatch 検出 ──

@test "T-LM-001: detects report done vs ledger pending after threshold (cmd_763/764 repro)" {
  [ -f "$LIB_FILE" ] || { echo "lib file not found: $LIB_FILE"; return 1; }
  # shellcheck source=/dev/null
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_763\n  status: pending\n- id: cmd_764\n  status: pending\n'
  seed_report "ashigaru1_report.yaml" $'parent_cmd: cmd_763\nstatus: done\n' 7
  seed_report "ashigaru2_report.yaml" $'parent_cmd: cmd_764\nstatus: done\n' 7

  run detect_ledger_mismatches "$TMP_DIR/reports" "$TMP_DIR/ledger.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" == *"cmd_763|"* ]]
  [[ "$output" == *"cmd_764|"* ]]
}

# ── T-LM-002: report done だが経過時間が閾値未満 → 検知しない(即時誤検知防止) ──

@test "T-LM-002: does not flag mismatch before threshold elapses" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_900\n  status: pending\n'
  seed_report "ashigaru3_report.yaml" $'parent_cmd: cmd_900\nstatus: done\n' 0

  run detect_ledger_mismatches "$TMP_DIR/reports" "$TMP_DIR/ledger.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_900"* ]]
}

# ── T-LM-003: 台帳側が既に done → 検知しない(正常系) ──

@test "T-LM-003: does not flag when ledger already reflects done" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_901\n  status: done\n'
  seed_report "ashigaru4_report.yaml" $'parent_cmd: cmd_901\nstatus: done\n' 7

  run detect_ledger_mismatches "$TMP_DIR/reports" "$TMP_DIR/ledger.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_901"* ]]
}

# ── T-LM-004: report が done でない(in_progress等) → 検知しない ──

@test "T-LM-004: does not flag when report itself is not done" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_902\n  status: in_progress\n'
  seed_report "ashigaru5_report.yaml" $'parent_cmd: cmd_902\nstatus: in_progress\n' 7

  run detect_ledger_mismatches "$TMP_DIR/reports" "$TMP_DIR/ledger.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_902"* ]]
}

# ── T-LM-005: 台帳に該当 cmd が存在しない → 検知しない(誤爆防止) ──

@test "T-LM-005: does not flag when cmd id is absent from ledger" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_903\n  status: pending\n'
  seed_report "ashigaru6_report.yaml" $'parent_cmd: cmd_unknown\nstatus: done\n' 7

  run detect_ledger_mismatches "$TMP_DIR/reports" "$TMP_DIR/ledger.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_903"* ]]
  [[ "$output" != *"cmd_unknown"* ]]
}

# ── T-LM-006: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-LM-006: stall_watchdog.sh sources ledger_mismatch_detect.sh and invokes the check" {
  grep -q "ledger_mismatch_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_ledger_mismatches|detect_ledger_mismatches" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}

# ── cmd_766 第一層 相乗り(subtask_766_layer1_blocked_reason_check):
# status: blocked/blocked_needs_decision なのに blocked_on/blocked_reason が
# 空の「statusが実態を語っていない」ケースの検知。2026-09-06に同日中
# ashigaru4→ashigaru5で2度実測された欠陥の再発防止。

seed_task() {
  local dir="$1" name="$2" content="$3"
  mkdir -p "$dir"
  printf '%s\n' "$content" > "$dir/$name"
}

# ── T-BRG-001: blocked_on/blocked_reason 両方ありは検知されない ──

@test "T-BRG-001: does not flag when both blocked_on and blocked_reason are present" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru4.yaml" $'task:\n  status: blocked\n  blocked_on: "殿の手番待ち"\n  blocked_reason: "swarmが勝手に書き換え禁止のため"\n'

  run detect_blocked_reason_gaps "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru4.yaml"* ]]
}

# ── T-BRG-002: blocked_needs_decisionでblocked_on空 = 検知される ──

@test "T-BRG-002: flags blocked_needs_decision with empty blocked_on" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru5.yaml" $'task:\n  status: blocked_needs_decision\n  blocked_on: ""\n  blocked_reason: "将軍裁可待ち"\n'

  run detect_blocked_reason_gaps "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashigaru5.yaml|blocked_needs_decision"* ]]
}

# ── T-BRG-003: blocked_byありの通常blockedは対象外(依存待ちは正常系) ──

@test "T-BRG-003: does not flag normal blocked_by dependency wait even without blocked_on/reason" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru6.yaml" $'task:\n  status: blocked\n  blocked_by: "subtask_760_prereq"\n'

  run detect_blocked_reason_gaps "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru6.yaml"* ]]
}

# ── T-BRG-004: status: assigned/done等は対象外 ──

@test "T-BRG-004: does not flag status assigned or done" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  status: assigned\n'
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  status: done\n'

  run detect_blocked_reason_gaps "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru1.yaml"* ]]
  [[ "$output" != *"ashigaru2.yaml"* ]]
}

# ── T-BRG-005: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-BRG-005: stall_watchdog.sh invokes detect_blocked_reason_gaps via check_blocked_reason_gaps" {
  grep -qE "check_blocked_reason_gaps|detect_blocked_reason_gaps" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}

# ── cmd_771 fix_c: 孤児cmd(idle足軽+台帳の未完了cmdが誰にも割り当てられて
# いない状態)の検知。maybe_nudge_idle はagent自身のassignedタスク前提で
# 動くため、台帳に残った未完了cmdがどのtask YAMLのparent_cmdにも現れない
# 場合に検知漏れとなる(2026-09-06 殿が2度、swarmより先に気づいた主犯)。

# ── T-ORPHAN-001: 台帳pending/in_progressだがどのtask YAMLのparent_cmdにも
# 現れない → 検知される(未割当) ──

@test "T-ORPHAN-001: flags a pending ledger cmd that appears in no task YAML's parent_cmd" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_910\n  status: in_progress\n'
  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  parent_cmd: cmd_999\n  status: assigned\n'

  run detect_orphan_cmds "$TMP_DIR/ledger.yaml" "$TMP_DIR/tasks" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cmd_910|in_progress"* ]]
}

# ── T-ORPHAN-002: 台帳cmdがいずれかのtask YAMLのparent_cmdとして現れる
# (=割当あり) かつ all_ashigaru_idle=false → 検知されない(正常系) ──

@test "T-ORPHAN-002: does not flag when the cmd is assigned to a task YAML and not all ashigaru are idle" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_911\n  status: in_progress\n'
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  parent_cmd: cmd_911\n  status: assigned\n'

  run detect_orphan_cmds "$TMP_DIR/ledger.yaml" "$TMP_DIR/tasks" "false"
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_911"* ]]
}

# ── T-ORPHAN-003: 割当ありでも全ashigaruがidle(all_ashigaru_idle=true)の
# 場合は誰も手を付けていないとみなし検知される ──

@test "T-ORPHAN-003: flags an assigned cmd when all_ashigaru_idle=true (nobody actually working)" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_912\n  status: pending\n'
  seed_task "$TMP_DIR/tasks" "ashigaru3.yaml" $'task:\n  parent_cmd: cmd_912\n  status: assigned\n'

  run detect_orphan_cmds "$TMP_DIR/ledger.yaml" "$TMP_DIR/tasks" "true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cmd_912|pending"* ]]
}

# ── T-ORPHAN-004: 台帳status=done/superseded等は検知対象外(誤爆防止) ──

@test "T-ORPHAN-004: does not flag ledger cmds with status done or superseded" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_913\n  status: done\n- id: cmd_914\n  status: superseded\n'

  run detect_orphan_cmds "$TMP_DIR/ledger.yaml" "$TMP_DIR/tasks" "false"
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_913"* ]]
  [[ "$output" != *"cmd_914"* ]]
}

# ── T-ORPHAN-005: stall_watchdog.sh がこの check を実際に呼び出している
# (相乗り確認) ──

@test "T-ORPHAN-005: stall_watchdog.sh invokes detect_orphan_cmds via check_orphan_cmds" {
  grep -qE "check_orphan_cmds|detect_orphan_cmds" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}
