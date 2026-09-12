#!/usr/bin/env bash
# tests/test_deadman_switch.sh — cmd_807: config/settings.yaml 消失検知の回帰テスト
#
# scripts/deadman_switch.sh には source ガードが無く常にメインループを実行する
# ため(test_stall_watchdog.sh のような source+関数単体テストが行えない)、
# 実プロセスとして起動し DEADMAN_* 環境変数一式で全パスを一時ディレクトリへ
# 差し替える(本番の queue/tasks・dashboard.md・queue/deadman_switch には一切
# 触れない)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEADMAN_SCRIPT="$SCRIPT_DIR/scripts/deadman_switch.sh"

PASS=0
FAIL=0
ERRORS=()

assert_true() {
    local test_name="$1" cond="$2"
    if [[ "$cond" == "true" ]]; then
        echo "  ✅ PASS: $test_name"
        PASS=$(( PASS + 1 ))
    else
        echo "  ❌ FAIL: $test_name"
        FAIL=$(( FAIL + 1 ))
        ERRORS+=("$test_name")
    fi
}

TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

setup_fixture() {
    rm -rf "$TMPROOT"
    mkdir -p "$TMPROOT/tasks" "$TMPROOT/state"
    cat > "$TMPROOT/dashboard.md" <<'EOF'
# dashboard

## 🚨 要対応 - 殿のご判断をお待ちしております (Action Required - Awaiting Lord's Decision)

- 既存項目
EOF
    # deadman本来の「判定不能」ガード(file_count=0かつstalled無し)を回避するため
    # 実働中とみなされるtask YAMLを1本用意する(本テストの主眼はsettings.yaml
    # 検知であり、通常の停滞判定は他ファイルのカバー範囲)。
    printf 'task:\n  status: idle\n' > "$TMPROOT/tasks/ashigaru1.yaml"
}

run_deadman() {
    local settings_file="$1"
    DEADMAN_TASKS_DIR="$TMPROOT/tasks" \
    DEADMAN_DASHBOARD="$TMPROOT/dashboard.md" \
    DEADMAN_STATE_DIR="$TMPROOT/state" \
    DEADMAN_LOG_FILE="$TMPROOT/deadman.log" \
    DEADMAN_LIVENESS_FILE="$TMPROOT/liveness" \
    DEADMAN_SETTINGS_FILE="$settings_file" \
    DEADMAN_KARO_INBOX="$TMPROOT/nonexistent_karo.yaml" \
    DEADMAN_SHOGUN_INBOX="$TMPROOT/nonexistent_shogun.yaml" \
    bash "$DEADMAN_SCRIPT" > /dev/null 2>&1 || true
}

echo ""
echo "=== config/settings.yaml 消失検知 ==="
echo ""

# 1. settings.yaml が存在する → 🚨エントリを出さない(誤検知しない)
echo "--- 1: settings.yaml 存在時 → 🚨を出さない ---"
setup_fixture
echo "present" > "$TMPROOT/existing_settings.yaml"
run_deadman "$TMPROOT/existing_settings.yaml"
if grep -q 'settings.yaml が見当たらぬ' "$TMPROOT/dashboard.md"; then
    assert_true "settings.yaml存在時は🚨を出さない" "false"
else
    assert_true "settings.yaml存在時は🚨を出さない" "true"
fi

# 2. settings.yaml が無い → 🚨要対応節の見出し直後にエントリが挿入される
echo "--- 2: settings.yaml 消失時 → 🚨要対応節の見出し直後に挿入される ---"
setup_fixture
run_deadman "$TMPROOT/nonexistent_settings.yaml"
if grep -A1 '^## .*要対応.*殿のご判断' "$TMPROOT/dashboard.md" | tail -1 | grep -q 'settings.yaml が見当たらぬ'; then
    assert_true "見出し直後への挿入" "true"
else
    assert_true "見出し直後への挿入" "false"
fi

# 3. 直後に再実行してもcooldown内は重複しない(狼少年化防止)
echo "--- 3: cooldown内の再実行は重複させない ---"
run_deadman "$TMPROOT/nonexistent_settings.yaml"
count=$(grep -c 'settings.yaml が見当たらぬ' "$TMPROOT/dashboard.md")
assert_true "cooldown内は1件のみ(実測=${count})" "$([[ "$count" -eq 1 ]] && echo true || echo false)"

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
if [[ "$FAIL" -gt 0 ]]; then
    echo "Failed tests: ${ERRORS[*]}"
    exit 1
fi
exit 0
