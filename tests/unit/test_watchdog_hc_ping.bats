#!/usr/bin/env bats
#
# tests/unit/test_watchdog_hc_ping.bats
#
# HC dead-man's-switch ping ユニットテスト
#
# Cases:
#   T-HC-001: HC_PING_URL_STALL_WATCHDOG 設定 + no --dry-run → 実スクリプトから curl が呼ばれる
#   T-HC-002: HC_PING_URL_STALL_WATCHDOG 空              → curl は呼ばれない (no-op)
#   T-HC-003: --dry-run 指定                              → curl は呼ばれない
#   T-HC-004: stall-watchdog-launcher.sh が HC_PING_URL を Keychain から注入する
#   T-HC-005: stall-watchdog-launcher.sh が Keychain ミス時に空で続行する (no abort)
#
# Approach:
#   T-HC-001/002/003: 実 stall_watchdog.sh を起動。tmux/flock/curl をモック。
#     - tmux モック: list-panes が空を返す → 全 pane 解決が空 → 全エージェントスキップ
#     - flock モック: 常に成功 → ロック競合なく scan 完了
#     - curl モック: 呼出を CALLS_LOG に記録
#   T-HC-004/005: temp project copy でランチャーを動かし stall_watchdog.sh スタブに
#     HC_PING_URL_STALL_WATCHDOG が注入されているか確認。

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

  # Mock tmux: list-panes は空を返す (全エージェントの pane 解決をスキップさせる)
  cat > "${MOCK_BIN}/tmux" << 'MOCK_TMUX'
#!/usr/bin/env bash
exit 0
MOCK_TMUX
  chmod +x "${MOCK_BIN}/tmux"

  # Mock flock: 常に成功 (ロック競合防止・タイミング依存除去)
  cat > "${MOCK_BIN}/flock" << 'MOCK_FLOCK'
#!/usr/bin/env bash
exit 0
MOCK_FLOCK
  chmod +x "${MOCK_BIN}/flock"
}

teardown() {
  rm -rf "$MOCK_BIN" "$CALLS_LOG" 2>/dev/null || true
}

# ── T-HC-001: HC_PING_URL 設定 → 実 stall_watchdog.sh から curl が呼ばれる ──

@test "T-HC-001: stall_watchdog.sh calls curl when HC_PING_URL_STALL_WATCHDOG is set" {
  local watchdog="${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  [ -f "$watchdog" ] || { echo "stall_watchdog.sh not found at $watchdog"; return 1; }

  run env PATH="${MOCK_BIN}:${PATH}" \
    HC_PING_URL_STALL_WATCHDOG="http://localhost:8000/ping/test-uuid-001" \
    bash "$watchdog"
  [ "$status" -eq 0 ]
  grep -q "CURL_CALLED" "${CALLS_LOG}"
}

# ── T-HC-002: HC_PING_URL 空 → 実 stall_watchdog.sh から curl 呼ばれない ─────

@test "T-HC-002: stall_watchdog.sh skips curl when HC_PING_URL_STALL_WATCHDOG is empty" {
  local watchdog="${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  [ -f "$watchdog" ] || { echo "stall_watchdog.sh not found at $watchdog"; return 1; }

  run env PATH="${MOCK_BIN}:${PATH}" \
    HC_PING_URL_STALL_WATCHDOG="" \
    bash "$watchdog"
  [ "$status" -eq 0 ]
  ! grep -q "CURL_CALLED" "${CALLS_LOG}" 2>/dev/null
}

# ── T-HC-003: --dry-run → 実 stall_watchdog.sh から curl 呼ばれない ──────────

@test "T-HC-003: stall_watchdog.sh skips curl under --dry-run even with HC_PING_URL set" {
  local watchdog="${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  [ -f "$watchdog" ] || { echo "stall_watchdog.sh not found at $watchdog"; return 1; }

  run env PATH="${MOCK_BIN}:${PATH}" \
    HC_PING_URL_STALL_WATCHDOG="http://localhost:8000/ping/test-uuid-003" \
    bash "$watchdog" --dry-run
  [ "$status" -eq 0 ]
  ! grep -q "CURL_CALLED" "${CALLS_LOG}" 2>/dev/null
}

# ── T-HC-004: launcher が HC_PING_URL を Keychain から注入する ───────────────

@test "T-HC-004: stall-watchdog-launcher.sh injects HC_PING_URL from Keychain into watchdog env" {
  local launcher="${PROJECT_ROOT}/scripts/stall-watchdog-launcher.sh"
  [ -f "$launcher" ] || { echo "stall-watchdog-launcher.sh not found at $launcher"; return 1; }

  # temp project copy: launcher はここからスクリプト相対パスで get-secret.sh と stall_watchdog.sh を解決する
  local proj_copy
  proj_copy="$(mktemp -d "$BATS_TMPDIR/proj_copy.XXXXXX")"
  mkdir -p "$proj_copy/scripts"
  cp "$launcher" "$proj_copy/scripts/stall-watchdog-launcher.sh"

  # stub stall_watchdog.sh: HC_PING_URL 環境変数を出力して終了
  cat > "$proj_copy/scripts/stall_watchdog.sh" << 'STUB'
#!/usr/bin/env bash
echo "HC_PING_URL=${HC_PING_URL_STALL_WATCHDOG:-EMPTY}"
exit 0
STUB
  chmod +x "$proj_copy/scripts/stall_watchdog.sh"

  # mock get-secret.sh: hc-ping-url-stall-watchdog キーを返す
  cat > "$proj_copy/scripts/get-secret.sh" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  local key="$1"
  if [[ "$key" == "hc-ping-url-stall-watchdog" ]]; then
    echo "http://localhost:8000/ping/mock-uuid-004"
    return 0
  fi
  return 1
}
MOCK_GS

  run env PATH="${MOCK_BIN}:${PATH}" \
    bash "$proj_copy/scripts/stall-watchdog-launcher.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HC_PING_URL=http://localhost:8000/ping/mock-uuid-004"* ]]

  rm -rf "$proj_copy"
}

# ── T-HC-005: Keychain ミス時に empty で続行する ────────────────────────────

@test "T-HC-005: stall-watchdog-launcher.sh continues with empty URL on Keychain miss" {
  local launcher="${PROJECT_ROOT}/scripts/stall-watchdog-launcher.sh"
  [ -f "$launcher" ] || { echo "stall-watchdog-launcher.sh not found at $launcher"; return 1; }

  local proj_copy
  proj_copy="$(mktemp -d "$BATS_TMPDIR/proj_copy.XXXXXX")"
  mkdir -p "$proj_copy/scripts"
  cp "$launcher" "$proj_copy/scripts/stall-watchdog-launcher.sh"

  # stub stall_watchdog.sh
  cat > "$proj_copy/scripts/stall_watchdog.sh" << 'STUB'
#!/usr/bin/env bash
echo "HC_PING_URL=${HC_PING_URL_STALL_WATCHDOG:-EMPTY}"
exit 0
STUB
  chmod +x "$proj_copy/scripts/stall_watchdog.sh"

  # mock get-secret.sh: 常に失敗
  cat > "$proj_copy/scripts/get-secret.sh" << 'MOCK_GS'
#!/usr/bin/env bash
get_secret() {
  return 1
}
MOCK_GS

  run env PATH="${MOCK_BIN}:${PATH}" \
    bash "$proj_copy/scripts/stall-watchdog-launcher.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HC_PING_URL=EMPTY"* ]]

  rm -rf "$proj_copy"
}
