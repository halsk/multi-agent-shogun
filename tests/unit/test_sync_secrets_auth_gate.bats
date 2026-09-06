#!/usr/bin/env bats
#
# tests/unit/test_sync_secrets_auth_gate.bats
#
# auth-gate unit tests for scripts/sync-secrets-to-keychain.sh.
#
# Cases:
#   (a) already authenticated  → no polling, proceeds to sync
#   (b) auth after N polls     → shows waiting message, then proceeds
#   (c) timeout exceeded       → exits non-zero with clear error
#
# Approach: mock 'op' binary in a temp PATH directory.
#   - 'op account get' simulates authentication state via a call-count file.
#   - 'op item get'    always returns a mock value (sync can complete).
#   - 'security'       mocked to avoid real Keychain access.
#
# Fast test settings: OP_AUTH_POLL_SEC=1, OP_AUTH_TIMEOUT_SEC=3

setup() {
  # scripts/sync-secrets-to-keychain.shは設計上macOS専用(uname -s != Darwinで
  # 早期exit・ヘッダコメント "macOS ONLY" 明記)。ubuntu-latest上ではop/security
  # のモック呼出しに到達する前にスクリプトが早期exitし、本テスト群の前提
  # (auth polling等)が成立しない。SKIP=FAIL方針の例外(「CI environment」を
  # 含むskip理由は許容・tests/unit/test_cli_adapter.bats:414と同一作法)。
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "sync-secrets-to-keychain.sh is macOS-only by design (CI environment: uname=$(uname -s))"
  fi

  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export MOCK_BIN
  MOCK_BIN="$(mktemp -d "$BATS_TMPDIR/mock_bin.XXXXXX")"

  export MOCK_STATE
  MOCK_STATE="$(mktemp -d "$BATS_TMPDIR/mock_state.XXXXXX")"

  export TEST_CONFIG
  TEST_CONFIG="$(mktemp "$BATS_TMPDIR/secrets.conf.XXXXXX")"

  # Minimal config: one entry (default vault, default field=password)
  echo "test-secret  test-item-name" > "$TEST_CONFIG"

  # Mock security: return empty for find (no cached hash), succeed for write ops
  cat > "${MOCK_BIN}/security" << 'MOCK_SECURITY'
#!/usr/bin/env bash
if [[ "$1" == "find-generic-password" ]]; then
  exit 1  # no cached entry → item treated as "changed"
fi
exit 0
MOCK_SECURITY
  chmod +x "${MOCK_BIN}/security"

  export OP_AUTH_POLL_SEC=1
  export OP_AUTH_TIMEOUT_SEC=3
  export KEYCHAIN_SYNC_CONFIG="$TEST_CONFIG"
}

teardown() {
  rm -rf "$MOCK_BIN" "$MOCK_STATE" "$TEST_CONFIG" 2>/dev/null || true
}

# _write_mock_op SUCCEED_AFTER
#   op account get fails for the first SUCCEED_AFTER calls, succeeds thereafter.
#   op item get always returns "mock-secret-value".
_write_mock_op() {
  local succeed_after="${1:-0}"
  local count_file="${MOCK_STATE}/op_account_get_count"

  cat > "${MOCK_BIN}/op" << EOF
#!/usr/bin/env bash
if [[ "\$1" == "account" && "\$2" == "get" ]]; then
  count=\$(cat "${count_file}" 2>/dev/null || echo 0)
  count=\$((count + 1))
  echo "\$count" > "${count_file}"
  if [[ "\$count" -gt ${succeed_after} ]]; then
    echo '{"email":"test@example.com","url":"account.1password.com"}'
    exit 0
  fi
  echo "not signed in" >&2
  exit 1
fi

if [[ "\$1" == "item" && "\$2" == "get" ]]; then
  echo "mock-secret-value"
  exit 0
fi

exit 0
EOF
  chmod +x "${MOCK_BIN}/op"
}

# ── (a) ────────────────────────────────────────────────────────────────────────
@test "(a) immediate auth: no polling, script proceeds to sync" {
  _write_mock_op 0  # succeed on first 'op account get' call

  run env \
    PATH="${MOCK_BIN}:${PATH}" \
    KEYCHAIN_SYNC_CONFIG="${TEST_CONFIG}" \
    OP_AUTH_POLL_SEC="${OP_AUTH_POLL_SEC}" \
    OP_AUTH_TIMEOUT_SEC="${OP_AUTH_TIMEOUT_SEC}" \
    bash "${PROJECT_ROOT}/scripts/sync-secrets-to-keychain.sh" 2>&1

  [ "$status" -eq 0 ]
  # Fast path: no waiting message
  [[ "$output" != *"Waiting up to"* ]]
  # Sync completed
  [[ "$output" == *"Sync complete"* ]]
}

# ── (b) ────────────────────────────────────────────────────────────────────────
@test "(b) delayed auth: shows waiting message, proceeds after authentication" {
  _write_mock_op 2  # fail first 2 calls (fast-path + poll 1), succeed on poll 2

  run env \
    PATH="${MOCK_BIN}:${PATH}" \
    KEYCHAIN_SYNC_CONFIG="${TEST_CONFIG}" \
    OP_AUTH_POLL_SEC="${OP_AUTH_POLL_SEC}" \
    OP_AUTH_TIMEOUT_SEC="${OP_AUTH_TIMEOUT_SEC}" \
    bash "${PROJECT_ROOT}/scripts/sync-secrets-to-keychain.sh" 2>&1

  [ "$status" -eq 0 ]
  # Waiting guidance printed
  [[ "$output" == *"Waiting up to"* ]]
  [[ "$output" == *"Touch ID"* ]]
  # Eventually authenticated
  [[ "$output" == *"authenticated after"* ]]
  # Sync still completed
  [[ "$output" == *"Sync complete"* ]]
}

# ── (c) ────────────────────────────────────────────────────────────────────────
@test "(c) timeout: exits non-zero with error message, does not fetch secrets" {
  _write_mock_op 999  # never succeeds within timeout

  run env \
    PATH="${MOCK_BIN}:${PATH}" \
    KEYCHAIN_SYNC_CONFIG="${TEST_CONFIG}" \
    OP_AUTH_POLL_SEC="${OP_AUTH_POLL_SEC}" \
    OP_AUTH_TIMEOUT_SEC="${OP_AUTH_TIMEOUT_SEC}" \
    bash "${PROJECT_ROOT}/scripts/sync-secrets-to-keychain.sh" 2>&1

  [ "$status" -ne 0 ]
  # Clear timeout error
  [[ "$output" == *"timed out"* ]]
  # Secret fetch must NOT have started
  [[ "$output" != *"Fetching"* ]]
}
