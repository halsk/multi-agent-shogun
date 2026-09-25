#!/usr/bin/env bats
#
# tests/unit/test_slim_yaml_canonical_reports.bats
#
# 家老起票2026-09-25(subtask_karo_20260925_watchdog_fixes)【二】:
# scripts/slim_yaml.py の slim_reports() は、正典の per-agent report ファイル
# (ashigaru{1-8}_report.yaml・gunshi_report.yaml)を CANONICAL_REPORTS 判定で
# 明示的にスキップしており、これらは各足軽が任務完了のたびに古い報告を
# 積み増していく設計(previous_report_cmdXXX等)のためアーカイブ機構が
# 一切無いまま無制限に肥大していた(実物: ashigaru2_report.yaml=521065B、
# ashigaru7_report.yaml=116413B、ashigaru5_report.yaml=102953B。いずれも
# mgmt_bloat_watchdogの上限100000Bを超過)。
#
# ★家老起票2026-09-25(subtask_karo_20260925_watchdog_fixes_redo1)による
# 是正: 初版(PR#165)は「多重YAMLドキュメント連結は常に末尾が最新」という
# 前提で無条件に`docs[:-1]`を退避していたが、軍師QC・家老の独立検証の両方が
# 実物のqueue/reports/ashigaru2_report.yaml(35ドキュメント)でこの前提が
# ★偽であると確認した——先頭ドキュメント(doc0・cmd_854・timestamp=
# 2026-09-18T18:35)の方が末尾ドキュメント(doc34・cmd_831・自身にtimestamp
# 無し)より明らかに新しい実例が実在する。位置(ファイル内の先頭/末尾)は
# 新旧の信頼できる手がかりではない。
#
# 是正後の判定方式(位置に一切依存しない・scripts/slim_yaml.pyの
# _select_current_entry()参照):
#   1) queue/tasks/{agent}.yaml の現在のtask_idと一致する、ただ1件の
#      ドキュメント(軍師が示唆した方式を最優先の軸とする)。
#   2) ドキュメント内のどこかに現れるtimestampフィールドの再帰的な最大値。
#   3) いずれでも一意に定まらなければ判定不能として扱い、一切退避しない
#      (安全側に倒す)。
#   + 同一ドキュメント内でトップレベルキーが重複している場合(YAMLの
#     safe_loadが黙って後勝ちで前の値を握り潰す)を検知し、該当ファイルは
#     今回のスイープでは一切変更しない。
#
# 実データ調査で判明した肥大パターンは2種類:
#   A) 多重YAMLドキュメント連結(`---`区切り・ashigaru2_report.yamlが実例・
#      35ドキュメント)。
#   B) 単一ドキュメント内で、書いた本人が既に「古い」と自己申告している
#      trailerキー(previous_report_*・old_report_*・_old_report_*。
#      ashigaru5/ashigaru7が実例)。
# ★意図的に対象外: ashigaru4/ashigaru6のような、old/previous等の自己申告
# 無しに report_cmdXXX_* や 無名のcmdXXX_* キーが並ぶだけの形式(単一
# ドキュメント内)は、どれが「最新」かを機械的に断定できず誤ってアーカイブ
# すると軍師QC・家老の履歴参照が壊れるため、本対策では触れない
# (安全側に倒す)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    [ -f "$PROJECT_ROOT/scripts/slim_yaml.py" ] || skip "slim_yaml.py not found"
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHON_BIN="$PROJECT_ROOT/.venv/bin/python3"
    [ -x "$PYTHON_BIN" ] || PYTHON_BIN="python3"
}

build_tmp_project() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/queue"/{inbox,tasks,reports,archive,archive/reports,archive/tasks}
    cp "$PROJECT_ROOT/scripts/slim_yaml.py" "$root/scripts/"
}

run_slim_yaml() {
    local root="$1"
    shift
    "$PYTHON_BIN" "$root/scripts/slim_yaml.py" "$@"
}

# ★GNUのstat -fはBSDと意味が違う(ファイルシステム情報表示・%mを渡しても
# エラーにならず無関係な出力を返す)ため、GNU形式(-c)を先に試し、BSD特有の
# 場合のみ-fへfallbackする(scripts/console_stall_watchdog.sh の
# file_mtime_epoch と同じ作法)。逆順にすると Linux CI で
# "integer expression expected" になる(cmd_karo_20260925実測)。
file_mtime_epoch() {
    stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

# ── T-SYCR-001 (RED対照): 是正前のslim_reports()は正典ashigaru{N}_report.yaml
# をCANONICAL_REPORTS判定で常にスキップし、多重ドキュメント肥大を一切
# 縮小しない(旧slim_reports単体の挙動をそのまま呼んで実証) ──

@test "T-SYCR-001 (RED対照・是正前): slim_reports()単体は正典report(多重ドキュメント肥大)を素通りする" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_canon_XXXXXX")"
    build_tmp_project "$root"

    cat > "$root/queue/reports/ashigaru2_report.yaml" <<'YAML'
report_old_1:
  status: done
  summary: "古い報告その1"
---
report_old_2:
  status: done
  summary: "古い報告その2"
---
task_id: subtask_latest
status: done
summary: "最新の報告"
YAML

    before_size=$(wc -c < "$root/queue/reports/ashigaru2_report.yaml")

    run "$PYTHON_BIN" -c "
import sys
sys.path.insert(0, '$root/scripts')
import slim_yaml
import os
os.environ['SHOGUN_QUEUE_DIR'] = '$root/queue'
print(slim_yaml.slim_reports(dry_run=False))
"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    after_size=$(wc -c < "$root/queue/reports/ashigaru2_report.yaml")
    [ "$before_size" -eq "$after_size" ]

    rm -rf "$root"
}

# ── T-SYCR-002 (是正後・位置非依存の確認): 多重YAMLドキュメント連結で、
# ★先頭ドキュメントの方がtimestampが新しい(末尾より古い)という、実データと
# 同型の並びを与え、位置でなくtimestampで正しく現在値を選ぶことを確認する ──

@test "T-SYCR-002 (是正後): 先頭ドキュメントの方が新しい並びでも、位置でなくtimestampで正しく現在値を選ぶ" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_canon_XXXXXX")"
    build_tmp_project "$root"

    # ★実データ(ashigaru2_report.yaml)と同型: 先頭(doc0)が新しく、末尾(doc1)が
    # 古い。旧ロジック(末尾=最新前提)なら doc0 を誤って退避してしまう並び。
    cat > "$root/queue/reports/ashigaru2_report.yaml" <<'YAML'
report_new:
  task_id: subtask_new
  status: done
  timestamp: "2026-09-18T18:35:00+09:00"
  summary: "先頭にある方が実は新しい報告"
---
task_id: subtask_old
status: done
summary: "末尾にあるが実は古い報告(timestamp無し)"
YAML

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    # 先頭(新しい方)が残っていること
    run grep -c "subtask_new" "$root/queue/reports/ashigaru2_report.yaml"
    [ "$output" = "1" ]

    # ★末尾ドキュメントはtimestampが無く新旧を判定できないため、安全側に倒し
    # 退避されず残っている(誤って古いと決めつけない)
    run grep -c "subtask_old" "$root/queue/reports/ashigaru2_report.yaml"
    [ "$output" = "1" ]

    rm -rf "$root"
}

# ── T-SYCR-002b (RED→GREEN対照・実データ由来): 実物のqueue/reports/
# ashigaru2_report.yamlから抽出した実際のフィールド値(doc0の
# report_854_policies_test_hardening entry、doc34のflatな主内容
# subtask_831_keychain_sync_plan_prep entry)を使い、
#   RED: 旧ロジック(「末尾=最新」前提・docs[:-1]を無条件退避)を
#        このテスト内に再現し、実際に doc0(cmd_854・より新しい実データ)を
#        誤って退避してしまうことを実証する。
#   GREEN: 是正後のslim_yaml.slim_canonical_reports()は、taskの前提が偽で
#          あることを踏まえ、cmd_854(timestampあり)を正しく現在値として
#          残し、cmd_831(timestampなし・新旧判定不能)も安全側に倒して
#          退避しないため、★どちらの実データも失われない。
# ★正直な注記: 実物のdoc34は本来この2entryに加え、より後の時刻
# (2026-09-18T20:06:20)を持つ別の追記(report_858b_*)も内包する多重構造の
# ドキュメントだった(karoの一次調査はdoc34の最初のキーのみを見て「doc34は
# cmd_831で古い」と判断していたが、実際にはさらに複雑だった)。本テストは
# その入れ子の追記を含めず、karoが実際に比較した2つのflatな実データ
# (cmd_854 と cmd_831)のみを使い、「位置(先頭/末尾)によるcmd_854の誤退避」
# という指摘された欠陥そのものに焦点を絞って再現する。

@test "T-SYCR-002b (RED→GREEN・実データ由来): 旧位置ベースロジックはcmd_854を誤って退避するが、是正後は退避しない" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_canon_XXXXXX")"
    build_tmp_project "$root"

    # 実物 queue/reports/ashigaru2_report.yaml の doc0(先頭)から抽出した
    # report_854_policies_test_hardening entry(timestamp=2026-09-18T18:35、
    # cmd_854・実際にはこちらが新しい)を doc0 に、doc34(末尾)の flat な
    # 主内容 subtask_831_keychain_sync_plan_prep entry(timestamp無し・
    # cmd_831・実際にはこちらが古い)を doc1(末尾)に、実データのまま配置。
    cat > "$root/queue/reports/ashigaru2_report.yaml" <<'YAML'
report_854_policies_test_hardening:
  task_id: subtask_854_policies_test_hardening
  parent_cmd: cmd_854
  agent: ashigaru2
  status: done
  timestamp: '2026-09-18T18:35:00+09:00'
  project: geonicdb-console
  pr_url: https://github.com/geolonia/geonicdb-console/pull/190
  summary: '軍師QC(qc_cmd854_pr190_policies_tests)所見F1への是正。PR#190は
    既にCI全緑・CR承認済み・家老が独立検証の上merge済み。'
---
task_id: subtask_831_keychain_sync_plan_prep
parent_cmd: cmd_831
status: done
report_to: gunshi
summary: 'cmd_831(Keychain同期でop呼出を減らす)の実行前計画書を作成した。opは
  一度も呼んでいない・Keychainへの書き込みもしていない。'
重要な訂正: 'cmd_831起票の前提だった将軍の見積もりを実際に検証した結果、
  実態と食い違っていた。'
YAML

    before_size=$(wc -c < "$root/queue/reports/ashigaru2_report.yaml")

    # RED対照: 是正前の旧ロジック(位置=末尾を無条件に「最新」とみなす)を
    # このテスト内で再現し、実際にcmd_854(先頭・より新しい)を退避して
    # しまうことを示す(旧slim_canonical_reports実装そのものの挙動)。
    run "$PYTHON_BIN" -c "
import yaml
docs = [d for d in yaml.safe_load_all(open('$root/queue/reports/ashigaru2_report.yaml')) if d is not None]
archived_docs = docs[:-1]
current = docs[-1]
archived_ids = [list(d.keys())[0] if isinstance(d, dict) else None for d in archived_docs]
print('archived:', archived_ids)
print('kept_task_id:', current.get('task_id') if isinstance(current, dict) else None)
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"archived: ['report_854_policies_test_hardening']"* ]]
    [[ "$output" == *"kept_task_id: subtask_831_keychain_sync_plan_prep"* ]]

    # GREEN: 是正後の実装は位置でなくtimestampの有無/大小で判定するため、
    # cmd_854(timestampあり・実際に新しい)を正しく残し、cmd_831
    # (timestampなし・新旧判定不能)も安全側に倒して退避しない
    # ——どちらの実データも失われない。
    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    run grep -c "report_854_policies_test_hardening" "$root/queue/reports/ashigaru2_report.yaml"
    [ "$output" = "1" ]

    run grep -c "subtask_831_keychain_sync_plan_prep" "$root/queue/reports/ashigaru2_report.yaml"
    [ "$output" = "1" ]

    # 新旧いずれも判定に使える根拠(timestampの有無)が変わらない限り、
    # 今回のスイープでは退避が起きないため archive/reports/ は空のまま。
    run sh -c "ls '$root/queue/archive/reports/' 2>/dev/null | wc -l"
    [ "$(echo "$output" | tr -d ' ')" = "0" ]

    after_size=$(wc -c < "$root/queue/reports/ashigaru2_report.yaml")
    [ "$before_size" -eq "$after_size" ]

    rm -rf "$root"
}

# ── T-SYCR-003 (是正後): previous_report_* trailerキーはarchiveへ退避し、
# report本体は残す ──

@test "T-SYCR-003 (是正後): previous_report_*キーは退避され、reportキーは残る" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_canon_XXXXXX")"
    build_tmp_project "$root"

    cat > "$root/queue/reports/ashigaru5_report.yaml" <<'YAML'
report:
  task_id: subtask_new
  status: done
  summary: "最新"
previous_report_cmd100:
  status: done
  summary: "古い報告100"
previous_report_cmd99:
  status: done
  summary: "古い報告99"
YAML

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    run grep -c "previous_report_cmd100\|previous_report_cmd99" "$root/queue/reports/ashigaru5_report.yaml"
    [ "$output" = "0" ]

    run grep -c "subtask_new" "$root/queue/reports/ashigaru5_report.yaml"
    [ "$output" = "1" ]

    run sh -c "grep -rl 'previous_report_cmd100' '$root/queue/archive/reports/'"
    [ "$status" -eq 0 ]

    rm -rf "$root"
}

# ── T-SYCR-004: old_report_*/_old_report_* も同様に退避対象 ──

@test "T-SYCR-004 (是正後): old_report_*・_old_report_*キーも退避対象になる" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_canon_XXXXXX")"
    build_tmp_project "$root"

    cat > "$root/queue/reports/ashigaru7_report.yaml" <<'YAML'
report:
  task_id: subtask_new7
  status: done
old_report_foo:
  status: done
_old_report_bar:
  status: done
YAML

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    run grep -c "old_report_foo\|_old_report_bar" "$root/queue/reports/ashigaru7_report.yaml"
    [ "$output" = "0" ]

    run grep -c "subtask_new7" "$root/queue/reports/ashigaru7_report.yaml"
    [ "$output" = "1" ]

    rm -rf "$root"
}

# ── T-SYCR-005: 曖昧な形式(old/previous自己申告の無いreport_cmdXXX_*)は
# 誤爆を避けるため触らない(安全側に倒す設計の確認) ──

@test "T-SYCR-005: old/previous自己申告の無い形式(ashigaru4/6型)は変更されない" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_canon_XXXXXX")"
    build_tmp_project "$root"

    cat > "$root/queue/reports/ashigaru4_report.yaml" <<'YAML'
report_subtask_a:
  status: done
report_subtask_b:
  status: done
report:
  status: done
YAML

    before_size=$(wc -c < "$root/queue/reports/ashigaru4_report.yaml")

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    after_size=$(wc -c < "$root/queue/reports/ashigaru4_report.yaml")
    [ "$before_size" -eq "$after_size" ]

    rm -rf "$root"
}

# ── T-SYCR-006: 変更が無い正典report(previous_report_*も多重docも無い)は
# 一切書き換えない(mtime保持含む・不要な差分を作らない) ──

@test "T-SYCR-006: 肥大の無い正典reportはmtimeも含め一切変更しない" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_canon_XXXXXX")"
    build_tmp_project "$root"

    cat > "$root/queue/reports/ashigaru1_report.yaml" <<'YAML'
report:
  task_id: subtask_x
  status: done
YAML
    touch -t 202501010000 "$root/queue/reports/ashigaru1_report.yaml"
    before_mtime=$(file_mtime_epoch "$root/queue/reports/ashigaru1_report.yaml")

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    after_mtime=$(file_mtime_epoch "$root/queue/reports/ashigaru1_report.yaml")
    [ "$before_mtime" -eq "$after_mtime" ]

    rm -rf "$root"
}

# ── T-SYCR-007: 退避を行ったファイルはmtimeを元のまま保持する
# (console_stall_watchdog.sh等、mtimeを最終活動時刻の代理指標として読む
# 消費者への副作用防止) ──

@test "T-SYCR-007: 退避処理そのものが正典reportのmtimeを進めない(消費者側の誤検知防止)" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_canon_XXXXXX")"
    build_tmp_project "$root"

    cat > "$root/queue/reports/ashigaru5_report.yaml" <<'YAML'
report:
  task_id: subtask_new
  status: done
previous_report_cmd100:
  status: done
YAML
    touch -t 202501010000 "$root/queue/reports/ashigaru5_report.yaml"
    before_mtime=$(file_mtime_epoch "$root/queue/reports/ashigaru5_report.yaml")

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    # 中身は変わっているはず(退避が実際に起きたことの確認)
    run grep -c "previous_report_cmd100" "$root/queue/reports/ashigaru5_report.yaml"
    [ "$output" = "0" ]

    after_mtime=$(file_mtime_epoch "$root/queue/reports/ashigaru5_report.yaml")
    [ "$before_mtime" -eq "$after_mtime" ]

    rm -rf "$root"
}

# ── T-SYCR-008 (B2是正): 同一ドキュメント内でトップレベルキーが重複する
# 場合、YAMLのsafe_loadは黙って後勝ちで前の値を握り潰す。是正後は
# これを検知し、当該ファイルは今回のスイープでは一切変更せず警告を出す ──

@test "T-SYCR-008 (是正後・B2): トップレベルキー重複を検知したら当該ファイルには触れず警告を出す" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_canon_XXXXXX")"
    build_tmp_project "$root"

    # doc0: トップレベルキー "report_dup" が2回定義されている
    # (safe_loadなら後者の値だけが残り前者は黙って握り潰される・危険な状態)。
    # doc1: 正常なドキュメントで、本来ならold-prefixキーが退避できる形。
    cat > "$root/queue/reports/ashigaru6_report.yaml" <<'YAML'
report_dup:
  status: done
  summary: "1つ目(本来はこちらが握り潰される)"
report_dup:
  status: done
  summary: "2つ目(safe_loadだとこちらだけが残る)"
---
report:
  task_id: subtask_new6
  status: done
previous_report_cmd1:
  status: done
YAML

    before_size=$(wc -c < "$root/queue/reports/ashigaru6_report.yaml")

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    # 重複キーを名指しした警告が出ていること
    [[ "$output" == *"report_dup"* ]]
    [[ "$output" == *"重複"* ]]

    # ★安全側に倒し、ファイル全体を今回のスイープでは一切変更しない
    # (doc1側にarchive可能なprevious_report_cmd1があっても、doc0の
    # 重複キー問題が解消されない限りこのファイルには触れない)。
    after_size=$(wc -c < "$root/queue/reports/ashigaru6_report.yaml")
    [ "$before_size" -eq "$after_size" ]

    run sh -c "ls '$root/queue/archive/reports/' 2>/dev/null | wc -l"
    [ "$(echo "$output" | tr -d ' ')" = "0" ]

    rm -rf "$root"
}

# ── T-SYCR-009 (task_id突き合わせの優先度確認): queue/tasks/{agent}.yaml の
# 現在のtask_idと一致するドキュメントがあれば、timestampの大小に関わらず
# それを現在値として優先する(軍師が示唆した方式を最優先の軸とする) ──

@test "T-SYCR-009: queue/tasks/{agent}.yamlのtask_id一致が、timestampより優先される" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_canon_XXXXXX")"
    build_tmp_project "$root"

    # doc0: timestampは古いが、現在のtask_idと一致する
    # doc1: timestampは新しいが、現在のtask_idとは無関係の別entry
    cat > "$root/queue/reports/ashigaru3_report.yaml" <<'YAML'
report_current:
  task_id: subtask_current_work
  status: done
  timestamp: "2026-01-01T00:00:00+09:00"
  summary: "現在進行中のtaskに対応する報告(timestampは古い表記のまま)"
---
report_unrelated_newer:
  task_id: subtask_unrelated
  status: done
  timestamp: "2026-09-01T00:00:00+09:00"
  summary: "timestampだけ見れば新しいが、現在のtaskとは無関係"
YAML

    cat > "$root/queue/tasks/ashigaru3.yaml" <<'YAML'
task:
  task_id: subtask_current_work
  status: in_progress
YAML

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    # task_id一致を優先し、timestampが古いdoc0(subtask_current_work)が残る
    run grep -c "subtask_current_work" "$root/queue/reports/ashigaru3_report.yaml"
    [ "$output" = "1" ]

    # timestampだけ見れば新しいdoc1(subtask_unrelated)は退避される
    run grep -c "subtask_unrelated" "$root/queue/reports/ashigaru3_report.yaml"
    [ "$output" = "0" ]

    run sh -c "grep -rl 'subtask_unrelated' '$root/queue/archive/reports/'"
    [ "$status" -eq 0 ]

    rm -rf "$root"
}
