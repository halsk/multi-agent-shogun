#!/usr/bin/env bats
#
# tests/unit/test_heartbeat_detect.bats
#
# cmd_767 第一層(心拍): 定期ジョブの last-run.json を読み、実行が止まって
# いる/失敗しているものを検知する純関数のユニットテスト。
#
# meeting-link sweep が2026-08-25〜09-05の13日間、一度も完走しなかったのに
# 誰も気づけなかった件(修理=cmd_749/PR#151)を受け、「なぜ気づけなかったか」
# を仕組みで塞ぐための検知層。★単独の新規監視機構ではなく、既存
# scripts/stall_watchdog.sh (cmd_766/771の相乗り作法と同じ)へ相乗りする。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/heartbeat_detect.sh"

  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/heartbeat_detect.XXXXXX")"
}

teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

write_last_run() {
  local file="$1" run_id="$2" end_iso="$3" exit_code="$4"
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<JSON
{
  "run_id": "${run_id}",
  "start": "${end_iso}",
  "end": "${end_iso}",
  "duration_s": 10,
  "exit": ${exit_code}
}
JSON
}

# ── T-HB-001: 正常(exit=0・許容時間内) → ok ──

@test "T-HB-001: ok when last run succeeded within max_interval" {
  source "$LIB_FILE"

  local_now=$(date '+%s')
  end_iso=$(date -j -f '%s' "$((local_now - 60))" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$((local_now - 60))" '+%Y-%m-%dT%H:%M:%S%z')
  write_last_run "${TMP_DIR}/ok-last-run.json" "run1" "$end_iso" 0

  run heartbeat_check_one "${TMP_DIR}/ok-last-run.json" 3600 "$local_now"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok|" ]]
}

# ── T-HB-002: last-run.json が存在しない → stale ──

@test "T-HB-002: stale when last-run.json is missing" {
  source "$LIB_FILE"

  run heartbeat_check_one "${TMP_DIR}/does-not-exist-last-run.json" 3600 "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ "$output" == stale\|* ]]
}

# ── T-HB-003: last-run.json はあるが max_interval を超えて経過 → stale ──

@test "T-HB-003: stale when last run is older than max_interval (job itself stopped running)" {
  source "$LIB_FILE"

  local_now=$(date '+%s')
  old_iso=$(date -j -f '%s' "$((local_now - 200000))" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$((local_now - 200000))" '+%Y-%m-%dT%H:%M:%S%z')
  write_last_run "${TMP_DIR}/stale-last-run.json" "run2" "$old_iso" 0

  run heartbeat_check_one "${TMP_DIR}/stale-last-run.json" 3600 "$local_now"
  [ "$status" -eq 0 ]
  [[ "$output" == stale\|* ]]
}

# ── T-HB-004: last-run.json の exit が非0 → fail(stale と区別する) ──

@test "T-HB-004: fail (not stale) when last run has non-zero exit code" {
  source "$LIB_FILE"

  local_now=$(date '+%s')
  end_iso=$(date -j -f '%s' "$((local_now - 60))" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$((local_now - 60))" '+%Y-%m-%dT%H:%M:%S%z')
  write_last_run "${TMP_DIR}/fail-last-run.json" "run3" "$end_iso" 1

  run heartbeat_check_one "${TMP_DIR}/fail-last-run.json" 3600 "$local_now"
  [ "$status" -eq 0 ]
  [[ "$output" == fail\|* ]]
  [[ "$output" == *"exit=1"* ]]
}

# ── T-HB-005: detect_stale_heartbeats — レジストリ複数行のうちokは列挙されず
# stale/failのみ列挙される ──

@test "T-HB-005: detect_stale_heartbeats lists only non-ok jobs from a multi-line registry" {
  source "$LIB_FILE"

  local_now=$(date '+%s')
  ok_iso=$(date -j -f '%s' "$((local_now - 60))" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$((local_now - 60))" '+%Y-%m-%dT%H:%M:%S%z')
  write_last_run "${TMP_DIR}/job-ok-last-run.json" "run-ok" "$ok_iso" 0
  write_last_run "${TMP_DIR}/job-fail-last-run.json" "run-fail" "$ok_iso" 1

  registry=$'job-ok|'"${TMP_DIR}/job-ok-last-run.json"$'|3600\njob-fail|'"${TMP_DIR}/job-fail-last-run.json"$'|3600\njob-missing|'"${TMP_DIR}/job-missing-last-run.json"$'|3600'

  run detect_stale_heartbeats "$registry" "$local_now"
  [ "$status" -eq 0 ]
  [[ "$output" != *"job-ok|"* ]]
  [[ "$output" == *"job-fail|fail|"* ]]
  [[ "$output" == *"job-missing|stale|"* ]]
}

# ── T-HB-006: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-HB-006: stall_watchdog.sh sources heartbeat_detect.sh and invokes the check" {
  grep -q "heartbeat_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_heartbeats|detect_stale_heartbeats" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}
