#!/usr/bin/env bats
# test_send_wakeup.bats — send_wakeup() unit tests
# Sources the REAL inbox_watcher.sh with __INBOX_WATCHER_TESTING__=1
# to test actual production functions with mocked externals (tmux, pgrep, etc).
#
# テスト構成:
#   T-SW-001: send_wakeup — active self-watch → skip nudge
#   T-SW-002: send_wakeup — no self-watch → tmux send-keys
#   T-SW-003: send_wakeup — send-keys content is "inboxN" + Enter (separated)
#   T-SW-004: send_wakeup — send-keys failure → return 1
#   T-SW-005: send_wakeup — no paste-buffer or set-buffer used
#   T-SW-006: agent_has_self_watch — detects inotifywait process
#   T-SW-007: agent_has_self_watch — no inotifywait → returns 1
#   T-SW-008: send_cli_command — /clear uses send-keys
#   T-SW-009: send_cli_command — /model uses send-keys
#   T-SW-010: nudge content format — inboxN (backward compatible)
#   T-SW-011: inbox_watcher.sh uses send-keys, functions exist
#   T-ESC-001: escalation — no unread → FIRST_UNREAD_SEEN stays 0
#   T-ESC-002: escalation — unread < 2min → standard nudge
#   T-ESC-003: escalation — unread 2-4min → Escape+nudge
#   T-ESC-004: escalation — unread > 4min → /clear sent
#   T-ESC-005: escalation — /clear cooldown → falls back to Escape+nudge
#   T-BUSY-001: agent_is_busy — detects "Working" in pane
#   T-BUSY-002: agent_is_busy — idle pane returns 1
#   T-BUSY-003: send_wakeup — skips when agent is busy
#   T-BUSY-004: send_wakeup_with_escape — skips when agent is busy
#   T-CODEX-001: send_cli_command — codex /clear → /new conversion
#   T-CODEX-002: send_cli_command — codex /model → skip
#   T-CODEX-003: C-u sent when unread=0 and agent is idle
#   T-CODEX-004: C-u NOT sent when agent is busy
#   T-CODEX-005: send_cli_command — claude /clear passes through as-is
#   T-CODEX-006: inbox_watcher.sh has agent_is_busy and Codex/Copilot handlers
#   T-CODEX-007: pane @agent_cli=codex overrides stale CLI_TYPE (Phase2 C-c抑止)
#   T-CODEX-008: pane @agent_cli=codex overrides stale CLI_TYPE (/clear→/new)
#   T-CODEX-009: normalize_special_command rejects invalid model_switch payload
#   T-CODEX-010: unresolved CLI type falls back to codex-safe path
#   T-CODEX-011: clear_command処理でauto-recovery task_assignedを自動投入
#   T-CODEX-012: auto-recovery task_assignedは重複投入しない
#   T-SHOGUN-001: session_has_client — returns 0 when client attached
#   T-SHOGUN-002: session_has_client — returns 1 when no client
#   T-SHOGUN-003: send_wakeup — shogun + active + attached → send-keys (post PR#75)
#   T-SHOGUN-004: send_wakeup — shogun + active + detached → send-keys fallthrough
#   T-BUSY-005: agent_is_busy — returns busy during /clear cooldown (LAST_CLEAR_TS)
#   T-BUSY-006: agent_is_busy — returns idle after /clear cooldown expires
#   T-BUSY-007: agent_is_busy — /clear cooldown overrides idle pane
#   T-BUSY-008: agent_is_busy — idle prompt at bottom overrides old busy markers (false-busy fix)
#   T-BUSY-009: agent_is_busy — 'background terminal running' detected as busy
#   T-BUSY-010: agent_is_busy — 'Compacting conversation' detected as busy
#   T-BUSY-011: agent_is_busy — 'esc to interrupt' alone detected as busy
#   T-SHOOK-001: Claude Code throttle uses 60s cooldown (stop-hook-supplementary)
#   T-SHOOK-002: Claude Code count change bypasses throttle (stop-hook-supplementary)
#   T-SHOOK-003: Non-Claude CLIs still bypass throttle on count change
#   T-CRESET-001: send_context_reset — suppresses /clear for karo
#   T-CRESET-002: send_context_reset — suppresses /clear for gunshi
#   T-CRESET-003: send_context_reset — sends /clear for ashigaru
#   T-COPILOT-001: send_cli_command — copilot /clear → Ctrl-C + restart
#   T-COPILOT-002: send_cli_command — copilot /model → skip
#   T-CRESET-004: send_context_reset — claude経路は/clear後にsend_startup_promptを呼ぶ
#         (★真因の回帰テスト。codex経路(T-CRESET-005)とのCONTEXT-RESET非対称是正)
#   T-CRESET-005: send_context_reset — codex経路は既にstartup promptを送る(regression)
#   T-CRESET-006: send_cli_command(clear_command型) — claude /clearは既にstartup promptを送る(regression)

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/send_wakeup_test.XXXXXX")"

    # Log file for tmux mock calls (all tmux invocations recorded here)
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    # Create mock pgrep (default: no self-watch found)
    export MOCK_PGREP="$TEST_TMPDIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    # Create test inbox directory
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    # Default mock control variables
    export MOCK_CAPTURE_PANE=""
    export MOCK_SENDKEYS_RC=0
    export MOCK_PANE_CLI=""
    export MOCK_PANE_ACTIVE=""
    export MOCK_LIST_CLIENTS=""

    # Test harness: sets up mocks, then sources the REAL inbox_watcher.sh
    # __INBOX_WATCHER_TESTING__=1 skips arg parsing, inotifywait check, and main loop.
    # Only function definitions are loaded — testing actual production code.
    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
# Variables required by inbox_watcher.sh functions
AGENT_ID="test_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/test_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"

# Mock external commands (defined before sourcing so they override real commands)
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
        echo "\${MOCK_PANE_CLI:-}"
        return 0
    fi
    if echo "\$*" | grep -q "list-clients"; then
        [ -n "\${MOCK_LIST_CLIENTS:-}" ] && echo "\$MOCK_LIST_CLIENTS"
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        if echo "\$*" | grep -q "pane_active"; then
            echo "\${MOCK_PANE_ACTIVE:-0}"
        else
            echo "mock_session"
        fi
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { "$MOCK_PGREP" "\$@"; }
sleep() { :; }
export -f tmux timeout pgrep sleep

# Source the REAL inbox_watcher.sh (testing guard skips startup & main loop)
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"

    # Default: create idle flag so agent_is_busy() returns idle (1) for claude CLI
    # Tests requiring busy state must rm this file before their run bash -c block
    touch "$TEST_TMPDIR/shogun_idle_test_agent"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# --- T-SW-001: self-watch active → skip nudge ---

@test "T-SW-001: send_wakeup skips nudge when agent has active self-watch" {
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
echo "12345 inotifywait -q -t 120 -e modify inbox/test_agent.yaml"
exit 0
MOCK
    chmod +x "$MOCK_PGREP"

    run bash -c "source '$TEST_HARNESS' && send_wakeup 3"
    [ "$status" -eq 0 ]

    # No nudge send-keys should have occurred
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"

    echo "$output" | grep -q "SKIP"
}

# --- T-SW-002: no self-watch → tmux send-keys ---

@test "T-SW-002: send_wakeup uses tmux send-keys when no self-watch" {
    run bash -c "source '$TEST_HARNESS' && send_wakeup 5"
    [ "$status" -eq 0 ]

    # Verify send-keys occurred with inbox5
    grep -q "send-keys.*inbox5" "$MOCK_LOG"
    # Verify Enter was sent (as separate call — Codex TUI compatibility)
    grep -q "send-keys.*Enter" "$MOCK_LOG"
}

# --- T-SW-003: send-keys content is "inboxN" + Enter (separated) ---

@test "T-SW-003: send-keys sends inboxN and Enter as separate calls" {
    run bash -c "source '$TEST_HARNESS' && send_wakeup 3"
    [ "$status" -eq 0 ]

    # Text and Enter are sent as separate send-keys calls (Codex TUI compatibility)
    grep -q "send-keys -t test:0.0 inbox3" "$MOCK_LOG"
    grep -q "send-keys -t test:0.0 Enter" "$MOCK_LOG"
}

# --- T-SW-004: send-keys failure → return 0 (daemon-safe) + WARNING log ---
# send_wakeup always returns 0 to avoid killing the watcher under set -euo pipefail.

@test "T-SW-004: send_wakeup returns 0 when send-keys fails (daemon-safe)" {
    run bash -c "MOCK_SENDKEYS_RC=1; source '$TEST_HARNESS' && send_wakeup 2"
    [ "$status" -eq 0 ]

    echo "$output" | grep -qi "WARNING\|failed"
}

# --- T-SW-005: no paste-buffer or set-buffer used ---

@test "T-SW-005: nudge delivery does NOT use paste-buffer or set-buffer" {
    run bash -c "source '$TEST_HARNESS' && send_wakeup 3"
    [ "$status" -eq 0 ]

    # These should never be used
    ! grep -q "paste-buffer" "$MOCK_LOG"
    ! grep -q "set-buffer" "$MOCK_LOG"

    # send-keys IS expected
    grep -q "send-keys" "$MOCK_LOG"
}

# --- T-SW-006: agent_has_self_watch — detects inotifywait ---

@test "T-SW-006: agent_has_self_watch returns 0 when inotifywait running" {
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
echo "99999 inotifywait -q -t 120 -e modify inbox/test_agent.yaml"
exit 0
MOCK
    chmod +x "$MOCK_PGREP"

    run bash -c "source '$TEST_HARNESS' && agent_has_self_watch"
    [ "$status" -eq 0 ]
}

# --- T-SW-007: agent_has_self_watch — no inotifywait ---

@test "T-SW-007: agent_has_self_watch returns 1 when no inotifywait" {
    run bash -c "source '$TEST_HARNESS' && agent_has_self_watch"
    [ "$status" -eq 1 ]
}

# --- T-SW-008: /clear uses send-keys ---

@test "T-SW-008: send_cli_command /clear uses tmux send-keys" {
    run bash -c "source '$TEST_HARNESS' && send_cli_command /clear"
    [ "$status" -eq 0 ]

    # Verify send-keys was used with /clear
    grep -q "send-keys.*/clear" "$MOCK_LOG"
    # C-c was sent first (stale input clearing)
    grep -q "send-keys.*C-c" "$MOCK_LOG"
    # Enter was sent after /clear
    grep -q "send-keys.*Enter" "$MOCK_LOG"
}

# --- T-SW-009: /model uses send-keys ---

@test "T-SW-009: send_cli_command /model uses tmux send-keys" {
    run bash -c "source '$TEST_HARNESS' && send_cli_command '/model opus'"
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/model opus" "$MOCK_LOG"
    grep -q "send-keys.*Enter" "$MOCK_LOG"
}

# --- T-SW-010: nudge content format ---

@test "T-SW-010: nudge content format is inboxN (backward compatible)" {
    run bash -c "source '$TEST_HARNESS' && send_wakeup 7"
    [ "$status" -eq 0 ]

    grep -q "send-keys.*inbox7" "$MOCK_LOG"
}

# --- T-SW-011: functions exist in inbox_watcher.sh ---

@test "T-SW-011: inbox_watcher.sh uses send-keys with required functions" {
    grep -q "send_wakeup()" "$WATCHER_SCRIPT"
    grep -q "agent_has_self_watch" "$WATCHER_SCRIPT"
    grep -q "send_wakeup_with_escape()" "$WATCHER_SCRIPT"
    grep -q "send_cli_command()" "$WATCHER_SCRIPT"

    # send-keys IS used in executable code
    local executable_lines
    executable_lines=$(grep -v '^\s*#' "$WATCHER_SCRIPT")
    echo "$executable_lines" | grep -q "send-keys"

    # paste-buffer and set-buffer are NOT used
    ! echo "$executable_lines" | grep -q "paste-buffer"
    ! echo "$executable_lines" | grep -q "set-buffer"
}

# --- T-ESC-001: no unread → FIRST_UNREAD_SEEN stays 0 ---

@test "T-ESC-001: escalation state resets when no unread messages" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        FIRST_UNREAD_SEEN=12345
        # Simulate no unread
        normal_count=0
        if [ "$normal_count" -gt 0 ] 2>/dev/null; then
            echo "SHOULD_NOT_REACH"
        else
            FIRST_UNREAD_SEEN=0
        fi
        echo "FIRST_UNREAD_SEEN=$FIRST_UNREAD_SEEN"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "FIRST_UNREAD_SEEN=0"
}

# --- T-ESC-002: unread < 2min → standard nudge ---

@test "T-ESC-002: escalation Phase 1 — unread under 2min uses standard nudge" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 30))  # 30 seconds ago
        age=$((now - FIRST_UNREAD_SEEN))
        if [ "$age" -lt "$ESCALATE_PHASE1" ]; then
            send_wakeup 2
            echo "PHASE1_NUDGE"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PHASE1_NUDGE"
    grep -q "send-keys.*inbox2" "$MOCK_LOG"
    # No Escape-based nudge
    ! grep -q "send-keys.*Escape" "$MOCK_LOG"
}

# --- T-ESC-003: unread 2-4min → Escape+nudge ---

@test "T-ESC-003: escalation Phase 2 — unread 2-4min uses Escape+nudge (copilot)" {
    # Escape escalation is suppressed for claude/codex (Stop hook / safety).
    # Test with copilot CLI which still uses Escape escalation.
    export MOCK_PANE_CLI="copilot"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 180))  # 3 minutes ago
        age=$((now - FIRST_UNREAD_SEEN))
        if [ "$age" -ge "$ESCALATE_PHASE1" ] && [ "$age" -lt "$ESCALATE_PHASE2" ]; then
            send_wakeup_with_escape 3
            echo "PHASE2_ESCAPE_NUDGE"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PHASE2_ESCAPE_NUDGE"
    # Escape was sent
    grep -q "send-keys.*Escape" "$MOCK_LOG"
    # Nudge was also sent
    grep -q "send-keys.*inbox3" "$MOCK_LOG"
}

# --- T-ESC-004: unread > 4min → /clear sent ---

@test "T-ESC-004: escalation Phase 3 — unread over 4min sends /clear" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 300))  # 5 minutes ago
        LAST_CLEAR_TS=0  # no recent /clear
        age=$((now - FIRST_UNREAD_SEEN))
        if [ "$age" -ge "$ESCALATE_PHASE2" ] && [ "$LAST_CLEAR_TS" -lt "$((now - ESCALATE_COOLDOWN))" ]; then
            send_cli_command "/clear"
            echo "PHASE3_CLEAR"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PHASE3_CLEAR"
    grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# --- T-ESC-005: /clear cooldown → falls back to Escape+nudge ---

@test "T-ESC-005: escalation /clear cooldown — falls back to Escape+nudge (copilot)" {
    # Escape escalation is suppressed for claude/codex. Test with copilot.
    export MOCK_PANE_CLI="copilot"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 300))  # 5 minutes ago
        LAST_CLEAR_TS=$((now - 60))  # /clear sent 1 min ago (within 5min cooldown)
        age=$((now - FIRST_UNREAD_SEEN))
        if [ "$age" -ge "$ESCALATE_PHASE2" ] && [ "$LAST_CLEAR_TS" -ge "$((now - ESCALATE_COOLDOWN))" ]; then
            send_wakeup_with_escape 4
            echo "COOLDOWN_FALLBACK"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "COOLDOWN_FALLBACK"
    grep -q "send-keys.*Escape" "$MOCK_LOG"
    grep -q "send-keys.*inbox4" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# --- T-BUSY-001: agent_is_busy detects "Working" ---

@test "T-BUSY-001: agent_is_busy returns 0 (busy) when no idle flag — claude CLI" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-002: agent_is_busy returns 1 when idle ---

@test "T-BUSY-002: agent_is_busy returns 1 when pane is idle" {
    run bash -c '
        MOCK_CAPTURE_PANE="› Summarize recent commits
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        agent_is_busy
    '
    [ "$status" -eq 1 ]
}

# --- T-BUSY-003: send_wakeup skips when agent is busy ---

@test "T-BUSY-003: send_wakeup skips nudge when agent is busy" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        send_wakeup 3
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "SKIP.*busy"

    # No nudge should have been sent
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
}

# --- T-BUSY-004: send_wakeup_with_escape skips when agent is busy ---

@test "T-BUSY-004: send_wakeup_with_escape skips when agent is busy" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        send_wakeup_with_escape 2
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "SKIP.*busy"

    # No nudge should have been sent
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
}

# --- T-CODEX-001: codex /clear → /new conversion ---

@test "T-CODEX-001: send_cli_command converts /clear to /new for codex" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    # Should send /new, NOT /clear
    grep -q "send-keys.*/new" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# --- T-CODEX-002: codex /model → skip ---

@test "T-CODEX-002: send_cli_command skips /model for codex" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        send_cli_command "/model opus"
    '
    [ "$status" -eq 0 ]

    # No tmux send-keys for /model
    ! grep -q "send-keys.*/model" "$MOCK_LOG"

    # Stderr indicates skip
    echo "$output" | grep -q "not supported on codex"
}

# --- T-CODEX-003: C-u sent when unread=0 and agent is idle ---

@test "T-CODEX-003: C-u cleanup sent when no unread and agent is idle" {
    run bash -c '
        MOCK_CAPTURE_PANE="› Summarize recent commits
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        # Simulate process_unread no-unread path
        FIRST_UNREAD_SEEN=12345
        normal_count=0
        if [ "$normal_count" -gt 0 ] 2>/dev/null; then
            echo "SHOULD_NOT_REACH"
        else
            FIRST_UNREAD_SEEN=0
            if ! agent_is_busy; then
                timeout 2 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null
                echo "C_U_SENT"
            fi
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "C_U_SENT"
    grep -q "send-keys.*C-u" "$MOCK_LOG"
}

# --- T-CODEX-004: C-u NOT sent when agent is busy ---

@test "T-CODEX-004: C-u cleanup NOT sent when agent is busy" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        FIRST_UNREAD_SEEN=12345
        normal_count=0
        if [ "$normal_count" -gt 0 ] 2>/dev/null; then
            echo "SHOULD_NOT_REACH"
        else
            FIRST_UNREAD_SEEN=0
            if ! agent_is_busy; then
                timeout 2 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null
                echo "C_U_SENT"
            else
                echo "C_U_SKIPPED"
            fi
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "C_U_SKIPPED"
    ! grep -q "C-u" "$MOCK_LOG"
}

# --- T-CODEX-005: claude /clear passes through as-is ---

@test "T-CODEX-005: send_cli_command sends /clear as-is for claude" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    # Should send /clear directly (not /new)
    grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "/new" "$MOCK_LOG"
}

# --- T-CODEX-006: inbox_watcher.sh has agent_is_busy and Codex/Copilot handlers ---

@test "T-CODEX-006: inbox_watcher.sh contains agent_is_busy and Codex/Copilot handlers" {
    grep -q "agent_is_busy()" "$WATCHER_SCRIPT"
    # Busy detection patterns live in lib/agent_status.sh (shared library)
    grep -q 'Working|Thinking|Planning|Sending' "$PROJECT_ROOT/lib/agent_status.sh"

    # Codex /clear → /new conversion exists
    grep -q '/new' "$WATCHER_SCRIPT"

    # Codex /model skip exists
    grep -q 'not supported on codex' "$WATCHER_SCRIPT"

    # C-u cleanup exists
    grep -q 'C-u' "$WATCHER_SCRIPT"

    # Copilot handler exists
    grep -q 'copilot --yolo' "$WATCHER_SCRIPT"
    grep -q 'not supported on copilot' "$WATCHER_SCRIPT"
}

# --- T-CODEX-007: pane cli overrides stale CLI_TYPE in Phase2 ---

@test "T-CODEX-007: pane @agent_cli=codex overrides stale CLI_TYPE for Phase2 (no C-c)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        send_wakeup_with_escape 2
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*inbox2" "$MOCK_LOG"
    # Codex: Escape escalation is suppressed (avoid interrupting work / human typing)
    ! grep -q "send-keys.*Escape" "$MOCK_LOG"
    ! grep -q "send-keys.*C-c" "$MOCK_LOG"
}

# --- T-CODEX-008: pane cli overrides stale CLI_TYPE in /clear path ---

@test "T-CODEX-008: pane @agent_cli=codex overrides stale CLI_TYPE for /clear (uses /new)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/new" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*C-c" "$MOCK_LOG"
}

# --- T-CODEX-009: invalid model_switch payload is rejected ---

@test "T-CODEX-009: normalize_special_command rejects invalid model_switch payload" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        cmd=$(normalize_special_command "model_switch" "please change model" 2>/dev/null)
        [ -z "$cmd" ]
    '
    [ "$status" -eq 0 ]
}

# --- T-CODEX-010: unresolved cli falls back to codex-safe ---

@test "T-CODEX-010: unresolved CLI type falls back to codex-safe (/clear->/new, no C-c)" {
    run bash -c '
        MOCK_PANE_CLI=""
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="unknown_cli"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/new" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*C-c" "$MOCK_LOG"
}

# --- T-CODEX-011: clear_command auto-recovery injection ---

@test "T-CODEX-011: process_unread injects auto-recovery task and sends inbox nudge after clear_command" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_clear
    from: karo
    timestamp: "2026-02-10T14:00:00+09:00"
    type: clear_command
    content: redo
    read: false
YAML
        process_unread event
        "$VENV_PYTHON" - << "PY" "$INBOX"
import sys
import yaml

inbox_path = sys.argv[1]
with open(inbox_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

messages = data.get("messages", []) or []
msg_clear = [m for m in messages if m.get("id") == "msg_clear"]
assert len(msg_clear) == 1 and msg_clear[0].get("read") is True

auto = [
    m for m in messages
    if m.get("from") == "inbox_watcher"
    and m.get("type") == "task_assigned"
    and "[auto-recovery]" in (m.get("content") or "")
]
assert len(auto) == 1
assert auto[0].get("read") is False
print("OK")
PY
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"

    # codex clear path uses /new
    grep -q "send-keys.*/new" "$MOCK_LOG"
    # After /new, startup prompt is sent (replaces inbox1 nudge for wake-up)
    grep -q "send-keys.*Session Start" "$MOCK_LOG"
}

# --- T-CODEX-012: auto-recovery dedupe ---

@test "T-CODEX-012: enqueue_recovery_task_assigned deduplicates unread auto-recovery message" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_auto_existing
    from: inbox_watcher
    timestamp: "2026-02-10T14:00:00+09:00"
    type: task_assigned
    content: "[auto-recovery] existing hint"
    read: false
YAML
        r1=$(enqueue_recovery_task_assigned)
        r2=$(enqueue_recovery_task_assigned)
        "$VENV_PYTHON" - << "PY" "$INBOX" "$r1" "$r2"
import sys
import yaml

inbox_path, r1, r2 = sys.argv[1], sys.argv[2], sys.argv[3]
with open(inbox_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}
messages = data.get("messages", []) or []
auto = [
    m for m in messages
    if m.get("from") == "inbox_watcher"
    and m.get("type") == "task_assigned"
    and "[auto-recovery]" in (m.get("content") or "")
    and m.get("read") is False
]
assert len(auto) == 1
assert r1 == "SKIP_DUPLICATE"
assert r2 == "SKIP_DUPLICATE"
print("OK")
PY
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-CODEX-013: auto-recovery skipped when task is cancelled ---

@test "T-CODEX-013: enqueue_recovery_task_assigned skips if task YAML status is cancelled" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        # Initialize inbox (required by enqueue_recovery_task_assigned)
        echo "messages: []" > "$INBOX"
        # Place task YAML with status: cancelled
        mkdir -p "$(dirname "$INBOX")/../tasks"
        cat > "$(dirname "$INBOX")/../tasks/test_agent.yaml" << "YAML"
worker_id: test_agent
task_id: subtask_test_cancelled
status: cancelled
YAML
        r=$(enqueue_recovery_task_assigned)
        # Should return SKIP_CANCELLED:cancelled
        if [ "$r" = "SKIP_CANCELLED:cancelled" ]; then echo "OK"; else echo "FAIL:$r"; fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-CODEX-014: auto-recovery skipped when task is idle ---

@test "T-CODEX-014: enqueue_recovery_task_assigned skips if task YAML status is idle" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        echo "messages: []" > "$INBOX"
        mkdir -p "$(dirname "$INBOX")/../tasks"
        cat > "$(dirname "$INBOX")/../tasks/test_agent.yaml" << "YAML"
worker_id: test_agent
task_id: subtask_test_idle
status: idle
YAML
        r=$(enqueue_recovery_task_assigned)
        if [ "$r" = "SKIP_CANCELLED:idle" ]; then echo "OK"; else echo "FAIL:$r"; fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-CODEX-015: auto-recovery proceeds when task is assigned ---

@test "T-CODEX-015: enqueue_recovery_task_assigned proceeds when task YAML status is assigned" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        echo "messages: []" > "$INBOX"
        mkdir -p "$(dirname "$INBOX")/../tasks"
        cat > "$(dirname "$INBOX")/../tasks/test_agent.yaml" << "YAML"
worker_id: test_agent
task_id: subtask_test_assigned
status: assigned
YAML
        r=$(enqueue_recovery_task_assigned)
        # Should return a message ID (not SKIP_*)
        if [[ "$r" != SKIP_* ]] && [[ "$r" != "ERROR" ]] && [[ -n "$r" ]]; then echo "OK"; else echo "FAIL:$r"; fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-COPILOT-001: copilot /clear → Ctrl-C + restart ---

@test "T-COPILOT-001: send_cli_command sends Ctrl-C + copilot restart for copilot /clear" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="copilot"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    # Should trigger copilot restart
    grep -q "send-keys.*C-c" "$MOCK_LOG"
    grep -q "send-keys.*copilot --yolo" "$MOCK_LOG"
    # NOT /clear or /new
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*/new" "$MOCK_LOG"
}

# --- T-COPILOT-002: copilot /model → skip ---

@test "T-COPILOT-002: send_cli_command skips /model for copilot" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="copilot"
        send_cli_command "/model opus"
    '
    [ "$status" -eq 0 ]

    ! grep -q "send-keys.*/model" "$MOCK_LOG"
    echo "$output" | grep -q "not supported on copilot"
}

# --- T-SHOGUN-001: session_has_client — client attached ---

@test "T-SHOGUN-001: session_has_client returns 0 when client attached" {
    run bash -c '
        MOCK_LIST_CLIENTS="/dev/pts/1: mock_session [200x50 xterm-256color]"
        source "'"$TEST_HARNESS"'"
        session_has_client
    '
    [ "$status" -eq 0 ]
}

# --- T-SHOGUN-002: session_has_client — no client ---

@test "T-SHOGUN-002: session_has_client returns 1 when no client" {
    run bash -c '
        MOCK_LIST_CLIENTS=""
        source "'"$TEST_HARNESS"'"
        session_has_client
    '
    [ "$status" -ne 0 ]
}

# --- T-SHOGUN-003: shogun + active pane + client attached → send-keys (post PR#75) ---

@test "T-SHOGUN-003: send_wakeup shogun + active + attached uses send-keys" {
    # cmd_768 v2: shogun+non-ntfy now skips unconditionally (busy or idle), so
    # this test — about send-keys mechanics (pane_active/list_clients), not
    # nudge-suppression semantics (see T-SHOGUN-005/007) — must pass has_ntfy=1
    # to reach the send-keys call at all. Idle flag is irrelevant here since
    # ntfy bypasses busy too, but kept for clarity.
    touch "$TEST_TMPDIR/shogun_idle_shogun"
    run bash -c '
        MOCK_PANE_ACTIVE="1"
        MOCK_LIST_CLIENTS="/dev/pts/1: mock_session [200x50 xterm-256color]"
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 2 1
    '
    [ "$status" -eq 0 ]

    # Post PR#75: shogun uses send-keys like other agents (display-message path removed)
    grep -q "send-keys.*inbox2" "$MOCK_LOG"
}

# --- T-SHOGUN-004: shogun + active pane + no client → send-keys fallthrough ---

@test "T-SHOGUN-004: send_wakeup shogun + active + detached falls through to send-keys" {
    # cmd_768 v2: see T-SHOGUN-003 — has_ntfy=1 required to reach send-keys.
    touch "$TEST_TMPDIR/shogun_idle_shogun"
    run bash -c '
        MOCK_PANE_ACTIVE="1"
        MOCK_LIST_CLIENTS=""
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 2 1
    '
    [ "$status" -eq 0 ]

    # Should NOT show display-message path
    ! echo "$output" | grep -q "DISPLAY"

    # Should have used send-keys
    grep -q "send-keys.*inbox2" "$MOCK_LOG"
}

# --- T-BUSY-005: agent_is_busy during /clear cooldown ---

@test "T-BUSY-005: agent_is_busy returns 0 (busy) during /clear cooldown period" {
    run bash -c '
        MOCK_CAPTURE_PANE="› prompt
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        LAST_CLEAR_TS=$((now - 10))  # /clear sent 10 seconds ago (within 30s cooldown)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-006: agent_is_busy idle after /clear cooldown expires ---

@test "T-BUSY-006: agent_is_busy returns 1 (idle) after /clear cooldown expires" {
    run bash -c '
        MOCK_CAPTURE_PANE="› prompt
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        LAST_CLEAR_TS=$((now - 40))  # /clear sent 40 seconds ago (past 30s cooldown)
        agent_is_busy
    '
    [ "$status" -eq 1 ]
}

# --- T-BUSY-007: /clear cooldown overrides idle pane ---

@test "T-BUSY-007: agent_is_busy /clear cooldown overrides idle pane state" {
    run bash -c '
        MOCK_CAPTURE_PANE="› Summarize recent commits
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        LAST_CLEAR_TS=$((now - 5))  # /clear sent 5 seconds ago
        # Pane looks idle, but cooldown should make it busy
        if agent_is_busy; then
            echo "BUSY_DURING_COOLDOWN"
        else
            echo "WRONGLY_IDLE"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BUSY_DURING_COOLDOWN"
}

# --- T-BUSY-008: idle prompt at bottom overrides old busy markers (false-busy fix) ---
# Bug: 59ec12f / 69c1ecb — old "Working" or "esc to interrupt" lingered in scroll-back
# above the idle prompt, causing false-busy. Fix: only check bottom 5 lines, idle first.

@test "T-BUSY-008: agent_is_busy returns idle when idle prompt is below old busy markers" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "◦ Working on task (12s • esc to interrupt)\nsome output line\nmore output\n\n❯ ")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        if agent_is_busy; then
            echo "WRONGLY_BUSY"
        else
            echo "CORRECTLY_IDLE"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "CORRECTLY_IDLE"
}

# --- T-BUSY-009: 'background terminal running' detected as busy ---
# Bug: 91ebf61 — Codex shows this when a tool is running in background.

@test "T-BUSY-009: agent_is_busy detects 'background terminal running' as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "Some output\nbackground terminal running\n")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="codex"  # pane-based detection (non-claude fallback)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-010: 'Compacting conversation' detected as busy ---

@test "T-BUSY-010: agent_is_busy detects 'Compacting conversation' as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "Compacting conversation...\n")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="codex"  # pane-based detection (non-claude fallback)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-011: 'esc to interrupt' detected as busy ---

@test "T-BUSY-011: agent_is_busy detects 'esc to interrupt' as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "◦ Thinking (5s • esc to interrupt)\n")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="codex"  # pane-based detection (non-claude fallback)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-SHOOK-001: Claude Code throttle uses 60s cooldown (post PR#75: stop-hook supplementary) ---

@test "T-SHOOK-001: Claude Code throttle uses 60s cooldown (stop-hook-supplementary)" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        LAST_NUDGE_TS=0
        LAST_NUDGE_COUNT=""

        # First call: should pass through (no throttle)
        should_throttle_nudge 1
        rc1=$?

        # Simulate 60s elapsed — cooldown expired for claude (60s, same as default)
        LAST_NUDGE_TS=$(($(date +%s) - 60))
        LAST_NUDGE_COUNT=1

        # Second call with same count after 60s: should NOT throttle (cooldown expired)
        should_throttle_nudge 1
        rc2=$?

        echo "rc1=$rc1 rc2=$rc2"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "rc1=1 rc2=1"  # 1=not-throttled, 1=not-throttled (60s cooldown expired)
}

# --- T-SHOOK-002: Claude Code count change bypasses throttle (post PR#75: standard behavior) ---

@test "T-SHOOK-002: Claude Code count change bypasses throttle (stop-hook-supplementary)" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        LAST_NUDGE_TS=0
        LAST_NUDGE_COUNT=""

        # First call: should pass through
        should_throttle_nudge 1
        rc1=$?

        # Simulate 30s elapsed, count changed from 1 to 2
        LAST_NUDGE_TS=$(($(date +%s) - 30))

        # Post PR#75: Claude uses standard throttle logic.
        # Count change (1→2) bypasses throttle for ALL CLIs including claude.
        should_throttle_nudge 2
        rc2=$?

        echo "rc1=$rc1 rc2=$rc2"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "rc1=1 rc2=1"  # Both: 1=not-throttled (count change bypasses)
}

# --- T-SHOOK-003: Non-Claude CLIs bypass throttle on count change ---

@test "T-SHOOK-003: Non-Claude CLIs still bypass throttle on count change" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="copilot"
        LAST_NUDGE_TS=0
        LAST_NUDGE_COUNT=""

        # First call
        should_throttle_nudge 1
        rc1=$?

        # Simulate 30s elapsed, count changed from 1 to 2
        LAST_NUDGE_TS=$(($(date +%s) - 30))

        # For copilot, count change (1→2) SHOULD bypass throttle
        should_throttle_nudge 2
        rc2=$?

        echo "rc1=$rc1 rc2=$rc2"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "rc1=1 rc2=1"  # Both pass through (count changed)
}

# --- T-CRESET-001: send_context_reset suppresses /clear for karo ---

@test "T-CRESET-001: send_context_reset suppresses /clear for karo" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="karo"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    # No send-keys should have occurred
    ! grep -q "send-keys" "$MOCK_LOG"

    # SKIP message in stderr
    echo "$output" | grep -q "SKIP.*karo"
}

# --- T-CRESET-002: send_context_reset suppresses /clear for gunshi ---

@test "T-CRESET-002: send_context_reset suppresses /clear for gunshi" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="gunshi"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    # No send-keys should have occurred
    ! grep -q "send-keys" "$MOCK_LOG"

    # SKIP message in stderr
    echo "$output" | grep -q "SKIP.*gunshi"
}

# --- T-CRESET-003: send_context_reset sends /clear for ashigaru ---

@test "T-CRESET-003: send_context_reset sends /clear for ashigaru" {
    # cmd_760 fix1(b): send_context_reset now confirms via agent_is_busy_confirmed()
    # before sending, which needs the idle flag under the AGENT_ID actually used
    # inside the run block (setup() only pre-creates one for the harness default
    # "test_agent", not for the "ashigaru3" this test reassigns to).
    touch "$TEST_TMPDIR/shogun_idle_ashigaru3"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru3"
        CLI_TYPE="claude"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    # /clear should have been sent via send-keys
    grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# --- T-CRESET-004: ★真因の回帰テスト — claude経路は/clear後にsend_startup_promptを呼ぶ ---
# 是正前: send_context_resetのnon-codex分岐(claude/copilot/kimi共通)は/clear送信後
# idleになるまでpollするだけで終わり、send_startup_promptを一切呼んでいなかった。
# codex経路(818-830行)はsend_startup_promptを呼ぶため、claude経路だけ非対称だった。

@test "T-CRESET-004: send_context_reset calls send_startup_prompt after /clear for claude (symmetry fix)" {
    touch "$TEST_TMPDIR/shogun_idle_ashigaru3"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru3"
        CLI_TYPE="claude"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    # /clear must have been sent
    grep -q "send-keys.*/clear" "$MOCK_LOG"

    # send_startup_prompt's fallback prompt text (no cli_adapter under __INBOX_WATCHER_TESTING__)
    # must appear AFTER the /clear send — proving the follow-up re-dispatch happened.
    local clear_line startup_line
    clear_line=$(grep -n "send-keys.*/clear" "$MOCK_LOG" | head -1 | cut -d: -f1)
    startup_line=$(grep -n "Session Start" "$MOCK_LOG" | head -1 | cut -d: -f1)
    [ -n "$clear_line" ]
    [ -n "$startup_line" ]
    [ "$startup_line" -gt "$clear_line" ]
}

# --- T-CRESET-005: regression — codex経路は既にstartup promptを送る ---

@test "T-CRESET-005: send_context_reset still sends startup prompt after /new for codex (regression)" {
    touch "$TEST_TMPDIR/shogun_idle_ashigaru4"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru4"
        CLI_TYPE="codex"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/new" "$MOCK_LOG"
    grep -q "Session Start" "$MOCK_LOG"
}

# --- T-CRESET-006: regression — clear_command型(send_cli_command)のclaude /clearは既にstartup promptを送る ---

@test "T-CRESET-006: send_cli_command still sends startup prompt after /clear for claude (regression)" {
    # setup() already created shogun_idle_test_agent (default AGENT_ID=test_agent)
    run bash -c '
        source "'"$TEST_HARNESS"'"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/clear" "$MOCK_LOG"
    grep -q "Session Start" "$MOCK_LOG"
}

# --- cmd_768 v2: 将軍paneへの通常nudge抑止(busy/idle問わず・ntfyは即時のまま) ---
# 真因(v1で見落とし): send_wakeup/process_unreadの旧guardが
# `agent_is_busy && { AGENT_ID!=shogun || has_ntfy!=1 }` という形で、
# busyの時にしか発火しなかった。将軍がidle(=殿が打鍵する瞬間そのもの)の
# 場合はagent_is_busy=falseとなり、通常報告がそのままsend-keysへ落ちて
# いた——差し戻しの核心はここ(busy時しか検証していなかった)。
# 修正: shogun+has_ntfy!=1は、busy/idleの分岐に入る前に無条件でreturn 0。
# shogun+has_ntfy=1は従来どおりbusyでも即時配送。他エージェントの
# busy guardは変更なし。
#
#   T-SHOGUN-005: send_wakeup — shogun IDLE + has_ntfy=0(通常) → nudge抑止 ★v1の穴
#   T-SHOGUN-005b: send_wakeup — shogun busy + has_ntfy=0(通常) → nudge抑止(回帰)
#   T-SHOGUN-006: send_wakeup — shogun IDLE + has_ntfy=1(ntfy) → nudge即時配送(回帰)
#   T-SHOGUN-006b: send_wakeup — shogun busy + has_ntfy=1(ntfy) → nudge即時配送(回帰)
#   T-SHOGUN-007: process_unread — shogun IDLE + karo通常報告 → send-keys発火せず ★実証(a)そのもの
#   T-SHOGUN-007b: process_unread — shogun busy + karo通常報告 → send-keys発火せず(回帰)
#   T-SHOGUN-008: process_unread — shogun IDLE + ntfy_received → send-keys即時発火 ★実証(b)そのもの
#   T-SHOGUN-008b: process_unread — shogun busy + ntfy_received → send-keys即時発火(回帰)
#   T-SHOGUN-009: send_cli_command — shogunはCLIコマンド注入抑止のまま(安全弁2・未変更確認)
#   T-SHOGUN-010: send_wakeup_with_escape — shogunはEscapeエスカレーション抑止のまま(安全弁3・未変更確認)

# --- T-SHOGUN-005: send_wakeup skips nudge for IDLE shogun when message is NOT ntfy (the v1 gap) ---

@test "T-SHOGUN-005: send_wakeup skips nudge when shogun is IDLE and has_ntfy=0 (normal report)" {
    # Idle flag present => agent_is_busy() reports idle. This is exactly the
    # moment the Lord is at the keyboard, and exactly what v1 failed to guard.
    touch "$TEST_TMPDIR/shogun_idle_shogun"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 3 0
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "SKIP.*shogun"

    # No nudge should have been sent, idle or not.
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
}

# --- T-SHOGUN-005b: send_wakeup skips nudge for BUSY shogun when message is NOT ntfy (regression) ---

@test "T-SHOGUN-005b: send_wakeup skips nudge when shogun is busy and has_ntfy=0 (normal report)" {
    rm -f "$TEST_TMPDIR/shogun_idle_shogun"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 3 0
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "SKIP.*shogun"

    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
}

# --- T-SHOGUN-006: send_wakeup still delivers immediately for IDLE shogun when message IS ntfy ---

@test "T-SHOGUN-006: send_wakeup still sends nudge when shogun is IDLE and has_ntfy=1 (ntfy)" {
    touch "$TEST_TMPDIR/shogun_idle_shogun"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 1 1
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*inbox1" "$MOCK_LOG"
}

# --- T-SHOGUN-006b: send_wakeup still delivers immediately for BUSY shogun when message IS ntfy (regression) ---

@test "T-SHOGUN-006b: send_wakeup still sends nudge when shogun is busy and has_ntfy=1 (ntfy)" {
    rm -f "$TEST_TMPDIR/shogun_idle_shogun"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 1 1
    '
    [ "$status" -eq 0 ]

    # ntfy must still reach the shogun pane immediately, even while busy.
    grep -q "send-keys.*inbox1" "$MOCK_LOG"
}

# --- T-SHOGUN-007: process_unread — IDLE shogun + normal (karo) report → no send-keys (実証a) ---

@test "T-SHOGUN-007: process_unread sends no nudge to IDLE shogun for a normal karo report" {
    # This is the exact scenario the Lord experiences: shogun idle, karo's
    # normal report arrives. v1 still fired send-keys here; v2 must not.
    touch "$TEST_TMPDIR/shogun_idle_shogun"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        INBOX="$TEST_INBOX_DIR/shogun.yaml"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_karo_report
    from: karo
    timestamp: "2026-09-06T09:00:00+09:00"
    type: report_received
    content: "cmd_999完了報告"
    read: false
YAML
        process_unread event
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "SKIP.*shogun"

    # No nudge keystrokes reached the shogun pane at all.
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
}

# --- T-SHOGUN-007b: process_unread — BUSY shogun + normal (karo) report → no send-keys (regression) ---

@test "T-SHOGUN-007b: process_unread sends no nudge to busy shogun for a normal karo report" {
    rm -f "$TEST_TMPDIR/shogun_idle_shogun"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        INBOX="$TEST_INBOX_DIR/shogun.yaml"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_karo_report
    from: karo
    timestamp: "2026-09-06T09:00:00+09:00"
    type: report_received
    content: "cmd_999完了報告"
    read: false
YAML
        process_unread event
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "busy"

    # No nudge keystrokes reached the shogun pane — Stop hook will pick it up at turn end.
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
}

# --- T-SHOGUN-008: process_unread — IDLE shogun + ntfy_received → nudge sent immediately (実証b) ---

@test "T-SHOGUN-008: process_unread still sends nudge to IDLE shogun for ntfy_received" {
    touch "$TEST_TMPDIR/shogun_idle_shogun"
    # Matches production launch config (shutsujin_departure.sh): ASW_DISABLE_NORMAL_NUDGE=0
    # forces the independent Phase-2+ throttle (disable_normal_nudge(), unrelated to cmd_768)
    # to never suppress Phase 1 nudges — the real deployed behavior this test verifies against.
    run bash -c '
        export ASW_DISABLE_NORMAL_NUDGE=0
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        INBOX="$TEST_INBOX_DIR/shogun.yaml"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_ntfy
    from: ntfy_listener
    timestamp: "2026-09-06T09:00:00+09:00"
    type: ntfy_received
    content: "ntfyから新しいメッセージ受信。queue/ntfy_inbox.yaml を確認し処理せよ。"
    read: false
YAML
        process_unread event
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*inbox1" "$MOCK_LOG"
}

# --- T-SHOGUN-008b: process_unread — BUSY shogun + ntfy_received → nudge sent immediately (regression) ---

@test "T-SHOGUN-008b: process_unread still sends nudge to busy shogun for ntfy_received (regression)" {
    rm -f "$TEST_TMPDIR/shogun_idle_shogun"
    run bash -c '
        export ASW_DISABLE_NORMAL_NUDGE=0
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        INBOX="$TEST_INBOX_DIR/shogun.yaml"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_ntfy
    from: ntfy_listener
    timestamp: "2026-09-06T09:00:00+09:00"
    type: ntfy_received
    content: "ntfyから新しいメッセージ受信。queue/ntfy_inbox.yaml を確認し処理せよ。"
    read: false
YAML
        process_unread event
    '
    [ "$status" -eq 0 ]

    # ntfy delivery must not be delayed by busy state.
    grep -q "send-keys.*inbox1" "$MOCK_LOG"
}

# --- T-SHOGUN-009: safety valve #2 (untouched) — CLI command injection suppression for shogun ---

@test "T-SHOGUN-009: send_cli_command still suppresses CLI injection for shogun (safety valve, unchanged)" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "suppressing CLI command injection"

    # /clear must never be injected into the shogun pane.
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# --- T-SHOGUN-010: safety valve #3 (untouched) — Escape escalation suppression for shogun ---

@test "T-SHOGUN-010: send_wakeup_with_escape still suppresses Escape for shogun (safety valve, unchanged)" {
    # has_ntfy=1 here — this test's job is to confirm Escape is never sent to
    # shogun, decoupled from cmd_768's has_ntfy=0 nudge-suppression (T-SHOGUN-005).
    # It falls through to plain send_wakeup, which for ntfy still delivers.
    touch "$TEST_TMPDIR/shogun_idle_shogun"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup_with_escape 2 1
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "suppressing Escape escalation"

    # Escape must never be sent to the shogun pane; falls through to plain nudge instead.
    ! grep -q "send-keys.*Escape" "$MOCK_LOG"
    grep -q "send-keys.*inbox2" "$MOCK_LOG"
}
