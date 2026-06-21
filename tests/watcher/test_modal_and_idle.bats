#!/usr/bin/env bats
# test_modal_and_idle.bats — detect_session_modal / should_nudge_idle unit tests
#
# Test cases:
#   T-MODAL-001: detect_session_modal — both anchors present -> return 0 (detected)
#   T-MODAL-002: detect_session_modal — first anchor only -> return 1 (no false positive)
#   T-MODAL-003: detect_session_modal — empty string -> return 1
#   T-MODAL-004: detect_session_modal — normal work log -> return 1 (no false positive)
#   T-MODAL-005: detect_session_modal — second anchor only -> return 1 (no false positive)
#   T-MODAL-006: detect_session_modal — second anchor lowercase 'dismiss' -> return 0 (I1 case-insensitive)
#   T-MODAL-007: detect_session_modal — second anchor uppercase 'DISMISS' -> return 0 (I1 case-insensitive)
#   T-MODAL-008: maybe_dismiss_modal — modal present -> send-keys "0" called (I2 compound case)
#   T-IDLE-001: should_nudge_idle — assigned+idle+age_ok+cooldown_ok -> return 0 (nudge)
#   T-IDLE-002: should_nudge_idle — done -> return 1
#   T-IDLE-003: should_nudge_idle — cancelled -> return 1
#   T-IDLE-004: should_nudge_idle — busy (is_idle=0) -> return 1
#   T-IDLE-005: should_nudge_idle — within cooldown -> return 1
#   T-IDLE-006: should_nudge_idle — idle_age too small -> return 1
#   T-IDLE-007: should_nudge_idle — work+idle+age_ok+cooldown_ok -> return 0
#   T-IDLE-008: should_nudge_idle — in_progress+idle+age_ok+cooldown_ok -> return 0
#   T-IDLE-009: should_nudge_idle — task_status=idle -> return 1

# --- Setup ---

setup_file() {
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || { echo "WATCHER_SCRIPT not found: $WATCHER_SCRIPT" >&3; return 1; }
}

setup() {
    export TEST_TMPDIR
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/modal_idle_test.XXXXXX")"

    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    export TEST_TASKS_DIR="$TEST_TMPDIR/queue/tasks"
    mkdir -p "$TEST_TASKS_DIR"

    # Test harness: __INBOX_WATCHER_TESTING__=1 loads function definitions only
    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
AGENT_ID="test_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/test_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"

tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then
        echo "\${MOCK_CAPTURE_PANE:-}"
        return 0
    fi
    if echo "\$*" | grep -q "send-keys"; then
        return \${MOCK_SENDKEYS_RC:-0}
    fi
    if echo "\$*" | grep -q "show-options"; then
        echo "\${MOCK_PANE_CLI:-claude}"
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        echo "0"
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { return 1; }
sleep() { :; }
export -f tmux timeout pgrep sleep

export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"

    # Default: idle flag present (agent is idle)
    touch "$TEST_TMPDIR/shogun_idle_test_agent"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# --- T-MODAL-001: both anchors present -> detected ---

@test "T-MODAL-001: detect_session_modal both anchors -> return 0 detected" {
    # Second anchor: case-insensitive 'dismiss' (I1 緩和後). Any capitalisation matches.
    local modal_fixture="$TEST_TMPDIR/modal.txt"
    cat > "$modal_fixture" << 'EOF'
How is Claude doing this session?
  > (1) Terrible
    (2) Bad
    (3) Okay
    (4) Good
    (5) Great
    (0) Dismiss
EOF

    run bash -c "
source '$TEST_HARNESS'
modal_text=\$(cat '$modal_fixture')
detect_session_modal \"\$modal_text\"
"
    [ "$status" -eq 0 ]
}

# --- T-MODAL-002: first anchor only -> no false positive ---

@test "T-MODAL-002: detect_session_modal first anchor only -> return 1" {
    local text="How is Claude doing this session? Let me think about this..."
    run bash -c "source '$TEST_HARNESS' && detect_session_modal '$text'"
    [ "$status" -eq 1 ]
}

# --- T-MODAL-003: empty string -> return 1 ---

@test "T-MODAL-003: detect_session_modal empty string -> return 1" {
    run bash -c "source '$TEST_HARNESS' && detect_session_modal ''"
    [ "$status" -eq 1 ]
}

# --- T-MODAL-004: normal work log -> no false positive ---

@test "T-MODAL-004: detect_session_modal normal work log -> return 1" {
    local log_fixture="$TEST_TMPDIR/normal.txt"
    cat > "$log_fixture" << 'EOF'
> Write the implementation to scripts/inbox_watcher.sh
Running bats tests
Checking test results
All tests passed. Creating PR...
EOF

    run bash -c "
source '$TEST_HARNESS'
log_text=\$(cat '$log_fixture')
detect_session_modal \"\$log_text\"
"
    [ "$status" -eq 1 ]
}

# --- T-MODAL-005: second anchor only -> no false positive ---

@test "T-MODAL-005: detect_session_modal second anchor only -> return 1" {
    local text="(0) Dismiss this conversation about the implementation plan."
    run bash -c "source '$TEST_HARNESS' && detect_session_modal '$text'"
    [ "$status" -eq 1 ]
}

# --- T-MODAL-006: I1 — lowercase 'dismiss' variant -> return 0 (case-insensitive) ---

@test "T-MODAL-006: detect_session_modal lowercase dismiss -> return 0" {
    local modal_fixture="$TEST_TMPDIR/modal_lower.txt"
    cat > "$modal_fixture" << 'EOF'
How is Claude doing this session?
  > (1) Terrible
    (2) Bad
    (3) Okay
    (4) Good
    (5) Great
    (0) dismiss
EOF

    run bash -c "
source '$TEST_HARNESS'
modal_text=\$(cat '$modal_fixture')
detect_session_modal \"\$modal_text\"
"
    [ "$status" -eq 0 ]
}

# --- T-MODAL-007: I1 — uppercase 'DISMISS' variant -> return 0 (case-insensitive) ---

@test "T-MODAL-007: detect_session_modal uppercase DISMISS -> return 0" {
    local modal_fixture="$TEST_TMPDIR/modal_upper.txt"
    cat > "$modal_fixture" << 'EOF'
How is Claude doing this session?
  > (1) Terrible
    (2) Bad
    (3) Okay
    (4) Good
    (5) Great
    (0) DISMISS
EOF

    run bash -c "
source '$TEST_HARNESS'
modal_text=\$(cat '$modal_fixture')
detect_session_modal \"\$modal_text\"
"
    [ "$status" -eq 0 ]
}

# --- T-MODAL-008: I2 compound — maybe_dismiss_modal fires and sends dismiss key when modal present ---
# Verifies that maybe_dismiss_modal (now called at top of process_unread, independent of unread state)
# correctly dismisses the modal when it is visible, regardless of whether unread messages exist.

@test "T-MODAL-008: maybe_dismiss_modal with modal present sends dismiss key" {
    local modal_fixture="$TEST_TMPDIR/modal_compound.txt"
    cat > "$modal_fixture" << 'EOF'
How is Claude doing this session?
  > (1) Terrible
    (2) Bad
    (3) Okay
    (4) Good
    (5) Great
    (0) dismiss
EOF

    run bash -c "
export MOCK_CAPTURE_PANE=\$(cat '$modal_fixture')
export LAST_MODAL_DISMISS=0
source '$TEST_HARNESS'
ASW_MODAL_DISMISS=1
LAST_MODAL_DISMISS=0
maybe_dismiss_modal
"
    [ "$status" -eq 0 ]
    grep -q 'send-keys' "$MOCK_LOG"
    grep -q '"0"' "$MOCK_LOG" || grep -q " 0$" "$MOCK_LOG" || grep -q " 0 " "$MOCK_LOG"
}

# --- T-IDLE-001: assigned+idle+age_ok+cooldown_ok -> nudge ---

@test "T-IDLE-001: should_nudge_idle assigned idle age_ok cooldown_ok -> return 0" {
    run bash -c "source '$TEST_HARNESS' && should_nudge_idle assigned 1 300 600"
    [ "$status" -eq 0 ]
}

# --- T-IDLE-002: done -> no nudge ---

@test "T-IDLE-002: should_nudge_idle done -> return 1" {
    run bash -c "source '$TEST_HARNESS' && should_nudge_idle done 1 300 600"
    [ "$status" -eq 1 ]
}

# --- T-IDLE-003: cancelled -> no nudge ---

@test "T-IDLE-003: should_nudge_idle cancelled -> return 1" {
    run bash -c "source '$TEST_HARNESS' && should_nudge_idle cancelled 1 300 600"
    [ "$status" -eq 1 ]
}

# --- T-IDLE-004: busy is_idle=0 -> no nudge ---

@test "T-IDLE-004: should_nudge_idle busy is_idle=0 -> return 1" {
    run bash -c "source '$TEST_HARNESS' && should_nudge_idle assigned 0 300 600"
    [ "$status" -eq 1 ]
}

# --- T-IDLE-005: within cooldown -> no nudge ---

@test "T-IDLE-005: should_nudge_idle within cooldown -> return 1" {
    # last_nudge_age=60 < ASW_IDLE_NUDGE_COOLDOWN default 300
    run bash -c "source '$TEST_HARNESS' && should_nudge_idle assigned 1 300 60"
    [ "$status" -eq 1 ]
}

# --- T-IDLE-006: idle_age too small -> no nudge ---

@test "T-IDLE-006: should_nudge_idle idle_age too small -> return 1" {
    # idle_age=60 < ASW_IDLE_NUDGE_AGE default 180
    run bash -c "source '$TEST_HARNESS' && should_nudge_idle assigned 1 60 600"
    [ "$status" -eq 1 ]
}

# --- T-IDLE-007: work+idle+age_ok+cooldown_ok -> nudge ---

@test "T-IDLE-007: should_nudge_idle work idle age_ok cooldown_ok -> return 0" {
    run bash -c "source '$TEST_HARNESS' && should_nudge_idle work 1 300 600"
    [ "$status" -eq 0 ]
}

# --- T-IDLE-008: in_progress+idle+age_ok+cooldown_ok -> nudge ---

@test "T-IDLE-008: should_nudge_idle in_progress idle age_ok cooldown_ok -> return 0" {
    run bash -c "source '$TEST_HARNESS' && should_nudge_idle in_progress 1 300 600"
    [ "$status" -eq 0 ]
}

# --- T-IDLE-009: task_status=idle -> no nudge ---

@test "T-IDLE-009: should_nudge_idle task_status_idle -> return 1" {
    run bash -c "source '$TEST_HARNESS' && should_nudge_idle idle 1 300 600"
    [ "$status" -eq 1 ]
}
