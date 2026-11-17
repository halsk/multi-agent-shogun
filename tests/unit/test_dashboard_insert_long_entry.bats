#!/usr/bin/env bats
#
# cmd_974(B): dashboard追記が2048バイト超のentryで落ちない/台帳status行の
# インラインコメントを除く、の回帰試験。
#  (2) BSD sed の a\ は本文1行が2048バイトを超えるとそこで行を切り
#      「invalid command code」で落ちる(2026-10-17〜18 実害)
#  (1) ledger_cmd_status() が "in_progress  # 注記" の注記まで返していた

setup() {
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/dash_insert.XXXXXX")"
  # SCRIPT_DIR(=スクリプトの親の親)を一時dirにするため、本物のdashboard.mdに触れぬよう複製ツリーで試す
  mkdir -p "$TMP_DIR/scripts" "$TMP_DIR/lib"
  cp "$PROJECT_ROOT"/scripts/stall_watchdog.sh "$PROJECT_ROOT"/scripts/console_stall_watchdog.sh "$TMP_DIR/scripts/"
  cp "$PROJECT_ROOT"/lib/*.sh "$TMP_DIR/lib/"
  printf '# dash\n\n## 🚨 要対応\n\n- 既存\n' > "$TMP_DIR/dashboard.md"
  LONG="$(printf 'あ%.0s' $(seq 1 1500))"   # 4500バイト・多バイト
}

teardown() { rm -rf "$TMP_DIR" 2>/dev/null || true; }

@test "stall_watchdog notify_dashboard: 2049バイト超のentryでも見出し直後へ挿入される" {
  run bash -c "source '$TMP_DIR/scripts/stall_watchdog.sh'; DRY_RUN=false; notify_dashboard ashigaru1 '$LONG'"
  [ "$status" -eq 0 ]
  grep -q "$LONG" "$TMP_DIR/dashboard.md"
  [ "$(grep -n 'stall_watchdog' "$TMP_DIR/dashboard.md" | cut -d: -f1)" = "4" ]
}

@test "console_stall_watchdog notify_dashboard: 2049バイト超のentryでも挿入される" {
  run bash -c "source '$TMP_DIR/scripts/console_stall_watchdog.sh'; DRY_RUN=false; notify_dashboard '$LONG'"
  [ "$status" -eq 0 ]
  grep -q "$LONG" "$TMP_DIR/dashboard.md"
  [ "$(grep -n 'console_stall_watchdog' "$TMP_DIR/dashboard.md" | cut -d: -f1)" = "4" ]
}

@test "dashboard.mdの既存行は壊れず、entryは1行だけ増える" {
  run bash -c "source '$TMP_DIR/scripts/stall_watchdog.sh'; DRY_RUN=false; notify_dashboard ashigaru1 '$LONG'"
  [ "$(wc -l < "$TMP_DIR/dashboard.md" | tr -d ' ')" = "6" ]
  grep -q '^- 既存$' "$TMP_DIR/dashboard.md"
}

@test "両scriptにsedのa\\\\挿入が残っていない(全17箇所を置換済み)" {
  ! grep -n 'sed "${_dash_marker}a' "$PROJECT_ROOT/scripts/stall_watchdog.sh" "$PROJECT_ROOT/scripts/console_stall_watchdog.sh"
}

@test "ledger_cmd_status: status行のインラインコメントを除いて返す" {
  source "$PROJECT_ROOT/lib/ledger_mismatch_detect.sh"
  printf -- '- id: cmd_932\n  status: in_progress  # 2026-10-14 将軍が長い注記 # 二つ目\n  x: 1\n- id: cmd_933\n  status: done\n' > "$TMP_DIR/ledger.yaml"
  [ "$(ledger_cmd_status "$TMP_DIR/ledger.yaml" cmd_932)" = "in_progress" ]
  [ "$(ledger_cmd_status "$TMP_DIR/ledger.yaml" cmd_933)" = "done" ]
}

@test "ledger_cmd_status: 引用符内の#は除かない・注記無しは従来どおり" {
  source "$PROJECT_ROOT/lib/ledger_mismatch_detect.sh"
  printf -- '- id: cmd_1\n  status: "a # b"\n- id: cmd_2\n  status: pending\n' > "$TMP_DIR/ledger.yaml"
  [ "$(ledger_cmd_status "$TMP_DIR/ledger.yaml" cmd_2)" = "pending" ]
  [ "$(ledger_cmd_status "$TMP_DIR/ledger.yaml" cmd_1)" = "a # b" ]
}
