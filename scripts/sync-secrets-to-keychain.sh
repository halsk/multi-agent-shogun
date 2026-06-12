#!/usr/bin/env bash
# scripts/sync-secrets-to-keychain.sh
#
# Syncs secrets from 1Password to macOS Keychain for prompt-free local access.
# macOS ONLY — exits 0 silently on WSL/Linux (no destructive side-effects, C6).
#
# ────────────────────────────────────────────────────────────
# ROTATION PROCEDURE (C4a):
#   1. Update the secret value in 1Password (via app or web vault).
#   2. Re-run this script:
#        bash scripts/sync-secrets-to-keychain.sh
#   The -U flag updates the existing Keychain entry in place.
# ────────────────────────────────────────────────────────────
#
# SECURITY NOTES (C5):
#   - FileVault MUST be enabled for full Keychain security.
#     The login keychain is encrypted with your FileVault key.
#     Without FileVault the keychain database file is readable if disk access is obtained.
#     Enable: System Settings > Privacy & Security > FileVault
#   - ACL policy: -A (allow all apps) is PROHIBITED (C1).
#     Partition-list 'apple-tool:,apple:' is used instead — grants access only to
#     Apple-signed security CLI and the Apple security framework.
#   - C3: set +x prevents secret values appearing in traces.
#     No secret values are written to files, logs, or stdout.
#   - C2: the 'security add-generic-password -w "$val"' call passes the value
#     via process argument. On macOS, other user accounts cannot read your process
#     args (unlike some Linux /proc configurations). Only root can see them.
#     Run this script only from a secure, private terminal session.
#
# ────────────────────────────────────────────────────────────
# CONFIG FILE FORMAT  ($KEYCHAIN_SYNC_CONFIG or ~/.config/keychain-sync/secrets.conf)
#
#   Each non-comment line:
#     <keychain-service-name>  <op-item-name>  [op-vault]  [op-field]
#
#   op-vault defaults to the default vault; op-field defaults to "password"
#
# EXAMPLE:
#   lawsy-api-key  lawsy-civic-intelligence-rag  geonic-ops  LAWSY_API_KEY
#   my-token       github-personal-token                    password
#
# ────────────────────────────────────────────────────────────

set +x            # C3: disable trace globally
set -euo pipefail

# C6: macOS only — exit 0 on WSL/Linux
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "INFO: sync-secrets-to-keychain.sh is macOS-only. Skipping on this platform." >&2
  exit 0
fi

readonly KS_ACCOUNT="keychain-secrets"
readonly KS_PARTITION_LIST="apple-tool:,apple:"
CONFIG_FILE="${KEYCHAIN_SYNC_CONFIG:-$HOME/.config/keychain-sync/secrets.conf}"

usage() {
  sed -n '/^# /p' "$0" | sed 's/^# //' | sed 's/^#$//'
  exit 0
}

# Add or update one Keychain entry, then set partition-list for prompt-free access.
# C1: no -A flag; partition-list used instead of path-based -T.
# C2: value passed via -w; see security notes above.
_ks_add_entry() {
  set +x  # C3: guard against caller re-enabling trace
  local name="$1"
  local val="$2"

  # -U: update-if-exists (idempotent; safe for rotation)
  # No -A or -T <path>: ACL will be set via partition-list below (C1)
  security add-generic-password \
    -s "$name" \
    -a "$KS_ACCOUNT" \
    -U \
    -w "$val" \
    2>/dev/null

  # C1: Set partition-list so apple-tool: (security CLI) can read without prompting.
  # 'apple-tool:' = code-signing identity for /usr/bin/security
  # 'apple:'      = Apple security framework (used by scripting bridges)
  # More restrictive than -T /usr/bin/security (path-based) and -A (all apps).
  # If the keychain is locked this call may fail; warn and continue.
  if ! security set-generic-password-partition-list \
      -s "$name" \
      -a "$KS_ACCOUNT" \
      -S "$KS_PARTITION_LIST" \
      2>/dev/null; then
    echo "WARN: partition-list set failed for '$name'." >&2
    echo "WARN: If 'security find-generic-password' prompts, run manually:" >&2
    echo "WARN:   security set-generic-password-partition-list -s '$name' -a '$KS_ACCOUNT' -S '$KS_PARTITION_LIST'" >&2
  fi

  unset val  # C3: clear secret from environment immediately
  echo "OK: '$name' synced to Keychain" >&2
}

_ks_sync_from_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    echo "" >&2
    echo "Create the file with lines of the form:" >&2
    echo "  <keychain-service-name>  <op-item-name>  [op-vault]  [op-field]" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  lawsy-api-key  lawsy-civic-intelligence-rag  geonic-ops  LAWSY_API_KEY" >&2
    exit 1
  fi

  echo "INFO: Reading config from $CONFIG_FILE" >&2

  local line kc_name op_item op_vault op_field val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue

    set +x  # C3: ensure trace stays off while processing secrets
    kc_name=""
    op_item=""
    op_vault=""
    op_field=""
    read -r kc_name op_item op_vault op_field <<< "$line" || true

    if [[ -z "$kc_name" || -z "$op_item" ]]; then
      echo "WARN: Skipping malformed config line: $line" >&2
      continue
    fi

    # Default op-field to "password" when omitted
    op_field="${op_field:-password}"

    echo "INFO: Fetching '$kc_name' from 1Password..." >&2

    # C3: op output is captured directly into a local variable — not logged or echoed
    if [[ -n "$op_vault" ]]; then
      val=$(op item get "$op_item" --vault "$op_vault" --field "label=$op_field" --reveal 2>/dev/null) || {
        echo "ERROR: Failed to retrieve '$op_item' from vault '$op_vault' (field: $op_field)" >&2
        continue
      }
    else
      val=$(op item get "$op_item" --field "label=$op_field" --reveal 2>/dev/null) || {
        echo "ERROR: Failed to retrieve '$op_item' from 1Password (field: $op_field)" >&2
        continue
      }
    fi

    if [[ -z "$val" ]]; then
      echo "ERROR: Empty value returned for '$op_item' — skipping" >&2
      continue
    fi

    _ks_add_entry "$kc_name" "$val"
    unset val  # C3: clear secret after use
  done < "$CONFIG_FILE"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage ;;
      --config)
        CONFIG_FILE="$2"
        shift 2
        ;;
      *)
        echo "ERROR: Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  if ! command -v op &>/dev/null; then
    echo "ERROR: 1Password CLI 'op' not found. Install: https://developer.1password.com/docs/cli" >&2
    exit 1
  fi

  if ! command -v security &>/dev/null; then
    echo "ERROR: macOS 'security' command not found" >&2
    exit 1
  fi

  echo "INFO: Starting Keychain sync (macOS)" >&2
  echo "INFO: 1Password Touch ID may be requested once for the session." >&2

  _ks_sync_from_config

  echo "INFO: Sync complete." >&2
}

main "$@"
