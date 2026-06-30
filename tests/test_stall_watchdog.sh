#!/usr/bin/env bash
# tests/test_stall_watchdog.sh — Stall Watchdog テストスイート
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/stall_detect.sh"
# stall_watchdog.sh を source — source ガードにより flock とメインループはスキップされる
source "$SCRIPT_DIR/scripts/stall_watchdog.sh"

PASS=0
FAIL=0
ERRORS=()

assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ✅ PASS: $test_name"
        PASS=$(( PASS + 1 ))
    else
        echo "  ❌ FAIL: $test_name"
        echo "     expected='$expected' actual='$actual'"
        FAIL=$(( FAIL + 1 ))
        ERRORS+=("$test_name")
    fi
}

# ── Section 1: classify_pane 単体テスト ──────────────────────────────────────

echo ""
echo "=== Section 1: classify_pane 単体テスト ==="
echo ""

# 1a. spinner ✻ あり → busy (誤検知しない — 最優先)
echo "--- 1a: spinner ✻ あり → busy (稼働中誤検知防止)"
fixture_busy_spinner="Thinking...
✻ Processing code review...
Analyzing files"
assert_eq "1a: spinner ✻ → busy" "busy" "$(classify_pane "$fixture_busy_spinner")"

# 1b. spinner ⏺ あり → busy
echo "--- 1b: spinner ⏺ あり → busy"
fixture_busy_spinner2="Working on task
⏺ Running bash command...
"
assert_eq "1b: spinner ⏺ → busy" "busy" "$(classify_pane "$fixture_busy_spinner2")"

# 1c. status bar 'esc to' あり → busy
echo "--- 1c: status bar 'esc to' → busy"
fixture_esc_to="Reading file /path/to/file.txt
Editing line 42...
● claude-opus-4-8 esc to interrupt"
assert_eq "1c: 'esc to' → busy" "busy" "$(classify_pane "$fixture_esc_to")"

# 1d. ❯ のみ → idle
echo "--- 1d: ❯ のみ → idle"
fixture_idle="Some previous output
Task completed.
❯"
assert_eq "1d: ❯ → idle" "idle" "$(classify_pane "$fixture_idle")"

# 1e. /clear to save 503k tokens → context_bloat
echo "--- 1e: /clear to save NNNk tokens → context_bloat"
fixture_bloat="  ...previous context...
/clear to save 503k tokens
"
assert_eq "1e: context_bloat" "context_bloat" "$(classify_pane "$fixture_bloat")"

# 1f. could not be parsed → parse_error
echo "--- 1f: could not be parsed → parse_error"
fixture_parse_err="Attempting to call tool...
Error: Response could not be parsed: unexpected token
Falling back..."
assert_eq "1f: parse_error (could not be parsed)" "parse_error" "$(classify_pane "$fixture_parse_err")"

# 1g. Churned → parse_error
echo "--- 1g: Churned → parse_error"
fixture_churned="Processing...
Churned. Please try again.
"
assert_eq "1g: parse_error (Churned)" "parse_error" "$(classify_pane "$fixture_churned")"

# 1h. 通常ログ末尾 → busy (稼働中誤検知しない)
echo "--- 1h: 通常ログ末尾 → busy (稼働中として扱う・誤検知しない)"
fixture_normal="Reading file /Users/hal/workspace/project/src/app.ts...
Successfully read 245 lines.
Analyzing code structure..."
result_normal=$(classify_pane "$fixture_normal")
# 通常ログは "busy" であるべき (idle/context_bloat/parse_error でなければOK)
if [[ "$result_normal" == "busy" ]]; then
    assert_eq "1h: 通常ログ → busy (not idle/bloat/error)" "busy" "$result_normal"
else
    assert_eq "1h: 通常ログ → busy (誤検知テスト)" "busy" "$result_normal"
fi

# 1i. spinner ✻ と ❯ が混在する場合 → busy が優先 (最重要テスト)
echo "--- 1i: spinner ✻ + ❯ 混在 → busy 優先 (稼働中誤検知防止・最重要)"
fixture_mixed="Previous task output
❯
✻ Now processing next step..."
assert_eq "1i: spinner優先 → busy" "busy" "$(classify_pane "$fixture_mixed")"

# ── Section 2: エスカレーション state machine 単体テスト (実 escalate() 使用) ─

echo ""
echo "=== Section 2: エスカレーション state machine 単体テスト (実 escalate()) ==="
echo ""

TMPDIR_TEST=$(mktemp -d)
# STATE_DIR・LOG_FILE をテスト用一時ディレクトリに上書き
STATE_DIR="$TMPDIR_TEST/stall_watchdog"
mkdir -p "$STATE_DIR"
LOG_FILE="$TMPDIR_TEST/stall_watchdog.log"
INBOX_LOG="$TMPDIR_TEST/inbox_calls.log"
DRY_RUN=false   # スタブが呼ばれるように false に設定

# send_inbox / send_ntfy / notify_dashboard を stub に差し替え (実ファイルを触らない)
send_inbox() {
    echo "INBOX: agent=$1 type=$3" >> "$INBOX_LOG"
}
send_ntfy() {
    echo "NTFY: agent=$1 sig=$2" >> "$INBOX_LOG"
}
notify_dashboard() {
    echo "DASHBOARD: agent=$1 sig=$2" >> "$INBOX_LOG"
}

# 状態ファイルをセットアップするヘルパー
setup_state_for_test() {
    local agent="$1" phase="$2"
    printf 'agent_id: %s\nescalation_phase: %s\nlast_action_ts: 0\nlast_action: none\n' \
        "$agent" "$phase" > "$STATE_DIR/${agent}.yaml"
}

# 2a. phase=0, elapsed=15min → no action (P1 grace 未到達)
: > "$INBOX_LOG"
setup_state_for_test "test_agent" "0"
escalate "test_agent" $((15 * 60)) "idle"
inbox_count=0
inbox_count=$(grep -c 'INBOX:\|NTFY:\|DASHBOARD:' "$INBOX_LOG" 2>/dev/null) || true
assert_eq "2a: phase=0 elapsed=15min → no_action" "0" "$inbox_count"

# 2b. phase=0, elapsed=21min → P1 nudge (non-shogun agent)
: > "$INBOX_LOG"
setup_state_for_test "test_agent" "0"
escalate "test_agent" $((21 * 60)) "idle"
if grep -q 'INBOX: agent=test_agent type=report_received' "$INBOX_LOG" 2>/dev/null; then
    assert_eq "2b: phase=0 elapsed=21min → P1 nudge sent" "found" "found"
else
    assert_eq "2b: phase=0 elapsed=21min → P1 nudge sent" "INBOX:report_received" "NOT FOUND: $(cat "$INBOX_LOG" 2>/dev/null || true)"
fi

# 2c. phase=1, elapsed=31min → P2 (observation_only=true なのでフェーズ=2 に進む)
: > "$INBOX_LOG"
setup_state_for_test "test_agent" "1"
OBSERVATION_ONLY=true
escalate "test_agent" $((31 * 60)) "idle"
phase_val=$(grep 'escalation_phase:' "$STATE_DIR/test_agent.yaml" 2>/dev/null | sed 's/.*: //' || echo "")
assert_eq "2c: phase=1 elapsed=31min → escalation_phase=2" "2" "$phase_val"

# 2d. phase=2, elapsed=41min → P3 notify
: > "$INBOX_LOG"
setup_state_for_test "test_agent" "2"
escalate "test_agent" $((41 * 60)) "idle"
if grep -q 'NTFY:\|DASHBOARD:' "$INBOX_LOG" 2>/dev/null; then
    assert_eq "2d: phase=2 elapsed=41min → P3 notify" "found" "found"
else
    assert_eq "2d: phase=2 elapsed=41min → P3 notify" "NTFY or DASHBOARD" "NOT FOUND: $(cat "$INBOX_LOG" 2>/dev/null || true)"
fi

# 2e. phase=1, elapsed=25min → no action (P2 grace 未到達)
: > "$INBOX_LOG"
setup_state_for_test "test_agent" "1"
escalate "test_agent" $((25 * 60)) "idle"
phase_val=$(grep 'escalation_phase:' "$STATE_DIR/test_agent.yaml" 2>/dev/null | sed 's/.*: //' || echo "")
assert_eq "2e: phase=1 elapsed=25min → no phase change (P2未到達)" "1" "$phase_val"

# 2f. phase=2, elapsed=35min → no action (P3 grace 未到達)
: > "$INBOX_LOG"
setup_state_for_test "test_agent" "2"
escalate "test_agent" $((35 * 60)) "idle"
ntfy_count=0
ntfy_count=$(grep -c 'NTFY:\|DASHBOARD:' "$INBOX_LOG" 2>/dev/null) || true
assert_eq "2f: phase=2 elapsed=35min → no P3 (P3未到達)" "0" "$ntfy_count"

# 2g (P1a 回帰): shogun に P1 nudge は絶対送らない (E5)
: > "$INBOX_LOG"
setup_state_for_test "shogun" "0"
escalate "shogun" $((21 * 60)) "idle"
if grep -q 'INBOX: agent=shogun' "$INBOX_LOG" 2>/dev/null; then
    assert_eq "2g: shogun P1 nudge NOT sent (E5)" "no_inbox_shogun" "INBOX SENT: $(cat "$INBOX_LOG")"
else
    assert_eq "2g: shogun P1 nudge NOT sent (E5)" "no_inbox_shogun" "no_inbox_shogun"
fi

rm -rf "$TMPDIR_TEST"

# ── Section 3: --dry-run 統合テスト ──────────────────────────────────────────

echo ""
echo "=== Section 3: --dry-run 統合テスト ==="
echo ""

# dry-run で実行 (inbox/ntfy を送らずに終了するか)
DRY_RUN_OUTPUT=$(bash "$SCRIPT_DIR/scripts/stall_watchdog.sh" --dry-run 2>&1 || true)

if echo "$DRY_RUN_OUTPUT" | grep -q '\[START\].*dry_run=true'; then
    assert_eq "3a: --dry-run フラグが機能する" "true" "true"
else
    assert_eq "3a: --dry-run フラグが機能する" "dry_run=true in output" "NOT FOUND"
fi

if echo "$DRY_RUN_OUTPUT" | grep -q '\[DONE\]'; then
    assert_eq "3b: --dry-run が正常終了する" "true" "true"
else
    assert_eq "3b: --dry-run が正常終了する" "DONE in output" "NOT FOUND: $DRY_RUN_OUTPUT"
fi

# --observation-only がデフォルトで有効
if echo "$DRY_RUN_OUTPUT" | grep -q 'observation_only=true'; then
    assert_eq "3c: --observation-only がデフォルト有効" "true" "true"
else
    assert_eq "3c: --observation-only がデフォルト有効" "observation_only=true" "NOT FOUND"
fi

# ── Section 4: 誤検知回帰テスト (最重要) ─────────────────────────────────────

echo ""
echo "=== Section 4: 誤検知回帰テスト (稼働中 spinner で発火しないこと — 最重要) ==="
echo ""

# 複数の spinner パターンで classify_pane が "busy" を返すことを確認
spinner_fixtures=(
    "✻ Thinking about the problem..."
    "✻ Processing 1/50 files..."
    "⏺ Executing bash command..."
    "Working...
✻ Still thinking..."
    "Running tests
⏺ Test 1/10 passed
⏺ Continuing..."
    "❯
✻ New request received"  # ❯ があっても ✻ が優先
)

all_busy=true
for i in "${!spinner_fixtures[@]}"; do
    fixture="${spinner_fixtures[$i]}"
    result=$(classify_pane "$fixture")
    if [[ "$result" != "busy" ]]; then
        assert_eq "4.$(( i+1 )): spinner fixture[$i] → busy (誤検知回帰)" "busy" "$result"
        all_busy=false
    else
        assert_eq "4.$(( i+1 )): spinner fixture[$i] → busy" "busy" "$result"
    fi
done

# 'esc to' パターン
esc_fixtures=(
    "● claude-opus-4-8 esc to interrupt"
    "Running tool... esc to stop"
    "Analyzing... esc to interrupt processing"
)

for i in "${!esc_fixtures[@]}"; do
    result=$(classify_pane "${esc_fixtures[$i]}")
    assert_eq "4.esc$(( i+1 )): esc-to fixture[$i] → busy (誤検知回帰)" "busy" "$result"
done

# ── Section 5: E5 (shogun /clear 禁止) コード確認 ────────────────────────────

echo ""
echo "=== Section 5: E5 — shogun への /clear 送らない (コード確認) ==="
echo ""

if grep -q 'shogun.*E5\|E5.*shogun\|agent.*==.*shogun.*clear.*絶対' "$SCRIPT_DIR/scripts/stall_watchdog.sh"; then
    assert_eq "5a: shogun E5 ガードがコードに存在" "found" "found"
else
    # shogun 判定が違う形でも OK
    if grep -qE '"shogun"' "$SCRIPT_DIR/scripts/stall_watchdog.sh" && grep -q 'SKIP-E5\|E5' "$SCRIPT_DIR/scripts/stall_watchdog.sh"; then
        assert_eq "5a: shogun E5 ガードがコードに存在" "found" "found"
    else
        assert_eq "5a: shogun E5 ガードがコードに存在" "found" "not found"
    fi
fi

if grep -q 'OBSERVATION_ONLY\|observation.only' "$SCRIPT_DIR/scripts/stall_watchdog.sh"; then
    assert_eq "5b: --observation-only フラグがコードに存在" "found" "found"
else
    assert_eq "5b: --observation-only フラグがコードに存在" "found" "not found"
fi

if grep -q 'DRY_RUN\|dry.run' "$SCRIPT_DIR/scripts/stall_watchdog.sh"; then
    assert_eq "5c: --dry-run フラグがコードに存在" "found" "found"
else
    assert_eq "5c: --dry-run フラグがコードに存在" "found" "not found"
fi

# ── Section 6: P0 回帰テスト — agent_is_busy_check idle で exit しない ────────

echo ""
echo "=== Section 6: P0 回帰テスト — set -e 下で idle rc=1 でも escalation に到達する ==="
echo ""

# agent_is_busy_check が rc=1 (idle) を返す fixture で
# メインループの後続処理 (escalation) まで到達することを確認する。
# stall_watchdog.sh の set -e 抑止修正 (busy_rc=0; func || busy_rc=$?) の回帰テスト。

# 6a: set -e 環境で || busy_rc=$? パターンが正しく rc=1 を取得できることを確認
result_6a=$(
    set -euo pipefail
    func_returns_1() { return 1; }
    busy_rc=0
    func_returns_1 || busy_rc=$?
    echo "rc=$busy_rc"
)
assert_eq "6a: idle rc=1 で exit せず busy_rc=1 を取得できる" "rc=1" "$result_6a"

# 6b: stall_watchdog.sh に set -e 抑止パターンが実装されているかコードで確認
if grep -q 'busy_rc=0' "$SCRIPT_DIR/scripts/stall_watchdog.sh" \
    && grep -q 'agent_is_busy_check.*||.*busy_rc' "$SCRIPT_DIR/scripts/stall_watchdog.sh"; then
    assert_eq "6b: set -e 抑止パターン (busy_rc=0; func || busy_rc=\$?) がコードに存在" "found" "found"
else
    assert_eq "6b: set -e 抑止パターン (busy_rc=0; func || busy_rc=\$?) がコードに存在" "found" "not found"
fi

# ── Section 7: macOS hash 互換テスト ─────────────────────────────────────────

echo ""
echo "=== Section 7: md5_short macOS 互換テスト ==="
echo ""

# 7a: md5_short が 8文字のhex文字列を返す
result_7a=$(md5_short "hello world")
if [[ ${#result_7a} -eq 8 ]] && echo "$result_7a" | grep -qE '^[0-9a-f]{8}$'; then
    assert_eq "7a: md5_short が 8文字 hex を返す" "ok" "ok"
else
    assert_eq "7a: md5_short が 8文字 hex を返す (got: '$result_7a')" "ok" "fail"
fi

# 7b: md5_short が同じ入力で同じ値を返す (決定論的)
hash1=$(md5_short "test string 123")
hash2=$(md5_short "test string 123")
assert_eq "7b: md5_short が決定論的 (同じ入力→同じ出力)" "$hash1" "$hash2"

# 7c: md5_short が異なる入力で異なる値を返す
hashA=$(md5_short "string_alpha")
hashB=$(md5_short "string_beta")
if [[ "$hashA" != "$hashB" ]]; then
    assert_eq "7c: md5_short が入力差異を検出" "ok" "ok"
else
    assert_eq "7c: md5_short が入力差異を検出" "ok" "fail"
fi

# 7d: md5_short 実装が shasum か md5sum を使っている (md5sum が無い環境でも動く)
if grep -q 'command -v md5sum' "$SCRIPT_DIR/scripts/stall_watchdog.sh" \
    && grep -q 'shasum' "$SCRIPT_DIR/scripts/stall_watchdog.sh"; then
    assert_eq "7d: md5_short が md5sum/shasum フォールバック実装を持つ" "found" "found"
else
    assert_eq "7d: md5_short が md5sum/shasum フォールバック実装を持つ" "found" "not found"
fi

# ── サマリー ──────────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo " テスト結果サマリー"
echo "========================================"
echo " PASS: $PASS"
echo " FAIL: $FAIL"
echo " SKIP: 0"
if [[ "${#ERRORS[@]}" -gt 0 ]]; then
    echo ""
    echo " 失敗したテスト:"
    for err in "${ERRORS[@]}"; do
        echo "   - $err"
    done
fi
echo "========================================"

if [[ "$FAIL" -eq 0 ]]; then
    echo " 全テスト PASS ✅"
    exit 0
else
    echo " テスト失敗 ❌ (SKIP=FAIL ルール: FAIL=$FAIL)"
    exit 1
fi
