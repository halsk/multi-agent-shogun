#!/usr/bin/env bats
# test_ntfy_ack.bats — ntfy ACK自動返信ユニットテスト
# PR #46: ntfyメッセージ受信時の自動ACK返信機能
#
# テスト構成:
#   T-ACK-001: 正常メッセージ → inbox_write to shogun (auto-ACK removed)
#   T-ACK-002: outboundタグ付き → ACKスキップ（ループ防御）
#   T-ACK-003: auto-ACK未送信確認 (shogun replies directly)
#   T-ACK-004: ACK送信失敗 → inbox_write継続
#   T-ACK-005: 空メッセージ → ACKスキップ
#   T-ACK-006: keepaliveイベント → ACKスキップ
#   T-ACK-007: append_ntfy_inbox失敗 → ACK・inbox_write両方スキップ
#   T-ACK-008: 特殊文字がinbox_writeに保持される

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    [ -x "$PROJECT_ROOT/.venv/bin/python3" ] || skip "python3 not found in .venv"
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/ntfy_ack_test.XXXXXX")"
    export MOCK_PROJECT="$TEST_TMPDIR/mock_project"
    export MOCK_BIN="$TEST_TMPDIR/mock_bin"
    export ACK_LOG="$TEST_TMPDIR/ack.log"
    export INBOX_LOG="$TEST_TMPDIR/inbox.log"
    export MOCK_CURL_OUTPUT="$TEST_TMPDIR/curl_output.json"

    # モックプロジェクト構築
    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts,queue,logs/ntfy_inbox_corrupt}
    mkdir -p "$MOCK_PROJECT/.venv/bin"
    mkdir -p "$MOCK_BIN"

    # settings.yaml
    cat > "$MOCK_PROJECT/config/settings.yaml" << 'YAML'
ntfy_topic: "test-ack-topic-12345"
YAML

    # 空の認証ファイル
    touch "$MOCK_PROJECT/config/ntfy_auth.env"

    # 本物のntfy_auth.shをコピー
    cp "$PROJECT_ROOT/lib/ntfy_auth.sh" "$MOCK_PROJECT/lib/"

    # python3 wrapper (exec to project venv so pyvenv.cfg is found → PyYAML available)
    # Note: a symlink chain breaks venv detection on macOS — argv[0] would point to
    # $MOCK_PROJECT/.venv/bin/python3 but pyvenv.cfg only exists in $PROJECT_ROOT/.venv/
    cat > "$MOCK_PROJECT/.venv/bin/python3" << WRAPPER
#!/bin/sh
exec "$PROJECT_ROOT/.venv/bin/python3" "\$@"
WRAPPER
    chmod +x "$MOCK_PROJECT/.venv/bin/python3"

    # ntfy_inbox初期化
    echo "inbox:" > "$MOCK_PROJECT/queue/ntfy_inbox.yaml"

    # --- モックスクリプト ---

    # mock curl
    cat > "$MOCK_BIN/curl" << 'CURL_MOCK'
#!/bin/bash
if [ -f "$MOCK_CURL_OUTPUT" ]; then
    cat "$MOCK_CURL_OUTPUT"
fi
CURL_MOCK
    chmod +x "$MOCK_BIN/curl"

    # mock ntfy.sh
    cat > "$MOCK_PROJECT/scripts/ntfy.sh" << 'NTFY_MOCK'
#!/bin/bash
echo "$1" >> "$ACK_LOG"
exit ${MOCK_NTFY_EXIT_CODE:-0}
NTFY_MOCK
    chmod +x "$MOCK_PROJECT/scripts/ntfy.sh"

    # mock inbox_write.sh
    cat > "$MOCK_PROJECT/scripts/inbox_write.sh" << 'INBOX_MOCK'
#!/bin/bash
echo "$@" >> "$INBOX_LOG"
INBOX_MOCK
    chmod +x "$MOCK_PROJECT/scripts/inbox_write.sh"

    # ntfy_listener.shコピー（SCRIPT_DIR差し替え）
    sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$MOCK_PROJECT\"|" \
        "$PROJECT_ROOT/scripts/ntfy_listener.sh" \
        > "$MOCK_PROJECT/ntfy_listener_test.sh"
    chmod +x "$MOCK_PROJECT/ntfy_listener_test.sh"

    # ログ初期化
    touch "$ACK_LOG" "$INBOX_LOG"

    # PATHにモックcurlを先頭配置
    export PATH="$MOCK_BIN:$PATH"

    # デフォルト: ntfy.sh正常終了
    unset MOCK_NTFY_EXIT_CODE
}

teardown() {
    # Restore permissions if changed (T-ACK-007)
    chmod 755 "$MOCK_PROJECT/queue" 2>/dev/null || true
    rm -rf "$TEST_TMPDIR"
}

# --- ヘルパー ---

run_listener() {
    timeout 3 bash "$MOCK_PROJECT/ntfy_listener_test.sh" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-001: Normal message triggers inbox_write to shogun (ACK removed, shogun replies directly)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-001: Normal message triggers inbox_write to shogun" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg001","time":1234567890,"message":"テスト通知","tags":[]}
JSON
    run_listener
    # Auto-ACK removed — shogun replies directly after processing.
    # Verify inbox_write to shogun was called instead.
    [ -s "$INBOX_LOG" ]
    grep -q "shogun" "$INBOX_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-002: Outbound message does NOT trigger ACK (loop prevention)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-002: Outbound message does NOT trigger ACK (loop prevention)" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg002","time":1234567890,"message":"📱受信: echo","tags":["outbound"]}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-003: No auto-ACK sent (shogun replies directly)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-003: No auto-ACK sent (shogun replies directly)" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg003","time":1234567890,"message":"テスト通知です","tags":[]}
JSON
    run_listener
    # Auto-ACK removed — ACK_LOG should be empty
    [ ! -s "$ACK_LOG" ]
    # But inbox_write to shogun should still fire
    [ -s "$INBOX_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-004: ACK failure does not block inbox_write
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-004: ACK failure does not block inbox_write" {
    export MOCK_NTFY_EXIT_CODE=1
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg004","time":1234567890,"message":"test msg","tags":[]}
JSON
    run_listener
    [ -s "$INBOX_LOG" ]
    grep -q "shogun" "$INBOX_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-005: Empty message skips ACK
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-005: Empty message skips ACK" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg005","time":1234567890,"message":"","tags":[]}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-006: Non-message event (keepalive) skips ACK
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-006: Non-message event (keepalive) skips ACK" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"keepalive","id":"","time":1234567890,"message":""}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-007: append_ntfy_inbox failure skips both ACK and inbox_write
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-007: append_ntfy_inbox failure skips both ACK and inbox_write" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg007","time":1234567890,"message":"should not ack","tags":[]}
JSON
    # Force append_ntfy_inbox failure in a UID-independent way.
    # chmod 555 does not deny writes when the suite runs as root (some CI
    # containers do) — root bypasses filesystem permission checks entirely,
    # so this would silently pass without exercising the failure path at all.
    # Replacing the target file with a directory of the same name makes the
    # write fail (EISDIR) regardless of uid.
    rm "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    mkdir "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    run_listener
    # Both ACK and inbox_write should be skipped (L159 continue)
    [ ! -s "$ACK_LOG" ]
    [ ! -s "$INBOX_LOG" ]
    # Restore for teardown
    rmdir "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    echo "inbox:" > "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-008: Special characters in message preserved in inbox_write
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-008: Special characters in message preserved in inbox_write" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg008","time":1234567890,"message":"こんにちは 'world' & <test>","tags":[]}
JSON
    run_listener
    # Auto-ACK removed — verify inbox_write still fires for special characters
    [ ! -s "$ACK_LOG" ]
    [ -s "$INBOX_LOG" ]
    grep -q "shogun" "$INBOX_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-LOOPBACK-001: outbound → ntfy_inbox.yaml に書き込まれない
# ═══════════════════════════════════════════════════════════════

@test "T-LOOPBACK-001: outbound message does NOT write to ntfy_inbox" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"lb1","time":1234567890,"message":"loop back","tags":["outbound"]}
JSON
    run_listener
    ! grep -q "lb1" "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
}

# ═══════════════════════════════════════════════════════════════
# T-LOOPBACK-002: outbound → inbox_write (将軍起こし) が呼ばれない
# ═══════════════════════════════════════════════════════════════

@test "T-LOOPBACK-002: outbound message does NOT call inbox_write (no shogun wake)" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"lb1","time":1234567890,"message":"loop back","tags":["outbound"]}
JSON
    run_listener
    [ ! -s "$INBOX_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-LOOPBACK-003: 無タグ通常メッセージ → ntfy_inbox 書込 + inbox_write 呼出
# ═══════════════════════════════════════════════════════════════

@test "T-LOOPBACK-003: normal (no-tag) message writes to ntfy_inbox and wakes shogun" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"n1","time":1234567890,"message":"real command","tags":[]}
JSON
    run_listener
    grep -q "n1" "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    grep -q "shogun" "$INBOX_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-SINGLETON-001〜003 (cmd_833): 起動経路(絶対パス/相対パス)が異なっても
# 同一トピックを二重に購読させない自己singleton化。
#
# 実測(2026-09-16): 稼働中の重複はPPID確認で「main daemon 2系統(絶対パス
# 起動+相対パス起動、それぞれ別々にcurl|whileのsubshellを持つ)」と判明。
# watcher_supervisor.shのpgrepベースsingletonは自身の相対パス起動しか
# 検知できず、shutsujin_departure.shの絶対パス起動(pkill後に再起動)を
# 見落とし、両方が生き残っていた。起動経路のpgrepパターン一致に依存せず、
# ntfy_listener.sh自身がflockで自己排他するのが根本対処。
# ═══════════════════════════════════════════════════════════════

@test "T-SINGLETON-001: second instance exits immediately when lock already held (no duplicate processing)" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"dup1","time":1234567890,"message":"should not process while locked","tags":[]}
JSON
    mkdir -p "$MOCK_PROJECT/logs"
    LOCK_FILE="$MOCK_PROJECT/logs/ntfy_listener.lock"
    # 既に別インスタンス(起動経路は問わない)がロックを保持している状態を模擬。
    exec 8>"$LOCK_FILE"
    flock -n 8

    run timeout 3 bash "$MOCK_PROJECT/ntfy_listener_test.sh"

    flock -u 8
    exec 8>&-

    [ "$status" -eq 0 ]
    [[ "$output" == *"already running"* ]]
    ! grep -q "dup1" "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    [ ! -s "$INBOX_LOG" ]
}

@test "T-SINGLETON-002: proceeds normally (processes message) when lock is free" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"free1","time":1234567890,"message":"lock free","tags":[]}
JSON
    run_listener
    grep -q "free1" "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    grep -q "shogun" "$INBOX_LOG"
}

@test "T-SINGLETON-003: two concurrent real launches (absolute-path-style and relative-path-style) only one processes the message" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"race1","time":1234567890,"message":"race","tags":[]}
JSON
    # 実際の二重起動を模す: 同じスクリプトを二重に(ほぼ同時に)起動する。
    # どちらが勝っても、負けた側は即exit 0し、メッセージは1回しか処理されない。
    timeout 3 bash "$MOCK_PROJECT/ntfy_listener_test.sh" >"$TEST_TMPDIR/out_a.log" 2>&1 &
    PID_A=$!
    # PID_Aがロックを取得し終えるまでの短い待ち(0.1s刻みで最大1s)。
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -f "$MOCK_PROJECT/logs/ntfy_listener.lock" ] && break
        sleep 0.1
    done
    timeout 3 bash "$MOCK_PROJECT/ntfy_listener_test.sh" >"$TEST_TMPDIR/out_b.log" 2>&1
    wait "$PID_A" 2>/dev/null || true

    # ntfy_inboxへの書込は1回だけ(重複記録が起きていない)
    [ "$(grep -c "race1" "$MOCK_PROJECT/queue/ntfy_inbox.yaml")" -eq 1 ]
    # shogun起こしも1回だけ
    [ "$(grep -c "shogun" "$INBOX_LOG")" -eq 1 ]
}
