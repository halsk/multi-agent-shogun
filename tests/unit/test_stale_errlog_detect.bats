#!/usr/bin/env bats
#
# tests/unit/test_stale_errlog_detect.bats
#
# cmd_786/787 相乗り: 常駐ジョブの StandardErrorPath が非空のまま長期間
# 触れられていない(=誰も確認していない疑い)ことを検知する純関数のユニットテスト。
#
# logs/stall_watchdog.err.log に "md5sum: command not found" が4件残ったまま
# 最終更新2026-06-29から2ヶ月以上放置された実例(バグ自体は06-30に修理済み)を
# 受け、「検知が無かったのではなく、出ている声を聞く仕組みが無かった」を
# 埋めるための検知層。★既存 scripts/stall_watchdog.sh
# (lib/heartbeat_detect.sh と同じ相乗り作法)へ相乗りする。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/stale_errlog_detect.sh"

  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/stale_errlog_detect.XXXXXX")"
}

teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

touch_with_mtime() {
  local file="$1" age_sec="$2" now="$3"
  local target=$(( now - age_sec ))
  local ts
  ts=$(date -j -f '%s' "$target" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$target" '+%Y%m%d%H%M.%S')
  touch -t "$ts" "$file"
}

# ── T-ERR-001: ファイルが存在しない → ok ──

@test "T-ERR-001: ok when the err log file does not exist" {
  source "$LIB_FILE"

  run errlog_check_one "${TMP_DIR}/does-not-exist.err.log" 259200 "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok|" ]]
}

# ── T-ERR-002: 空ファイル → ok(非空条件を満たさない) ──

@test "T-ERR-002: ok when the err log file is empty" {
  source "$LIB_FILE"
  : > "${TMP_DIR}/empty.err.log"

  run errlog_check_one "${TMP_DIR}/empty.err.log" 259200 "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok|" ]]
}

# ── T-ERR-003: 非空だが最終更新が許容内 → ok ──

@test "T-ERR-003: ok when non-empty but recently modified (within max_age)" {
  source "$LIB_FILE"
  local_now=$(date '+%s')
  echo "some error" > "${TMP_DIR}/recent.err.log"
  touch_with_mtime "${TMP_DIR}/recent.err.log" 3600 "$local_now"

  run errlog_check_one "${TMP_DIR}/recent.err.log" 259200 "$local_now"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok|" ]]
}

# ── T-ERR-004: 非空 かつ max_age を超えて未更新 → stale ──

@test "T-ERR-004: stale when non-empty and untouched beyond max_age (the actual incident)" {
  source "$LIB_FILE"
  local_now=$(date '+%s')
  echo "md5sum: command not found" > "${TMP_DIR}/stale.err.log"
  # 72日放置(実インシデントの2ヶ月超相当)を再現
  touch_with_mtime "${TMP_DIR}/stale.err.log" $((72 * 86400)) "$local_now"

  run errlog_check_one "${TMP_DIR}/stale.err.log" 259200 "$local_now"
  [ "$status" -eq 0 ]
  [[ "$output" == stale\|* ]]
  [[ "$output" == *"72日"* ]]
}

# ── T-ERR-005: detect_stale_errlogs — レジストリ複数行のうちokは列挙されず
# staleのみ列挙される ──

@test "T-ERR-005: detect_stale_errlogs lists only stale jobs from a multi-line registry" {
  source "$LIB_FILE"
  local_now=$(date '+%s')
  echo "err" > "${TMP_DIR}/job-ok.err.log"
  touch_with_mtime "${TMP_DIR}/job-ok.err.log" 3600 "$local_now"
  echo "err" > "${TMP_DIR}/job-stale.err.log"
  touch_with_mtime "${TMP_DIR}/job-stale.err.log" $((10 * 86400)) "$local_now"

  registry=$'job-ok|'"${TMP_DIR}/job-ok.err.log"$'|259200|\njob-stale|'"${TMP_DIR}/job-stale.err.log"$'|259200|\njob-missing|'"${TMP_DIR}/job-missing.err.log"$'|259200|'

  run detect_stale_errlogs "$registry" "$local_now"
  [ "$status" -eq 0 ]
  [[ "$output" != *"job-ok|"* ]]
  [[ "$output" != *"job-missing|"* ]]
  [[ "$output" == *"job-stale|stale|"* ]]
}

# ── T-ERR-006: 期限付き除外(excluded_until) — 期限内は無視される ──

@test "T-ERR-006: excluded_until in the future suppresses an otherwise-stale entry" {
  source "$LIB_FILE"
  local_now=$(date '+%s')
  echo "err" > "${TMP_DIR}/job-excluded.err.log"
  touch_with_mtime "${TMP_DIR}/job-excluded.err.log" $((10 * 86400)) "$local_now"

  future_date=$(date -j -f '%s' "$((local_now + 5 * 86400))" '+%Y-%m-%d' 2>/dev/null || date -d "@$((local_now + 5 * 86400))" '+%Y-%m-%d')
  registry="job-excluded|${TMP_DIR}/job-excluded.err.log|259200|${future_date}"

  run detect_stale_errlogs "$registry" "$local_now"
  [ "$status" -eq 0 ]
  [[ "$output" != *"job-excluded"* ]]
}

# ── T-ERR-007: 期限付き除外 — 期限が過ぎたら自動的に再浮上する(cmd_787⑩・
# 「登録して忘れる」の温床にしない) ──

@test "T-ERR-007: excluded_until in the past auto-resurfaces the stale entry" {
  source "$LIB_FILE"
  local_now=$(date '+%s')
  echo "err" > "${TMP_DIR}/job-expired-exclude.err.log"
  touch_with_mtime "${TMP_DIR}/job-expired-exclude.err.log" $((10 * 86400)) "$local_now"

  past_date=$(date -j -f '%s' "$((local_now - 5 * 86400))" '+%Y-%m-%d' 2>/dev/null || date -d "@$((local_now - 5 * 86400))" '+%Y-%m-%d')
  registry="job-expired-exclude|${TMP_DIR}/job-expired-exclude.err.log|259200|${past_date}"

  run detect_stale_errlogs "$registry" "$local_now"
  [ "$status" -eq 0 ]
  [[ "$output" == *"job-expired-exclude|stale|"* ]]
}

# ── T-ERR-008: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-ERR-008: stall_watchdog.sh sources stale_errlog_detect.sh and invokes the check" {
  grep -q "stale_errlog_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_stale_errlogs|detect_stale_errlogs" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}
