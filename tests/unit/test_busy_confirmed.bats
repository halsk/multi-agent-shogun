#!/usr/bin/env bats
# test_busy_confirmed.bats — cmd_760 busy guard根本修正 (fix1(b)+fix3) unit tests
#
# 背景: idleフラグ shogun_idle_<agent> は create-only であり、削除する
# コードがどこにも存在しない(stop_hook_inbox.shのコメントは「Claude Codeが
# 削除する」と主張するが実装は無い)。一度idleフラグが立つと、その後
# 本当にbusy(Working)になっても agent_is_busy() は永久にfalse(idle)を
# 返し続け、609/1110/1160のbusy guardが実質no-op化する。
#
# fix1(b): 破壊的サイト(/clear送信)の直前でのみ、pane解析による
#   ground truth確認を追加する新関数 agent_is_busy_confirmed() を使う。
# fix3: /clear送信を送信確認+リトライループ化し、C-uで送信前に入力欄を
#   クリアする。9/5型(残滓/clear遅延発火)を塞ぐ。
#
# テスト構成:
#   T-C1: agent_is_busy_confirmed — flagがbusy(なし)ならbusy (baseline)
#   T-C2: agent_is_busy_confirmed — flagがidle(あり)でもpaneがWorking中ならbusy
#         (★根本バグの再現・これがfix1(b)の核心)
#   T-C3: agent_is_busy_confirmed — flagがidle・paneも確認できて初めてidle (regression)
#   T-C4: send_cli_command — flagはidleだがpaneがWorking中の/clearはスキップされる
#   T-C5: send_cli_command — 正常系(真にidle)の/clearは送信される (regression)
#   T-C6: send_cli_command — /clear送信前にC-uが送られる (fix3)
#   T-C7: send_cli_command — 送信後に残存確認し、残存していればリトライする (fix3)
#   T-C8: stale-busy回復 — flag無し(busy)が長時間続き、pane確認でidleと判れば
#         flagを強制作成する (旧: 無条件touch → 新: pane確認後touch)
#   T-C9: stale-busy回復 — flag無し(busy)が長時間続いても、paneが実際に
#         Working中なら flag を強制作成しない (★退行防止: 本当に長考中の
#         agentへ誤ってidle判定を持ち込まない)
#   T-C10: ★安全性 — Phase3でbusy確認時にEscape/C-c等の破壊的キーを送らない
#         (テスト作成中に発見: 当初案はsend_wakeup_with_escapeを呼んでおり、
#         確認済みで真にWorking中のagentへEscape+C-cを送る危険があった)
#   T-C11: ★テスト作成中に発見した第三の未ガード送信箇所 — send_context_reset
#         はtask_assigned初検知時に/clear|/newを無条件送信しており、busy確認
#         guardが一切無かった(fix1(b)/fix4の対象漏れ)。confirmed-busy時は
#         送信せずreturn 1し、NEW_CONTEXT_SENTを立てず次サイクルへ再試行する。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"

setup_file() {
    export PROJECT_ROOT="$SCRIPT_DIR"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export IDLE_FLAG_DIR="$(mktemp -d "$BATS_TMPDIR/busy_confirmed_test.XXXXXX")"
    export TEST_TMP="$(mktemp -d "$BATS_TMPDIR/busy_confirmed_tmp.XXXXXX")"
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks" "$TEST_TMP/lib"
    # T-C9実runner調査(cmd_766残赤): 旧実装は raw system python3(command -v
    # python3)を$TEST_TMP/.venv/bin/python3へsymlinkしていたが、GitHub Actions
    # macos-latestのsystem/homebrew python3にはPyYAMLが入っておらずimportに
    # 失敗していた(setup_file()のVENV_PYTHON検証は通っているのに、ここだけ
    # 別のpython3を指していたのが原因)。単に実.venvのpython3バイナリ1本だけを
    # symlinkする案も試したが、venvのpython3はpyvenv.cfgを実行ファイルの
    # 「symlink先を辿らない」隣接ディレクトリから探すため、バイナリ単体の
    # symlinkでは$TEST_TMP/.venv/pyvenv.cfgが見つからずsite-packages解決に
    # 失敗し同じImportErrorを再現した(ローカルで実際に再現・確認済み)。
    # .venvディレクトリ全体をsymlinkし、pyvenv.cfgも一緒に見えるようにする。
    ln -sfn "$PROJECT_ROOT/.venv" "$TEST_TMP/.venv"
    # agent_is_busy_check() lives in the real lib/agent_status.sh — symlink it into
    # the isolated SCRIPT_DIR so process_unread()/agent_is_busy_confirmed() can find it
    # without pointing SCRIPT_DIR at the real project root (which would make
    # get_task_status() read the live queue/tasks/ directory).
    ln -sf "$SCRIPT_DIR/lib/agent_status.sh" "$TEST_TMP/lib/agent_status.sh"

    export WATCHER_HARNESS="$IDLE_FLAG_DIR/watcher_harness.sh"
    export MOCK_LOG="$IDLE_FLAG_DIR/tmux_calls.log"
    > "$MOCK_LOG"
    export MOCK_CAPTURE_PANE=""
    export MOCK_PANE_CLI="claude"
    export MOCK_SENDKEYS_RC=0

    cat > "$WATCHER_HARNESS" << HARNESS
#!/bin/bash
AGENT_ID="test_busy_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_TMP/queue/inbox/test_busy_agent.yaml"
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

# ─── T-C1: baseline — flag無し(busy)ならbusy ───

@test "T-C1: agent_is_busy_confirmed returns busy when idle flag absent" {
    rm -f "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    MOCK_CAPTURE_PANE=""

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        agent_is_busy_confirmed
    "
    [ "$status" -eq 0 ]  # 0 = busy
}

# ─── T-C2: ★根本バグ再現 — flagがidleでもpaneがWorking中ならbusy ───

@test "T-C2: agent_is_busy_confirmed returns busy when flag says idle but pane shows Working (stuck idle flag)" {
    # idle flag が立ったまま(create-onlyバグの再現) — これがなければ本当のバグ再現にならない
    touch "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    MOCK_CAPTURE_PANE="✻ Working on task (12s • esc to interrupt)"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        agent_is_busy_confirmed
    "
    [ "$status" -eq 0 ]  # 0 = busy — pane ground truthがflagを上書きする
}

# ─── T-C3: regression — flagがidleでpaneも確認できて初めてidle ───

@test "T-C3: agent_is_busy_confirmed returns idle when flag says idle and pane confirms idle" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    MOCK_CAPTURE_PANE="❯"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        agent_is_busy_confirmed
    "
    [ "$status" -eq 1 ]  # 1 = idle
}

# ─── T-C4: send_cli_command — flagはidleだがpane Working中の/clearはスキップ ───

@test "T-C4: send_cli_command skips /clear when flag says idle but pane confirms busy" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    MOCK_CAPTURE_PANE="✻ Working on task (12s • esc to interrupt)"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        send_cli_command '/clear'
    "
    [ "$status" -eq 0 ]
    # send-keys for the actual /clear text must NOT appear at all — the pane
    # confirms Working, so agent_is_busy_confirmed() must block the send.
    run grep -qF "send-keys -t test:0.0 /clear" "$MOCK_LOG"
    [ "$status" -ne 0 ]
}

# ─── T-C5: regression — 正常系(真にidle)の/clearは送信される ───

@test "T-C5: send_cli_command sends /clear when agent is truly idle" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    MOCK_CAPTURE_PANE="❯"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        send_cli_command '/clear'
    "
    [ "$status" -eq 0 ]
    run grep -qF "send-keys -t test:0.0 /clear" "$MOCK_LOG"
    assert_success 2>/dev/null || [ "$status" -eq 0 ]
}

# ─── T-C6: fix3 — /clear送信前にC-uが送られる ───

@test "T-C6: send_cli_command sends C-u before /clear text (residue prevention)" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    MOCK_CAPTURE_PANE="❯"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        send_cli_command '/clear'
    "
    [ "$status" -eq 0 ]
    # The C-u immediately preceding the FIRST '/clear' send (not a later
    # send_startup_prompt C-u) must exist — check relative line order.
    local cu_line clear_line
    cu_line=$(grep -n "send-keys -t test:0.0 C-u" "$MOCK_LOG" | head -1 | cut -d: -f1)
    clear_line=$(grep -n "send-keys -t test:0.0 /clear" "$MOCK_LOG" | head -1 | cut -d: -f1)
    [ -n "$cu_line" ]
    [ -n "$clear_line" ]
    [ "$cu_line" -lt "$clear_line" ]
}

# ─── T-C7: fix3 — 送信後に残存確認し、残存していればリトライする ───

@test "T-C7: send_cli_command retries when /clear text still visible in pane after send" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    # capture-pane が常に "/clear" を含む残存状態を返す(=送信が受理されず残った)
    MOCK_CAPTURE_PANE="/clear"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        send_cli_command '/clear'
    "
    [ "$status" -eq 0 ]
    run grep -qF "retrying" "$MOCK_LOG"
    # ログにretry文言が出るか、少なくとも複数回 '/clear' の送信が記録されている
    local clear_sends
    clear_sends=$(grep -cF "send-keys -t test:0.0 /clear" "$MOCK_LOG")
    [ "$clear_sends" -ge 2 ]
}

# ─── T-C8: stale-busy回復 — pane確認でidleと判ればflag強制作成 ───

@test "T-C8: stale-busy recovery forces idle flag when pane confirms truly idle" {
    rm -f "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    MOCK_CAPTURE_PANE="❯"

    cat > "$TEST_TMP/queue/inbox/test_busy_agent.yaml" << 'YAML'
messages:
- content: task
  from: karo
  id: msg_001
  read: false
  timestamp: '2026-01-01T00:00:00'
  type: task_assigned
YAML
    cat > "$TEST_TMP/queue/tasks/test_busy_agent.yaml" << 'YAML'
task:
  status: in_progress
YAML

    run bash -c "
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        FIRST_UNREAD_SEEN=\$((now - 400))
        LAST_CLEAR_TS=0
        ASW_DISABLE_ESCALATION=0
        process_unread event
    "
    [ "$status" -eq 0 ]
    [ -f "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent" ]
}

# ─── T-C9: ★退行防止 — paneが本当にWorking中ならflagを強制作成しない ───

@test "T-C9: stale-busy recovery does NOT force idle flag when pane confirms still Working" {
    rm -f "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    MOCK_CAPTURE_PANE="✻ Working on task (600s • esc to interrupt)"

    cat > "$TEST_TMP/queue/inbox/test_busy_agent.yaml" << 'YAML'
messages:
- content: task
  from: karo
  id: msg_001
  read: false
  timestamp: '2026-01-01T00:00:00'
  type: task_assigned
YAML
    cat > "$TEST_TMP/queue/tasks/test_busy_agent.yaml" << 'YAML'
task:
  status: in_progress
YAML

    run bash -c "
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        FIRST_UNREAD_SEEN=\$((now - 400))
        LAST_CLEAR_TS=0
        ASW_DISABLE_ESCALATION=0
        process_unread event
    "
    [ "$status" -eq 0 ]
    [ ! -f "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent" ]
}

# ─── T-C10: ★安全性 — Phase3で busy確認時にEscape/C-c等の破壊的キーを送らない ───

@test "T-C10: Phase 3 sends no keystrokes at all when agent_is_busy_confirmed is true (no Escape, no /clear)" {
    # idle flag はある(=軽量flagチェックはidleと判定し、Phase3のロジックまで
    # 到達する) が、pane は実際にWorking中(=stuck idle flagバグの再現)。
    touch "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    MOCK_CAPTURE_PANE="✻ Working on task (250s • esc to interrupt)"

    cat > "$TEST_TMP/queue/inbox/test_busy_agent.yaml" << 'YAML'
messages:
- content: task
  from: karo
  id: msg_001
  read: false
  timestamp: '2026-01-01T00:00:00'
  type: task_assigned
YAML
    cat > "$TEST_TMP/queue/tasks/test_busy_agent.yaml" << 'YAML'
task:
  status: in_progress
YAML

    run bash -c "
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        FIRST_UNREAD_SEEN=\$((now - 250))  # past ESCALATE_PHASE2(240s) -> Phase 3
        LAST_CLEAR_TS=0
        ASW_DISABLE_ESCALATION=0
        process_unread event
    "
    [ "$status" -eq 0 ]
    run grep -qF "send-keys -t test:0.0 /clear" "$MOCK_LOG"
    [ "$status" -ne 0 ]
    run grep -qF "send-keys -t test:0.0 Escape" "$MOCK_LOG"
    [ "$status" -ne 0 ]
}

# ─── T-C11: send_context_reset — 未ガードだった第三の破壊的送信箇所 ───

@test "T-C11: send_context_reset defers (returns 1, sends nothing) when agent_is_busy_confirmed is true" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    MOCK_CAPTURE_PANE="✻ Working on task (5s • esc to interrupt)"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        send_context_reset
    "
    [ "$status" -eq 1 ]
    run grep -qF "send-keys -t test:0.0 /clear" "$MOCK_LOG"
    [ "$status" -ne 0 ]
}

@test "T-C11b: send_context_reset sends /clear (returns 0) when agent is truly idle (regression)" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_busy_agent"
    MOCK_CAPTURE_PANE="❯"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        send_context_reset
    "
    [ "$status" -eq 0 ]
    run grep -qF "send-keys -t test:0.0 /clear" "$MOCK_LOG"
    [ "$status" -eq 0 ]
}
