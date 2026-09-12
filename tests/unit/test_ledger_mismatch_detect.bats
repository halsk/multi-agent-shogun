#!/usr/bin/env bats
#
# tests/unit/test_ledger_mismatch_detect.bats
#
# cmd_766 第一層: report が完了 (status: done) を示しているのに、対応する
# 台帳 (shogun_to_karo.yaml) の cmd が pending/in_progress のまま N 時間
# 経過している状態を機械的に検知する純関数のユニットテスト。
#
# 本日 cmd_763/cmd_764 が実際にこの型だった(完了報告済みで pending のまま
# 残っていた・将軍指摘で是正)——このテストはその再現ケースを含む。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/ledger_mismatch_detect.sh"

  export TMP_DIR
  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/ledger_mismatch.XXXXXX")"
  mkdir -p "$TMP_DIR/reports"
}

teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

seed_ledger() {
  printf '%s\n' "$1" > "$TMP_DIR/ledger.yaml"
}

seed_report() {
  local name="$1" content="$2" age_hours="${3:-0}"
  printf '%s\n' "$content" > "$TMP_DIR/reports/$name"
  if [[ "$age_hours" -gt 0 ]]; then
    local ts
    ts=$(date -v-"${age_hours}"H '+%Y%m%d%H%M' 2>/dev/null || date -d "-${age_hours} hours" '+%Y%m%d%H%M')
    touch -t "$ts" "$TMP_DIR/reports/$name"
  fi
}

# ── T-LM-001: report done + ledger pending + 経過 N 時間 → mismatch 検出 ──

@test "T-LM-001: detects report done vs ledger pending after threshold (cmd_763/764 repro)" {
  [ -f "$LIB_FILE" ] || { echo "lib file not found: $LIB_FILE"; return 1; }
  # shellcheck source=/dev/null
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_763\n  status: pending\n- id: cmd_764\n  status: pending\n'
  seed_report "ashigaru1_report.yaml" $'parent_cmd: cmd_763\nstatus: done\n' 7
  seed_report "ashigaru2_report.yaml" $'parent_cmd: cmd_764\nstatus: done\n' 7

  run detect_ledger_mismatches "$TMP_DIR/reports" "$TMP_DIR/ledger.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" == *"cmd_763|"* ]]
  [[ "$output" == *"cmd_764|"* ]]
}

# ── T-LM-002: report done だが経過時間が閾値未満 → 検知しない(即時誤検知防止) ──

@test "T-LM-002: does not flag mismatch before threshold elapses" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_900\n  status: pending\n'
  seed_report "ashigaru3_report.yaml" $'parent_cmd: cmd_900\nstatus: done\n' 0

  run detect_ledger_mismatches "$TMP_DIR/reports" "$TMP_DIR/ledger.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_900"* ]]
}

# ── T-LM-003: 台帳側が既に done → 検知しない(正常系) ──

@test "T-LM-003: does not flag when ledger already reflects done" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_901\n  status: done\n'
  seed_report "ashigaru4_report.yaml" $'parent_cmd: cmd_901\nstatus: done\n' 7

  run detect_ledger_mismatches "$TMP_DIR/reports" "$TMP_DIR/ledger.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_901"* ]]
}

# ── T-LM-004: report が done でない(in_progress等) → 検知しない ──

@test "T-LM-004: does not flag when report itself is not done" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_902\n  status: in_progress\n'
  seed_report "ashigaru5_report.yaml" $'parent_cmd: cmd_902\nstatus: in_progress\n' 7

  run detect_ledger_mismatches "$TMP_DIR/reports" "$TMP_DIR/ledger.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_902"* ]]
}

# ── T-LM-005: 台帳に該当 cmd が存在しない → 検知しない(誤爆防止) ──

@test "T-LM-005: does not flag when cmd id is absent from ledger" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_903\n  status: pending\n'
  seed_report "ashigaru6_report.yaml" $'parent_cmd: cmd_unknown\nstatus: done\n' 7

  run detect_ledger_mismatches "$TMP_DIR/reports" "$TMP_DIR/ledger.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_903"* ]]
  [[ "$output" != *"cmd_unknown"* ]]
}

# ── T-LM-006: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-LM-006: stall_watchdog.sh sources ledger_mismatch_detect.sh and invokes the check" {
  grep -q "ledger_mismatch_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_ledger_mismatches|detect_ledger_mismatches" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}

# ── cmd_766 第一層 相乗り(subtask_766_layer1_blocked_reason_check):
# status: blocked/blocked_needs_decision なのに blocked_on/blocked_reason が
# 空の「statusが実態を語っていない」ケースの検知。2026-09-06に同日中
# ashigaru4→ashigaru5で2度実測された欠陥の再発防止。

seed_task() {
  local dir="$1" name="$2" content="$3"
  mkdir -p "$dir"
  printf '%s\n' "$content" > "$dir/$name"
}

# ── T-BRG-001: blocked_on/blocked_reason 両方ありは検知されない ──

@test "T-BRG-001: does not flag when both blocked_on and blocked_reason are present" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru4.yaml" $'task:\n  status: blocked\n  blocked_on: "殿の手番待ち"\n  blocked_reason: "swarmが勝手に書き換え禁止のため"\n'

  run detect_blocked_reason_gaps "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru4.yaml"* ]]
}

# ── T-BRG-002: blocked_needs_decisionでblocked_on空 = 検知される ──

@test "T-BRG-002: flags blocked_needs_decision with empty blocked_on" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru5.yaml" $'task:\n  status: blocked_needs_decision\n  blocked_on: ""\n  blocked_reason: "将軍裁可待ち"\n'

  run detect_blocked_reason_gaps "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashigaru5.yaml|blocked_needs_decision"* ]]
}

# ── T-BRG-003: blocked_byありの通常blockedは対象外(依存待ちは正常系) ──

@test "T-BRG-003: does not flag normal blocked_by dependency wait even without blocked_on/reason" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru6.yaml" $'task:\n  status: blocked\n  blocked_by: "subtask_760_prereq"\n'

  run detect_blocked_reason_gaps "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru6.yaml"* ]]
}

# ── T-BRG-004: status: assigned/done等は対象外 ──

@test "T-BRG-004: does not flag status assigned or done" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  status: assigned\n'
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  status: done\n'

  run detect_blocked_reason_gaps "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru1.yaml"* ]]
  [[ "$output" != *"ashigaru2.yaml"* ]]
}

# ── T-BRG-005: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-BRG-005: stall_watchdog.sh invokes detect_blocked_reason_gaps via check_blocked_reason_gaps" {
  grep -qE "check_blocked_reason_gaps|detect_blocked_reason_gaps" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}

# ── cmd_771 fix_c: 孤児cmd(idle足軽+台帳の未完了cmdが誰にも割り当てられて
# いない状態)の検知。maybe_nudge_idle はagent自身のassignedタスク前提で
# 動くため、台帳に残った未完了cmdがどのtask YAMLのparent_cmdにも現れない
# 場合に検知漏れとなる(2026-09-06 殿が2度、swarmより先に気づいた主犯)。

# ── T-ORPHAN-001: 台帳pending/in_progressだがどのtask YAMLのparent_cmdにも
# 現れない → 検知される(未割当) ──

@test "T-ORPHAN-001: flags a pending ledger cmd that appears in no task YAML's parent_cmd" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_910\n  status: in_progress\n'
  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  parent_cmd: cmd_999\n  status: assigned\n'

  run detect_orphan_cmds "$TMP_DIR/ledger.yaml" "$TMP_DIR/tasks" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cmd_910|in_progress"* ]]
}

# ── T-ORPHAN-002: 台帳cmdがいずれかのtask YAMLのparent_cmdとして現れる
# (=割当あり) かつ all_ashigaru_idle=false → 検知されない(正常系) ──

@test "T-ORPHAN-002: does not flag when the cmd is assigned to a task YAML and not all ashigaru are idle" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_911\n  status: in_progress\n'
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  parent_cmd: cmd_911\n  status: assigned\n'

  run detect_orphan_cmds "$TMP_DIR/ledger.yaml" "$TMP_DIR/tasks" "false"
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_911"* ]]
}

# ── T-ORPHAN-003: 割当ありでも全ashigaruがidle(all_ashigaru_idle=true)の
# 場合は誰も手を付けていないとみなし検知される ──

@test "T-ORPHAN-003: flags an assigned cmd when all_ashigaru_idle=true (nobody actually working)" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_912\n  status: pending\n'
  seed_task "$TMP_DIR/tasks" "ashigaru3.yaml" $'task:\n  parent_cmd: cmd_912\n  status: assigned\n'

  run detect_orphan_cmds "$TMP_DIR/ledger.yaml" "$TMP_DIR/tasks" "true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cmd_912|pending"* ]]
}

# ── T-ORPHAN-004: 台帳status=done/superseded等は検知対象外(誤爆防止) ──

@test "T-ORPHAN-004: does not flag ledger cmds with status done or superseded" {
  source "$LIB_FILE"

  seed_ledger $'commands:\n- id: cmd_913\n  status: done\n- id: cmd_914\n  status: superseded\n'

  run detect_orphan_cmds "$TMP_DIR/ledger.yaml" "$TMP_DIR/tasks" "false"
  [ "$status" -eq 0 ]
  [[ "$output" != *"cmd_913"* ]]
  [[ "$output" != *"cmd_914"* ]]
}

# ── T-ORPHAN-005: stall_watchdog.sh がこの check を実際に呼び出している
# (相乗り確認) ──

@test "T-ORPHAN-005: stall_watchdog.sh invokes detect_orphan_cmds via check_orphan_cmds" {
  grep -qE "check_orphan_cmds|detect_orphan_cmds" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}

# ── cmd_778② (型h): report・task YAMLの食い違い検知(名前は関数名の
# 由来である"three_way"のまま残すが、cmd_800恒久修正によりmismatch判定
# 自体はtask面のみの二面照合へ簡素化済み——理由・詳細は
# lib/ledger_mismatch_detect.shのdetect_three_way_mismatch直上コメント参照)。
# 個別の型(a〜g)を列挙するのでなく「一致しているか」という一つの
# 不変条件で見る。本日 ashigaru6 が実際に踏んだ事例
# (report=done / task YAML=assigned・7〜12時間)の再現を含む。
# inbox面(inbox_ok)は出力に参考情報として残るため、そちらの算出自体の
# 単体テストも引き続き用意する(T-3WM-003b以降参照)。

seed_inbox() {
  local content="$1"
  printf '%s\n' "$content" > "$TMP_DIR/inbox_karo.yaml"
}

# ── T-3WM-001: report=done・task=assigned・inbox無音(本日の実例再現) → 検知 ──

@test "T-3WM-001: flags report=done/task=assigned/inbox-silent (ashigaru6 repro)" {
  source "$LIB_FILE"

  seed_report "ashigaru6_report.yaml" $'worker_id: ashigaru6\nparent_cmd: cmd_738\ntimestamp: "2026-09-06T10:49:00"\nstatus: done\n' 7
  seed_task "$TMP_DIR/tasks" "ashigaru6.yaml" $'task:\n  status: assigned\n'
  seed_inbox $'messages:\n- content: dummy\n  from: karo\n  id: msg_1\n  read: true\n  timestamp: "2026-09-06T09:00:00"\n  type: task_assigned\n'

  run detect_three_way_mismatch "$TMP_DIR/reports" "$TMP_DIR/tasks" "$TMP_DIR/inbox_karo.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashigaru6|cmd_738|"* ]]
  [[ "$output" == *"|assigned|0|"* ]]
}

# ── T-3WM-002: task=done かつ inboxにreport以降のfrom:{agent}あり → 検知しない(正常系) ──

@test "T-3WM-002: does not flag when task is done and inbox has a from-agent entry after report" {
  source "$LIB_FILE"

  seed_report "ashigaru2_report.yaml" $'worker_id: ashigaru2\nparent_cmd: cmd_800\ntimestamp: "2026-09-06T10:00:00"\nstatus: done\n' 7
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  status: done\n'
  seed_inbox $'messages:\n- content: 完了報告\n  from: ashigaru2\n  id: msg_2\n  read: true\n  timestamp: "2026-09-06T10:05:00"\n  type: report_received\n'

  run detect_three_way_mismatch "$TMP_DIR/reports" "$TMP_DIR/tasks" "$TMP_DIR/inbox_karo.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru2"* ]]
}

# ── T-3WM-003: task=doneだがinboxにreport以降のfrom:{agent}なし(=inbox_write.sh
# の50件上限で正常な通知エントリが物理的に押し出された状態を模す)
# → ★cmd_800恒久修正後は検知しない(task面が一致していればinbox面の
# 欠落だけでは誤検知させない。cmd_800夜間7件連発の直接原因への対応) ──

@test "T-3WM-003: does not flag when task is done even if no matching inbox entry exists (cmd_800 eviction repro)" {
  source "$LIB_FILE"

  seed_report "ashigaru3_report.yaml" $'worker_id: ashigaru3\nparent_cmd: cmd_801\ntimestamp: "2026-09-06T10:00:00"\nstatus: done\n' 7
  seed_task "$TMP_DIR/tasks" "ashigaru3.yaml" $'task:\n  status: done\n'
  seed_inbox $'messages:\n- content: dummy\n  from: karo\n  id: msg_3\n  read: true\n  timestamp: "2026-09-06T09:00:00"\n  type: task_assigned\n'

  run detect_three_way_mismatch "$TMP_DIR/reports" "$TMP_DIR/tasks" "$TMP_DIR/inbox_karo.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru3"* ]]
}

# ── T-3WM-003b: task=assigned(未完了)のまま・inbox欠落 → ★改修後も検知され
# 続ける(こちらは真の異常であり、inbox面の扱い変更で検知能力を落として
# はならない、が task instructions の acceptance_criteria)。task_ok=0が
# 唯一の判定条件になったことの直接確認。 ──

@test "T-3WM-003b: still flags when task remains assigned (true anomaly, not just inbox eviction)" {
  source "$LIB_FILE"

  seed_report "ashigaru3b_report.yaml" $'worker_id: ashigaru3b\nparent_cmd: cmd_801b\ntimestamp: "2026-09-06T10:00:00"\nstatus: done\n' 7
  seed_task "$TMP_DIR/tasks" "ashigaru3b.yaml" $'task:\n  status: assigned\n'
  seed_inbox $'messages:\n- content: dummy\n  from: karo\n  id: msg_3b\n  read: true\n  timestamp: "2026-09-06T09:00:00"\n  type: task_assigned\n'

  run detect_three_way_mismatch "$TMP_DIR/reports" "$TMP_DIR/tasks" "$TMP_DIR/inbox_karo.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashigaru3b|cmd_801b|"* ]]
  [[ "$output" == *"|assigned|0|"* ]]
}

# ── T-3WM-004: report=done経過時間が閾値未満 → 検知しない(即時誤検知防止) ──

@test "T-3WM-004: does not flag before threshold elapses" {
  source "$LIB_FILE"

  seed_report "ashigaru4_report.yaml" $'worker_id: ashigaru4\nparent_cmd: cmd_802\ntimestamp: "2026-09-06T10:00:00"\nstatus: done\n' 0
  seed_task "$TMP_DIR/tasks" "ashigaru4.yaml" $'task:\n  status: assigned\n'
  seed_inbox $'messages:\n- content: dummy\n  from: karo\n  id: msg_4\n  read: true\n  timestamp: "2026-09-06T09:00:00"\n  type: task_assigned\n'

  run detect_three_way_mismatch "$TMP_DIR/reports" "$TMP_DIR/tasks" "$TMP_DIR/inbox_karo.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru4"* ]]
}

# ── T-3WM-005: reportがdoneでない → 検知しない ──

@test "T-3WM-005: does not flag when report itself is not done" {
  source "$LIB_FILE"

  seed_report "ashigaru5_report.yaml" $'worker_id: ashigaru5\nparent_cmd: cmd_803\ntimestamp: "2026-09-06T10:00:00"\nstatus: in_progress\n' 7
  seed_task "$TMP_DIR/tasks" "ashigaru5.yaml" $'task:\n  status: assigned\n'

  run detect_three_way_mismatch "$TMP_DIR/reports" "$TMP_DIR/tasks" "$TMP_DIR/inbox_karo.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru5"* ]]
}

# ── T-3WM-006: task・inbox両面とも整合 → 両面ともOKなら検知しない(健全系の再確認) ──

@test "T-3WM-006: does not flag when both task and inbox faces are consistent" {
  source "$LIB_FILE"

  seed_report "ashigaru7_report.yaml" $'worker_id: ashigaru7\nparent_cmd: cmd_804\ntimestamp: "2026-09-06T08:00:00"\nstatus: done\n' 7
  seed_task "$TMP_DIR/tasks" "ashigaru7.yaml" $'task:\n  status: cancelled\n'
  seed_inbox $'messages:\n- content: 完了報告\n  from: ashigaru7\n  id: msg_7\n  read: false\n  timestamp: "2026-09-06T08:10:00"\n  type: report_received\n'

  run detect_three_way_mismatch "$TMP_DIR/reports" "$TMP_DIR/tasks" "$TMP_DIR/inbox_karo.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru7"* ]]
}

# ── T-3WM-007: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-3WM-007: stall_watchdog.sh invokes detect_three_way_mismatch via check_three_way_mismatch" {
  grep -qE "check_three_way_mismatch|detect_three_way_mismatch" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}

# ── cmd_778②やり直し: 実データ(queue/reports/ashigaru2_report.yaml等)実測で
# 発覚した「最新エントリ特定」の再発防止。旧実装はエントリ境界を
# report:/report_*:/worker_id:/task_id: というヘッダー行パターンで検出
# していたが、report_to:/report_command: というありふれたフィールド名が
# たまたま "report_" で始まるだけで誤ってヘッダー扱いされ、真に最後の
# エントリのstatus/parent_cmdが範囲外に追い出され空文字になっていた
# (実データ実測: ashigaru2はstatus/parent_cmdとも空文字、ashigaru5も
# 同様に空文字だった)。

@test "T-3WM-008: does not let a 'report_to:' field inside the newest entry be mistaken for an entry header (ashigaru2 repro)" {
  source "$LIB_FILE"

  seed_report "ashigaru_x_report.yaml" $'report_774_legend_fix_complete:\n  task_id: subtask_old\n  parent_cmd: cmd_774\n  status: done\n  timestamp: "2026-09-06T10:00:00"\n\ntask_id: subtask_new_entry\nparent_cmd: cmd_900\nstatus: in_progress\nreport_to: karo\n\nsummary: |\n  newest entry, not done yet\n'

  [ "$(_lmd_report_field "$TMP_DIR/reports/ashigaru_x_report.yaml" "status")" = "in_progress" ]
  [ "$(_lmd_report_field "$TMP_DIR/reports/ashigaru_x_report.yaml" "parent_cmd")" = "cmd_900" ]
}

@test "T-3WM-009: does not let a 'report_command:' field inside the newest entry be mistaken for an entry header (ashigaru5 repro)" {
  source "$LIB_FILE"

  seed_report "ashigaru_y_report.yaml" $'worker_id: ashigaru_y\ntask_id: subtask_old\nparent_cmd: cmd_777\nstatus: done\ntimestamp: "2026-09-05T10:00:00"\n\nreport_command: |\n  bash scripts/inbox_write.sh karo "old report" report_received ashigaru_y\n'

  [ "$(_lmd_report_field "$TMP_DIR/reports/ashigaru_y_report.yaml" "status")" = "done" ]
  [ "$(_lmd_report_field "$TMP_DIR/reports/ashigaru_y_report.yaml" "parent_cmd")" = "cmd_777" ]
}

# ashigaru2の実report yaml(queue/reports/・gitignore対象で本テストからは
# 参照できない)を実測した際の実際の構造を模したフィクスチャ。
# 複数の`report_<name>:`ブロック(旧形式)の後に、列0のフラットな
# エントリ(task_id:/parent_cmd:/status:/report_to:)が複数回追記され、
# 最後のエントリのstatusは厳密な"done"でなく"done_pending_karo_merge_decision"
# である、という本日実際に踏んだ実データの形をそのまま再現する。

@test "T-3WM-010: correctly resolves the latest entry in a mixed nested+flat multi-entry accumulated report (ashigaru2 shape repro)" {
  source "$LIB_FILE"

  seed_report "ashigaru2_report.yaml" $'report_774_legend_fix_complete:\n  task_id: subtask_774\n  parent_cmd: cmd_774\n  status: done\n  timestamp: "2026-09-06T16:50:00+09:00"\n\ntask_id: subtask_e2e010b_first_attempt\nparent_cmd: cmd_766\nstatus: done_pending_karo_merge_decision\nreport_to: karo\n\ntask_id: subtask_e2e010b_fix_test_scenario\nparent_cmd: cmd_766\nstatus: done_pending_karo_merge_decision\nreport_to: karo\n\nsummary: |\n  latest entry, awaiting karo merge decision\n' 7

  [ "$(_lmd_report_field "$TMP_DIR/reports/ashigaru2_report.yaml" "status")" = "done_pending_karo_merge_decision" ]
  [ "$(_lmd_report_field "$TMP_DIR/reports/ashigaru2_report.yaml" "parent_cmd")" = "cmd_766" ]

  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  status: assigned\n'
  run detect_three_way_mismatch "$TMP_DIR/reports" "$TMP_DIR/tasks" "$TMP_DIR/inbox_karo.yaml" 21600
  [ "$status" -eq 0 ]
  # report_status が厳密に "done" ではない(done_pending_karo_merge_decision)ため
  # 本検知の対象外(型どおり)。ashigaru2 という行自体が出ないことを確認する。
  [[ "$output" != *"ashigaru2|"* ]]
}

# ── cmd_778②follow-up: instructions/gunshi.md が必須と定める報告フッター
# "north_star_alignment:\n  status: aligned" の nested status を、entry
# 本体の top-level status と混同しない再発防止(軍師が実データ実行で発見:
# gunshi_report.yaml の top-level status(done) ではなく north_star_alignment
# .status(aligned) を誤取得していた)。旧実装(grep単体+tail -1)は「ファイル内
# 最後に出現した"status:"行」を無差別に採るため、north_star_alignment.status
# がフッターとして最後に来ると、そちらを report_status として誤採用し、
# その結果 `[[ "$report_status" != "done" ]] && continue` により本来
# 検知すべき mismatch を静かに見逃す(偽陰性)危険があった。

@test "T-3WM-011: does not let a north_star_alignment footer's nested status be mistaken for the entry's top-level status (gunshi_report.yaml shape repro)" {
  source "$LIB_FILE"

  seed_report "gunshi_report.yaml" $'worker_id: gunshi\ntask_id: subtask_738_pr156_133_134_recheck\nparent_cmd: cmd_738\ntimestamp: "2026-09-08T01:20:00"\nstatus: done\nresult:\n  tests_status: all_pass\n\nskill_candidate:\n  found: false\n\nnorth_star_alignment:\n  status: aligned\n  reason: "..."\n  risks_to_north_star:\n    - "..."\n' 7

  # 中間抽出値そのものを確認する: report_status/parent_cmd が north_star_alignment
  # 配下ではなく entry 本体(top-level)から取れていること。
  [ "$(_lmd_report_field "$TMP_DIR/reports/gunshi_report.yaml" "status")" = "done" ]
  [ "$(_lmd_report_field "$TMP_DIR/reports/gunshi_report.yaml" "parent_cmd")" = "cmd_738" ]

  # task YAML 側を意図的に未完了のまま(assigned)にして三面食い違いを作る。
  # report_status を正しく"done"と読めていなければ、この mismatch はそもそも
  # 判定対象に入らず(偽陰性で)出力されない。
  seed_task "$TMP_DIR/tasks" "gunshi.yaml" $'task:\n  status: assigned\n'
  run detect_three_way_mismatch "$TMP_DIR/reports" "$TMP_DIR/tasks" "$TMP_DIR/inbox_karo.yaml" 21600
  [ "$status" -eq 0 ]
  [[ "$output" == *"gunshi|cmd_738|"* ]]
}

# ══════════════════════════════════════════════════════════════════════════
# cmd_778 相乗り: RACE-001(同一ファイルへの複数task並行割当)の機械検知
# detect_file_collisions / detect_undeclared_touches_files
# ══════════════════════════════════════════════════════════════════════════

# ── T-FC-001: 2つのactive taskが同一ファイルをtouches_filesに持つ → 衝突検出
#   (本日のgunshi2.yaml並行割当事故の再現) ──
@test "T-FC-001: flags a file listed in touches_files of two active tasks (gunshi2.yaml repro)" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  status: in_progress\n  touches_files:\n    - queue/tasks/gunshi2.yaml\n    - scripts/deadman_switch.sh\n'
  seed_task "$TMP_DIR/tasks" "ashigaru7.yaml" $'task:\n  status: assigned\n  touches_files:\n    - queue/tasks/gunshi2.yaml\n    - config/settings.yaml\n'

  run detect_file_collisions "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" == *"queue/tasks/gunshi2.yaml|"* ]]
  [[ "$output" == *"ashigaru1"* ]]
  [[ "$output" == *"ashigaru7"* ]]
  # 各taskが1件しか触れぬファイルは衝突扱いしない
  [[ "$output" != *"scripts/deadman_switch.sh|"* ]]
  [[ "$output" != *"config/settings.yaml|"* ]]
}

# ── T-FC-002: 別々のファイルに触れる2 task → 衝突なし ──
@test "T-FC-002: does not flag when active tasks touch different files" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  status: in_progress\n  touches_files:\n    - scripts/a.sh\n'
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  status: in_progress\n  touches_files:\n    - scripts/b.sh\n'

  run detect_file_collisions "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-FC-003: 同一ファイルでも片方がdone/blocked(非active) → 衝突なし
#   (RACE=同時編集の問題ゆえactiveのみ対象) ──
@test "T-FC-003: does not flag when one of the two tasks is not active (done/blocked)" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  status: in_progress\n  touches_files:\n    - shared/x.yaml\n'
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  status: done\n  touches_files:\n    - shared/x.yaml\n'
  seed_task "$TMP_DIR/tasks" "ashigaru3.yaml" $'task:\n  status: blocked\n  touches_files:\n    - shared/x.yaml\n'

  run detect_file_collisions "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-FC-004: 3 taskのうち2つだけが同一ファイル共有 → その2つを列挙 ──
@test "T-FC-004: with three active tasks, flags only the file shared by two of them" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  status: assigned\n  touches_files:\n    - queue/dashboard.md\n'
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  status: assigned\n  touches_files:\n    - queue/dashboard.md\n'
  seed_task "$TMP_DIR/tasks" "ashigaru3.yaml" $'task:\n  status: assigned\n  touches_files:\n    - scripts/only_me.sh\n'

  run detect_file_collisions "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" == *"queue/dashboard.md|"* ]]
  [[ "$output" != *"scripts/only_me.sh|"* ]]
}

# ── T-FC-005: stall_watchdog.sh が check_file_collisions を呼ぶ ──
@test "T-FC-005: stall_watchdog.sh invokes detect_file_collisions via check_file_collisions" {
  grep -qE "check_file_collisions" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "detect_file_collisions" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}

# ── T-UTF-001: active 2件以上でtouches_files未宣言のtaskがある → 炙り出す
#   (書き忘れを機械が拾う=将軍の必須要件) ──
@test "T-UTF-001: flags an active task missing touches_files when >=2 tasks are active" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  status: in_progress\n  touches_files:\n    - scripts/a.sh\n'
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  status: assigned\n'

  run detect_undeclared_touches_files "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashigaru2|assigned"* ]]
  [[ "$output" != *"ashigaru1|"* ]]
}

# ── T-UTF-002: active が1件だけなら未宣言でも炙り出さない(衝突不能ゆえ無音) ──
@test "T-UTF-002: does not flag a single active task missing touches_files (no collision possible)" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  status: in_progress\n'
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  status: done\n'

  run detect_undeclared_touches_files "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-UTF-003: active 2件が両方touches_filesを宣言 → 炙り出しなし ──
@test "T-UTF-003: does not flag when all active tasks declare touches_files" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  status: in_progress\n  touches_files:\n    - scripts/a.sh\n'
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  status: assigned\n  touches_files:\n    - scripts/b.sh\n'

  run detect_undeclared_touches_files "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-UTF-004: 非active(done/blocked)のtouches_files未宣言は対象外 ──
@test "T-UTF-004: does not flag non-active tasks missing touches_files" {
  source "$LIB_FILE"

  seed_task "$TMP_DIR/tasks" "ashigaru1.yaml" $'task:\n  status: in_progress\n  touches_files:\n    - scripts/a.sh\n'
  seed_task "$TMP_DIR/tasks" "ashigaru2.yaml" $'task:\n  status: assigned\n  touches_files:\n    - scripts/b.sh\n'
  seed_task "$TMP_DIR/tasks" "ashigaru3.yaml" $'task:\n  status: blocked\n'
  seed_task "$TMP_DIR/tasks" "ashigaru4.yaml" $'task:\n  status: done\n'

  run detect_undeclared_touches_files "$TMP_DIR/tasks"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ashigaru3|"* ]]
  [[ "$output" != *"ashigaru4|"* ]]
}

# ── T-UTF-005: stall_watchdog.sh が check_undeclared_touches_files を呼ぶ ──
@test "T-UTF-005: stall_watchdog.sh invokes detect_undeclared_touches_files via check_undeclared_touches_files" {
  grep -qE "check_undeclared_touches_files" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "detect_undeclared_touches_files" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}
