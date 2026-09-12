#!/usr/bin/env bats
#
# tests/unit/test_orphan_test_detect.bats
#
# subtask_741_layer3_orphan_detection①: cmd_741第三層(orphan test検知)の
# ユニットテスト。「どのCI job/Makefileからも実行されないtestファイル」
# (実例④「e2e/tenants-crud.spec.tsが一度もCIで実行されていなかった」相当)
# を静的grep+突合で検知する純関数のテスト。
#
# T-ORPH-009/010は本リポの実データ(.github/workflows/test.yml・tests/)を
# 直接対象にした回帰テストである。2026-09-09着手時点で実測確認した4件の
# 実在orphan(tests/watcher/test_modal_and_idle.bats・
# tests/test_stall_watchdog.sh・tests/test_console_stall_watchdog.sh・
# tests/test_claude_usage_report.py)は、殿ご裁可の二の矢
# (subtask_ci_orphan_tests_wiring)でCIへ接続済み。T-ORPH-010は
# 「orphanとして固定する」テストから「再びorphan化していないことを
# 守る」回帰ガードへ更新した。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/orphan_test_detect.sh"
}

# ── T-ORPH-001: extract_covered_test_patterns — workflow本文からtests/トークンを抽出 ──

@test "T-ORPH-001: extract_covered_test_patterns extracts literal tests/ path tokens from a workflow file" {
  source "$LIB_FILE"

  local wf="$BATS_TEST_TMPDIR/fake_workflow.yml"
  cat > "$wf" <<'EOF'
steps:
  - run: |
      ROOT_TESTS=$(ls tests/*.bats 2>/dev/null | grep -v 'tests/agent_selfwatch.bats' || true)
      bats $ROOT_TESTS --timing
  - run: bats tests/unit/ --timing
  - run: bats tests/e2e/ --timing --jobs 1
EOF

  run extract_covered_test_patterns "$wf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/*.bats"* ]]
  [[ "$output" == *"tests/agent_selfwatch.bats"* ]]
  [[ "$output" == *"tests/unit/"* ]]
  [[ "$output" == *"tests/e2e/"* ]]
}

# ── T-ORPH-002: extract_covered_test_patterns — 存在しないworkflow_fileは空を返す ──

@test "T-ORPH-002: extract_covered_test_patterns returns nothing for a missing workflow file" {
  source "$LIB_FILE"

  run extract_covered_test_patterns "$BATS_TEST_TMPDIR/does_not_exist.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-ORPH-003: is_target_test_file — *.bats は対象 ──

@test "T-ORPH-003: is_target_test_file accepts .bats files" {
  source "$LIB_FILE"

  run is_target_test_file "tests/unit/test_foo.bats"
  [ "$status" -eq 0 ]
}

# ── T-ORPH-004: is_target_test_file — test_*.sh / test_*.py は対象 ──

@test "T-ORPH-004: is_target_test_file accepts test_*.sh and test_*.py" {
  source "$LIB_FILE"

  run is_target_test_file "tests/test_stall_watchdog.sh"
  [ "$status" -eq 0 ]

  run is_target_test_file "tests/test_claude_usage_report.py"
  [ "$status" -eq 0 ]
}

# ── T-ORPH-005: is_target_test_file — "test_"始まりでない.sh(実験・比較ツール)は対象外 ──
# (bloom_classification_accuracy.sh・dim_d_quality_comparison.sh実例:
#  手動実行前提の測定ツールでbats形式の回帰テストではない・誤検知禁止)

@test "T-ORPH-005: is_target_test_file rejects non test_-prefixed scripts (measurement tools, not regression tests)" {
  source "$LIB_FILE"

  run is_target_test_file "tests/bloom_classification_accuracy.sh"
  [ "$status" -ne 0 ]

  run is_target_test_file "tests/dim_d_quality_comparison.sh"
  [ "$status" -ne 0 ]
}

# ── T-ORPH-006: is_target_test_file — test_helper/配下(vendor済みsubmodule)は対象外 ──

@test "T-ORPH-006: is_target_test_file excludes vendored tests/test_helper/ files even if named test_*.bats" {
  source "$LIB_FILE"

  run is_target_test_file "tests/test_helper/bats-assert/test/assert_equal.bats"
  [ "$status" -ne 0 ]
}

# ── T-ORPH-007: path_matches_any_pattern — globパターンは"/"を跨がない(直下限定) ──
# (bashの `[[ str == pattern ]]` はデフォルトで"*"が"/"を跨ぐため、素朴な実装だと
#  "tests/*.bats" が "tests/watcher/x.bats" のようなサブディレクトリまで誤って
#  「カバー済み」と判定してしまう。本ライブラリ実装中に実際に踏んだ回帰ガード)

@test "T-ORPH-007: path_matches_any_pattern does not let a glob pattern cross a directory boundary" {
  source "$LIB_FILE"

  run path_matches_any_pattern "tests/watcher/test_modal_and_idle.bats" "tests/*.bats"
  [ "$status" -ne 0 ]

  run path_matches_any_pattern "tests/test_inbox_write.bats" "tests/*.bats"
  [ "$status" -eq 0 ]
}

# ── T-ORPH-008: path_matches_any_pattern — ディレクトリ表記は直下のみ(非再帰) ──
# (bats本体が-r/--recursiveを明示しない限りサブディレクトリを読まない実挙動に合わせる)

@test "T-ORPH-008: path_matches_any_pattern treats a bare directory reference as non-recursive" {
  source "$LIB_FILE"

  run path_matches_any_pattern "tests/unit/foo.bats" "tests/unit/"
  [ "$status" -eq 0 ]

  run path_matches_any_pattern "tests/unit/sub/deep.bats" "tests/unit/"
  [ "$status" -ne 0 ]
}

# ── T-ORPH-009: detect_orphan_tests — 合成fixtureでend-to-end検証(カバー済み/orphan混在) ──

@test "T-ORPH-009: detect_orphan_tests flags only files not covered by any workflow pattern" {
  source "$LIB_FILE"

  local tests_dir="$BATS_TEST_TMPDIR/tests"
  mkdir -p "$tests_dir/unit" "$tests_dir/watcher" "$tests_dir/test_helper/vendor"
  : > "$tests_dir/covered_root.bats"                      # covered by tests/*.bats
  : > "$tests_dir/unit/covered_unit.bats"                  # covered by tests/unit/
  : > "$tests_dir/watcher/orphan_watcher.bats"             # NOT covered (subdir未参照)
  : > "$tests_dir/test_orphan_tool.sh"                     # test_*.sh・NOT covered
  : > "$tests_dir/not_a_test_tool.sh"                      # test_prefixでない→対象外(orphanでもない)
  : > "$tests_dir/test_helper/vendor/test_vendored.bats"   # vendor→対象外

  local wf="$BATS_TEST_TMPDIR/fake_workflow.yml"
  cat > "$wf" <<'EOF'
steps:
  - run: bats tests/*.bats --timing
  - run: bats tests/unit/ --timing
EOF

  run detect_orphan_tests "$wf" "$tests_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/watcher/orphan_watcher.bats"* ]]
  [[ "$output" == *"tests/test_orphan_tool.sh"* ]]
  [[ "$output" != *"covered_root.bats"* ]]
  [[ "$output" != *"covered_unit.bats"* ]]
  [[ "$output" != *"not_a_test_tool.sh"* ]]
  [[ "$output" != *"test_vendored.bats"* ]]
}

# ── T-ORPH-010: detect_orphan_tests — 本リポ実データでの回帰確認(subtask_ci_orphan_tests_wiringで接続済み・再発防止ガード) ──

@test "T-ORPH-010: detect_orphan_tests no longer finds the 4 tests wired in by subtask_ci_orphan_tests_wiring" {
  source "$LIB_FILE"

  run detect_orphan_tests "${PROJECT_ROOT}/.github/workflows/test.yml" "${PROJECT_ROOT}/tests"
  [ "$status" -eq 0 ]
  # 2026-09-09時点は実在orphanだったが、subtask_ci_orphan_tests_wiringで
  # .github/workflows/test.ymlへ接続済み——再びorphan化していないことを守る。
  [[ "$output" != *"tests/watcher/test_modal_and_idle.bats"* ]]
  [[ "$output" != *"tests/test_stall_watchdog.sh"* ]]
  [[ "$output" != *"tests/test_console_stall_watchdog.sh"* ]]
  [[ "$output" != *"tests/test_claude_usage_report.py"* ]]
  # false-positive guard: root-level test_inbox_write.bats IS covered by
  # `tests/*.bats` (CI/Makefile共通) ゆえ検知されてはならない
  [[ "$output" != *"tests/test_inbox_write.bats"* ]]
}

# ── T-ORPH-011: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-ORPH-011: stall_watchdog.sh sources orphan_test_detect.sh and invokes the check" {
  grep -q "orphan_test_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_orphan_tests" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "detect_orphan_tests" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}
