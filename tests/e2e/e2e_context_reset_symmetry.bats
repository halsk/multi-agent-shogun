#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-CRSYM: CONTEXT-RESET 3経路対称性 — 実配送路(real tmux)による実測
# ═══════════════════════════════════════════════════════════════
# 背景: send_context_resetのclaude経路(task_assigned検知時)は/clear送信後
# にsend_startup_promptを呼んでいなかった(codex経路とsend_cli_command経路
# は既に対称)。unitテスト(tests/unit/test_send_wakeup.bats T-CRESET-004〜006)
# はtmuxをモックして関数呼び出し順序を検証するが、将軍裁定
# (queue/tasks/ashigaru2.yaml addendum_20260905_2215)は「実際の配送経路を
# 通した確認」も求めている。
#
# このファイルは REAL tmux (モック無し) + 最小限のfake CLI を使い、
# inbox_watcher.shが実際にtmux paneへ/clear(またはcodexは/new)を送り、
# 続けてstartup promptを送り、fake CLIがそれを実際の1行入力として受理し
# "TASK_READ_TRIGGERED" を記録することを実測する。
# 共有ヘルパーsetup_e2e_session()の "agents.0" 決め打ちアドレッシングは
# このマシンのtmux設定(pane-base-index=1)と噛み合わず落ちるため
# (pre-existing・本taskの変更と無関係)、本ファイルは list-panes で得た
# 実際のpane_idを使い、その問題を回避する。
#
# 3経路 (queue/tasks/ashigaru2.yaml本文が指す「3経路」と対応):
#   E2E-CRSYM-A: send_context_reset — claude (task_assigned) ★真因の実測
#   E2E-CRSYM-B: send_context_reset — codex (task_assigned) regression
#   E2E-CRSYM-C: send_cli_command   — claude (clear_command) regression
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

E2E_HELPERS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/helpers" && pwd)"
source "$E2E_HELPERS_DIR/assertions.bash"

setup_file() {
    command -v tmux &>/dev/null || skip "tmux not available"
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -c "import yaml" 2>/dev/null || skip "python3-yaml not available"

    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    export E2E_QUEUE
    E2E_QUEUE="$(mktemp -d "/tmp/e2e_crsym_queue_XXXXXX")"
    mkdir -p "$E2E_QUEUE"/queue/{inbox,tasks,reports,metrics}
    mkdir -p "$E2E_QUEUE/scripts" "$E2E_QUEUE/lib" "$E2E_QUEUE/config"
    cp "$PROJECT_ROOT/scripts/inbox_write.sh" "$E2E_QUEUE/scripts/"
    cp "$PROJECT_ROOT/scripts/inbox_watcher.sh" "$E2E_QUEUE/scripts/"
    chmod +x "$E2E_QUEUE/scripts/"*.sh
    cp "$PROJECT_ROOT/lib/cli_adapter.sh" "$E2E_QUEUE/lib/" 2>/dev/null || true
    cp "$PROJECT_ROOT/lib/agent_status.sh" "$E2E_QUEUE/lib/" 2>/dev/null || true
    cp "$PROJECT_ROOT/config/settings.yaml" "$E2E_QUEUE/config/" 2>/dev/null || true

    if [ -d "$PROJECT_ROOT/.venv" ]; then
        ln -sf "$PROJECT_ROOT/.venv" "$E2E_QUEUE/.venv"
    fi
    if [ ! -x "$E2E_QUEUE/.venv/bin/python3" ] && command -v python3 &>/dev/null; then
        rm -f "$E2E_QUEUE/.venv"
        mkdir -p "$E2E_QUEUE/.venv/bin"
        ln -sf "$(command -v python3)" "$E2E_QUEUE/.venv/bin/python3"
    fi

    echo "messages:" > "$E2E_QUEUE/queue/inbox/ashigaru9.yaml"

    # Minimal REAL CLI stand-in — reads real lines delivered via real tmux
    # send-keys (no mocking of tmux itself). Records every line it consumes
    # and stamps TASK_READ_TRIGGERED when the startup prompt's actual text
    # arrives as a submitted turn (proving the reset→re-dispatch promise
    # was honored end-to-end, not just that a function was called).
    cat > "$E2E_QUEUE/fake_cli.sh" << 'FAKECLI'
#!/usr/bin/env bash
# Real CLIs survive C-c gracefully; inbox_watcher's send_cli_command sends
# C-c before /clear to clear stale input (see mock_cli.sh for the same
# workaround). Without this trap, SIGINT kills this process and tmux
# destroys the pane (remain-on-exit is off), making all later
# capture-pane calls return empty — a harness bug, not a product bug.
trap '' INT
LOG_FILE="${1:?log file required}"
echo "READY"
echo '$ '
while IFS= read -r line; do
    echo "LINE:$line" >> "$LOG_FILE"
    case "$line" in
        "Session Start"*)
            echo "TASK_READ_TRIGGERED" >> "$LOG_FILE"
            ;;
    esac
    echo '$ '
done
FAKECLI
    chmod +x "$E2E_QUEUE/fake_cli.sh"

    export E2E_CRSYM_SESSION="e2e_crsym_$$"
    tmux new-session -d -s "$E2E_CRSYM_SESSION" -x 200 -y 50
    export E2E_CRSYM_PANE
    E2E_CRSYM_PANE=$(tmux list-panes -t "$E2E_CRSYM_SESSION" -F '#{pane_id}' | head -1)
}

teardown_file() {
    tmux kill-session -t "$E2E_CRSYM_SESSION" 2>/dev/null || true
    [ -n "${E2E_QUEUE:-}" ] && [ -d "$E2E_QUEUE" ] && rm -rf "$E2E_QUEUE"
}

setup() {
    echo "messages:" > "$E2E_QUEUE/queue/inbox/ashigaru9.yaml"
    rm -f "$E2E_QUEUE"/queue/tasks/*.yaml "$E2E_QUEUE"/queue/reports/*.yaml
    export FAKE_LOG
    FAKE_LOG="$(mktemp "$E2E_QUEUE/fake_cli_log.XXXXXX")"
    : > "$FAKE_LOG"
    export IDLE_FLAG_DIR
    IDLE_FLAG_DIR="$(mktemp -d "$E2E_QUEUE/idle_flags.XXXXXX")"
}

# ─── respawn_fake_cli — restart the real pane with the fake CLI process ───
respawn_fake_cli() {
    tmux respawn-pane -k -t "$E2E_CRSYM_PANE" \
        "bash '$E2E_QUEUE/fake_cli.sh' '$FAKE_LOG'"
    sleep 1
}

# ═══════════════════════════════════════════════════════════════
# E2E-CRSYM-A: send_context_reset — claude経路(task_assigned) ★真因の実測
# ═══════════════════════════════════════════════════════════════

@test "E2E-CRSYM-A: real tmux — claude task_assigned context-reset delivers /clear then startup prompt, real CLI reads it" {
    respawn_fake_cli
    touch "$IDLE_FLAG_DIR/shogun_idle_ashigaru9"

    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru2_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru9.yaml" 2>/dev/null || \
    cat > "$E2E_QUEUE/queue/tasks/ashigaru9.yaml" << 'YAML'
task:
  task_id: subtask_test_crsym_a
  status: assigned
YAML

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru9" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    local log_file="/tmp/e2e_crsym_watcher_a_$$.log"
    IDLE_FLAG_DIR="$IDLE_FLAG_DIR" \
    ESCALATE_PHASE1=10 ESCALATE_PHASE2=20 ESCALATE_COOLDOWN=25 INOTIFY_TIMEOUT=5 \
    bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru9" "$E2E_CRSYM_PANE" "claude" \
        > "$log_file" 2>&1 &
    local watcher_pid=$!

    # Real pane must actually display /clear (proves real tmux delivery, not a mock)
    run wait_for_pane_text "$E2E_CRSYM_PANE" "/clear" 15
    if [ "$status" -ne 0 ]; then cat "$log_file" >&2; fi
    assert_success

    # The fake CLI (a real process reading real pty input) must receive the
    # startup prompt as an actual submitted line and flag TASK_READ_TRIGGERED.
    local elapsed=0
    while [ "$elapsed" -lt 50 ]; do
        grep -q "TASK_READ_TRIGGERED" "$FAKE_LOG" && break
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if ! grep -q "TASK_READ_TRIGGERED" "$FAKE_LOG"; then
        echo "=== watcher log ===" >&2; cat "$log_file" >&2
        echo "=== fake cli log ===" >&2; cat "$FAKE_LOG" >&2
    fi
    grep -q "TASK_READ_TRIGGERED" "$FAKE_LOG"

    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# E2E-CRSYM-B: send_context_reset — codex経路(task_assigned) regression
# ═══════════════════════════════════════════════════════════════

@test "E2E-CRSYM-B: real tmux — codex task_assigned context-reset still delivers /new then startup prompt (regression)" {
    respawn_fake_cli
    touch "$IDLE_FLAG_DIR/shogun_idle_ashigaru9"

    cat > "$E2E_QUEUE/queue/tasks/ashigaru9.yaml" << 'YAML'
task:
  task_id: subtask_test_crsym_b
  status: assigned
YAML

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru9" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    local log_file="/tmp/e2e_crsym_watcher_b_$$.log"
    IDLE_FLAG_DIR="$IDLE_FLAG_DIR" \
    ESCALATE_PHASE1=10 ESCALATE_PHASE2=20 ESCALATE_COOLDOWN=25 INOTIFY_TIMEOUT=5 \
    bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru9" "$E2E_CRSYM_PANE" "codex" \
        > "$log_file" 2>&1 &
    local watcher_pid=$!

    run wait_for_pane_text "$E2E_CRSYM_PANE" "/new" 15
    if [ "$status" -ne 0 ]; then cat "$log_file" >&2; fi
    assert_success

    local elapsed=0
    while [ "$elapsed" -lt 50 ]; do
        grep -q "TASK_READ_TRIGGERED" "$FAKE_LOG" && break
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if ! grep -q "TASK_READ_TRIGGERED" "$FAKE_LOG"; then
        echo "=== watcher log ===" >&2; cat "$log_file" >&2
        echo "=== fake cli log ===" >&2; cat "$FAKE_LOG" >&2
    fi
    grep -q "TASK_READ_TRIGGERED" "$FAKE_LOG"

    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# E2E-CRSYM-C: send_cli_command — claude clear_command経路 regression
# ═══════════════════════════════════════════════════════════════

@test "E2E-CRSYM-C: real tmux — claude clear_command still delivers /clear then startup prompt (regression)" {
    respawn_fake_cli
    touch "$IDLE_FLAG_DIR/shogun_idle_ashigaru9"

    cat > "$E2E_QUEUE/queue/tasks/ashigaru9.yaml" << 'YAML'
task:
  task_id: subtask_test_crsym_c
  status: assigned
YAML

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru9" \
        "/clear" "clear_command" "karo"

    local log_file="/tmp/e2e_crsym_watcher_c_$$.log"
    IDLE_FLAG_DIR="$IDLE_FLAG_DIR" \
    ESCALATE_PHASE1=10 ESCALATE_PHASE2=20 ESCALATE_COOLDOWN=25 INOTIFY_TIMEOUT=5 \
    bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru9" "$E2E_CRSYM_PANE" "claude" \
        > "$log_file" 2>&1 &
    local watcher_pid=$!

    run wait_for_pane_text "$E2E_CRSYM_PANE" "/clear" 15
    if [ "$status" -ne 0 ]; then cat "$log_file" >&2; fi
    assert_success

    local elapsed=0
    while [ "$elapsed" -lt 50 ]; do
        grep -q "TASK_READ_TRIGGERED" "$FAKE_LOG" && break
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if ! grep -q "TASK_READ_TRIGGERED" "$FAKE_LOG"; then
        echo "=== watcher log ===" >&2; cat "$log_file" >&2
        echo "=== fake cli log ===" >&2; cat "$FAKE_LOG" >&2
    fi
    grep -q "TASK_READ_TRIGGERED" "$FAKE_LOG"

    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
}
