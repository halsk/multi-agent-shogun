#!/usr/bin/env bash
# test_report_auto_notify.sh — report_auto_notify.py(cmd_778①)の回帰テスト。
# Usage: bash scripts/hooks/test_report_auto_notify.sh
#
# ★実データを汚さぬ設計: すべて `_hooktest_` prefix の使い捨てagent名で
# queue/tasks・queue/reports・queue/inbox に一時ファイルを作り、
# 終了時に必ず削除する(trap EXIT)。実エージェントのYAMLには一切触れない。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR/../..")"
export CLAUDE_PROJECT_DIR="$PROJ_ROOT"

HOOK="$PROJ_ROOT/scripts/hooks/report_auto_notify.py"
INBOX_WRITE="$PROJ_ROOT/scripts/inbox_write.sh"

TASK_YAML="$PROJ_ROOT/queue/tasks/_hooktest_agent.yaml"
REPORT_YAML="$PROJ_ROOT/queue/reports/_hooktest_agent_report.yaml"
UNKNOWN_REPORT_YAML="$PROJ_ROOT/queue/reports/_hooktest_unknown_report.yaml"
KARO_REPORT_YAML="$PROJ_ROOT/queue/reports/karo_report.yaml"
KARO_TARGET_INBOX="$PROJ_ROOT/queue/inbox/_hooktest_karo.yaml"
STATE_FILE="$PROJ_ROOT/.claude/hook_state/report_auto_notify_state.json"
DEDUP_SCOPE_INBOX="$PROJ_ROOT/queue/inbox/_hooktest_dedup_scope.yaml"
RETRY_TASK_YAML="$PROJ_ROOT/queue/tasks/_hooktest_retry_agent.yaml"
RETRY_REPORT_YAML="$PROJ_ROOT/queue/reports/_hooktest_retry_agent_report.yaml"
RETRY_TARGET_INBOX="$PROJ_ROOT/queue/inbox/_hooktest_retry_karo.yaml"
KARO_REPORT_EXISTED=0

cleanup() {
  rm -f "$TASK_YAML" "$REPORT_YAML" "$UNKNOWN_REPORT_YAML" "$KARO_TARGET_INBOX" "$DEDUP_SCOPE_INBOX"
  rm -f "$RETRY_TASK_YAML" "$RETRY_REPORT_YAML" "$RETRY_TARGET_INBOX"
  if [ "$KARO_REPORT_EXISTED" -eq 0 ]; then
    rm -f "$KARO_REPORT_YAML"
  fi
  # state fileはfile_pathキー単位で他agentの分も混在するため全消しはしない。
  # テスト対象キーのみ除去する。
  python3 -c "
import json
p = '$STATE_FILE'
try:
    with open(p) as f:
        state = json.load(f)
except (OSError, ValueError):
    state = {}
for k in list(state.keys()):
    if '_hooktest_' in k:
        del state[k]
with open(p, 'w') as f:
    json.dump(state, f)
" 2>/dev/null || true
}
trap cleanup EXIT

[ -f "$KARO_REPORT_YAML" ] && KARO_REPORT_EXISTED=1

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ FAIL: $desc (expected=$expected, got=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

msg_count() {
  local inbox="$1"
  [ -f "$inbox" ] || { echo 0; return; }
  python3 -c "
import yaml
d = yaml.safe_load(open('$inbox'))
print(len(d.get('messages', [])) if d else 0)
"
}

run_hook() {
  local file_path="$1"
  local payload
  payload="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$file_path\"},\"tool_response\":{\"success\":true}}"
  echo "$payload" | python3 "$HOOK" >/tmp/_hooktest_stderr_capture 2>&1
  echo $?
}

# --- 前準備 ---
mkdir -p "$PROJ_ROOT/queue/tasks" "$PROJ_ROOT/queue/reports" "$PROJ_ROOT/queue/inbox"
cat > "$TASK_YAML" <<'EOF'
task:
  task_id: subtask_hooktest_001
  parent_cmd: cmd_hooktest
  assigned_to: _hooktest_agent
  status: assigned
  report_to: _hooktest_karo
EOF

echo "=== report_auto_notify.py: status遷移検知・宛先解決・冪等性 ==="

cat > "$REPORT_YAML" <<'EOF'
worker_id: _hooktest_agent
task_id: subtask_hooktest_001
parent_cmd: cmd_hooktest
status: assigned
timestamp: "2026-01-01T00:00:00"
EOF
EXIT_A=$(run_hook "$REPORT_YAML")
assert_eq "T-A: status=assigned -> exit 0" "0" "$EXIT_A"
assert_eq "T-A: status=assigned -> inboxへ通知なし" "0" "$(msg_count "$KARO_TARGET_INBOX")"

cat > "$REPORT_YAML" <<'EOF'
worker_id: _hooktest_agent
task_id: subtask_hooktest_001
parent_cmd: cmd_hooktest
status: done
timestamp: "2026-01-01T00:05:00"
EOF
EXIT_B=$(run_hook "$REPORT_YAML")
assert_eq "T-B: status:done遷移 -> exit 0" "0" "$EXIT_B"
assert_eq "T-B: status:done遷移 -> report_toで解決した宛先へ1件通知" "1" "$(msg_count "$KARO_TARGET_INBOX")"

EXIT_C=$(run_hook "$REPORT_YAML")
assert_eq "T-C: 同一done状態への再編集 -> exit 0" "0" "$EXIT_C"
assert_eq "T-C: 同一done状態への再編集 -> 二重通知しない" "1" "$(msg_count "$KARO_TARGET_INBOX")"

cat > "$REPORT_YAML" <<'EOF'
worker_id: _hooktest_agent
task_id: subtask_hooktest_001
parent_cmd: cmd_hooktest
status: in_progress
timestamp: "2026-01-01T00:10:00"
EOF
run_hook "$REPORT_YAML" >/dev/null
# dedup windowを避けるため、直前の通知を意図的に古い時刻へ書き換える
python3 -c "
import yaml
p = '$KARO_TARGET_INBOX'
d = yaml.safe_load(open(p))
d['messages'][0]['timestamp'] = '2020-01-01T00:00:00'
yaml.dump(d, open(p, 'w'), default_flow_style=False, allow_unicode=True, indent=2)
"
cat > "$REPORT_YAML" <<'EOF'
worker_id: _hooktest_agent
task_id: subtask_hooktest_001
parent_cmd: cmd_hooktest
status: done
timestamp: "2026-01-01T00:15:00"
EOF
EXIT_D=$(run_hook "$REPORT_YAML")
assert_eq "T-D: redo(in_progress経由で再度done、dedup窓外) -> exit 0" "0" "$EXIT_D"
assert_eq "T-D: redo再完了 -> 再通知される(合計2件)" "2" "$(msg_count "$KARO_TARGET_INBOX")"

cat > "$UNKNOWN_REPORT_YAML" <<'EOF'
worker_id: _hooktest_unknown
task_id: subtask_hooktest_002
parent_cmd: cmd_hooktest
status: done
timestamp: "2026-01-01T00:20:00"
EOF
EXIT_E=$(run_hook "$UNKNOWN_REPORT_YAML")
assert_eq "T-E: 宛先解決不能(task yaml無し・既定マッピング外) -> exit 2で可視化" "2" "$EXIT_E"

if [ "$KARO_REPORT_EXISTED" -eq 0 ]; then
  cat > "$KARO_REPORT_YAML" <<'EOF'
status: done
task_id: subtask_hooktest_karo
parent_cmd: cmd_hooktest
EOF
  EXIT_F=$(run_hook "$KARO_REPORT_YAML")
  assert_eq "T-F: agent=karo -> dashboard専用ポリシーによりexit 0で静かにスキップ" "0" "$EXIT_F"
  assert_eq "T-F: agent=karo -> shogunへのinbox書込は発生しない" "0" "$(ls "$PROJ_ROOT"/queue/inbox/ 2>/dev/null | grep -c '^shogun\.yaml$' || true)"
else
  echo "  ℹ️  queue/reports/karo_report.yaml が実在するためT-Fはスキップ(実データ保護)"
fi

echo ""
echo "=== report_auto_notify.py: 発火失敗時にnotified状態を汚さないこと(実測で発見した回帰バグ) ==="
cat > "$RETRY_TASK_YAML" <<'EOF'
task:
  task_id: subtask_hooktest_retry
  parent_cmd: cmd_hooktest
  assigned_to: _hooktest_retry_agent
  status: assigned
  report_to: _hooktest_retry_karo
EOF
cat > "$RETRY_REPORT_YAML" <<'EOF'
worker_id: _hooktest_retry_agent
task_id: subtask_hooktest_retry
parent_cmd: cmd_hooktest
status: done
timestamp: "2026-01-01T00:00:00"
EOF
# inbox_write.shを一時的に破壊し、発火自体を失敗させる
mv "$INBOX_WRITE" "${INBOX_WRITE}.disabled_for_test"
EXIT_RETRY1=$(run_hook "$RETRY_REPORT_YAML")
mv "${INBOX_WRITE}.disabled_for_test" "$INBOX_WRITE"
assert_eq "T-H1: inbox_write.sh起動失敗 -> exit 2で可視化(黙って落ちない)" "2" "$EXIT_RETRY1"
assert_eq "T-H1: 発火失敗時は通知されていない" "0" "$(msg_count "$RETRY_TARGET_INBOX")"

# inbox_write.sh復旧後、同じdoneファイルへの再editで再試行できること
# (発火失敗時にnotified=Trueを書いてしまうと、ここが黙って握りつぶされる回帰バグだった)
EXIT_RETRY2=$(run_hook "$RETRY_REPORT_YAML")
assert_eq "T-H2: 復旧後の再edit -> exit 0" "0" "$EXIT_RETRY2"
assert_eq "T-H2: 復旧後の再edit -> 今度こそ通知が届く" "1" "$(msg_count "$RETRY_TARGET_INBOX")"

echo ""
echo "=== inbox_write.sh: report_received限定dedupが他typeへ波及しないこと ==="
bash "$INBOX_WRITE" _hooktest_dedup_scope "message one" task_assigned karo >/dev/null 2>&1
bash "$INBOX_WRITE" _hooktest_dedup_scope "message two" task_assigned karo >/dev/null 2>&1
assert_eq "T-G: task_assigned x2連続 -> dedup対象外で両方書き込まれる" "2" "$(msg_count "$DEDUP_SCOPE_INBOX")"

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
