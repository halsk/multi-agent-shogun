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
  mkdir -p "$TMP_DIR/tasks" "$TMP_DIR/state" "$TMP_DIR/reports"

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
  # cmd_784: 家老/将軍inbox生存信号の差し替え口。既定では存在せぬ一時パスを指し、
  # 本番 queue/inbox/{karo,shogun}.yaml を読まぬようにする(dispatcher検知を
  # 明示的にテストするケースのみ、各testでこの変数へ実ファイルを書く)。
  export DEADMAN_KARO_INBOX="$TMP_DIR/karo_inbox.yaml"
  export DEADMAN_SHOGUN_INBOX="$TMP_DIR/shogun_inbox.yaml"
  # cmd_880: HC_PING_URL_DEADMAN取得口を実在せぬパスへ差し替える。本ファイルの
  # 既存27テストはHC ping配線を意識していないため、差し替えを怠ると実Keychainから
  # 実ping URLを取得し実curlで本番Healthchecksへping送信してしまう
  # (実際に本is修正の開発中、この隔離漏れにより新規checkへ実ping34件が送信される
  # 事故を起こした・実害は開発中の一時checkのみで本番監視への影響は無かった)。
  export DEADMAN_GET_SECRET="$TMP_DIR/nonexistent-get-secret.sh"

  # cmd_914【一】T2: REPORTED_NOT_CLOSED判定の隔離口。REPORTS_DIRは既定で
  # dirname(DEADMAN_TASKS_DIR)/reports = $TMP_DIR/reports を指す(本番でも
  # queue/tasksとqueue/reportsは兄弟ディレクトリ)ため明示指定は必須では
  # ないが、テストの意図を読みやすくするため明示する。DEADMAN_PYTHON_BIN
  # は本番同様、.venv/bin/python3があればそれを、無ければ python3 を使う
  # (deadman_switch.sh自身のデフォルト解決に委ねるため未設定のままにする)。
  export DEADMAN_REPORTS_DIR="$TMP_DIR/reports"
  export DEADMAN_RECONCILE_SCRIPT="${PROJECT_ROOT}/scripts/deadman_reconcile.py"
}

# cmd_914【一】T2: fixture(実物のashigaru1 task/report YAMLの複製・
# tests/fixtures/cmd914/)をTMP_DIR/tasks・TMP_DIR/reportsへ配置し、
# mtimeを指定する。task/reportどちらもfixtureのtimestamp欄(task=16:53:00・
# report=17:00:00)はそのまま(report > task)。
place_cmd914_fixture() {
  local agent="$1" task_mtime="$2" report_mtime="$3"
  local fixtures_dir="${PROJECT_ROOT}/tests/fixtures/cmd914"
  cp "$fixtures_dir/task_ashigaru1_reported_not_closed.yaml" "$TMP_DIR/tasks/${agent}.yaml"
  cp "$fixtures_dir/report_ashigaru1_reported_not_closed.yaml" "$TMP_DIR/reports/${agent}_report.yaml"
  touch -t "$task_mtime" "$TMP_DIR/tasks/${agent}.yaml"
  touch -t "$report_mtime" "$TMP_DIR/reports/${agent}_report.yaml"
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
@test "T-DM-002: idleが閾値超・昼間は家老通知が飛ぶ・殿宛ntfyはcmd_795で恒久停止" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  # 1回目: 家老通知のみ。殿はまだ起こさぬ
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  [ ! -s "$CALLS_LOG" ]
  [ -f "$DEADMAN_STATE_DIR/karo_notified_agents.txt" ]

  # 2回目: 15分経過・同一agentがまだ停止中でも、cmd_795(殿裁定=丙・2026-09-11)
  # により殿宛エスカレーションは無効化済み(guard exit 0)。ntfyは飛ばない。
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:16:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ ! -s "$CALLS_LOG" ]
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

  # cmd_795(殿裁定=丙・2026-09-11)により殿宛エスカレーションは無効化済み。ntfyは飛ばない。
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:16:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ ! -s "$CALLS_LOG" ]
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
@test "T-DM-011: 昼間の停止検知時は家老inboxのみ機能する(殿へのntfyはcmd_795で恒久停止)" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  [ ! -s "$CALLS_LOG" ]

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:16:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS_LOG" ]
  run grep -c "軽い作業のみ" "$KARO_CALLS_LOG"
  [ "$output" -eq 0 ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
  [ -f "$DEADMAN_STATE_DIR/karo_last_fire_epoch.txt" ]
}

# ── T-DM-012: 家老宛cooldown(30分)以内の再発火は抑止される。殿宛cooldown(2h)
#   とは独立した状態ファイルで管理されている(状態ファイル名が別であることも実証)。
#   殿宛エスカレーション条件(15分経過+同一agent停止中)は別途満たしておく ──
@test "T-DM-012: 家老宛cooldown(20分)以内は再通知しない・殿宛ntfyはcmd_795で恒久停止" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  mkdir -p "$DEADMAN_STATE_DIR"
  echo "$(epoch_of "2026-09-08 13:45:00")" > "$DEADMAN_STATE_DIR/karo_last_fire_epoch.txt"
  echo "$(epoch_of "2026-09-08 13:30:00"),ashigaru1" > "$DEADMAN_STATE_DIR/karo_notified_agents.txt"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$KARO_CALLS_LOG" ]
  # cmd_795(殿裁定=丙・2026-09-11)により殿宛エスカレーションは条件充足でも発火しない
  [ ! -s "$CALLS_LOG" ]
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

# ── T-DM-017: gunshi2はcmd_803(2026-09-12・軍師2人体制)によりpaneが常設化され、
#   停止検知の対象に含まれるようになった(旧T-DM-017は「pane不在ゆえ除外」を
#   検証していたが、その前提はshutsujin_departure.shの改修で解消済み) ──
@test "T-DM-017: gunshi2はpane常設化により停止検知の対象に含まれる" {
  cat > "$TMP_DIR/tasks/gunshi2.yaml" <<'YAML'
task:
  status: assigned
YAML
  touch -t 202609081000.00 "$TMP_DIR/tasks/gunshi2.yaml"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  [ ! -s "$CALLS_LOG" ]
  run grep -o "gunshi2" "$KARO_CALLS_LOG"
  [ -n "$output" ]
}

# ══════════════════════════════════════════════════════════════════════════
# cmd_784: 緊急バグ①②修正 + 家老/将軍(dispatcher)自己監視
# ══════════════════════════════════════════════════════════════════════════

# ── T-DM-018【バグ①再現・修正実証】家老へ個別通知されていない新規停止agentは
#   殿宛エスカレーションに巻き込まれない ──
#   snapshot=[ashigaru5](15分経過済)・現在の停止=ashigaru1+ashigaru5。
#   殿へ飛ぶのはashigaru5のみで、家老通知を経ていないashigaru1は含まれない。
@test "T-DM-018: 殿宛エスカレーション自体がcmd_795で恒久停止(交差集合ロジックは到達不能として保全)" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"   # 240分idle(新規停止)
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru5.yaml"   # 240分idle(通知済)
  mkdir -p "$DEADMAN_STATE_DIR"
  # 家老宛cooldown内(10分前)にしてkaro再通知をskip→旧snapshotを温存させる
  echo "$(epoch_of "2026-09-08 13:50:00")" > "$DEADMAN_STATE_DIR/karo_last_fire_epoch.txt"
  # snapshot: 20分前にashigaru5のみを家老通知済(15分経過条件を満たす)
  echo "$(epoch_of "2026-09-08 13:40:00"),ashigaru5" > "$DEADMAN_STATE_DIR/karo_notified_agents.txt"
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # 家老は再通知されない(cooldown内)
  [ ! -s "$KARO_CALLS_LOG" ]
  # cmd_795(殿裁定=丙・2026-09-11)により殿宛エスカレーションは条件充足でも発火しない。
  # 交差集合(escalate_agents)のバグ①修正ロジック自体はコードとして保全されているが、
  # 273行以降が到達不能ゆえ実行されない。
  [ ! -s "$CALLS_LOG" ]
}

# ── T-DM-019【バグ②修正実証】家老宛cooldownは20分(30分ではない) ──
#   前回家老通知から25分経過 → 20分ルールなら再通知される・30分ルールなら
#   まだブロックされる。再通知されることで20分であることを実証する。
@test "T-DM-019: 家老宛cooldownは20分(前回通知から25分経過で再通知される)" {
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  mkdir -p "$DEADMAN_STATE_DIR"
  echo "$(epoch_of "2026-09-08 13:35:00")" > "$DEADMAN_STATE_DIR/karo_last_fire_epoch.txt"  # 25分前
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]   # 25分>20分ゆえ再通知される(30分なら来ない)
}

# ── T-DM-020【家老生存監視】家老inboxに閾値超の未読滞留 → 家老停止を検知 ──
@test "T-DM-020: 家老inboxの未読が閾値超に滞留すると家老停止として検知する" {
  touch -t 202609081359.00 "$TMP_DIR/tasks/ashigaru1.yaml"   # 足軽は正常(1分idle)
  cat > "$DEADMAN_KARO_INBOX" <<'YAML'
messages:
- content: test
  from: shogun
  id: x1
  read: false
  timestamp: '2026-09-08T11:00:00'
  type: task_assigned
YAML
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "未読滞留" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
  run grep -c "karo" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
}

# ── T-DM-021【idle区別】家老inboxに未読が無ければ(手番待ちでなく正常idle)検知しない ──
@test "T-DM-021: 家老inboxに未読が無ければ家老停止として検知しない" {
  touch -t 202609081359.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  cat > "$DEADMAN_KARO_INBOX" <<'YAML'
messages:
- content: test
  from: shogun
  id: x1
  read: true
  timestamp: '2026-09-08T11:00:00'
  type: task_assigned
YAML
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$KARO_CALLS_LOG" ]
  [ ! -s "$CALLS_LOG" ]
  [ ! -f "$DEADMAN_STATE_DIR/last_fire_epoch.txt" ]
}

# ── T-DM-022【将軍生存監視】将軍inboxに閾値超の未読滞留 → 将軍停止を検知 ──
@test "T-DM-022: 将軍inboxの未読が閾値超に滞留すると将軍停止として検知する" {
  touch -t 202609081359.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  cat > "$DEADMAN_SHOGUN_INBOX" <<'YAML'
messages:
- content: test
  from: karo
  id: s1
  read: false
  timestamp: '2026-09-08T11:00:00'
  type: task_assigned
YAML
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "shogun" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
}

# ── T-DM-023【dispatcher→殿の最後の砦】家老停止が15分後も未解消なら殿へ発火 ──
@test "T-DM-023: 家老停止が15分後も未解消でも、殿宛ntfy(最後の砦)はcmd_795で恒久停止" {
  touch -t 202609081359.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  cat > "$DEADMAN_KARO_INBOX" <<'YAML'
messages:
- content: test
  from: shogun
  id: x1
  read: false
  timestamp: '2026-09-08T11:00:00'
  type: task_assigned
YAML
  # 1回目: 家老通知のみ(snapshotに karo を記録)
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  [ ! -s "$CALLS_LOG" ]
  # 2回目: 16分後・家老はまだ停止(未読滞留のまま)でも、cmd_795(殿裁定=丙・
  # 2026-09-11)により殿宛「最後の砦」エスカレーションは発火しない。
  # ★gunshi設計文書が正直に記帳した穴(家中完全停止+家老自身も詰まった時に
  # 気づく主体が居なくなる)がまさにこの状態。埋める案(家老自動/clear復旧)は
  # 本cmdでは未実装・殿裁可待ち。
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:16:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS_LOG" ]
}

# ══════════════════════════════════════════════════════════════════════════
# cmd_785⑨(2026-09-09)→cmd_914【一】T2(2026-09-28)で置き換え:
# 当初は「夜間・全員status:done停止」を3時間cooldownへ間引くだけだった
# (20分毎の連打を減らす対症療法)。軍師設計(queue/reports/
# cmd914_status_update_gap.md §3.2)は真因に踏み込み、「status=doneは
# 手が空いただけで止まっていない」と判じ、間引くのではなく★そもそも
# stalledとして報せない★よう改めた(blockedと同じ扱い)。旧T-DM-024〜026
# (間引きcooldownの実証)はこの変更で検証対象そのものが消えたため、
# 新しいT-DM-024〜026(status=doneは常にstalled非対象であることの実証)へ
# 置き換える。
# ══════════════════════════════════════════════════════════════════════════

# ── T-DM-024【新】status=doneで手が空いた足軽は、idleがどれだけ長くても
#   stalledと報せない(夜間・昼間いずれも)──
@test "T-DM-024: status=doneは夜間・昼間いずれもstalledと報せない" {
  cat > "$TMP_DIR/tasks/ashigaru1.yaml" <<'YAML'
task:
  status: done
YAML
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru1.yaml"

  # 夜間(idle=17h超)でも通知なし
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 23:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$KARO_CALLS_LOG" ]

  # 昼間に切り替わってもなお通知なし(idle=32h超)
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-09 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$KARO_CALLS_LOG" ]
}

# ── T-DM-025【新】停止中に1件でもstatus:assigned等(done以外)が混じれば、
#   その1件だけは従来どおり検知・通知される(doneの足軽は引き続き無視) ──
@test "T-DM-025: status:done以外が1件混じればその1件だけ検知・通知される" {
  cat > "$TMP_DIR/tasks/ashigaru1.yaml" <<'YAML'
task:
  status: done
YAML
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  cat > "$TMP_DIR/tasks/ashigaru2.yaml" <<'YAML'
task:
  status: unknown
YAML
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru2.yaml"

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 23:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "ashigaru1" "$KARO_CALLS_LOG"
  [ "$output" -eq 0 ]
  run grep -c "ashigaru2" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
}

# ── T-DM-026【新】status=doneの足軽しかいない場合、全体としても発火しない
#   (stalled配列が空のまま終わることの実証・heartbeat行のstalled=0も確認) ──
@test "T-DM-026: status=doneの足軽しかいなければstalled=0のまま発火しない" {
  cat > "$TMP_DIR/tasks/ashigaru1.yaml" <<'YAML'
task:
  status: done
YAML
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru1.yaml"

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$KARO_CALLS_LOG" ]
  run grep -c "stalled=0" "$DEADMAN_DASHBOARD"
  [ "$output" -ge 1 ]
}

# ══════════════════════════════════════════════════════════════════════════
# cmd_942派生(2026-10-07): status:行のインラインコメントで誤検知する穴
# 家老はstatus:をdoneへ書き戻す時、慣例として
#   status: done  # 2026-10-07 16:58 CI全green・main be2647aへmerge済み(家老)
# のようにinline commentで根拠を添える。是正前の抽出
#   sed 's/.*status:[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d ' '
# は「#」以降を切り捨てず、$statusが
#   done#2026-10-0716:58CI全green・mainbe2647aへmerge済み(家老)
# となり[ "$status" = "done" ]に一致せず、手が空いただけの足軽へ20分おきに
# 🚨を出し続けた(実例: ashigaru6へ3回以上)。blockedも同じ抽出を通るため
# 同じ穴がある。番号はT-DM-027〜035が既にcmd_914 T2で使われているため
# 036/037を振る(task YAMLの「T-DM-027(仮称)」は仮の番号)。
# ══════════════════════════════════════════════════════════════════════════

# ── T-DM-036【RED→GREEN】status:doneにinline commentが付いていても、
#   idleがどれだけ長くてもstalledと報せない。是正前はKARO_CALLS_LOGに
#   ashigaru1の🚨が積まれた ──
@test "T-DM-036: status:done行にinline commentが付いていてもstalledと報せない—是正前は誤検知した" {
  cat > "$TMP_DIR/tasks/ashigaru1.yaml" <<'YAML'
task:
  task_id: subtask_test_done_trailing_comment
  status: done  # 2026-10-07 16:58 CI全green・main be2647aへmerge済み(家老)
YAML
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru1.yaml"

  # 夜間(idle=17h超)でも通知なし
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 23:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$KARO_CALLS_LOG" ]

  # 昼間に切り替わってもなお通知なし(idle=32h超)
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-09 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$KARO_CALLS_LOG" ]
  run grep -c "stalled=0" "$DEADMAN_DASHBOARD"
  [ "$output" -ge 1 ]
}

# ── T-DM-037【RED→GREEN】status:blockedにinline commentが付いていても
#   同様に素通りする(殿裁可待ちは正しい停止)。併せて、空白1つだけの
#   「done #…」・クォート付き「"done" # …」の形もdoneと読めることを
#   確かめる(書き方の揺れで判定が変わらぬこと) ──
@test "T-DM-037: status:blocked行のinline comment・空白1つ/クォート付きの揺れでも誤検知しない—是正前は誤検知した" {
  cat > "$TMP_DIR/tasks/ashigaru1.yaml" <<'YAML'
task:
  task_id: subtask_test_blocked_trailing_comment
  status: blocked  # 殿裁可待ち
YAML
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  cat > "$TMP_DIR/tasks/ashigaru2.yaml" <<'YAML'
task:
  task_id: subtask_test_done_single_space_comment
  status: done #merge済み
YAML
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru2.yaml"
  cat > "$TMP_DIR/tasks/ashigaru3.yaml" <<'YAML'
task:
  task_id: subtask_test_done_quoted_comment
  status: "done"  # PR#199 merge済み
YAML
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru3.yaml"

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-09 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$KARO_CALLS_LOG" ]
  run grep -c "stalled=0" "$DEADMAN_DASHBOARD"
  [ "$output" -ge 1 ]
}

# ── T-DM-038【歯止め・RED→GREEN】inline commentを切っても、done/blocked
#   以外(assigned等)は従来どおり検知される(コメント切りが「何でも素通り」に
#   なっていないこと)。併せて家老への文言のstatus=欄がコメントの残骸
#   (assigned#2026-10-0720:32家老が割当)でなく素のassignedになることを確かめる
#   (是正前は検知自体はしたが文言に残骸が混じった) ──
@test "T-DM-038: inline comment付きでもstatus:assignedは従来どおり検知され、文言のstatus=欄は素の値になる" {
  cat > "$TMP_DIR/tasks/ashigaru2.yaml" <<'YAML'
task:
  task_id: subtask_test_assigned_trailing_comment
  status: assigned  # 2026-10-07 20:32 家老が割当
YAML
  touch -t 202609080600.00 "$TMP_DIR/tasks/ashigaru2.yaml"

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-09 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "ashigaru2(status=assigned・idle=" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
}

# ══════════════════════════════════════════════════════════════════════════
# cmd_914【一】T2: REPORTED_NOT_CLOSED判定(軍師設計§3.2・§4の条件1〜6)
# ══════════════════════════════════════════════════════════════════════════

# ── T-DM-027【RED→GREEN・実物fixture】ashigaru1の実際の食い違い
#   (subtask_cmd911_e1_e2_vault_write・task=assigned/report=done)を複製した
#   fixtureを使う。是正前のdeadman_switch.shならこの組は単なる「放置」として
#   stalled扱いのまま残った(2026-09-28 16:40の実ログと同じ形)。是正後は
#   task YAMLのstatusをdoneへ書き戻し、stalledとは別の文言で家老へ通知する ──
@test "T-DM-027: REPORTED_NOT_CLOSED正常系(実物ashigaru1食い違いfixture)—書き戻し・専用文言通知・stalledに入らない" {
  place_cmd914_fixture ashigaru1 202609281651.00 202609281654.00
  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-28 19:30:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # task YAMLのstatusがdoneへ書き戻されている
  run grep -E '^\s*status:\s*done\s*$' "$TMP_DIR/tasks/ashigaru1.yaml"
  [ "$status" -eq 0 ]

  # 家老へは「閉じた」の専用文言で通知され、放置の文言(「放置中」)は含まない
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "閉じた" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
  run grep -c "放置中" "$KARO_CALLS_LOG"
  [ "$output" -eq 0 ]

  # dashboard・logにも記録される
  run grep -c "REPORTED_NOT_CLOSED" "$DEADMAN_DASHBOARD"
  [ "$output" -ge 1 ]
  run grep -c "REPORTED_NOT_CLOSED agent=ashigaru1" "$DEADMAN_LOG_FILE"
  [ "$output" -ge 1 ]
}

# ── T-DM-028【安全側①】報告のtask_idがtask YAMLと違えば閉じない。
#   前のtaskの報告で今のtaskを誤って閉じる事故(2026-09-28実測の知らせの
#   取り違えと同型)を防ぐ ──
@test "T-DM-028: 報告のtask_idがtaskと違えばREPORTED_NOT_CLOSEDとせずstalledのまま(理由付き)" {
  cat > "$TMP_DIR/tasks/ashigaru2.yaml" <<'YAML'
task:
  task_id: subtask_test_028_task
  status: assigned
  timestamp: "2026-09-08T10:00:00"
YAML
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru2.yaml"
  cat > "$TMP_DIR/reports/ashigaru2_report.yaml" <<'YAML'
report:
  worker_id: ashigaru2
  task_id: subtask_test_028_OTHER
  parent_cmd: cmd_x
  status: done
  timestamp: "2026-09-08T10:05:00"
  result: ok
skill_candidate: null
YAML
  touch -t 202609081005.00 "$TMP_DIR/reports/ashigaru2_report.yaml"

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 14:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "task_idが違う" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
  # taskのstatusは書き換わっていない(assignedのまま)
  run grep -E '^\s*status:\s*assigned\s*$' "$TMP_DIR/tasks/ashigaru2.yaml"
  [ "$status" -eq 0 ]
}

# ── T-DM-029【安全側②】報告のmtimeがtaskより古ければ閉じない。家老の書き足し・
#   差し戻し(addendum)後に古い報告で閉じる事故を防ぐ ──
@test "T-DM-029: 報告のmtimeがtaskより古ければREPORTED_NOT_CLOSEDとせずstalledのまま" {
  cat > "$TMP_DIR/tasks/ashigaru3.yaml" <<'YAML'
task:
  task_id: subtask_test_029
  status: assigned
  timestamp: "2026-09-08T10:00:00"
YAML
  touch -t 202609081200.00 "$TMP_DIR/tasks/ashigaru3.yaml"   # task mtime: 12:00(報告より後)
  cat > "$TMP_DIR/reports/ashigaru3_report.yaml" <<'YAML'
report:
  worker_id: ashigaru3
  task_id: subtask_test_029
  parent_cmd: cmd_x
  status: done
  timestamp: "2026-09-08T10:05:00"
  result: ok
skill_candidate: null
YAML
  touch -t 202609081005.00 "$TMP_DIR/reports/ashigaru3_report.yaml"  # report mtime: 10:05(taskより古い)

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 15:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "報告がtaskより古い" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
}

# ── T-DM-030【安全側③-a】報告が複数文書(`---`区切り)なら閉じない ──
@test "T-DM-030: 報告が複数文書ならREPORTED_NOT_CLOSEDとせずstalledのまま" {
  cat > "$TMP_DIR/tasks/ashigaru4.yaml" <<'YAML'
task:
  task_id: subtask_test_030
  status: assigned
  timestamp: "2026-09-08T10:00:00"
YAML
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru4.yaml"
  cat > "$TMP_DIR/reports/ashigaru4_report.yaml" <<'YAML'
report:
  worker_id: ashigaru4
  task_id: subtask_test_030
  parent_cmd: cmd_x
  status: done
  timestamp: "2026-09-08T10:05:00"
  result: ok
  skill_candidate: null
---
stray: doc
YAML
  touch -t 202609081005.00 "$TMP_DIR/reports/ashigaru4_report.yaml"

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 15:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "単一文書でない" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
}

# ── T-DM-031【安全側③-b】報告に重複キーがあれば閉じない(2026-09-27
#   ashigaru2の重複キー事故=cmd_900と同型の壊れ方を、閉じる材料として
#   使わない) ──
@test "T-DM-031: 報告に重複キーがあればREPORTED_NOT_CLOSEDとせずstalledのまま" {
  cat > "$TMP_DIR/tasks/ashigaru5.yaml" <<'YAML'
task:
  task_id: subtask_test_031
  status: assigned
  timestamp: "2026-09-08T10:00:00"
YAML
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru5.yaml"
  cat > "$TMP_DIR/reports/ashigaru5_report.yaml" <<'YAML'
report:
  worker_id: ashigaru5
  worker_id: ashigaru5
  task_id: subtask_test_031
  parent_cmd: cmd_x
  status: done
  timestamp: "2026-09-08T10:05:00"
  result: ok
  skill_candidate: null
YAML
  touch -t 202609081005.00 "$TMP_DIR/reports/ashigaru5_report.yaml"

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 15:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "重複キー" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
}

# ── T-DM-032【条件6】報告のstatusがblockedならtaskへblockedを書き戻すが、
#   「閉じた」「closed」とは表現しない(軍師設計§4条件6) ──
@test "T-DM-032: 報告のstatusがblockedならblockedへ書き戻すが「閉じた」とは言わない" {
  cat > "$TMP_DIR/tasks/ashigaru6.yaml" <<'YAML'
task:
  task_id: subtask_test_032
  status: assigned
  timestamp: "2026-09-08T10:00:00"
YAML
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru6.yaml"
  cat > "$TMP_DIR/reports/ashigaru6_report.yaml" <<'YAML'
report:
  worker_id: ashigaru6
  task_id: subtask_test_032
  parent_cmd: cmd_x
  status: blocked
  timestamp: "2026-09-08T10:05:00"
  result: 1Password認証待ち
skill_candidate: null
YAML
  touch -t 202609081005.00 "$TMP_DIR/reports/ashigaru6_report.yaml"

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 15:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -E '^\s*status:\s*blocked\s*$' "$TMP_DIR/tasks/ashigaru6.yaml"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "閉じた" "$KARO_CALLS_LOG"
  [ "$output" -eq 0 ]
  run grep -c "blocked" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
}

# ── T-DM-033【報告なし】対応する報告ファイルが存在しなければ、従来どおり
#   stalledとして報せる(REPORTED_NOT_CLOSEDへ迂回しない) ──
@test "T-DM-033: 報告ファイルが無ければREPORTED_NOT_CLOSEDとせず従来どおりstalledとして報せる" {
  cat > "$TMP_DIR/tasks/ashigaru7.yaml" <<'YAML'
task:
  task_id: subtask_test_033
  status: assigned
  timestamp: "2026-09-08T10:00:00"
YAML
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru7.yaml"
  # queue/reports/ashigaru7_report.yaml を意図的に用意しない

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 15:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "放置中" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
  run grep -c "報告ファイルなし" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
}

# ══════════════════════════════════════════════════════════════════════════
# cmd_914【一】T2続き: 軍師QC是正(F1・F2)
# ══════════════════════════════════════════════════════════════════════════

# ── T-DM-034【F1・RED→GREEN】報告が「平らな形」(report:で包まない・
#   worker_id/task_id等を文書の一番上に直接並べる。正典=instructions/
#   ashigaru.md Report Format・inbox skill Step 10)であってもCLOSEできる。
#   実測: 今のqueue/reports/ashigaru{2,6,7}_report.yamlはこの形であり、
#   report:で包む形しか受けなかった是正前は「report欄なし」でSTALLEDの
#   ままだった(2026-09-28 20:00頃、軍師QCで手動確認済み)。本fixtureは
#   ashigaru7_report.yamlの実物の形を模したもの(tests/fixtures/cmd914/
#   report_flat_form_ashigaru7_shape.yaml参照)──
@test "T-DM-034: 報告が平らな形(ashigaru7_report.yaml実物型)でもCLOSEになる—是正前はSTALLEDのままだった" {
  cat > "$TMP_DIR/tasks/ashigaru1.yaml" <<'YAML'
task:
  task_id: subtask_test_f1_flat_form
  status: assigned
  timestamp: "2026-09-28T15:40:00"
YAML
  touch -t 202609281540.00 "$TMP_DIR/tasks/ashigaru1.yaml"
  cp "${PROJECT_ROOT}/tests/fixtures/cmd914/report_flat_form_ashigaru7_shape.yaml" "$TMP_DIR/reports/ashigaru1_report.yaml"
  touch -t 202609281550.00 "$TMP_DIR/reports/ashigaru1_report.yaml"

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-28 19:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # task YAMLのstatusがdoneへ書き戻されている(平らな形の報告でCLOSEした証拠)
  run grep -E '^  status: done$' "$TMP_DIR/tasks/ashigaru1.yaml"
  [ "$status" -eq 0 ]

  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "閉じた" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
  run grep -c "放置中" "$KARO_CALLS_LOG"
  [ "$output" -eq 0 ]
  run grep -c "report欄なし" "$KARO_CALLS_LOG"
  [ "$output" -eq 0 ]
}

# ── T-DM-035【F2・RED→GREEN】task:直下の字下げ(2つの空白)だけのstatus:行を
#   書き換え、context等のblock文字列中の「status: …」という言及(家老の
#   説明文によく出る)は書き換わらない。是正前(`^[[:space:]]*status:`と
#   字下げ不問)ならcontextブロック内の「    status: draft (…)」という行を
#   誤って書き換え、本物のtask.statusは assigned のまま残った(2026-09-28
#   軍師QC・手動再現で確認済み)。書き戻し後にyamlで読み直しtask.statusが
#   新しい値になったことを確かめる仕組み自体もここで検証する ──
@test "T-DM-035: block文中のstatus:言及は書き換わらず、task:直下の本物のstatus:のみ書き換わる—是正前は誤って書き換わった" {
  cat > "$TMP_DIR/tasks/ashigaru2.yaml" <<'YAML'
task:
  task_id: subtask_test_f2_block_status
  parent_cmd: cmd_x
  context: |
    前回の是正メモ:
    status: draft (これは足軽が書き残した言及であり、本物のtask.statusではない)
  status: assigned
  timestamp: "2026-09-08T10:00:00"
YAML
  touch -t 202609081000.00 "$TMP_DIR/tasks/ashigaru2.yaml"
  cat > "$TMP_DIR/reports/ashigaru2_report.yaml" <<'YAML'
report:
  worker_id: ashigaru2
  task_id: subtask_test_f2_block_status
  parent_cmd: cmd_x
  status: done
  timestamp: "2026-09-08T10:05:00"
  result: ok
skill_candidate: null
YAML
  touch -t 202609081005.00 "$TMP_DIR/reports/ashigaru2_report.yaml"

  DEADMAN_NOW_EPOCH="$(epoch_of "2026-09-08 15:00:00")" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # 本物のtask.status(task:直下・2space)がdoneへ書き換わっている
  run grep -E '^  status: done$' "$TMP_DIR/tasks/ashigaru2.yaml"
  [ "$status" -eq 0 ]

  # contextブロック内の「status: draft」という言及は一切変わっていない
  run grep -c "status: draft (これは足軽が書き残した言及であり、本物のtask.statusではない)" "$TMP_DIR/tasks/ashigaru2.yaml"
  [ "$output" -eq 1 ]

  # 「  status: draft」(2space+status:draft)は存在しない(書き換わっていたら残るはずの旧誤爆の跡が無い)
  run grep -c '^  status: draft' "$TMP_DIR/tasks/ashigaru2.yaml"
  [ "$output" -eq 0 ]

  [ -s "$KARO_CALLS_LOG" ]
  run grep -c "閉じた" "$KARO_CALLS_LOG"
  [ "$output" -ge 1 ]
}
