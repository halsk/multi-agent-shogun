#!/usr/bin/env bats
#
# tests/unit/test_ci_heartbeat_detect.bats
#
# subtask_767_771_self_ci_heartbeat: 自リポ(multi-agent-shogun)のGitHub
# Actions CI心拍検知(判定ロジックのみの単体テスト・gh api呼び出しは
# ci_heartbeat_fetchに分離済みでここでは対象外)。
#
# 殿がActions権限を許可(2026-09-06)するまでtest.ymlのrunが一度も立たなかった
# (total_count=0)件を受け、cmd_767の心拍検知と同じ考え方を自リポCIへ適用する。
# ★単独の新規監視機構ではなく、既存 scripts/stall_watchdog.sh へ相乗りする。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/ci_heartbeat_detect.sh"
}

# ── T-CIHB-001: PRが1件も無い(pr_created_epoch=0) → ok ──

@test "T-CIHB-001: ok when there is no PR to judge against" {
  source "$LIB_FILE"

  run ci_heartbeat_judge 0 0 1800 "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok|" ]]
}

# ── T-CIHB-002: 直近PRに紐付くrunが見つかった → ok ──

@test "T-CIHB-002: ok when a matching CI run was found for the latest PR" {
  source "$LIB_FILE"

  now=$(date '+%s')
  pr_created=$((now - 120))
  matched_run=$((now - 60))

  run ci_heartbeat_judge "$pr_created" "$matched_run" 1800 "$now"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok|" ]]
}

# ── T-CIHB-003: 直近PR作成後、猶予(grace_sec)内でまだrunが無い → ok(まだ判定不能・stale扱いしない) ──

@test "T-CIHB-003: ok when no matching run yet but still within grace period" {
  source "$LIB_FILE"

  now=$(date '+%s')
  pr_created=$((now - 60))

  run ci_heartbeat_judge "$pr_created" 0 1800 "$now"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok|" ]]
}

# ── T-CIHB-004: 直近PR作成からgrace_secを超えてもrunが見つからない → stale ──

@test "T-CIHB-004: stale when grace period elapsed with no matching CI run" {
  source "$LIB_FILE"

  now=$(date '+%s')
  pr_created=$((now - 3600))

  run ci_heartbeat_judge "$pr_created" 0 1800 "$now"
  [ "$status" -eq 0 ]
  [[ "$output" == stale\|* ]]
}

# ── T-CIHB-005: PR#67(実PR)のケースを実データで再現 → ok(正常系実証) ──
# PR#67作成: 2026-09-06T06:17:45Z、対応するworkflow run created_at:
# 2026-09-06T06:17:48Z(3秒後)。gh api実測値(将軍実測・2026-09-06)。

@test "T-CIHB-005: ok reproduces the real PR#67 case (run fired 3s after PR creation)" {
  source "$LIB_FILE"

  pr_created_epoch=$(_ci_iso_to_epoch "2026-09-06T06:17:45Z")
  matched_run_epoch=$(_ci_iso_to_epoch "2026-09-06T06:17:48Z")
  now_epoch=$(( pr_created_epoch + 60 ))

  [ "$pr_created_epoch" -gt 0 ]
  [ "$matched_run_epoch" -gt "$pr_created_epoch" ]

  run ci_heartbeat_judge "$pr_created_epoch" "$matched_run_epoch" 1800 "$now_epoch"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok|" ]]
}

# ── T-CIHB-006: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-CIHB-006: stall_watchdog.sh sources ci_heartbeat_detect.sh and invokes the check" {
  grep -q "ci_heartbeat_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_ci_heartbeat" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}
