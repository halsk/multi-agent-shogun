#!/usr/bin/env bash
# scripts/sync-secrets-to-keychain.sh
#
# Syncs secrets from 1Password to macOS Keychain for prompt-free local access.
# macOS ONLY — exits 0 silently on WSL/Linux (no destructive side-effects, C6).
#
# ────────────────────────────────────────────────────────────
# STALENESS MODEL (macOS-only; WSL reads op directly so staleness is not a concern)
#
# Layer 1 — Boundary sync with change detection:
#   At each sync (session start / before deploy / rotation), the value fetched
#   from 1Password is hashed (sha256). The hash is stored alongside the secret in
#   Keychain as a separate entry (<name>-hash). On the next sync the hashes are
#   compared; the Keychain entry is updated only when the value has changed.
#   ★ Hash comparison happens only at sync boundaries, never per-access
#     (to avoid unnecessary Touch ID prompts).
#
# Layer 2 — Failure self-healing via get-secret.sh:
#   If a cached secret causes an auth failure (e.g. HTTP 401), the caller can
#   force a fresh fetch:
#     val=$(get_secret --refresh "my-api-key")
#   This re-fetches from 1Password, updates Keychain, and returns the fresh value.
#   See scripts/get-secret.sh for the full API.
#
# Layer 3 — Pre-deploy forced refresh:
#   Deploy scripts should call sync-secrets-to-keychain.sh with --force-refresh
#   before using any cached secret:
#     bash scripts/sync-secrets-to-keychain.sh --force-refresh lawsy-api-key
#   This always updates the named entry (bypasses hash equality check) and
#   confirms freshness with a log message.
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
#     Hash values are also stored in Keychain — never written to plain files or logs.
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
FORCE_REFRESH=0         # 1 = bypass hash equality check, always update
FORCE_REFRESH_NAME=""   # if non-empty, only process this keychain-service-name

usage() {
  sed -n '/^# /p' "$0" | sed 's/^# //' | sed 's/^#$//'
  exit 0
}

# Compute sha256 hash of a value; prints the hex digest. (C3: set +x applied)
_ks_compute_hash() {
  set +x  # C3
  local val="$1"
  printf '%s' "$val" | shasum -a 256 | awk '{print $1}'
  unset val
}

# Return the hash cached in Keychain for <name>; empty string if absent. (C3: set +x)
_ks_get_cached_hash() {
  set +x  # C3
  local name="$1"
  security find-generic-password -w -s "${name}-hash" -a "$KS_ACCOUNT" 2>/dev/null || true
}

# Store hash value in Keychain as <name>-hash. (C3: hash is non-secret but kept in
# Keychain to avoid plain-file residue and to benefit from Keychain encryption.)
_ks_store_hash() {
  set +x  # C3
  local name="$1"
  local hash_val="$2"
  security add-generic-password \
    -s "${name}-hash" \
    -a "$KS_ACCOUNT" \
    -U \
    -w "$hash_val" \
    2>/dev/null
  if ! security set-generic-password-partition-list \
      -s "${name}-hash" \
      -a "$KS_ACCOUNT" \
      -S "$KS_PARTITION_LIST" \
      2>/dev/null; then
    echo "WARN: partition-list set failed for '${name}-hash'." >&2
  fi
  unset hash_val
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

    # Layer 1 / Layer 3: if a specific entry was requested, skip all others
    if [[ -n "$FORCE_REFRESH_NAME" && "$kc_name" != "$FORCE_REFRESH_NAME" ]]; then
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

    # Layer 1: hash-based staleness check (boundary sync only, never per-access)
    local current_hash cached_hash
    current_hash=$(_ks_compute_hash "$val")
    cached_hash=$(_ks_get_cached_hash "$kc_name")

    if [[ "$FORCE_REFRESH" -eq 0 && "$current_hash" == "$cached_hash" ]]; then
      echo "INFO: '$kc_name' unchanged (hash match) — skipping update." >&2
      unset val current_hash cached_hash
      continue
    fi

    if [[ "$current_hash" == "$cached_hash" ]]; then
      # FORCE_REFRESH=1: confirmed fresh, update anyway (Layer 3 guarantee)
      echo "INFO: '$kc_name' confirmed fresh (hash match) — force-refreshed." >&2
    else
      echo "INFO: '$kc_name' changed — updating Keychain." >&2
    fi

    _ks_add_entry "$kc_name" "$val"
    _ks_store_hash "$kc_name" "$current_hash"
    unset val current_hash cached_hash
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
      --force-refresh)
        # Layer 3: bypass hash equality check, always update.
        # Optional second argument narrows to a single keychain-service-name.
        FORCE_REFRESH=1
        if [[ -n "${2:-}" && "${2:-}" != "--"* ]]; then
          FORCE_REFRESH_NAME="$2"
          shift
        fi
        shift
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
