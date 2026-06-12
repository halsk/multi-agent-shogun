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

# Main entry point: print secret to stdout or exit 1 on failure
get_secret() {
  set +x  # C3: ensure trace stays off inside the function
  local name="$1"

  if [[ -z "$name" ]]; then
    echo "ERROR: get_secret requires a service name argument" >&2
    return 1
  fi

  local platform
  platform="$(_ks_get_platform)"

  if [[ "$platform" == "macos" ]]; then
    # --- macOS: Keychain first, then op fallback (C4b) ---
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
    # --- WSL/Linux: op only (C6: Darwin-only path added, WSL path unchanged) ---
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

# Allow direct execution as well as sourcing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  get_secret "$@"
fi
