#!/usr/bin/env bats
# test_cmd778_double_clear_fix.bats — cmd_778 24時間家中完全停止・根本原因2件の回帰テスト
#
# 背景 (2026-09-06 22:47-22:48 ashigaru4実測ログ, logs/inbox_watcher_ashigaru4.log):
#   22:47:15 [SEND-KEYS] /clear送信 (send_cli_command, clear_command由来)
#   22:47:36 [STARTUP] still busy after 15s — proceeding with startup prompt anyway
#            (★疑い1: agent_is_busy()の/clear cooldown(30s)がpollの上限(15s)より
#             長く、pollは常にタイムアウトしてbusyなpaneへ強制Enterを送る)
#   22:47:42 [AUTO-RECOVERY] queued task_assigned (clear_sent==1で自動投入)
#   22:48:12 [CONTEXT-RESET] /clear送信 ← 2度目 (send_context_reset, task_assigned由来)
#            (★疑い2: send_context_resetの生send-keysにはC-c/C-u前処理も受理検証も
#             無く、かつ同一エージェントへの/clear送出に冷却期間が無かったため、
#             1度目の残滓の上に2度目の/clearが上書き/結合されうる)
#   以後24時間無音
#
# 是正 (scripts/inbox_watcher.sh):
#   1. send_reset_command_verified() — send_cli_command専用だったC-c/C-u前処理+
#      受理検証+リトライを共有ヘルパー化し、send_context_reset()からも呼ぶ。
#   2. CLEAR_RESEND_COOLDOWN_SEC(既定60s) — send_context_reset()とsend_cli_command()
#      の両方に、直近の/clear送出から冷却期間内なら送出をスキップするガードを追加。
#   3. send_startup_prompt() — pollがタイムアウトして「busyなまま強制送出」する
#      経路でのみ、Enter取りこぼしに備えた安全網の再送を行う(確実にidleと判った
#      経路では追加送信しない — 進行中ターンへの無関係な割り込みを避けるため)。
#
# テスト構成:
#   T-778-01: send_context_reset — 冷却期間内なら送信せずreturn 1 (★疑い2の核心)
#   T-778-02: send_context_reset — 冷却期間が過ぎていれば通常通り送信 (regression)
#   T-778-03: send_context_reset — /clear送信前にC-uが送られる (★疑い2、旧実装は無かった)
#   T-778-04: send_context_reset — 残滓検出時にリトライする (★疑い2、旧実装は無かった)
#   T-778-05: send_cli_command — 冷却期間内なら/clear送信をスキップする (symmetry)
#   T-778-06: send_startup_prompt — busyが解消せず強制送出する経路ではEnterを2回送る (★疑い1)
#   T-778-07: send_startup_prompt — 最初からidleならEnterは1回だけ (過剰な安全網を避ける)
#   T-778-08: send_context_reset — 短時間に2回呼ばれても2発目は完全に無送信 (★E2Eシナリオ実測)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"

setup_file() {
    export PROJECT_ROOT="$SCRIPT_DIR"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export IDLE_FLAG_DIR="$(mktemp -d "$BATS_TMPDIR/cmd778_test.XXXXXX")"
    export TEST_TMP="$(mktemp -d "$BATS_TMPDIR/cmd778_tmp.XXXXXX")"
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks" "$TEST_TMP/lib"
    ln -sfn "$PROJECT_ROOT/.venv" "$TEST_TMP/.venv"
    ln -sf "$SCRIPT_DIR/lib/agent_status.sh" "$TEST_TMP/lib/agent_status.sh"

    export WATCHER_HARNESS="$IDLE_FLAG_DIR/watcher_harness.sh"
    export MOCK_LOG="$IDLE_FLAG_DIR/tmux_calls.log"
    > "$MOCK_LOG"
    export MOCK_CAPTURE_PANE=""
    export MOCK_PANE_CLI="claude"
    export MOCK_SENDKEYS_RC=0

    cat > "$WATCHER_HARNESS" << HARNESS
#!/bin/bash
AGENT_ID="test_778_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_TMP/queue/inbox/test_778_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$TEST_TMP"

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
    if echo "\$*" | grep -q "display-message.*pane_id"; then
        echo "%1"
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        echo "mock_session"
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { return 1; }
sleep() { :; }
export -f tmux timeout pgrep sleep

export __INBOX_WATCHER_TESTING__=1
source "$SCRIPT_DIR/scripts/inbox_watcher.sh"
HARNESS
    chmod +x "$WATCHER_HARNESS"
}

teardown() {
    rm -rf "$IDLE_FLAG_DIR" "$TEST_TMP"
}

# ─── T-778-01: 冷却期間内なら送信せずreturn 1 (★疑い2の核心) ───

@test "T-778-01: send_context_reset defers (returns 1, no send-keys) when a /clear was sent within the cooldown" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_778_agent"
    MOCK_CAPTURE_PANE="❯"

    run bash -c "
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        LAST_CLEAR_TS=\$((now - 10))  # /clear sent 10s ago (well within 60s cooldown)
        send_context_reset
    "
    [ "$status" -eq 1 ]
    run grep -qF "cooldown active" <<< "$output"
    assert_success 2>/dev/null || [ "$status" -eq 0 ]
    run grep -qF "send-keys.*/clear" "$MOCK_LOG"
    [ "$status" -ne 0 ]
}

# ─── T-778-02: 冷却期間が過ぎていれば通常通り送信 (regression) ───

@test "T-778-02: send_context_reset sends /clear normally once the cooldown has elapsed" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_778_agent"
    MOCK_CAPTURE_PANE="❯"

    run bash -c "
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        LAST_CLEAR_TS=\$((now - 90))  # /clear sent 90s ago (past 60s cooldown)
        send_context_reset
    "
    [ "$status" -eq 0 ]
    grep -q "send-keys -t test:0.0 /clear" "$MOCK_LOG"
}

# ─── T-778-03: /clear送信前にC-uが送られる (★疑い2、旧実装は無かった) ───

@test "T-778-03: send_context_reset clears stale input (C-u) before typing /clear" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_778_agent"
    MOCK_CAPTURE_PANE="❯"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        send_context_reset
    "
    [ "$status" -eq 0 ]
    local cu_line clear_line
    cu_line=$(grep -n "send-keys -t test:0.0 C-u" "$MOCK_LOG" | head -1 | cut -d: -f1)
    clear_line=$(grep -n "send-keys -t test:0.0 /clear" "$MOCK_LOG" | head -1 | cut -d: -f1)
    [ -n "$cu_line" ]
    [ -n "$clear_line" ]
    [ "$cu_line" -lt "$clear_line" ]
}

# ─── T-778-04: 残滓検出時にリトライする (★疑い2、旧実装は無かった) ───

@test "T-778-04: send_context_reset retries the /clear send when residual text is still visible" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_778_agent"
    # capture-pane always shows "/clear" still sitting in the input line —
    # simulates the exact "second /clear concatenated onto residual text"
    # failure mode from the 2026-09-06 incident.
    MOCK_CAPTURE_PANE="/clear"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        send_context_reset
    "
    [ "$status" -eq 0 ]
    local clear_sends
    clear_sends=$(grep -c "send-keys -t test:0.0 /clear" "$MOCK_LOG")
    [ "$clear_sends" -gt 1 ]
    echo "$output" | grep -q "may not have been accepted"
}

# ─── T-778-05: send_cli_command — 冷却期間内なら/clear送信をスキップ (symmetry) ───

@test "T-778-05: send_cli_command also defers /clear within the cooldown (symmetry with send_context_reset)" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_778_agent"
    MOCK_CAPTURE_PANE="❯"

    # 40s ago: past agent_is_busy()'s own built-in 30s /clear-cooldown (so the
    # pre-existing agent_is_busy_confirmed guard above ours does NOT fire),
    # but still within CLEAR_RESEND_COOLDOWN_SEC's 60s window — isolates the
    # NEW explicit guard from the old implicit one.
    run bash -c "
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        LAST_CLEAR_TS=\$((now - 40))
        send_cli_command '/clear'
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "cooldown active"
    run grep -qF "send-keys.*/clear" "$MOCK_LOG"
    [ "$status" -ne 0 ]
}

# ─── T-778-06: busyが解消せず強制送出する経路ではEnterを2回送る (★疑い1) ───

@test "T-778-06: send_startup_prompt sends a safety-net second Enter when it had to force-send into an unconfirmed-busy pane" {
    # No idle flag ever created -> agent_is_busy() stays busy the entire poll,
    # matching the real incident where the poll's 15s bound is shorter than
    # agent_is_busy()'s own 30s /clear cooldown and can never observe idle.
    rm -f "$IDLE_FLAG_DIR/shogun_idle_test_778_agent"
    MOCK_CAPTURE_PANE="✻ Working on task (5s • esc to interrupt)"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        send_startup_prompt
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "proceeding with startup prompt anyway"
    echo "$output" | grep -q "safety net"
    local enter_sends
    enter_sends=$(grep -c "send-keys -t test:0.0 Enter" "$MOCK_LOG")
    [ "$enter_sends" -eq 2 ]
}

# ─── T-778-07: 最初からidleならEnterは1回だけ (過剰な安全網を避ける) ───

@test "T-778-07: send_startup_prompt sends only ONE Enter when idle was confirmed cleanly (no unnecessary retry)" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_778_agent"
    MOCK_CAPTURE_PANE="❯"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        send_startup_prompt
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "idle after 1×5s"
    ! echo "$output" | grep -q "safety net"
    local enter_sends
    enter_sends=$(grep -c "send-keys -t test:0.0 Enter" "$MOCK_LOG")
    [ "$enter_sends" -eq 1 ]
}

# ─── T-778-08: 短時間に2回呼ばれても2発目は完全に無送信 (★E2Eシナリオ実測) ───
# acceptance_criteria: "短時間に2回task_assignedが来てcontext resetが二重発火
# しそうになるシナリオ" を、process_unread相当の2回連続呼び出しで直接再現する。

@test "T-778-08: two send_context_reset calls in quick succession — the second is a complete no-op" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_778_agent"
    MOCK_CAPTURE_PANE="❯"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        send_context_reset   # first call — simulates the clear_command-triggered /clear
        first_rc=\$?
        first_sends=\$(grep -c 'send-keys -t test:0.0 /clear' '$MOCK_LOG')
        send_context_reset   # second call moments later — simulates the auto-recovery
                             # task_assigned message reaching send_context_reset on the
                             # very next watcher cycle (the real 2026-09-06 sequence)
        second_rc=\$?
        second_sends=\$(grep -c 'send-keys -t test:0.0 /clear' '$MOCK_LOG')
        echo \"first_rc=\$first_rc first_sends=\$first_sends second_rc=\$second_rc second_sends=\$second_sends\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "first_rc=0 first_sends=1 second_rc=1 second_sends=1"
}
