#!/usr/bin/env bats
#
# tests/unit/test_report_consumption_detect.bats
#
# subtask_741_layer3_orphan_detection②: cmd_741第三層(QC report未消費検知)の
# ユニットテスト。「軍師のQC判定reportがdashboard.mdに一度も言及されないまま
# 長時間経過していないか」(実例⑤「軍師のsubtask_739のQC判定が2日間死蔵」相当)
# を検知する純関数のテスト。
#
# ★live dashboard.md/queue/reports/*.yamlを直接参照するテストは書かない
# (両ファイルとも稼働中swarmが常時更新する可変データのため、それを対象に
# assertするとテストが不安定になる)。全ケース合成fixtureで完結させる。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/report_consumption_detect.sh"
}

# ── T-RCD-001: _rcd_report_field — フラット形式の最後の出現値を返す ──

@test "T-RCD-001: _rcd_report_field extracts the field value from a flat report yaml" {
  source "$LIB_FILE"

  local f="$BATS_TEST_TMPDIR/report.yaml"
  cat > "$f" <<'EOF'
worker_id: gunshi
task_id: subtask_739_qc_review
parent_cmd: cmd_739
status: done
EOF

  run _rcd_report_field "$f" "parent_cmd"
  [ "$status" -eq 0 ]
  [ "$output" = "cmd_739" ]

  run _rcd_report_field "$f" "task_id"
  [ "$output" = "subtask_739_qc_review" ]

  run _rcd_report_field "$f" "status"
  [ "$output" = "done" ]
}

# ── T-RCD-002: _rcd_report_field — north_star_alignment配下の同名statusを誤って拾わない ──
# (lib/ledger_mismatch_detect.shの_lmd_report_fieldと同じ既知バグの回帰ガード:
#  instructions/gunshi.md必須のreportフッターがtop-level statusを上書きしない
#  ことを確認する)

@test "T-RCD-002: _rcd_report_field does not mistake north_star_alignment.status for the top-level status" {
  source "$LIB_FILE"

  local f="$BATS_TEST_TMPDIR/report.yaml"
  cat > "$f" <<'EOF'
worker_id: gunshi
task_id: subtask_739_qc_review
parent_cmd: cmd_739
status: done
north_star_alignment:
  status: aligned
EOF

  run _rcd_report_field "$f" "status"
  [ "$output" = "done" ]
}

# ── T-RCD-003/004/005: report_mentioned_in_dashboard ──

@test "T-RCD-003: report_mentioned_in_dashboard finds a parent_cmd mention" {
  source "$LIB_FILE"

  local d="$BATS_TEST_TMPDIR/dashboard.md"
  echo "## cmd_739のQC結果はGOであった" > "$d"

  run report_mentioned_in_dashboard "$d" "cmd_739" "subtask_739_qc_review"
  [ "$status" -eq 0 ]
}

@test "T-RCD-004: report_mentioned_in_dashboard finds a task_id mention" {
  source "$LIB_FILE"

  local d="$BATS_TEST_TMPDIR/dashboard.md"
  echo "subtask_739_qc_review is done" > "$d"

  run report_mentioned_in_dashboard "$d" "cmd_739" "subtask_739_qc_review"
  [ "$status" -eq 0 ]
}

@test "T-RCD-005: report_mentioned_in_dashboard returns failure when neither identifier appears" {
  source "$LIB_FILE"

  local d="$BATS_TEST_TMPDIR/dashboard.md"
  echo "全く無関係の話題" > "$d"

  run report_mentioned_in_dashboard "$d" "cmd_739" "subtask_739_qc_review"
  [ "$status" -ne 0 ]
}

# ── T-RCD-006〜009: detect_unconsumed_reports ──

_rcd_make_report() {
  local file="$1" status="$2" parent_cmd="$3" task_id="$4"
  cat > "$file" <<EOF
worker_id: gunshi
task_id: ${task_id}
parent_cmd: ${parent_cmd}
status: ${status}
EOF
}

@test "T-RCD-006: detect_unconsumed_reports skips reports whose status is not done" {
  source "$LIB_FILE"

  local reports_dir="$BATS_TEST_TMPDIR/reports"
  mkdir -p "$reports_dir"
  _rcd_make_report "$reports_dir/gunshi_report.yaml" "in_progress" "cmd_739" "subtask_739_qc_review"
  # in_progress でも古く見せる(statusで弾かれることの確認のため)
  touch -t 202001010000 "$reports_dir/gunshi_report.yaml"

  local dashboard="$BATS_TEST_TMPDIR/dashboard.md"
  echo "無関係" > "$dashboard"

  run detect_unconsumed_reports "$reports_dir" "gunshi_report.yaml" "$dashboard" 3600
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T-RCD-007: detect_unconsumed_reports skips a done report younger than the threshold (not-yet-reviewed guard)" {
  source "$LIB_FILE"

  local reports_dir="$BATS_TEST_TMPDIR/reports"
  mkdir -p "$reports_dir"
  _rcd_make_report "$reports_dir/gunshi_report.yaml" "done" "cmd_739" "subtask_739_qc_review"
  # touch = 今書かれたばかり(mtime=now)

  local dashboard="$BATS_TEST_TMPDIR/dashboard.md"
  echo "無関係" > "$dashboard"

  run detect_unconsumed_reports "$reports_dir" "gunshi_report.yaml" "$dashboard" 86400
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T-RCD-008: detect_unconsumed_reports does not flag a report already mentioned in dashboard.md" {
  source "$LIB_FILE"

  local reports_dir="$BATS_TEST_TMPDIR/reports"
  mkdir -p "$reports_dir"
  _rcd_make_report "$reports_dir/gunshi_report.yaml" "done" "cmd_739" "subtask_739_qc_review"
  touch -t 202001010000 "$reports_dir/gunshi_report.yaml"

  local dashboard="$BATS_TEST_TMPDIR/dashboard.md"
  echo "cmd_739のQCはGO" > "$dashboard"

  run detect_unconsumed_reports "$reports_dir" "gunshi_report.yaml" "$dashboard" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T-RCD-009: detect_unconsumed_reports flags an old done report never mentioned in dashboard.md (subtask_739-like)" {
  source "$LIB_FILE"

  local reports_dir="$BATS_TEST_TMPDIR/reports"
  mkdir -p "$reports_dir"
  _rcd_make_report "$reports_dir/gunshi_report.yaml" "done" "cmd_739" "subtask_739_qc_review"
  touch -t 202001010000 "$reports_dir/gunshi_report.yaml"

  local dashboard="$BATS_TEST_TMPDIR/dashboard.md"
  echo "全く無関係の話題" > "$dashboard"

  run detect_unconsumed_reports "$reports_dir" "gunshi_report.yaml" "$dashboard" 0
  [ "$status" -eq 0 ]
  [[ "$output" == "gunshi|cmd_739|subtask_739_qc_review|${reports_dir}/gunshi_report.yaml"* ]]
}

@test "T-RCD-010: detect_unconsumed_reports skips reports with neither parent_cmd nor task_id (no correlation material)" {
  source "$LIB_FILE"

  local reports_dir="$BATS_TEST_TMPDIR/reports"
  mkdir -p "$reports_dir"
  cat > "$reports_dir/gunshi_report.yaml" <<'EOF'
worker_id: gunshi
status: done
EOF
  touch -t 202001010000 "$reports_dir/gunshi_report.yaml"

  local dashboard="$BATS_TEST_TMPDIR/dashboard.md"
  echo "無関係" > "$dashboard"

  run detect_unconsumed_reports "$reports_dir" "gunshi_report.yaml" "$dashboard" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-RCD-011: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-RCD-011: stall_watchdog.sh sources report_consumption_detect.sh and invokes the check" {
  grep -q "report_consumption_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_unconsumed_reports" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "detect_unconsumed_reports" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}
