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
