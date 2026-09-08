#!/usr/bin/env bats
#
# tests/unit/test_deadman_switch.bats
#
# cmd_779 死者確認スイッチ(scripts/deadman_switch.sh)のユニットテスト。
#
# ★独立性の実証: 本テストはinbox_watcher/stall_watchdog/heartbeat_detect等の
# 既存検知機構を一切source/呼び出ししていないことをgrepで確認する(T-DM-000)。
#
# DEADMAN_TASKS_DIR/DASHBOARD/STATE_DIR/LOG_FILE/LIVENESS_FILE/NTFY_SCRIPT/
# INBOX_WRITE_SCRIPT/NOW_EPOCHの差し替え口を使い、production queue/tasks・
# dashboard.md・/tmp/deadman-last-run・実ntfy送信・実queue/inbox/karo.yamlを
# 一切汚さず隔離実行する。ntfy.sh/inbox_write.shは呼出を記録するだけの
# スタブに差し替える(config/settings.yamlはgitignore対象でCI checkoutに
# 存在せず、実ntfy.shはcurl到達前にexit 1するため)。実際の到達確認は
# ashigaru7がHTTP 200を手動で実測済み・report参照。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SCRIPT="${PROJECT_ROOT}/scripts/deadman_switch.sh"

  export TMP_DIR
  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/deadman.XXXXXX")"
  mkdir -p "$TMP_DIR/tasks" "$TMP_DIR/state"

  export CALLS_LOG
  CALLS_LOG="$(mktemp "$BATS_TMPDIR/deadman_ntfy_calls.XXXXXX")"
  # ntfy.shスタブ(既存のtest_mgmt_bloat_watchdog.bats慣習に倣う): 実curl/実
  # config/settings.yamlに一切触れず、呼び出しを記録するだけ。config/settings.yaml
  # はgitignore対象でCI checkoutに存在しないため、実ntfy.shを経由するとntfy_topic
  # 未設定でcurl到達前にexit 1する(CI ubuntu-latest/macos-latest両方で実測)。
  export NTFY_STUB="$TMP_DIR/ntfy_stub.sh"
  cat > "$NTFY_STUB" << STUB
#!/usr/bin/env bash
echo "NTFY_CALLED: \$*" >> "${CALLS_LOG}"
STUB
  chmod +x "$NTFY_STUB"

  # 家老inbox通知スタブ(cmd_781): 実scripts/inbox_write.shを経由すると
  # production queue/inbox/karo.yamlへテスト用メッセージが実際に書き込まれて
  # しまうため、呼出を記録するだけのスタブに差し替える(ntfy_stub.shと同じ設計)
  export KARO_CALLS_LOG
  KARO_CALLS_LOG="$(mktemp "$BATS_TMPDIR/deadman_inbox_calls.XXXXXX")"
  export INBOX_WRITE_STUB="$TMP_DIR/inbox_write_stub.sh"
  cat > "$INBOX_WRITE_STUB" << STUB
#!/usr/bin/env bash
echo "INBOX_WRITE_CALLED: \$*" >> "${KARO_CALLS_LOG}"
STUB
  chmod +x "$INBOX_WRITE_STUB"

  export DEADMAN_TASKS_DIR="$TMP_DIR/tasks"
  export DEADMAN_DASHBOARD="$TMP_DIR/dashboard.md"
  export DEADMAN_STATE_DIR="$TMP_DIR/state"
  export DEADMAN_LOG_FILE="$TMP_DIR/log.log"
  export DEADMAN_LIVENESS_FILE="$TMP_DIR/liveness"
  export DEADMAN_NTFY_SCRIPT="$NTFY_STUB"
  export DEADMAN_INBOX_WRITE_SCRIPT="$INBOX_WRITE_STUB"
}

teardown() {
  rm -rf "$TMP_DIR" "$CALLS_LOG" "$KARO_CALLS_LOG" 2>/dev/null || true
}

epoch_of() {
  # $1: "YYYY-MM-DD HH:MM:SS" — BSD date(macOS)/GNU date(ubuntu-latest)双方で通る書式
  date -j -f "%Y-%m-%d %H:%M:%S" "$1" +%s 2>/dev/null || date -d "$1" +%s
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
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:05:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-002: idle大・昼間 → 家老通知の15分後、同一agentが停止中なら殿宛ntfyが
#   発火する(cmd_783『殿は最後の砦』により1回の実行では発火しない) ──
@test "T-DM-002: idleが閾値超・昼間は家老通知→15分後に殿宛ntfyが発火する" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  # 1回目: 家老通知のみ。殿はまだ起こさぬ
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  [ ! -s "$CALLS_LOG" ]
  [ -f "$DEADMAN_STATE_DIR/karo_notified_agents.txt" ]

  # 2回目: 15分経過・同一agentがまだ停止中 → 殿宛ntfy発火
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:16:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ -s "$CALLS_LOG" ]
  run grep -c "deadman_switch" "$DEADMAN_DASHBOARD"
  [ "$output" -ge 1 ]
}

# ── T-DM-003: idle大・夜間(22-8時) → 発火しない ──
@test "T-DM-003: idle大でも夜間は発火しない" {
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 23:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-004: cooldown内の再発火は抑止される(殿宛エスカレーション条件は
#   満たした状態にした上で、cooldownそのものが独立して効くことを確認する) ──
@test "T-DM-004: cooldown(2h)以内は再発火しない" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  mkdir -p "$DEADMAN_STATE_DIR"
  echo "$(epoch_of "2026-09-08 13:50:00")" > "$DEADMAN_STATE_DIR/last_fire_epoch.txt"
  # 家老通知記録は15分以上前(エスカレーション条件を満たす)にしておく。
  # karo_last_fire_epochは30分cooldown内(直近)に設定し、本テスト実行中に
  # 家老再通知でこの記録が上書きされ条件が変わらぬようにする
  echo "$(epoch_of "2026-09-08 13:30:00"),ashigaru1" > "$DEADMAN_STATE_DIR/karo_notified_agents.txt"
  echo "$(epoch_of "2026-09-08 13:45:00")" > "$DEADMAN_STATE_DIR/karo_last_fire_epoch.txt"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-005: 網自身の生存証跡(liveness touch + dashboard heartbeat行) ──
@test "T-DM-005: 毎回liveness fileをtouchしdashboard heartbeat行を更新する" {
  touch -t 202609081400.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:05:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$DEADMAN_LIVENESS_FILE" ]
  run grep -c "deadman_switch:heartbeat" "$DEADMAN_DASHBOARD"
  [ "$output" -eq 1 ]

  # 2回目実行 → heartbeat行は追記でなく上書き(1行のまま)
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:10:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "deadman_switch:heartbeat" "$DEADMAN_DASHBOARD"
  [ "$output" -eq 1 ]
}

# ── T-DM-006: queue/tasks/*.yamlが1件も無ければ判定不能で終了する ──
@test "T-DM-006: tasksディレクトリが空なら判定不能でexit 1" {
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-007: status: blockedのエージェントは放置idle大でも除外(2026-09-07
#   将軍実測・ashigaru3の35時間放置事故を受けた設計変更) ──
@test "T-DM-007: status:blockedは放置扱いされず発火しない" {
  cat > "$TMP_DIR/tasks/ashigaru8.yaml" <<'YAML'
task:
  status: blocked
YAML
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru8.yaml"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-008: 7名中1名だけ死んでいても(他は稼働中)個別に検知する
#   (「最新1本のmtimeだけ見る」旧設計の穴=ashigaru3型事故の再現テスト) ──
@test "T-DM-008: 他のエージェントが稼働中でも1名だけ放置なら個別検知する" {
  cat > "$TMP_DIR/tasks/ashigaru9.yaml" <<'YAML'
task:
  status: assigned
YAML
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru9.yaml"

  cat > "$TMP_DIR/tasks/ashigaru8.yaml" <<'YAML'
task:
  status: assigned
YAML
  touch -t 202609081359.00 "$TMP_DIR/tasks/ashigaru8.yaml"

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  [ ! -s "$CALLS_LOG" ]

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:16:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ -s "$CALLS_LOG" ]
  run grep -o "ashigaru9" "$DEADMAN_DASHBOARD"
  [ -n "$output" ]
  run grep -o "ashigaru8" "$DEADMAN_DASHBOARD"
  [ -z "$output" ]
}

# ── T-DM-009: エージェント名でないファイル(実測で発見: queue/tasks/には
#   gunshi_cmd624_design.yaml等が混在し、何ヶ月も前のmtimeのまま)は
#   判定対象から除外する ──
@test "T-DM-009: エージェント名パターンに合わないファイルは対象外" {
  cat > "$TMP_DIR/tasks/gunshi_cmd624_design.yaml" <<'YAML'
task:
  title: old design doc
YAML
  touch -t 202001010000.00 "$TMP_DIR/tasks/gunshi_cmd624_design.yaml"
  touch -t 202609081359.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-010: 夜間+停止検知 → 家老inboxへ通知が飛ぶ(「軽い作業のみ」文言含む)。
#   殿へのntfyは従来どおり夜間は発火しない(cmd_781・9/7-9/8全停止事故対応) ──
@test "T-DM-010: 夜間の停止検知時は家老inboxへ通知(軽い作業のみ文言)・殿へのntfyは飛ばない" {
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 23:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS_LOG" ]
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "karo" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
  run grep -c "軽い作業のみ" "$KARO_CALLS_LOG"
  [ "$output" -eq 1 ]
  [ -f "$DEADMAN_STATE_DIR/karo_last_fire_epoch.txt" ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
}

# ── T-DM-011: 昼間+停止検知 → 家老inbox・殿へのntfy双方が機能する(15分の
#   エスカレーション猶予を経て。cmd_783是正後の挙動) ──
@test "T-DM-011: 昼間の停止検知時は家老inbox・殿へのntfy双方が機能する" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  [ ! -s "$CALLS_LOG" ]

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:16:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$CALLS_LOG" ]
  run grep -c "軽い作業のみ" "$KARO_CALLS_LOG"
  [ "$output" -eq 0 ]
  [ -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ -f "$DEADMAN_STATE_DIR/karo_last_fire_epoch.txt" ]
}

# ── T-DM-012: 家老宛cooldown(30分)以内の再発火は抑止される。殿宛cooldown(2h)
#   とは独立した状態ファイルで管理されている(状態ファイル名が別であることも実証)。
#   殿宛エスカレーション条件(15分経過+同一agent停止中)は別途満たしておく ──
@test "T-DM-012: 家老宛cooldown(30分)以内は再通知しない・殿宛cooldownとは独立" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  mkdir -p "$DEADMAN_STATE_DIR"
  echo "$(epoch_of "2026-09-08 13:45:00")" > "$DEADMAN_STATE_DIR/karo_last_fire_epoch.txt"
  echo "$(epoch_of "2026-09-08 13:30:00"),ashigaru1" > "$DEADMAN_STATE_DIR/karo_notified_agents.txt"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$KARO_CALLS_LOG" ]
  # 殿宛cooldownは別状態ファイルゆえ影響を受けず、エスカレーション条件が
  # 揃っていれば通常どおり発火する
  [ -s "$CALLS_LOG" ]
}

# ── T-DM-013: 家老宛cooldownが切れていれば夜間でも再度通知される ──
@test "T-DM-013: 家老宛cooldown経過後は夜間でも再通知される" {
  touch -t 202609080300.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  mkdir -p "$DEADMAN_STATE_DIR"
  echo "$(epoch_of "2026-09-08 22:00:00")" > "$DEADMAN_STATE_DIR/karo_last_fire_epoch.txt"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 23:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  [ ! -s "$CALLS_LOG" ]
}

# ── cmd_783【殿は最後の砦】追加テスト ──

# ── T-DM-014: 家老通知から15分未満は殿宛ntfyが発火しない ──
@test "T-DM-014: 家老通知から15分未満は殿宛ntfyが発火しない" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  mkdir -p "$DEADMAN_STATE_DIR"
  echo "$(epoch_of "2026-09-08 13:50:00")" > "$DEADMAN_STATE_DIR/karo_last_fire_epoch.txt"
  echo "$(epoch_of "2026-09-08 13:50:00"),ashigaru1" > "$DEADMAN_STATE_DIR/karo_notified_agents.txt"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-015: 15分経過後でも、記録されたagentが解消済み(現在の停止一覧に
#   含まれない)なら殿宛ntfyは発火しない ──
@test "T-DM-015: 15分経過後でも記録agentが解消済みなら殿宛ntfyは発火しない" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru2.yaml"
  mkdir -p "$DEADMAN_STATE_DIR"
  echo "$(epoch_of "2026-09-08 13:45:00")" > "$DEADMAN_STATE_DIR/karo_last_fire_epoch.txt"
  echo "$(epoch_of "2026-09-08 13:30:00"),ashigaru1" > "$DEADMAN_STATE_DIR/karo_notified_agents.txt"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-016: 夜間は、家老通知から15分経過し同一agentが停止中でも殿宛ntfyは
#   発火しない(★夜間は家老のみ・殿は絶対に起こさない、を維持) ──
@test "T-DM-016: 夜間は15分経過・同一agent停止中でも殿宛ntfyは発火しない" {
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  mkdir -p "$DEADMAN_STATE_DIR"
  echo "$(epoch_of "2026-09-08 22:40:00"),ashigaru1" > "$DEADMAN_STATE_DIR/karo_notified_agents.txt"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 23:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-017: gunshi2は実在しないpane(2026-09-05将軍確認済み)ゆえ停止検知の
#   対象から除外される ──
@test "T-DM-017: gunshi2は停止検知の対象から除外される" {
  cat > "$TMP_DIR/tasks/gunshi2.yaml" <<'YAML'
task:
  status: assigned
YAML
  touch -t 202001010000.00 "$TMP_DIR/tasks/gunshi2.yaml"
  touch -t 202609081359.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ ! -s "$CALLS_LOG" ]
  [ ! -s "$KARO_CALLS_LOG" ]
  run grep -o "gunshi2" "$DEADMAN_DASHBOARD"
  [ -z "$output" ]
}
