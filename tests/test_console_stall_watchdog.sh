#!/usr/bin/env bash
# tests/test_console_stall_watchdog.sh — console stall watchdog (cmd_725第三段) テストスイート
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/console_stall_detect.sh"
# source ガードにより flock・メインループはスキップされる (関数のみ利用)
source "$SCRIPT_DIR/scripts/console_stall_watchdog.sh"

PASS=0
FAIL=0
SKIP=0
ERRORS=()

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
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

# ── Section 1: max_epoch ─────────────────────────────────────────────────────
echo ""
echo "=== Section 1: max_epoch ==="
assert_eq "1a: max_epoch(10,20,5)=20" "20" "$(max_epoch 10 20 5)"
assert_eq "1b: max_epoch(0,0,0)=0" "0" "$(max_epoch 0 0 0)"
assert_eq "1c: max_epoch(999,1,2)=999" "999" "$(max_epoch 999 1 2)"

# ── Section 2: in_night_window ───────────────────────────────────────────────
echo ""
echo "=== Section 2: in_night_window (night_start=22 night_end=8) ==="

check_night() {
    local hour="$1" expected="$2" name="$3"
    if in_night_window "$hour" 22 8; then
        assert_eq "$name" "$expected" "night"
    else
        assert_eq "$name" "$expected" "day"
    fi
}
check_night 22 "night" "2a: 22時 → 夜間"
check_night 23 "night" "2b: 23時 → 夜間"
check_night 0  "night" "2c: 0時(日跨ぎ) → 夜間"
check_night 7  "night" "2d: 7時 → 夜間"
check_night 8  "day"   "2e: 8時 → 昼間(境界)"
check_night 21 "day"   "2f: 21時 → 昼間(境界)"
check_night 14 "day"   "2g: 14時 → 昼間"

# ── Section 3: classify_stall_reason ─────────────────────────────────────────
echo ""
echo "=== Section 3: classify_stall_reason 優先順位 a>b>c>d>e ==="

assert_eq "3a: dashboardにconsole言及あり → a" "a" \
    "$(classify_stall_reason "### 🚨【殿裁可】console PR#999 merge" "" "assigned" "")"

assert_eq "3b: reportsに1Password言及 → b" "b" \
    "$(classify_stall_reason "" "1Password Touch ID認証待ち" "assigned" "")"

assert_eq "3c: task status=blocked かつ reason あり → c" "c" \
    "$(classify_stall_reason "" "" "blocked" "SpaHashedAssets Lambdaの原因未特定")"

assert_eq "3d: reportsにbackend依存言及 → d" "d" \
    "$(classify_stall_reason "" "backend実装が要る(API未実装)" "assigned" "")"

assert_eq "3e: 該当なし → e" "e" \
    "$(classify_stall_reason "" "" "assigned" "")"

# 優先順位: dashboard(a)がreports(b)より優先されること
assert_eq "3f: aとbが両方該当してもaが優先" "a" \
    "$(classify_stall_reason "console 殿裁可待ち" "1Password認証待ち" "assigned" "")"

# blocked だが reason 空 → c にならず後続へフォールスルー (dも該当なければ e)
assert_eq "3g: blockedだがreason空 → cにならずeへ" "e" \
    "$(classify_stall_reason "" "" "blocked" "")"

# ── Section 4: notification_body ─────────────────────────────────────────────
echo ""
echo "=== Section 4: notification_body — 区分+依頼内容が必ず含まれる ==="

for cat in a b c d e; do
    body=$(notification_body "$cat" "テスト詳細_$cat")
    if echo "$body" | grep -q "区分$cat"; then
        assert_eq "4.$cat: 区分ラベルを含む" "found" "found"
    else
        assert_eq "4.$cat: 区分ラベルを含む" "found" "NOT FOUND: $body"
    fi
    if echo "$body" | grep -q "テスト詳細_$cat"; then
        assert_eq "4.$cat: 詳細内容を含む" "found" "found"
    else
        assert_eq "4.$cat: 詳細内容を含む" "found" "NOT FOUND: $body"
    fi
done

# (e) は「手番はござらぬ」を明示すること (手番でないものを手番のように見せない)
body_e=$(notification_body "e" "順序表の次位が未着手")
if echo "$body_e" | grep -q "手番はござらぬ"; then
    assert_eq "4e-special: (e)は殿の手番なしを明示" "found" "found"
else
    assert_eq "4e-special: (e)は殿の手番なしを明示" "found" "NOT FOUND: $body_e"
fi

# unknown category → 詳細不明 (捏造しない)
body_unknown=$(notification_body "z" "判定不能ケース")
if echo "$body_unknown" | grep -q "詳細不明"; then
    assert_eq "4-unknown: 未知区分は詳細不明と明記" "found" "found"
else
    assert_eq "4-unknown: 未知区分は詳細不明と明記" "found" "NOT FOUND: $body_unknown"
fi

# ── Section 5: --sample-all 統合テスト (5区分サンプル生成) ──────────────────
echo ""
echo "=== Section 5: --sample-all で5区分すべてのサンプル文言を出力する ==="

SAMPLE_OUTPUT=$(bash "$SCRIPT_DIR/scripts/console_stall_watchdog.sh" --sample-all 2>&1 || true)
for cat in a b c d e; do
    if echo "$SAMPLE_OUTPUT" | grep -q "区分${cat}"; then
        assert_eq "5.${cat}: --sample-all出力に区分${cat}が含まれる" "found" "found"
    else
        assert_eq "5.${cat}: --sample-all出力に区分${cat}が含まれる" "found" "NOT FOUND"
    fi
done

# ── Section 6: --dry-run 統合テスト (状態を書き換えない) ─────────────────────
echo ""
echo "=== Section 6: --dry-run 統合テスト ==="

DRY_RUN_OUTPUT=$(bash "$SCRIPT_DIR/scripts/console_stall_watchdog.sh" --dry-run 2>&1 || true)
if echo "$DRY_RUN_OUTPUT" | grep -q '\[START\]'; then
    assert_eq "6a: --dry-runがSTARTログを出す" "true" "true"
else
    assert_eq "6a: --dry-runがSTARTログを出す" "START in output" "NOT FOUND: $DRY_RUN_OUTPUT"
fi
if echo "$DRY_RUN_OUTPUT" | grep -q '\[DONE\]'; then
    assert_eq "6b: --dry-runが正常終了する" "true" "true"
else
    assert_eq "6b: --dry-runが正常終了する" "DONE in output" "NOT FOUND: $DRY_RUN_OUTPUT"
fi

# ── Section 7: 設定値の読み込み ──────────────────────────────────────────────
echo ""
echo "=== Section 7: config/settings.yaml から閾値等を読み込む(ハードコード禁止) ==="

threshold=$(load_console_setting "stall_threshold_hours" "999")
assert_eq "7a: stall_threshold_hoursが設定から読める" "4" "$threshold"

night_start=$(load_console_setting "night_start_hour" "999")
assert_eq "7b: night_start_hourが設定から読める" "22" "$night_start"

night_end=$(load_console_setting "night_end_hour" "999")
assert_eq "7c: night_end_hourが設定から読める" "8" "$night_end"

throttle=$(load_console_setting "throttle_hours" "999")
assert_eq "7d: throttle_hoursが設定から読める" "6" "$throttle"

# ── Section 8: 既存 stall_watchdog.sh 非破壊確認 ─────────────────────────────
# ★cmd_725当初は console_stall_watchdog.sh を stall_watchdog.sh と完全独立に
# 保つ方針だったため「差分ゼロ」を assert していた。cmd_767(静かな失敗の検知)
# はこの方針を上書きし、★★★単独の新規監視機構を作らず既存stall_watchdog.sh
# へ相乗りすることを明示的に要求する(lib/heartbeat_detect.sh経由)。
# よって本セクションは「差分ゼロ」ではなく「既存ロジックの削除・書き換えを
# 伴わない(純追加のみ)」へ弱める——cmd_766/771の相乗りでも同じ形の追加が
# 既に前例としてある。
echo ""
echo "=== Section 8: 既存 stall_watchdog.sh のエスカレーションロジックが破壊されていないこと(cmd_767以降は純追加の相乗りを許可) ==="

removed_lines=$(git -C "$SCRIPT_DIR" diff -- scripts/stall_watchdog.sh scripts/com.swarm.stall-watchdog.plist scripts/stall-watchdog-launcher.sh 2>/dev/null | grep -E '^-' | grep -vc '^--- ' || true)
if [[ "$removed_lines" -eq 0 ]]; then
    assert_eq "8a: 既存stall-watchdog関連ファイルは純追加のみ(既存行の削除・書き換えなし)" "0" "0"
else
    assert_eq "8a: 既存stall-watchdog関連ファイルは純追加のみ(既存行の削除・書き換えなし)" "0" "$removed_lines"
fi

# 新規ジョブ名が既存と異なること (Label衝突防止)
if [[ -f "$SCRIPT_DIR/scripts/com.swarm.console-stall-watchdog.plist" ]]; then
    new_label=$(grep -A1 '<key>Label</key>' "$SCRIPT_DIR/scripts/com.swarm.console-stall-watchdog.plist" | tail -1)
    if echo "$new_label" | grep -q "com.swarm.console-stall-watchdog"; then
        assert_eq "8b: 新規plistのLabelが既存と異なる独立ジョブ名" "found" "found"
    else
        assert_eq "8b: 新規plistのLabelが既存と異なる独立ジョブ名" "found" "NOT FOUND: $new_label"
    fi
else
    assert_eq "8b: 新規plistファイルが存在する" "exists" "MISSING"
fi

# ── Section 9: set -e 回帰テスト — console_reports_text() が最終行で非0を ────
#    返してもスクリプト全体を落とさないこと (実機検証で発見した実バグの回帰)
echo ""
echo "=== Section 9: P0回帰 — console_reports_text()がset -e下で早期終了させない ==="

result_9a=$(
    set -euo pipefail
    source "$SCRIPT_DIR/scripts/console_stall_watchdog.sh"
    reports_text=$(console_reports_text)
    echo "survived"
)
assert_eq "9a: reports_text=\$(console_reports_text) がset -e下で生き残る" "survived" "$result_9a"

# 強制停滞(閾値0h)状態でも --dry-run がSTALL/NOTIFYまで到達し正常終了すること
# ★sed -i ''(BSD専用書式)はGNU sedでは壊れる(cmd_766教訓・本ファイルを
# ubuntu-latest CIへ接続する際に実測発覚・state_set()と同じ一時ファイル
# 経由のsed→mvへ是正)。
# ★★実在の config/settings.yaml は一切書き換えない(cmd_new_ci_orphan_tests
# 軍師QC F-3)——閾値0hの一時コピーを作り、CONSOLE_STALL_WATCHDOG_SETTINGS
# でスクリプトの読み先だけを差し替える。中断されても実ファイルは無傷。
_tmp_settings=$(mktemp)
sed 's/stall_threshold_hours: 4/stall_threshold_hours: 0/' "$SCRIPT_DIR/config/settings.yaml" > "$_tmp_settings"
FORCED_STALL_OUTPUT=$(CONSOLE_STALL_WATCHDOG_SETTINGS="$_tmp_settings" bash "$SCRIPT_DIR/scripts/console_stall_watchdog.sh" --dry-run 2>&1) && FORCED_RC=0 || FORCED_RC=$?
rm -f "$_tmp_settings"

assert_eq "9b: 強制停滞状態でも--dry-runがrc=0で完走する" "0" "$FORCED_RC"
if echo "$FORCED_STALL_OUTPUT" | grep -q '\[STALL\]'; then
    assert_eq "9c: 強制停滞状態で[STALL]ログに到達する" "found" "found"
else
    assert_eq "9c: 強制停滞状態で[STALL]ログに到達する" "found" "NOT FOUND: $FORCED_STALL_OUTPUT"
fi
if echo "$FORCED_STALL_OUTPUT" | grep -q '\[DONE\]'; then
    assert_eq "9d: 強制停滞状態でも[DONE]まで正常終了する" "found" "found"
else
    assert_eq "9d: 強制停滞状態でも[DONE]まで正常終了する" "found" "NOT FOUND: $FORCED_STALL_OUTPUT"
fi

# ── Section 10: iso_to_epoch — UTC/JST混同回帰(cmd_new_utc_jst F2) ──────────
# ★date -j -f '...Z' はTZ未指定だとローカルTZとして解釈され、真のepochより
# ローカルTZ分ずれる(macOS実機再現・家老確認済み)。既知の正epoch値と突き合わせ、
# 再発を検出できる構造にする。
echo ""
echo "=== Section 10: iso_to_epoch がTZ非依存で正しいepochを返す(UTC/JST混同回帰) ==="

assert_eq "10a: iso_to_epoch('2026-09-06T06:17:45Z') が既知の正epochと一致" \
    "1788675465" "$(iso_to_epoch "2026-09-06T06:17:45Z")"

# ── Section 11: state_set() の`|`区切り文字衝突 回帰テスト(PR#108 follow-up) ──
# PR#108(scripts/stall_watchdog.sh)で見つかったsed区切り文字衝突バグと
# 同型のパターンが本ファイルにも残存していた(前回監査の見逃し)。
# 実state fileを汚さぬようSTATE_FILEを一時ファイルへ差し替えて検証する。
echo ""
echo "=== Section 11: state_set()の|区切り文字衝突 回帰テスト ==="

TMPDIR_TEST11=$(mktemp -d)
STATE_FILE="$TMPDIR_TEST11/state.yaml"

pipe_value='21|2026-09-10T12:00:00|resolve待ち(halsk氏)x18,差し戻し中(足軽)x1'
state_set "pending_body" "$pipe_value"
readback_11a=$(state_get "pending_body" "")
assert_eq "11a: |を含む値の新規書き込みが正しく読める" "$pipe_value" "$readback_11a"

state_set "pending_body" "old_value"
readback_before_11b=$(state_get "pending_body" "")
assert_eq "11b前提: 上書き前は旧値" "old_value" "$readback_before_11b"
pipe_value2='22|2026-09-10T13:00:00|resolve待ち(halsk氏)x22'
state_set "pending_body" "$pipe_value2"
readback_11b=$(state_get "pending_body" "")
assert_eq "11b: |を含む値でのupsertが正しく反映される" "$pipe_value2" "$readback_11b"

state_set "pending" "false"
readback_11c=$(state_get "pending" "")
assert_eq "11c: 他フィールドは|衝突の影響を受けない" "false" "$readback_11c"

rm -rf "$TMPDIR_TEST11"

# ── Section 12: notify_dashboard — 見出し行(^##)以外の言及に惑わされない ─────
# 実バグ回帰(cmd_793 FU-1)。本文中に過去の解説として、見出し検出に使う
# パターン文字列自体への言及(decoy)が複数箇所あっても、非アンカーの
# grep/sedはそれらにも一致してしまい重複挿入する瑕疵があった
# (subtask_console_stall_watchdog_dashboard_heading_grep_fix)。
# PR#119(stall_watchdog.sh)・PR#120(mgmt_bloat_watchdog.sh)のT-MBW-014と
# 同型のテスト: 修正前のnotify_dashboard()に対して実行すると本テストは
# FAILすることを確認済み(3箇所へ重複挿入・実見出し以外にも入る)。
echo ""
echo "=== Section 12: notify_dashboard — 見出し行以外の言及に惑わされない(実バグ回帰・cmd_793 FU-1) ==="

TMPDIR_TEST12=$(mktemp -d)
mkdir -p "$TMPDIR_TEST12/scripts" "$TMPDIR_TEST12/lib" "$TMPDIR_TEST12/logs" "$TMPDIR_TEST12/queue"
cp "$SCRIPT_DIR/scripts/console_stall_watchdog.sh" "$TMPDIR_TEST12/scripts/console_stall_watchdog.sh"
cp "$SCRIPT_DIR/lib/console_stall_detect.sh" "$TMPDIR_TEST12/lib/console_stall_detect.sh"
cp "$SCRIPT_DIR/lib/run_log.sh" "$TMPDIR_TEST12/lib/run_log.sh"

cat > "$TMPDIR_TEST12/dashboard.md" <<'DASH'
# dashboard

**参考**: `grep -q '## 🚨 要対応'`というパターンを使い実際の見出しに一致させている、という解説がここに書かれている(本文中の言及であり見出しではない)。

別の言及: sedのアドレス指定は`/## 🚨 要対応/a`のように書ける、という説明もここにある。

## 🚨 要対応 - 殿のご判断をお待ちしております (Action Required - Awaiting Lord's Decision)

(既存の項目はここに続く)
DASH

(
    set -euo pipefail
    source "$TMPDIR_TEST12/lib/console_stall_detect.sh"
    source "$TMPDIR_TEST12/scripts/console_stall_watchdog.sh"
    notify_dashboard "T12FIXTURE_MARKER_UNIQUE"
)

decoy1_line=$(grep -n '\*\*参考\*\*' "$TMPDIR_TEST12/dashboard.md" | head -1 | cut -d: -f1)
decoy2_line=$(grep -n '別の言及' "$TMPDIR_TEST12/dashboard.md" | head -1 | cut -d: -f1)
heading_line=$(grep -n '^## 🚨 要対応' "$TMPDIR_TEST12/dashboard.md" | head -1 | cut -d: -f1)
entry_count=$(grep -c 'T12FIXTURE_MARKER_UNIQUE' "$TMPDIR_TEST12/dashboard.md" || true)
entry_line=$(grep -n 'T12FIXTURE_MARKER_UNIQUE' "$TMPDIR_TEST12/dashboard.md" | head -1 | cut -d: -f1)

assert_eq "12a: 通知は1件のみ挿入される(decoyへの重複挿入なし)" "1" "$entry_count"
if [[ -n "$heading_line" && -n "$entry_line" && "$entry_line" -eq "$((heading_line + 1))" ]]; then
    assert_eq "12b: 通知は実見出し(^## )の直後に挿入される" "found" "found"
else
    assert_eq "12b: 通知は実見出し(^## )の直後に挿入される" "found" "NOT FOUND: heading=$heading_line entry=$entry_line"
fi
if [[ -n "$entry_line" && -n "$decoy1_line" && -n "$decoy2_line" && "$entry_line" -gt "$decoy1_line" && "$entry_line" -gt "$decoy2_line" ]]; then
    assert_eq "12c: 通知は本文中の言及(decoy)より後に入る" "found" "found"
else
    assert_eq "12c: 通知は本文中の言及(decoy)より後に入る" "found" "NOT FOUND: decoy1=$decoy1_line decoy2=$decoy2_line entry=$entry_line"
fi

rm -rf "$TMPDIR_TEST12"

# ── サマリー ──────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo " テスト結果サマリー"
echo "========================================"
echo " PASS: $PASS"
echo " FAIL: $FAIL"
echo " SKIP: $SKIP"
if [[ "${#ERRORS[@]}" -gt 0 ]]; then
    echo ""
    echo " 失敗したテスト:"
    for err in "${ERRORS[@]}"; do
        echo "   - $err"
    done
fi
echo "========================================"

if [[ "$FAIL" -eq 0 && "$SKIP" -eq 0 ]]; then
    echo " 全テスト PASS ✅"
    exit 0
else
    echo " テスト失敗 ❌ (SKIP=FAIL ルール: FAIL=$FAIL SKIP=$SKIP)"
    exit 1
fi
