#!/usr/bin/env bats
#
# tests/unit/test_get_secret_refresh_guard.bats
#
# Guards scripts/get-secret.sh's --refresh path against silently swallowing a
# Keychain write failure (cmd_899 gunshi QC finding K1).
#
# Root cause: get_secret --refresh re-fetches from 1Password then calls
# `security add-generic-password -U` to update the login Keychain, but
# discards its exit code and stderr (`2>/dev/null`, no status check). When
# the login Keychain is locked (e.g. `security` exit 36), the write silently
# fails while --refresh still prints the fresh value and returns 0 — callers
# believe the Keychain is now in sync when it is not.
#
# Approach: mock the 'security', 'op' and 'uname' binaries in a temp PATH
# directory.
#   - 'op item get' always returns a mock fresh value (so the op-fetch half
#     of --refresh always succeeds; only the Keychain-write half varies).
#   - 'security add-generic-password' exit code is controlled per test via
#     SECURITY_ADD_EXIT_CODE to simulate a locked Keychain (exit 36).
#   - 'uname -s' always reports "Darwin" so get-secret.sh's
#     _ks_get_platform() takes the macOS branch regardless of the actual CI
#     runner OS (unlike test_sync_secrets_*.bats, get-secret.sh's --refresh
#     Keychain-write path has no real macOS-only dependency beyond the
#     uname check itself — every syscall it makes is through the mocked
#     'security'/'op' binaries — so there is nothing left to skip).

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  export MOCK_BIN
  MOCK_BIN="$(mktemp -d "$BATS_TMPDIR/mock_bin.XXXXXX")"

  # op: --refresh always re-fetches via `op item get <name> --field password`
  # (no keychain-sync config entry in these tests, so get-secret.sh falls
  # back to the plain `op item get` form).
  cat > "${MOCK_BIN}/op" << 'MOCK_OP'
#!/usr/bin/env bash
if [[ "$1" == "item" && "$2" == "get" ]]; then
  echo "mock-fresh-value"
  exit 0
fi
exit 0
MOCK_OP
  chmod +x "${MOCK_BIN}/op"

  # security mock: find-generic-password unused by --refresh; only
  # add-generic-password matters here. Exit code controlled via env var.
  cat > "${MOCK_BIN}/security" << 'MOCK_SECURITY'
#!/usr/bin/env bash
if [[ "$1" == "add-generic-password" ]]; then
  if [[ "${SECURITY_ADD_EXIT_CODE:-0}" != "0" ]]; then
    echo "security: SecKeychainAddGenericPassword: User interaction is not allowed." >&2
    exit "${SECURITY_ADD_EXIT_CODE}"
  fi
  exit 0
fi
exit 1
MOCK_SECURITY
  chmod +x "${MOCK_BIN}/security"

  # uname: force get-secret.sh's _ks_get_platform() onto the macOS branch
  # regardless of the CI runner's real OS (see approach note above).
  cat > "${MOCK_BIN}/uname" << 'MOCK_UNAME'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then
  echo "Darwin"
  exit 0
fi
exit 1
MOCK_UNAME
  chmod +x "${MOCK_BIN}/uname"
}

teardown() {
  rm -rf "$MOCK_BIN" 2>/dev/null || true
}

# ── RED/GREEN: Keychain write fails (locked, exit 36) ───────────────────────
@test "(a) --refresh: Keychain write fails (exit 36) → get_secret --refresh must fail non-zero and report the failure on stderr" {
  run env \
    PATH="${MOCK_BIN}:${PATH}" \
    SECURITY_ADD_EXIT_CODE=36 \
    KEYCHAIN_SYNC_CONFIG=/nonexistent-secrets.conf \
    bash -c "source '${PROJECT_ROOT}/scripts/get-secret.sh'; get_secret --refresh some-service"

  # Before the fix this returns 0 (silently swallowed) — this is the guard.
  [ "$status" -ne 0 ]

  [[ "$output" == *"Keychain"* ]]
}

# ── Keychain write succeeds → unchanged behaviour ───────────────────────────
@test "(b) --refresh: Keychain write succeeds → get_secret --refresh still returns 0 and prints the fresh value" {
  run env \
    PATH="${MOCK_BIN}:${PATH}" \
    SECURITY_ADD_EXIT_CODE=0 \
    KEYCHAIN_SYNC_CONFIG=/nonexistent-secrets.conf \
    bash -c "source '${PROJECT_ROOT}/scripts/get-secret.sh'; get_secret --refresh some-service"

  [ "$status" -eq 0 ]
  [[ "$output" == "mock-fresh-value" ]]
}
