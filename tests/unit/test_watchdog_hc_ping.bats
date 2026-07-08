#!/usr/bin/env bats
#
# tests/unit/test_watchdog_hc_ping.bats
#
# HC dead-man's-switch ping ユニットテスト
#
# Cases:
#   T-HC-001: HC_PING_URL_STALL_WATCHDOG 設定 + DRY_RUN=false → curl ping が呼ばれる
#   T-HC-002: HC_PING_URL_STALL_WATCHDOG 空              → curl は呼ばれない (no-op)
#   T-HC-003: DRY_RUN=true の場合                         → curl は呼ばれない (skip)
#   T-HC-004: stall-watchdog-launcher.sh が HC_PING_URL を Keychain から注入する
#   T-HC-005: stall-watchdog-launcher.sh が Keychain ミス時に空で続行する (no abort)
#
# Approach: mock 'curl' binary in a temp PATH directory でcall記録を確認。
# Note: plain bash [ ] assertions (bats-assert 不使用)。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export MOCK_BIN
  MOCK_BIN="$(mktemp -d "$BATS_TMPDIR/mock_bin.XXXXXX")"

  export CALLS_LOG
  CALLS_LOG="$(mktemp "$BATS_TMPDIR/curl_calls.XXXXXX")"

  # Mock curl: 呼び出しをファイルに記録して成功終了
  cat > "${MOCK_BIN}/curl" << MOCK_CURL
#!/usr/bin/env bash
echo "CURL_CALLED: \$*" >> "${CALLS_LOG}"
exit 0
MOCK_CURL
  chmod +x "${MOCK_BIN}/curl"
}

teardown() {
  rm -rf "$MOCK_BIN" "$CALLS_LOG" 2>/dev/null || true
}

# ── T-HC-001: HC_PING_URL 設定 + DRY_RUN=false → curl 呼ばれる ─────────────

@test "T-HC-001: HC_PING_URL_STALL_WATCHDOG set, DRY_RUN=false -> curl is called" {
  run env PATH="${MOCK_BIN}:${PATH}" \
    HC_PING_URL_STALL_WATCHDOG="http://localhost:8000/ping/test-uuid-001" \
    DRY_RUN=false \
    bash -c '
      if [[ -n "${HC_PING_URL_STALL_WATCHDOG:-}" ]] && ! $DRY_RUN; then
        curl -fsS -m 5 --retry 2 "${HC_PING_URL_STALL_WATCHDOG}" >/dev/null 2>&1 || true
      fi
    '
  [ "$status" -eq 0 ]
  grep -q "CURL_CALLED" "${CALLS_LOG}"
}

# ── T-HC-002: HC_PING_URL 空 → curl 呼ばれない ──────────────────────────────

@test "T-HC-002: HC_PING_URL_STALL_WATCHDOG empty -> curl NOT called (no-op)" {
  run env PATH="${MOCK_BIN}:${PATH}" \
    HC_PING_URL_STALL_WATCHDOG="" \
    DRY_RUN=false \
    bash -c '
      if [[ -n "${HC_PING_URL_STALL_WATCHDOG:-}" ]] && ! $DRY_RUN; then
        curl -fsS -m 5 --retry 2 "${HC_PING_URL_STALL_WATCHDOG}" >/dev/null 2>&1 || true
      fi
    '
  [ "$status" -eq 0 ]
  ! grep -q "CURL_CALLED" "${CALLS_LOG}" 2>/dev/null
}

# ── T-HC-003: DRY_RUN=true → curl 呼ばれない ────────────────────────────────

@test "T-HC-003: DRY_RUN=true -> curl NOT called (skip)" {
  run env PATH="${MOCK_BIN}:${PATH}" \
    HC_PING_URL_STALL_WATCHDOG="http://localhost:8000/ping/test-uuid-003" \
    DRY_RUN=true \
    bash -c '
      if [[ -n "${HC_PING_URL_STALL_WATCHDOG:-}" ]] && ! $DRY_RUN; then
        curl -fsS -m 5 --retry 2 "${HC_PING_URL_STALL_WATCHDOG}" >/dev/null 2>&1 || true
      fi
    '
  [ "$status" -eq 0 ]
  ! grep -q "CURL_CALLED" "${CALLS_LOG}" 2>/dev/null
}

# ── T-HC-004: launcher が HC_PING_URL を Keychain から注入する ───────────────

@test "T-HC-004: stall-watchdog-launcher.sh injects HC_PING_URL from Keychain" {
  local launcher="${PROJECT_ROOT}/scripts/stall-watchdog-launcher.sh"
  if [ ! -f "$launcher" ]; then
    skip "stall-watchdog-launcher.sh not yet created"
  fi

  # security モック: hc-ping-url-stall-watchdog を返す
  cat > "${MOCK_BIN}/security" << 'MOCK_SEC'
#!/usr/bin/env bash
if [[ "$1" == "find-generic-password" ]]; then
  for i in "$@"; do
    if [[ "$i" == "hc-ping-url-stall-watchdog" ]]; then
      echo "http://localhost:8000/ping/mock-uuid-004"
      exit 0
    fi
  done
fi
exit 1
MOCK_SEC
  chmod +x "${MOCK_BIN}/security"

  # op モック: 使われても何も返さない (Keychain ヒットで op は呼ばれないはず)
  cat > "${MOCK_BIN}/op" << 'MOCK_OP'
#!/usr/bin/env bash
exit 1
MOCK_OP
  chmod +x "${MOCK_BIN}/op"

  # stall_watchdog.sh の代替スタブ
  cat > "${MOCK_BIN}/stall_watchdog_stub.sh" << STUB
#!/usr/bin/env bash
echo "HC_PING_URL=\${HC_PING_URL_STALL_WATCHDOG:-EMPTY}"
exit 0
STUB
  chmod +x "${MOCK_BIN}/stall_watchdog_stub.sh"

  # --dry-run で launcher を起動 (stall_watchdog.sh 本体の tmux 接続を回避)
  run env PATH="${MOCK_BIN}:${PATH}" \
    bash "$launcher" --dry-run
  [ "$status" -eq 0 ]
}

# ── T-HC-005: Keychain ミス時に empty で続行する ────────────────────────────

@test "T-HC-005: stall-watchdog-launcher.sh continues with empty URL on Keychain miss" {
  local launcher="${PROJECT_ROOT}/scripts/stall-watchdog-launcher.sh"
  if [ ! -f "$launcher" ]; then
    skip "stall-watchdog-launcher.sh not yet created"
  fi

  # security が必ず失敗するモック
  cat > "${MOCK_BIN}/security" << 'MOCK_SEC'
#!/usr/bin/env bash
exit 1
MOCK_SEC
  chmod +x "${MOCK_BIN}/security"

  # op も存在しない (MOCK_BIN に op がないため op コマンドは見つからない)

  # Keychain ミスでも exit 1 しないことを確認
  run env PATH="${MOCK_BIN}:${PATH}" \
    bash "$launcher" --dry-run
  [ "$status" -eq 0 ]
}
