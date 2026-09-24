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
# 実データ調査で判明した実際の肥大パターンは2種類:
#   A) 多重YAMLドキュメント連結(`---`区切りで単純追記された結果・
#      ashigaru2_report.yamlが実例・35ドキュメント)。ドキュメントは
#      常にファイル末尾へ追記されるため、最後のドキュメント以外は
#      すべて確実に古い(構造上安全な判定)。
#   B) 単一ドキュメント内で、書いた本人が既に「古い」と自己申告している
#      trailerキー(previous_report_*・old_report_*・_old_report_*。
#      ashigaru5/ashigaru7が実例)。
# ★意図的に対象外: ashigaru4/ashigaru6のような、old/previous等の自己申告
# 無しに report_cmdXXX_* や 無名のcmdXXX_* キーが並ぶだけの形式は、
# どれが「最新」かを機械的に断定できず誤ってアーカイブすると軍師QC・家老の
# 履歴参照が壊れるため、本対策では触れない(安全側に倒す)。

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

# ── T-SYCR-002 (是正後): 多重ドキュメント肥大 → 最終ドキュメントのみ残し、
# 残りをqueue/archive/reports/へ退避 ──

@test "T-SYCR-002 (是正後): 多重YAMLドキュメント連結の正典reportは最後の1件のみ残しそれ以前をarchiveへ退避する" {
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

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    run grep -c "report_old_1\|report_old_2" "$root/queue/reports/ashigaru2_report.yaml"
    [ "$output" = "0" ]

    run grep -c "subtask_latest" "$root/queue/reports/ashigaru2_report.yaml"
    [ "$output" = "1" ]

    # 完全削除ではなく退避であること(Iron Law/forbidden: 完全削除禁止)
    run sh -c "grep -rl 'report_old_1' '$root/queue/archive/reports/'"
    [ "$status" -eq 0 ]

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
    before_mtime=$(stat -f '%m' "$root/queue/reports/ashigaru1_report.yaml" 2>/dev/null || stat -c '%Y' "$root/queue/reports/ashigaru1_report.yaml")

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    after_mtime=$(stat -f '%m' "$root/queue/reports/ashigaru1_report.yaml" 2>/dev/null || stat -c '%Y' "$root/queue/reports/ashigaru1_report.yaml")
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
    before_mtime=$(stat -f '%m' "$root/queue/reports/ashigaru5_report.yaml" 2>/dev/null || stat -c '%Y' "$root/queue/reports/ashigaru5_report.yaml")

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    # 中身は変わっているはず(退避が実際に起きたことの確認)
    run grep -c "previous_report_cmd100" "$root/queue/reports/ashigaru5_report.yaml"
    [ "$output" = "0" ]

    after_mtime=$(stat -f '%m' "$root/queue/reports/ashigaru5_report.yaml" 2>/dev/null || stat -c '%Y' "$root/queue/reports/ashigaru5_report.yaml")
    [ "$before_mtime" -eq "$after_mtime" ]

    rm -rf "$root"
}
