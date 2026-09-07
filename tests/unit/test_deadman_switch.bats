#!/usr/bin/env bats
#
# tests/unit/test_deadman_switch.bats
#
# cmd_779 死者確認スイッチ(scripts/deadman_switch.sh)のユニットテスト。
#
# ★独立性の実証: 本テストはinbox_watcher/stall_watchdog/heartbeat_detect等の
# 既存検知機構を一切source/呼び出ししていないことをgrepで確認する(T-DM-000)。
#
# DEADMAN_TASKS_DIR/DASHBOARD/STATE_DIR/LOG_FILE/LIVENESS_FILE/NOW_EPOCHの
# 差し替え口を使い、production queue/tasks・dashboard.md・/tmp/deadman-last-run
# を一切汚さず隔離実行する。curlはPATH先頭のモックで差し替え、実ntfy送信は
# 行わない(実際の到達確認はashigaru7がHTTP 200を手動で実測済み・report参照)。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SCRIPT="${PROJECT_ROOT}/scripts/deadman_switch.sh"

  export TMP_DIR
  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/deadman.XXXXXX")"
  mkdir -p "$TMP_DIR/tasks" "$TMP_DIR/state"

  export MOCK_BIN
  MOCK_BIN="$(mktemp -d "$BATS_TMPDIR/deadman_mock_bin.XXXXXX")"
  export CALLS_LOG
  CALLS_LOG="$(mktemp "$BATS_TMPDIR/deadman_curl_calls.XXXXXX")"
  cat > "${MOCK_BIN}/curl" << MOCK_CURL
#!/usr/bin/env bash
echo "CURL_CALLED: \$*" >> "${CALLS_LOG}"
exit 0
MOCK_CURL
  chmod +x "${MOCK_BIN}/curl"

  export DEADMAN_TASKS_DIR="$TMP_DIR/tasks"
  export DEADMAN_DASHBOARD="$TMP_DIR/dashboard.md"
  export DEADMAN_STATE_DIR="$TMP_DIR/state"
  export DEADMAN_LOG_FILE="$TMP_DIR/log.log"
  export DEADMAN_LIVENESS_FILE="$TMP_DIR/liveness"
}

teardown() {
  rm -rf "$TMP_DIR" "$MOCK_BIN" "$CALLS_LOG" 2>/dev/null || true
}

epoch_of() {
  date -j -f "%Y%m%d%H%M.%S" "$1" +%s 2>/dev/null || date -d "$1" +%s
}

# ── T-DM-000: 既存検知機構への依存が皆無であることの静的確認 ──
@test "T-DM-000: 既存検知機構(inbox_watcher/stall_watchdog/heartbeat_detect)をsource/呼び出ししない" {
  run bash -c "grep -E 'source .*(inbox_watcher|stall_watchdog|heartbeat_detect)\.sh' '${SCRIPT}'"
  [ "$status" -ne 0 ]
  run bash -c "grep -E '(^|[^-])(inbox_watcher|stall_watchdog|heartbeat_detect)\.sh' '${SCRIPT}' | grep -v '^#'"
  [ "$status" -ne 0 ]
}

# ── T-DM-001: idle小(working中)・昼間 → 発火しない ──
@test "T-DM-001: idleが閾値未満なら誤報しない" {
  touch -t 202609081400.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  PATH="${MOCK_BIN}:${PATH}" DEADMAN_NOW_EPOCH="$(epoch_of 202609081405.00)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-002: idle大・昼間 → 発火する(ntfy呼出) ──
@test "T-DM-002: idleが閾値超・昼間なら発火してntfyを呼ぶ" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  PATH="${MOCK_BIN}:${PATH}" DEADMAN_NOW_EPOCH="$(epoch_of 202609081400.00)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ -s "$CALLS_LOG" ]
  run grep -c "deadman_switch" "$DEADMAN_DASHBOARD"
  [ "$output" -ge 1 ]
}

# ── T-DM-003: idle大・夜間(22-8時) → 発火しない ──
@test "T-DM-003: idle大でも夜間は発火しない" {
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  PATH="${MOCK_BIN}:${PATH}" DEADMAN_NOW_EPOCH="$(epoch_of 202609082300.00)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-004: cooldown内の再発火は抑止される ──
@test "T-DM-004: cooldown(2h)以内は再発火しない" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  mkdir -p "$DEADMAN_STATE_DIR"
  echo "$(epoch_of 202609081350.00)" > "$DEADMAN_STATE_DIR/last_fire_epoch.txt"
  PATH="${MOCK_BIN}:${PATH}" DEADMAN_NOW_EPOCH="$(epoch_of 202609081400.00)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-005: 網自身の生存証跡(liveness touch + dashboard heartbeat行) ──
@test "T-DM-005: 毎回liveness fileをtouchしdashboard heartbeat行を更新する" {
  touch -t 202609081400.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  PATH="${MOCK_BIN}:${PATH}" DEADMAN_NOW_EPOCH="$(epoch_of 202609081405.00)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$DEADMAN_LIVENESS_FILE" ]
  run grep -c "deadman_switch:heartbeat" "$DEADMAN_DASHBOARD"
  [ "$output" -eq 1 ]

  # 2回目実行 → heartbeat行は追記でなく上書き(1行のまま)
  PATH="${MOCK_BIN}:${PATH}" DEADMAN_NOW_EPOCH="$(epoch_of 202609081410.00)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "deadman_switch:heartbeat" "$DEADMAN_DASHBOARD"
  [ "$output" -eq 1 ]
}

# ── T-DM-006: queue/tasks/*.yamlが1件も無ければ判定不能で終了する ──
@test "T-DM-006: tasksディレクトリが空なら判定不能でexit 1" {
  PATH="${MOCK_BIN}:${PATH}" DEADMAN_NOW_EPOCH="$(epoch_of 202609081400.00)" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ ! -s "$CALLS_LOG" ]
}
