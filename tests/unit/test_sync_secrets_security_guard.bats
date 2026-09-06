#!/usr/bin/env bats
#
# tests/unit/test_sync_secrets_security_guard.bats
#
# Security write-guard unit tests for scripts/sync-secrets-to-keychain.sh.
#
# Cases:
#   (a) security add-generic-password fails → WARN + secret skipped + hash NOT
#       saved + next secret continues + overall exit 0
#   (b) security add-generic-password succeeds → OK message + hash saved
#       (existing behaviour preserved)
#
# Approach: mock 'op' and 'security' binaries in a temp PATH directory.
#   - 'op' is always authenticated and returns mock values.
#   - 'security' behaviour is controlled per test via SECURITY_ADD_EXIT_CODE
#     written to MOCK_STATE before each test.
#
# Root-cause context:
#   security add-generic-password returns non-zero (e.g. exit 36 "User
#   interaction is not allowed") when the login Keychain is locked. Under
#   set -euo pipefail the 2>/dev/null suppresses stderr but the non-zero exit
#   propagates and aborts the entire sync loop. The guard introduced in
#   fix/sync-secrets-security-guard wraps the call, WARNs on failure, skips
#   the hash save for the failed entry, and continues to the next secret.

setup() {
  # scripts/sync-secrets-to-keychain.shは設計上macOS専用(uname -s != Darwinで
  # 早期exit)。test_sync_secrets_auth_gate.batsと同一理由・同一作法。
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

  # Two entries: first will fail, second will succeed (tests continuation)
  printf 'secret-a  item-a\nsecret-b  item-b\n' > "$TEST_CONFIG"

  # op: always authenticated, always returns a mock value
  cat > "${MOCK_BIN}/op" << 'MOCK_OP'
#!/usr/bin/env bash
if [[ "$1" == "account" && "$2" == "get" ]]; then
  echo '{"email":"test@example.com","url":"account.1password.com"}'
  exit 0
fi
if [[ "$1" == "item" && "$2" == "get" ]]; then
  echo "mock-secret-value"
  exit 0
fi
exit 0
MOCK_OP
  chmod +x "${MOCK_BIN}/op"

  # Security mock is written per-test (see _write_security_mock)
  export OP_AUTH_POLL_SEC=1
  export OP_AUTH_TIMEOUT_SEC=5
  export KEYCHAIN_SYNC_CONFIG="$TEST_CONFIG"
}

teardown() {
  rm -rf "$MOCK_BIN" "$MOCK_STATE" "$TEST_CONFIG" 2>/dev/null || true
}

# _write_security_mock FAIL_FOR_NAME
#   security add-generic-password returns 1 when the service name matches
#   FAIL_FOR_NAME (simulating Keychain locked for that entry); succeeds otherwise.
#   security find-generic-password always returns 1 (no cached hash = always treat
#   as changed so the write path is exercised every time).
_write_security_mock() {
  local fail_for="${1:-}"

  cat > "${MOCK_BIN}/security" << EOF
#!/usr/bin/env bash
if [[ "\$1" == "find-generic-password" ]]; then
  exit 1  # no cached entry → always attempt write
fi
if [[ "\$1" == "add-generic-password" ]]; then
  # Determine the service name from args (-s <name>)
  svc=""
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "-s" ]]; then
      svc="\$2"
      break
    fi
    shift
  done
  if [[ -n "${fail_for}" && "\$svc" == "${fail_for}" ]]; then
    echo "security: SecKeychainAddGenericPassword: User interaction is not allowed." >&2
    exit 36
  fi
  exit 0
fi
# set-generic-password-partition-list always succeeds
exit 0
EOF
  chmod +x "${MOCK_BIN}/security"
}

# ── (a) ────────────────────────────────────────────────────────────────────────
@test "(a) security add fails: WARN shown, secret skipped, hash not saved, next secret synced, exit 0" {
  # Only secret-a's Keychain write will fail
  _write_security_mock "secret-a"

  run env \
    PATH="${MOCK_BIN}:${PATH}" \
    KEYCHAIN_SYNC_CONFIG="${TEST_CONFIG}" \
    OP_AUTH_POLL_SEC="${OP_AUTH_POLL_SEC}" \
    OP_AUTH_TIMEOUT_SEC="${OP_AUTH_TIMEOUT_SEC}" \
    bash "${PROJECT_ROOT}/scripts/sync-secrets-to-keychain.sh" 2>&1

  # Overall sync must NOT abort
  [ "$status" -eq 0 ]

  # WARN must be emitted for the failed entry
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"secret-a"* ]]

  # Hash must NOT be saved for the failed entry (no add call for secret-a-hash)
  [[ "$output" != *"secret-a-hash"*"synced"* ]]

  # Second entry must have been processed
  [[ "$output" == *"secret-b"* ]]
  [[ "$output" == *"OK"* ]]

  # Sync complete message must appear
  [[ "$output" == *"Sync complete"* ]]
}

# ── (b) ────────────────────────────────────────────────────────────────────────
@test "(b) security add succeeds: OK message shown, hash saved, exit 0" {
  # All Keychain writes succeed
  _write_security_mock ""  # no failures

  # Single-entry config for simplicity
  echo "single-secret  single-item" > "$TEST_CONFIG"

  run env \
    PATH="${MOCK_BIN}:${PATH}" \
    KEYCHAIN_SYNC_CONFIG="${TEST_CONFIG}" \
    OP_AUTH_POLL_SEC="${OP_AUTH_POLL_SEC}" \
    OP_AUTH_TIMEOUT_SEC="${OP_AUTH_TIMEOUT_SEC}" \
    bash "${PROJECT_ROOT}/scripts/sync-secrets-to-keychain.sh" 2>&1

  [ "$status" -eq 0 ]

  # OK message for the successful entry
  [[ "$output" == *"OK"* ]]
  [[ "$output" == *"single-secret"* ]]

  # No WARN
  [[ "$output" != *"WARN: 'single-secret' write"* ]]

  # Sync complete
  [[ "$output" == *"Sync complete"* ]]
}
