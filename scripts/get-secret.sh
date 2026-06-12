#!/usr/bin/env bash
# scripts/get-secret.sh
#
# Retrieves a named secret from macOS Keychain (primary) or 1Password (fallback).
# On WSL/Linux: delegates directly to 1Password CLI (op).
#
# USAGE (sourced as a library):
#   source scripts/get-secret.sh
#   val=$(get_secret <service-name>)
#
# USAGE (direct execution):
#   scripts/get-secret.sh <service-name>
#   scripts/get-secret.sh --refresh <service-name>   # Layer 2: force re-fetch from op
#
# PLATFORM BEHAVIOR:
#   macOS : security find-generic-password (Keychain) → op fallback (C4b)
#   WSL   : op item get (unchanged from previous behavior — C6)
#   Linux : op item get
#
# EXIT CODES:
#   0  secret printed to stdout
#   1  not found in Keychain or 1Password (error on stderr)
#
# SECURITY NOTES (C5):
#   macOS Keychain encryption requires FileVault to be ENABLED.
#   Without FileVault the keychain database is readable if disk is physically accessed.
#   Enable: System Settings > Privacy & Security > FileVault
#
# C3: set +x prevents secret values from appearing in bash -x traces.
# Secrets are never written to files, logs, or stderr — only returned via stdout.
#
# ────────────────────────────────────────────────────────────
# STALENESS / RETRY PATTERN (Layer 2 — macOS-only requirement; WSL reads op directly)
#
# When a cached Keychain secret causes an auth failure (e.g. HTTP 401), callers
# should re-fetch the fresh value with --refresh:
#
#   source scripts/get-secret.sh
#   API_KEY=$(get_secret "lawsy-api-key")
#   response=$(curl -sI -H "Authorization: Bearer $API_KEY" "$ENDPOINT")
#   if grep -q "^HTTP/.*401" <<< "$response"; then
#     API_KEY=$(get_secret --refresh "lawsy-api-key")   # re-fetch from op, update Keychain
#     response=$(curl -sI -H "Authorization: Bearer $API_KEY" "$ENDPOINT")
#   fi
#
# Or use the convenience alias:
#   API_KEY=$(get_secret_with_retry "lawsy-api-key")   # equivalent to --refresh
#
# ── WSL NOTE ──
# On WSL/Linux, op is called directly on every get_secret call, so Keychain staleness
# is not a concern. The --refresh flag is a no-op difference: it calls op the same way.
# ────────────────────────────────────────────────────────────

set +x  # C3: disable trace

# Detect the current platform
_ks_get_platform() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "macos"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    echo "wsl"
  else
    echo "linux"
  fi
}

# Main entry point: print secret to stdout or exit 1 on failure.
# Supports --refresh flag (Layer 2): forces re-fetch from 1Password and updates Keychain.
get_secret() {
  set +x  # C3: ensure trace stays off inside the function
  local refresh=0
  if [[ "${1:-}" == "--refresh" ]]; then
    refresh=1
    shift
  fi
  local name="$1"

  if [[ -z "$name" ]]; then
    echo "ERROR: get_secret requires a service name argument" >&2
    return 1
  fi

  local platform
  platform="$(_ks_get_platform)"

  if [[ "$platform" == "macos" ]]; then
    if [[ "$refresh" -eq 0 ]]; then
      # --- macOS normal: Keychain first, then op fallback (C4b) ---
      local val
      # find-generic-password -w prints only the password; -a = account filter
      val=$(security find-generic-password -w -s "$name" -a "keychain-secrets" 2>/dev/null)
      if [[ -n "$val" ]]; then
        printf '%s' "$val"
        return 0
      fi

      # C4b: Keychain miss → op fallback
      if command -v op &>/dev/null; then
        val=$(op item get "$name" --field password 2>/dev/null)
        if [[ -n "$val" ]]; then
          printf '%s' "$val"
          return 0
        fi
      fi

      # C4b: both failed → exit != 0 (silent fail prohibited)
      echo "ERROR: Secret '$name' not found in Keychain or 1Password" >&2
      return 1

    else
      # --- macOS --refresh (Layer 2): re-fetch from op, update Keychain ---
      if ! command -v op &>/dev/null; then
        echo "ERROR: 1Password CLI 'op' not found (required for --refresh)" >&2
        return 1
      fi
      local val
      val=$(op item get "$name" --field password 2>/dev/null)
      if [[ -z "$val" ]]; then
        echo "ERROR: Secret '$name' not found in 1Password (--refresh)" >&2
        return 1
      fi
      # Update Keychain with fresh value so subsequent normal reads get the new secret
      security add-generic-password \
        -s "$name" \
        -a "keychain-secrets" \
        -U \
        -w "$val" \
        2>/dev/null
      printf '%s' "$val"
      unset val
      return 0
    fi

  else
    # --- WSL/Linux: op only (C6). --refresh behaves identically to normal. ---
    if ! command -v op &>/dev/null; then
      echo "ERROR: '1Password CLI (op)' not found. Install from https://developer.1password.com/docs/cli" >&2
      return 1
    fi
    local val
    val=$(op item get "$name" --field password 2>/dev/null)
    if [[ -n "$val" ]]; then
      printf '%s' "$val"
      return 0
    fi

    # Both paths failed → exit != 0
    echo "ERROR: Secret '$name' not found in 1Password" >&2
    return 1
  fi
}

# Layer 2 convenience alias: equivalent to get_secret --refresh <name>.
# Use in deploy scripts after an auth failure to get a guaranteed-fresh value:
#   val=$(get_secret_with_retry "lawsy-api-key")
get_secret_with_retry() {
  get_secret --refresh "$@"
}

# Allow direct execution as well as sourcing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  get_secret "$@"
fi
