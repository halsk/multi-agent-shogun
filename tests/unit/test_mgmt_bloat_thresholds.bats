#!/usr/bin/env bats
#
# tests/unit/test_mgmt_bloat_thresholds.bats
#
# cmd_766 第四層(ファイルサイズ閾値)の閾値テーブル単体テスト。
# 実測(queue/reports/gunshi_report.yaml measured_current_sizes)に基づく閾値が
# 正しく引けることを確認する。ファイルI/Oは伴わない純粋な関数テスト。

setup() {
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=../../lib/mgmt_bloat_thresholds.sh
  source "$PROJECT_ROOT/lib/mgmt_bloat_thresholds.sh"
}

@test "T-THR-001: ledger threshold is 300000 bytes / 40 entries" {
  [ "$(mgmt_bloat_threshold_bytes ledger)" = "300000" ]
  [ "$(mgmt_bloat_threshold_count ledger)" = "40" ]
}

@test "T-THR-002: dashboard threshold is 100000 bytes, no count threshold" {
  [ "$(mgmt_bloat_threshold_bytes dashboard)" = "100000" ]
  [ "$(mgmt_bloat_threshold_count dashboard)" = "0" ]
}

@test "T-THR-003: inbox threshold is 30000 bytes / 20 messages" {
  [ "$(mgmt_bloat_threshold_bytes inbox)" = "30000" ]
  [ "$(mgmt_bloat_threshold_count inbox)" = "20" ]
}

@test "T-THR-004: tasks threshold is 20000 bytes" {
  [ "$(mgmt_bloat_threshold_bytes tasks)" = "20000" ]
}

@test "T-THR-005: reports threshold is 100000 bytes" {
  [ "$(mgmt_bloat_threshold_bytes reports)" = "100000" ]
}

@test "T-THR-006: unknown category returns 0 (fail-safe, not fail-open)" {
  [ "$(mgmt_bloat_threshold_bytes nope)" = "0" ]
}

@test "T-THR-007: far exceed factor is 2x" {
  [ "$(mgmt_bloat_far_exceed_factor)" = "2" ]
}

@test "T-THR-008: category_for_path classifies each managed path correctly" {
  [ "$(mgmt_bloat_category_for_path "/x/queue/shogun_to_karo.yaml")" = "ledger" ]
  [ "$(mgmt_bloat_category_for_path "/x/dashboard.md")" = "dashboard" ]
  [ "$(mgmt_bloat_category_for_path "/x/queue/inbox/karo.yaml")" = "inbox" ]
  [ "$(mgmt_bloat_category_for_path "/x/queue/tasks/ashigaru4.yaml")" = "tasks" ]
  [ "$(mgmt_bloat_category_for_path "/x/queue/reports/ashigaru2_report.yaml")" = "reports" ]
  [ "$(mgmt_bloat_category_for_path "/x/unrelated/foo.yaml")" = "" ]
}

@test "T-THR-009: count_for_file counts ledger cmd entries" {
  local f
  f="$(mktemp "$BATS_TMPDIR/ledger_XXXXXX.yaml")"
  printf -- '- id: cmd_1\n  status: pending\n- id: cmd_2\n  status: done\n' > "$f"
  [ "$(mgmt_bloat_count_for_file "$f" ledger)" = "2" ]
  rm -f "$f"
}

@test "T-THR-010: count_for_file counts inbox messages" {
  local f
  f="$(mktemp "$BATS_TMPDIR/inbox_XXXXXX.yaml")"
  printf -- 'messages:\n- content: a\n  read: true\n- content: b\n  read: false\n' > "$f"
  [ "$(mgmt_bloat_count_for_file "$f" inbox)" = "2" ]
  rm -f "$f"
}

@test "T-THR-011: count_for_file returns 0 for categories without count rule" {
  local f
  f="$(mktemp "$BATS_TMPDIR/tasks_XXXXXX.yaml")"
  printf -- 'task:\n  status: assigned\n' > "$f"
  [ "$(mgmt_bloat_count_for_file "$f" tasks)" = "0" ]
  rm -f "$f"
}
