#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# tests/unit/test_deadman_switch_hc_ping.bats
#
# cmd_880: deadman_switch.sh の Healthchecks.io ping 配線テスト。
# deadman_switch.sh は launchd から直接起動され専用ラッパーを持たないため、
# Keychain取得+curl送信の両方を本体スクリプト内で行う。
# yaml_slim_weekly.sh / yaml-slim-launcher.sh の既存テスト(T-YS-*)と同じ
# stub curl / stub get-secret.sh パターンに倣う。
#
# Cases:
#   T-DMHC-001: HC_PING_URL_DEADMAN 設定時 → scan完了後にcurlが呼ばれる
#   T-DMHC-002: HC_PING_URL_DEADMAN 空      → curlは呼ばれない (no-op)
#   T-DMHC-003: DEADMAN_GET_SECRET経由でKeychainから注入される
#   T-DMHC-004: Keychainミス時は空のまま続行する(abortしない)
#   T-DMHC-005: get_secretがhangしてもtimeoutで有限時間に収まる

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SCRIPT="${PROJECT_ROOT}/scripts/deadman_switch.sh"

  export MOCK_BIN
  MOCK_BIN="$(mktemp -d "$BATS_TMPDIR/mock_bin.XXXXXX")"
  export CALLS_LOG
  CALLS_LOG="$(mktemp "$BATS_TMPDIR/curl_calls.XXXXXX")"
  cat > "${MOCK_BIN}/curl" << MOCK_CURL
#!/usr/bin/env bash
echo "CURL_CALLED: \$*" >> "${CALLS_LOG}"
exit 0
MOCK_CURL
  chmod +x "${MOCK_BIN}/curl"

  export TMP_DIR
  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/deadman_hc.XXXXXX")"
  mkdir -p "$TMP_DIR/tasks" "$TMP_DIR/state"

  export NTFY_STUB="$TMP_DIR/ntfy_stub.sh"
  cat > "$NTFY_STUB" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$NTFY_STUB"

  export INBOX_WRITE_STUB="$TMP_DIR/inbox_write_stub.sh"
  cat > "$INBOX_WRITE_STUB" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$INBOX_WRITE_STUB"

  export DEADMAN_TASKS_DIR="$TMP_DIR/tasks"
  export DEADMAN_DASHBOARD="$TMP_DIR/dashboard.md"
  export DEADMAN_STATE_DIR="$TMP_DIR/state"
  export DEADMAN_LOG_FILE="$TMP_DIR/log.log"
  export DEADMAN_LIVENESS_FILE="$TMP_DIR/liveness"
  export DEADMAN_NTFY_SCRIPT="$NTFY_STUB"
  export DEADMAN_INBOX_WRITE_SCRIPT="$INBOX_WRITE_STUB"
  export DEADMAN_KARO_INBOX="$TMP_DIR/karo_inbox.yaml"
  export DEADMAN_SHOGUN_INBOX="$TMP_DIR/shogun_inbox.yaml"
  # 判定不能ガード(file_count=0 && stalled=0 → exit 1)を回避するため、
  # 停止していない正常taskを1件置く(scanが正常完了しheartbeat以降へ到達する条件)。
  cat > "$TMP_DIR/tasks/ashigaru1.yaml" << 'T'
task:
  status: done
T
}

teardown() {
  rm -rf "$MOCK_BIN" "$CALLS_LOG" "$TMP_DIR" 2>/dev/null || true
}

@test "T-DMHC-001: deadman_switch.sh calls curl when HC_PING_URL_DEADMAN is set" {
  run env PATH="${MOCK_BIN}:${PATH}" \
    HC_PING_URL_DEADMAN="http://localhost:8000/ping/test-uuid-dmhc001" \
    bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "CURL_CALLED: -fsS -m 5 --retry 2 http://localhost:8000/ping/test-uuid-dmhc001" "$CALLS_LOG"
}

@test "T-DMHC-002: deadman_switch.sh skips curl when HC_PING_URL_DEADMAN is empty" {
  run env PATH="${MOCK_BIN}:${PATH}" \
    HC_PING_URL_DEADMAN="" \
    bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run ! grep -q "CURL_CALLED" "$CALLS_LOG"
}

@test "T-DMHC-003: deadman_switch.sh injects HC_PING_URL_DEADMAN from Keychain (DEADMAN_GET_SECRET)" {
  local mock_gs="$TMP_DIR/get-secret.sh"
  cat > "$mock_gs" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  local key="$1"
  if [[ "$key" == "hc-ping-url-deadman" ]]; then
    echo "http://localhost:8000/ping/mock-uuid-dmhc003"
    return 0
  fi
  return 1
}
MOCK_GS

  run env PATH="${MOCK_BIN}:${PATH}" \
    DEADMAN_GET_SECRET="$mock_gs" \
    bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "CURL_CALLED: -fsS -m 5 --retry 2 http://localhost:8000/ping/mock-uuid-dmhc003" "$CALLS_LOG"
}

@test "T-DMHC-004: deadman_switch.sh continues (no abort) on Keychain miss" {
  local mock_gs="$TMP_DIR/get-secret.sh"
  cat > "$mock_gs" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  return 1
}
MOCK_GS

  run env PATH="${MOCK_BIN}:${PATH}" \
    DEADMAN_GET_SECRET="$mock_gs" \
    bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run ! grep -q "CURL_CALLED" "$CALLS_LOG"
}

@test "T-DMHC-005: deadman_switch.sh does not hang forever when get_secret hangs" {
  command -v timeout &>/dev/null || command -v gtimeout &>/dev/null \
    || skip "timeout/gtimeout not available on this host"

  local mock_gs="$TMP_DIR/get-secret.sh"
  cat > "$mock_gs" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  sleep 999
}
MOCK_GS

  local start end elapsed
  start=$(date '+%s')
  run env PATH="${MOCK_BIN}:${PATH}" DEADMAN_GET_SECRET="$mock_gs" timeout 15 bash "$SCRIPT"
  end=$(date '+%s')
  elapsed=$(( end - start ))

  [ "$status" -eq 0 ]
  run ! grep -q "CURL_CALLED" "$CALLS_LOG"
  [ "$elapsed" -lt 10 ]
}
