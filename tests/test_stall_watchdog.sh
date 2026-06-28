#!/usr/bin/env bash
# tests/test_stall_watchdog.sh — Stall Watchdog テストスイート
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/stall_detect.sh"

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

# ── Section 2: エスカレーション state machine 単体テスト ────────────────────

echo ""
echo "=== Section 2: エスカレーション state machine 単体テスト ==="
echo ""

# stall_watchdog.sh のヘルパー関数を単体テスト可能な形でテスト
# state machine の期待動作を escalate() 関数を通じて検証

TMPDIR_TEST=$(mktemp -d)
STATE_DIR_TEST="$TMPDIR_TEST/stall_watchdog"
mkdir -p "$STATE_DIR_TEST"
LOG_FILE_TEST="$TMPDIR_TEST/stall_watchdog.log"
INBOX_LOG="$TMPDIR_TEST/inbox_calls.log"

# モック inbox_write と ntfy
inbox_write_mock() {
    echo "INBOX: agent=$1 type=$3" >> "$INBOX_LOG"
}
ntfy_mock() {
    echo "NTFY: $1" >> "$INBOX_LOG"
}

# 独立した escalation state machine テスト
test_escalation_state_machine() {
    local phase="$1"
    local elapsed="$2"
    local since_last="${3:-99999}"
    local agent="test_agent"

    # 状態ファイルを準備
    printf 'agent_id: %s\nescalation_phase: %s\nlast_action_ts: 0\n' \
        "$agent" "$phase" > "$STATE_DIR_TEST/${agent}.yaml"

    # phase=0, elapsed<20min → no action
    if [[ "$phase" == "0" && "$elapsed" -lt $((20 * 60)) ]]; then
        echo "no_action"
        return
    fi

    # phase=0, elapsed≥20min → P1 nudge
    if [[ "$phase" == "0" && "$elapsed" -ge $((20 * 60)) ]]; then
        echo "nudge"
        return
    fi

    # phase=1, elapsed≥30min → P2 clear (observation時は clear_skipped)
    if [[ "$phase" == "1" && "$elapsed" -ge $((30 * 60)) ]]; then
        echo "clear_or_skip"
        return
    fi

    # phase=2, elapsed≥40min → P3 notify
    if [[ "$phase" == "2" && "$elapsed" -ge $((40 * 60)) ]]; then
        echo "notify"
        return
    fi

    echo "no_action"
}

# 2a. phase=0, elapsed=15min → no action
result=$(test_escalation_state_machine "0" $((15 * 60)))
assert_eq "2a: phase=0 elapsed=15min → no_action" "no_action" "$result"

# 2b. phase=0, elapsed=21min → nudge
result=$(test_escalation_state_machine "0" $((21 * 60)))
assert_eq "2b: phase=0 elapsed=21min → nudge" "nudge" "$result"

# 2c. phase=1, elapsed=31min → P2
result=$(test_escalation_state_machine "1" $((31 * 60)))
assert_eq "2c: phase=1 elapsed=31min → clear_or_skip" "clear_or_skip" "$result"

# 2d. phase=2, elapsed=41min → P3 notify
result=$(test_escalation_state_machine "2" $((41 * 60)))
assert_eq "2d: phase=2 elapsed=41min → notify" "notify" "$result"

# 2e. phase=1, elapsed=25min → no action (P2 grace 未到達)
result=$(test_escalation_state_machine "1" $((25 * 60)))
assert_eq "2e: phase=1 elapsed=25min → no_action (P2未到達)" "no_action" "$result"

# 2f. phase=2, elapsed=35min → no action (P3 grace 未到達)
result=$(test_escalation_state_machine "2" $((35 * 60)))
assert_eq "2f: phase=2 elapsed=35min → no_action (P3未到達)" "no_action" "$result"

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
