#!/usr/bin/env bats
# test_watcher_stop_flag.bats — cmd_760 item③: D006-safe watcher swap-in
#
# watcher_supervisor.sh に stop 機能を追加した。kill/pkill等でプロセスを
# 終了させるのではなく、停止フラグファイルを置くだけに留め、実際の終了は
# inbox_watcher.sh 自身がメインループ内でフラグを検知し exit 0 する
# (cooperative shutdown)。D006(kill系統無条件禁止)に一切触れない設計で
# あることを実際にプロセスを起動して確認する。
#
# テスト構成:
#   T-STOP-001: watcher_supervisor.sh stop <agent> がフラグファイルを作成する
#   T-STOP-002: watcher_supervisor.sh stop all が全ALL_AGENTS分のフラグを作成する
#   T-STOP-003: inbox_watcher.sh の実プロセスが、フラグ検知後に自ら exit 0 する
#               (killもpkillも一切使わない)
#   T-STOP-004: 停止後、フラグファイル自体は消費され(rm)残らない

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SUPERVISOR_SCRIPT="$SCRIPT_DIR/scripts/watcher_supervisor.sh"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"

setup_file() {
    [ -f "$SUPERVISOR_SCRIPT" ] || return 1
    [ -f "$WATCHER_SCRIPT" ] || return 1
    # T-C9調査(cmd_766残赤)で見つかった同種の問題: watcher_supervisor.sh/
    # inbox_watcher.shが実際にYAML解析へ使うのは$SCRIPT_DIR/.venv/bin/python3
    # (プロジェクトの実.venv、pip install pyyaml済み)であり、ここで素の
    # `python3`(PATH上のsystem python3)を検査しても対象が違う。GitHub Actions
    # macos-latestのsystem/homebrew python3にはPyYAMLが入っておらず、このズレに
    # より本来greenであるべき全T-STOP系テストがSKIP扱いになっていた
    # (SKIP=FAIL方針違反)。検査対象を実際に使われるvenv側へ合わせる。
    local venv_python="$SCRIPT_DIR/.venv/bin/python3"
    [ -x "$venv_python" ] || skip "project .venv python3 not available at $venv_python"
    "$venv_python" -c "import yaml" 2>/dev/null || skip "PyYAML not available in project .venv"
}

setup() {
    export TEST_FLAG_DIR="$(mktemp -d "$BATS_TMPDIR/watcher_stop_test.XXXXXX")"
}

teardown() {
    if [ -n "${WATCHER_PID:-}" ] && kill -0 "$WATCHER_PID" 2>/dev/null; then
        # Test cleanup only (not the mechanism under test): if a test failed
        # before the watcher exited on its own, stop it via its own stop-flag
        # path rather than kill, to avoid masking a real bug with a kill.
        touch "$TEST_FLAG_DIR/shogun_watcher_stop_${WATCHER_AGENT:-test_stopflag_agent}"
        for _ in $(seq 1 10); do
            kill -0 "$WATCHER_PID" 2>/dev/null || break
            sleep 1
        done
    fi
    rm -rf "$TEST_FLAG_DIR"
    rm -rf "$SCRIPT_DIR/queue/inbox/${WATCHER_AGENT:-test_stopflag_agent}.yaml"
}

# ─── T-STOP-001 ───

@test "T-STOP-001: watcher_supervisor.sh stop <agent> creates the stop flag" {
    run bash "$SUPERVISOR_SCRIPT" stop test_stopflag_agent
    [ "$status" -eq 0 ]
    WATCHER_STOP_FLAG_DIR="$TEST_FLAG_DIR" run bash -c "
        WATCHER_STOP_FLAG_DIR='$TEST_FLAG_DIR' bash '$SUPERVISOR_SCRIPT' stop test_stopflag_agent
    "
    [ "$status" -eq 0 ]
    [ -f "$TEST_FLAG_DIR/shogun_watcher_stop_test_stopflag_agent" ]
}

# ─── T-STOP-002 ───

@test "T-STOP-002: watcher_supervisor.sh stop all creates a flag for every ALL_AGENTS entry" {
    run bash -c "WATCHER_STOP_FLAG_DIR='$TEST_FLAG_DIR' bash '$SUPERVISOR_SCRIPT' stop all"
    [ "$status" -eq 0 ]
    for agent in shogun karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7 gunshi gunshi2; do
        [ -f "$TEST_FLAG_DIR/shogun_watcher_stop_${agent}" ]
    done
}

# ─── T-STOP-003 / T-STOP-004: 実プロセスでの検証 ───

@test "T-STOP-003/004: a running inbox_watcher.sh process exits on its own when the stop flag appears, and consumes the flag (no kill/pkill involved)" {
    export WATCHER_AGENT="test_stopflag_agent"
    rm -f "$SCRIPT_DIR/queue/inbox/${WATCHER_AGENT}.yaml"

    INOTIFY_TIMEOUT=1 WATCHER_STOP_FLAG_DIR="$TEST_FLAG_DIR" IDLE_FLAG_DIR="$TEST_FLAG_DIR" \
        bash "$WATCHER_SCRIPT" "$WATCHER_AGENT" "nonexistent_session:0.0" "claude" \
        > "$TEST_FLAG_DIR/watcher.log" 2>&1 &
    WATCHER_PID=$!
    export WATCHER_PID

    # Give it a moment to reach the main loop.
    for _ in $(seq 1 10); do
        kill -0 "$WATCHER_PID" 2>/dev/null && break
        sleep 0.5
    done
    run kill -0 "$WATCHER_PID"
    [ "$status" -eq 0 ]  # process is alive before we ask it to stop

    # Ask it to stop via the flag file — the ONLY interaction with the process.
    # No kill/pkill/SIGTERM is ever sent to $WATCHER_PID by this test.
    bash "$SUPERVISOR_SCRIPT" stop "$WATCHER_AGENT" 2>/dev/null || true
    WATCHER_STOP_FLAG_DIR="$TEST_FLAG_DIR" bash "$SUPERVISOR_SCRIPT" stop "$WATCHER_AGENT"

    # It must exit on its own within a few INOTIFY_TIMEOUT cycles.
    local exited=0
    for _ in $(seq 1 15); do
        if ! kill -0 "$WATCHER_PID" 2>/dev/null; then
            exited=1
            break
        fi
        sleep 1
    done
    echo "# --- T-STOP-003/004 debug ---" >&3
    echo "# uname=$(uname -a)" >&3
    echo "# exited=$exited" >&3
    while IFS= read -r __l; do echo "# $__l" >&3; done < "$TEST_FLAG_DIR/watcher.log"

    [ "$exited" -eq 1 ]

    # The flag must have been consumed (rm'd) by the watcher itself, not left behind.
    [ ! -f "$TEST_FLAG_DIR/shogun_watcher_stop_${WATCHER_AGENT}" ]

    unset WATCHER_PID
}
