#!/usr/bin/env bats
#
# tests/unit/test_stall_watchdog_report.bats
#
# cmd_771 ④ 24時間計数報告の純関数ユニットテスト。実際の停止検知は各checkが
# 既にリアルタイムでdashboard+ntfy済みのため、本報告は「本当に何も起きな
# かった」ことの正直な確認のみを担う。「0件かつ稼働N>0の場合のみ送信」
# (稼働0件の"0件"は無意味という軍師指摘)を検証する。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/stall_watchdog_report.sh"

  export TMP_DIR
  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/stall_watchdog_report.XXXXXX")"
}

teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

seed_log() {
  printf '%s\n' "$1" > "$TMP_DIR/stall_watchdog.log"
}

# ── T-REPORT-001: cutoff以降のtagのみ数える(窓外は数えない) ──

@test "T-REPORT-001: count_tag_in_window only counts lines at/after cutoff" {
  source "$LIB_FILE"

  seed_log $'[2026-09-04T10:00:00] [P1] old stall outside window\n[2026-09-06T10:00:00] [P1] recent stall inside window\n[2026-09-06T11:00:00] [P1] another recent stall'

  run count_tag_in_window "$TMP_DIR/stall_watchdog.log" "[P1]" "2026-09-05T00:00:00"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

# ── T-REPORT-002: tagが一致しない行は数えない ──

@test "T-REPORT-002: count_tag_in_window does not count lines with a different tag" {
  source "$LIB_FILE"

  seed_log $'[2026-09-06T10:00:00] [P1] stall\n[2026-09-06T10:05:00] [STALL] agent watched'

  run count_tag_in_window "$TMP_DIR/stall_watchdog.log" "[ORPHAN-CMD]" "2026-09-05T00:00:00"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ── T-REPORT-003: 停止0件かつ稼働>0 → 送信すべき(true) ──

@test "T-REPORT-003: should_send_24h_report is true when total_stops=0 and activity>0" {
  source "$LIB_FILE"

  run should_send_24h_report "0" "5"
  [ "$status" -eq 0 ]
  [ "$output" == "true" ]
}

# ── T-REPORT-004: 停止0件かつ稼働0件 → 送信すべきでない(false・軍師指摘の要) ──

@test "T-REPORT-004: should_send_24h_report is false when total_stops=0 and activity=0 (meaningless zero)" {
  source "$LIB_FILE"

  run should_send_24h_report "0" "0"
  [ "$status" -eq 0 ]
  [ "$output" == "false" ]
}

# ── T-REPORT-005: 停止件数>0 → 送信すべきでない(既にリアルタイム通知済) ──

@test "T-REPORT-005: should_send_24h_report is false when total_stops>0 (already notified realtime)" {
  source "$LIB_FILE"

  run should_send_24h_report "3" "10"
  [ "$status" -eq 0 ]
  [ "$output" == "false" ]
}

# ── T-REPORT-006: report_due — 未報告(epoch=0)なら常にtrue ──

@test "T-REPORT-006: report_due is true when never reported before (epoch=0)" {
  source "$LIB_FILE"

  run report_due "0" "1000000" "86400"
  [ "$status" -eq 0 ]
  [ "$output" == "true" ]
}

# ── T-REPORT-007: report_due — 24時間未経過ならfalse ──

@test "T-REPORT-007: report_due is false before the 24h window elapses" {
  source "$LIB_FILE"

  run report_due "1000000" "1003600" "86400"
  [ "$status" -eq 0 ]
  [ "$output" == "false" ]
}

# ── T-REPORT-008: report_due — 24時間経過後はtrue ──

@test "T-REPORT-008: report_due is true after the 24h window elapses" {
  source "$LIB_FILE"

  run report_due "1000000" "1086401" "86400"
  [ "$status" -eq 0 ]
  [ "$output" == "true" ]
}

# ── T-REPORT-009: stall_watchdog.sh が本報告を既存周期(5分)から呼び出して
# いる(新規launchdジョブを作らず既存に相乗り・相乗り確認) ──

@test "T-REPORT-009: stall_watchdog.sh invokes stall_watchdog_report.sh" {
  grep -q "stall_watchdog_report.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}
