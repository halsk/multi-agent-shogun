#!/usr/bin/env bats
# test_watcher_supervisor.bats — watcher_supervisor ntfy_listener singleton テスト
#
# テスト構成:
#   T-SUP-001: pgrep が稼働中 (exit 0) → launch_ntfy_listener が呼ばれない
#   T-SUP-002: pgrep が不在 (exit 1) → launch_ntfy_listener が1回呼ばれる

setup_file() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/watcher_sup_test.XXXXXX")"
    export TEST_TMPDIR
    export MOCK_BIN="$TEST_TMPDIR/mock_bin"
    export LAUNCH_LOG="$TEST_TMPDIR/launch.log"
    mkdir -p "$MOCK_BIN"
    touch "$LAUNCH_LOG"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════
# T-SUP-001: pgrep が稼働中 (exit 0) → launch_ntfy_listener が呼ばれない
# ═══════════════════════════════════════════════════════════════

@test "T-SUP-001: pgrep found (exit 0) → launch_ntfy_listener NOT called" {
    cat > "$MOCK_BIN/pgrep" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_BIN/pgrep"

    PATH="$MOCK_BIN:$PATH" bash << SCRIPT
source "$PROJECT_ROOT/scripts/watcher_supervisor.sh"
launch_ntfy_listener() { echo "launched" >> "$LAUNCH_LOG"; }
start_ntfy_listener_if_missing
SCRIPT

    [ ! -s "$LAUNCH_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-SUP-002: pgrep が不在 (exit 1) → launch_ntfy_listener が1回呼ばれる
# ═══════════════════════════════════════════════════════════════

@test "T-SUP-002: pgrep not found (exit 1) → launch_ntfy_listener called once" {
    cat > "$MOCK_BIN/pgrep" << 'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$MOCK_BIN/pgrep"

    PATH="$MOCK_BIN:$PATH" bash << SCRIPT
source "$PROJECT_ROOT/scripts/watcher_supervisor.sh"
launch_ntfy_listener() { echo "launched" >> "$LAUNCH_LOG"; }
start_ntfy_listener_if_missing
SCRIPT

    [ -s "$LAUNCH_LOG" ]
    [ "$(wc -l < "$LAUNCH_LOG")" -eq 1 ]
}
