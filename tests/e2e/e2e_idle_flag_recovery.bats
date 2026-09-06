#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-010: /clear + idle flag recovery
# ═══════════════════════════════════════════════════════════════
# Validates:
#   A) /clear processing restores idle flag (IDLE_FLAG_DIR)
#   B) stale busy recovery can force idle flag creation
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

E2E_HELPERS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/helpers" && pwd)"
source "$E2E_HELPERS_DIR/setup.bash"
source "$E2E_HELPERS_DIR/assertions.bash"
source "$E2E_HELPERS_DIR/tmux_helpers.bash"

setup_file() {
    command -v tmux &>/dev/null || skip "tmux not available"
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -c "import yaml" 2>/dev/null || skip "python3-yaml not available"

    setup_e2e_session 2
}

teardown_file() {
    teardown_e2e_session
}

setup() {
    reset_queues
    sleep 1
}

wait_for_file_within() {
    local target="$1" timeout="${2:-20}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        [ -f "$target" ] && return 0
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT: file not found: $target" >&2
    return 1
}

wait_for_log() {
    local log_file="$1" pattern="$2" timeout="${3:-20}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if grep -qF "$pattern" "$log_file" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT: '$pattern' not found in $log_file after ${timeout}s" >&2
    return 1
}

# ═══ E2E-010-A: /clear後にidle flagが作成される ═══

@test "E2E-010-A: /clear recovery creates idle flag" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)
    local flag_dir log_file watcher_pid

    flag_dir="$(mktemp -d "/tmp/e2e_idle_flags_XXXXXX")"
    local ashigaru_idle_flag="$flag_dir/shogun_idle_ashigaru1"

    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
        "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    log_file="/tmp/e2e_inbox_watcher_ashigaru1_clear_${BASHPID}.log"
    watcher_pid=$(
        IDLE_FLAG_DIR="$flag_dir" \
        bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru1" "$ashigaru1_pane" "claude" \
            > "$log_file" 2>&1 &
        echo $!
    )
    sleep 1

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "/clear" "clear_command" "karo"

    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "done" 45
    assert_success

    run wait_for_file_within "$ashigaru_idle_flag" 10
    assert_success

    stop_inbox_watcher "$watcher_pid"
    rm -rf "$flag_dir"
}

# ═══ E2E-010-B: stale busy recovery forces idle flag (claude stuck-flag scenario) ═══
#
# ★subtask_e2e010b_fix_test_scenario (gunshi design evaluation, 甲 recommendation):
# this test originally exercised the stale-busy-recovery safety net with
# cli="copilot", but that machinery only ever matters for claude. agent_is_busy()
# is flag-based for claude (busy = idle flag file ABSENT) and pane-based for
# every other CLI (agent_is_busy_check() against the live tmux pane) — see
# scripts/inbox_watcher.sh lines ~944-950. The safety net exists specifically
# to recover from claude's create-only idle-flag deadlock: the flag can get
# stuck reporting "busy" for good after a bug, even though the pane itself has
# long since gone idle. For non-claude CLIs, agent_is_busy() re-reads the real
# pane every cycle, so there is no "stuck flag" state to recover from in the
# first place — testing this path with copilot was checking the wrong CLI.
# The real scenario: idle flag file is simply missing (claude "busy" per
# flag), the pane has actually been idle the whole time, and unread messages
# have been sitting for >5 minutes (FIRST_UNREAD_SEEN pre-set stale below).

@test "E2E-010-B: stale busy recovery forces idle flag creation (claude stuck-flag scenario)" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)
    local flag_dir log_file watcher_pid first_unread_seen

    flag_dir="$(mktemp -d "/tmp/e2e_idle_flags_stale_XXXXXX")"
    local ashigaru_idle_flag="$flag_dir/shogun_idle_ashigaru1"
    first_unread_seen=$(( $(date +%s) - 420 ))

    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "claude"
    # Reset the pane's visible screen so no leftover text from an earlier
    # test (e.g. E2E-010-A's own /clear cycle) can be misread as busy by
    # agent_is_busy_check()'s broad keyword fallback (see E2E-009-B fix in
    # this same file's git history for why `clear-history` alone is not
    # enough — it doesn't touch the visible screen, only scrollback).
    tmux send-keys -R -t "$ashigaru1_pane" 2>/dev/null || true
    sleep 1

    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
        "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # Start the watcher WITHOUT the task_assigned message yet.
    # inbox_watcher.sh unconditionally touches the idle flag at startup for
    # cli=claude ("CLI starts idle") — if the task_assigned message were
    # already queued, process_unread_once() would consume it right there
    # via the normal send_context_reset() path (flag present = idle) before
    # this test ever reaches the busy branch it's actually targeting.
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_stale_busy_${BASHPID}.log"
    watcher_pid=$(
        IDLE_FLAG_DIR="$flag_dir" \
        FIRST_UNREAD_SEEN="$first_unread_seen" \
        bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru1" "$ashigaru1_pane" "claude" \
            > "$log_file" 2>&1 &
        echo $!
    )

    run wait_for_file_within "$ashigaru_idle_flag" 10
    assert_success

    # Simulate the flag going missing (the create-only-flag deadlock this
    # safety net exists to recover from) BEFORE the unread message arrives,
    # so agent_is_busy() reports "busy" (flag absent) from the very first
    # read — matching the real "stuck busy while pane is actually idle" bug.
    rm -f "$ashigaru_idle_flag"

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    run wait_for_log "$log_file" "forcing idle flag"
    if [ "$status" -ne 0 ]; then
        dump_pane_for_debug "$ashigaru1_pane" "ashigaru1-claude-010B"
        echo "=== Watcher log ($log_file) ===" >&2
        cat "$log_file" >&2 2>/dev/null || true
        echo "=== End watcher log ===" >&2
    fi
    assert_success

    run wait_for_file_within "$ashigaru_idle_flag" 10
    assert_success

    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "done" 45
    assert_success

    stop_inbox_watcher "$watcher_pid"
    rm -rf "$flag_dir"
}
