#!/usr/bin/env bats
# tests/unit/test_run_log.bats — lib/run_log.sh の検証 (cmd_767)
#
# halsk/automation scripts/lib/run-log.sh からの移植版。定期ジョブ共通の
# ログ規約(run_id境界+last-run.json+rotation)を本リポジトリ内の定期ジョブ
# (console_stall_watchdog.sh・n8n_inbox_relay.sh 等)でも使えるようにする。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/run_log.sh"

  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/run_log.XXXXXX")"
  LOG_DIR="${TMP_DIR}/logs/testjob"
  STATUS_FILE="${TMP_DIR}/logs/testjob-last-run.json"
}

teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

@test "A: run_log_new_id — 連続呼出しでも一意なIDを返す" {
  run bash -c "source '${LIB_FILE}' && id1=\$(run_log_new_id); id2=\$(run_log_new_id); [ \"\$id1\" != \"\$id2\" ] && echo ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "B: run_log_start — ログディレクトリ・ファイルを作成しSTART境界を書く" {
  run bash -c "source '${LIB_FILE}' && run_log_start '${LOG_DIR}' 'testrun1' 'testjob'"
  [ "$status" -eq 0 ]
  LOG_FILE="$output"
  [ -f "${LOG_FILE}" ]
  [[ "${LOG_FILE}" == *"testjob-testrun1.log" ]]
  grep -q "=== RUN testrun1 START" "${LOG_FILE}"
}

@test "C: run_log_end — END境界(run_id/exit/duration)を追記する" {
  LOG_FILE="$(bash -c "source '${LIB_FILE}' && run_log_start '${LOG_DIR}' 'testrun2' 'testjob'")"
  START_EPOCH="$(( $(date '+%s') - 5 ))"
  run bash -c "source '${LIB_FILE}' && run_log_end '${LOG_FILE}' 'testrun2' '${START_EPOCH}' 0"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  grep -q "=== RUN testrun2 END" "${LOG_FILE}"
  grep -q "exit=0" "${LOG_FILE}"
}

@test "D: run_log_write_last_run — 必須キーを持つJSONを書く" {
  run bash -c "source '${LIB_FILE}' && run_log_write_last_run '${STATUS_FILE}' 'testrun3' '2026-09-06T09:00:00+0900' '2026-09-06T09:06:00+0900' '360' '0'"
  [ "$status" -eq 0 ]
  [ -f "${STATUS_FILE}" ]
  grep -q '"run_id": "testrun3"' "${STATUS_FILE}"
  grep -q '"duration_s": 360' "${STATUS_FILE}"
  grep -q '"exit": 0' "${STATUS_FILE}"
}

@test "E: 2回連続実行 — last-run.jsonは常に最新実行を指す" {
  bash -c "
    source '${LIB_FILE}'
    log1=\$(run_log_start '${LOG_DIR}' '20260906T090000-1' 'testjob')
    run_log_end \"\$log1\" '20260906T090000-1' \$(( \$(date +%s) - 10 )) 0 >/dev/null
    run_log_write_last_run '${STATUS_FILE}' '20260906T090000-1' 'start1' 'end1' '10' '0'
  "
  bash -c "
    source '${LIB_FILE}'
    log2=\$(run_log_start '${LOG_DIR}' '20260906T090100-2' 'testjob')
    run_log_end \"\$log2\" '20260906T090100-2' \$(( \$(date +%s) - 3 )) 0 >/dev/null
    run_log_write_last_run '${STATUS_FILE}' '20260906T090100-2' 'start2' 'end2' '3' '0'
  "
  grep -q '"run_id": "20260906T090100-2"' "${STATUS_FILE}"
  ! grep -q '"run_id": "20260906T090000-1"' "${STATUS_FILE}"
}

@test "F: run_log_rotate — 保持数超過分は削除でなくarchiveへ退避される" {
  mkdir -p "${LOG_DIR}"
  for i in 1 2 3 4 5; do
    echo "dummy" > "${LOG_DIR}/testjob-2026090${i}T000000-${i}.log"
  done
  run bash -c "source '${LIB_FILE}' && run_log_rotate '${LOG_DIR}' 2"
  [ "$status" -eq 0 ]
  local_count="$(find "${LOG_DIR}" -maxdepth 1 -name '*.log' | wc -l | tr -d ' ')"
  [ "${local_count}" = "2" ]
  [ -f "${LOG_DIR}/archive/testjob-20260901T000000-1.log" ]
  grep -q "dummy" "${LOG_DIR}/archive/testjob-20260901T000000-1.log"
}

@test "G: run_log_write_last_run — 呼出し毎に上書きされ追記累積しない" {
  bash -c "source '${LIB_FILE}' && run_log_write_last_run '${STATUS_FILE}' 'first' 's1' 'e1' '1' '0'"
  bash -c "source '${LIB_FILE}' && run_log_write_last_run '${STATUS_FILE}' 'second' 's2' 'e2' '2' '0'"
  [ "$(grep -c '"run_id"' "${STATUS_FILE}")" = "1" ]
  grep -q '"run_id": "second"' "${STATUS_FILE}"
}
