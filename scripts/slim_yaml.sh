#!/usr/bin/env bash
#
# slim_yaml.sh - YAML slimming wrapper with file locking
#
# Usage: bash slim_yaml.sh <agent_id>
#
# This script acquires an exclusive lock before calling the Python slimmer,
# ensuring no concurrent modifications to YAML files (same pattern as inbox_write.sh).
#

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
QUEUE_DIR="${SHOGUN_QUEUE_DIR:-${SCRIPT_DIR}/../queue}"
LOCK_FILE="${QUEUE_DIR}/.slim_yaml.lock"
LOCK_TIMEOUT=10
DRY_RUN=false
PYTHON_BIN="${SHOGUN_PYTHON_BIN:-${PROJECT_ROOT}/.venv/bin/python3}"

if [ ! -x "$PYTHON_BIN" ]; then
    PYTHON_BIN="python3"
fi

for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
        DRY_RUN=true
        break
    fi
done

# Acquire exclusive lock for mutating runs. Dry-run intentionally avoids
# creating a lock file so it remains filesystem-read-only for queue data.
if [ "$DRY_RUN" != true ]; then
    mkdir -p "$QUEUE_DIR"
    if command -v flock &>/dev/null; then
        exec 200>"$LOCK_FILE"
        if ! flock -w "$LOCK_TIMEOUT" 200; then
            echo "Error: Failed to acquire lock within $LOCK_TIMEOUT seconds" >&2
            exit 1
        fi
    else
        _ld="${LOCK_FILE}.d"; _i=0
        while ! mkdir "$_ld" 2>/dev/null; do
            sleep 0.1; _i=$((_i+1))
            [ $_i -ge $((LOCK_TIMEOUT * 10)) ] && { echo "Error: Failed to acquire lock within $LOCK_TIMEOUT seconds" >&2; exit 1; }
        done
        trap 'rmdir "$_ld" 2>/dev/null' EXIT
    fi
fi

# Call the Python implementation. Prefer the project venv because CI installs
# PyYAML there on macOS and does not install it into the system Python.
"$PYTHON_BIN" "$(dirname "$0")/slim_yaml.py" "$@"
exit_code=$?

# Lock is automatically released when file descriptor is closed
exit "$exit_code"
