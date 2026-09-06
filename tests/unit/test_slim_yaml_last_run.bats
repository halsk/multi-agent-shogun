#!/usr/bin/env bats
#
# tests/unit/test_slim_yaml_last_run.bats
#
# cmd_766 第三層(掃除機自身の監視)の前提: slim_yaml.py が karo フルスイープ実行時に
# queue/metrics/slim_yaml_last_run.json へ archived_count と対象別 before/after
# サイズを機械可読に出力することを確認する。
#
# last-run.json 自体はここで検証し、それを読んで発火するヒステリシス判定は
# tests/unit/test_mgmt_bloat_watchdog.bats(layer3)で別途検証する。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    [ -f "$PROJECT_ROOT/scripts/slim_yaml.py" ] || skip "slim_yaml.py not found"
    command -v python3 &>/dev/null || skip "python3 not available"
    # slim_yaml.pyはPyYAML必須。proj_copyには.venvが無いため素のpython3を
    # 使うと(特にmacOS系のシステムpython3は)ModuleNotFoundErrorで落ちる。
    # slim_yaml.sh自身と同じ作法(実PROJECT_ROOTの.venv優先)にする。
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

metrics_file() {
    echo "$1/queue/metrics/slim_yaml_last_run.json"
}

set_mtime_hours_ago() {
    # touch -A はBSD/GNUで引数書式・対応可否が異なる(GNU touchには-A自体が
    # 無い・CI macOSはGNU coreutilsをPATH先頭に置くため touch -A が丸ごと失敗する)。
    # python3(本ファイルのsetup()で必須化済み)経由でmtimeを直接設定し、
    # シェル非依存にする。
    local file="$1" hours="$2"
    python3 -c "
import os, time
t = time.time() - ${hours} * 3600
os.utime('${file}', (t, t))
"
}

json_get() {
    # json_get <file> <python-expr-on-d>
    python3 -c "import json,sys; d=json.load(open('$1')); print($2)"
}

@test "T-LR-001: karo フルスイープで last-run.json が生成される" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_lastrun_XXXXXX")"
    build_tmp_project "$root"

    printf 'commands: []\n' > "$root/queue/shogun_to_karo.yaml"

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]
    [ -f "$(metrics_file "$root")" ]

    rm -rf "$root"
}

@test "T-LR-002: archived_count が実際の回収件数と一致する(台帳2件+タスク1件+report1件+inbox1件)" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_lastrun_XXXXXX")"
    build_tmp_project "$root"

    # 台帳: done 2件, pending 1件 → 2件archive
    cat > "$root/queue/shogun_to_karo.yaml" <<'YAML'
commands:
  - id: cmd_1
    status: done
  - id: cmd_2
    status: done
  - id: cmd_3
    status: pending
YAML

    # tasks: 非canonicalなdoneファイル1件 → archiveされる
    printf 'task:\n  status: done\n' > "$root/queue/tasks/subtask_x.yaml"

    # reports: 非canonicalな古い report で parent_cmd が非活性(cmd_3以外) → archiveされる
    printf 'parent_cmd: cmd_done_elsewhere\nstatus: done\n' > "$root/queue/reports/subtask_x_report.yaml"
    set_mtime_hours_ago "$root/queue/reports/subtask_x_report.yaml" 48

    # inbox: read:true 1件 → archiveされる
    cat > "$root/queue/inbox/ashigaru9.yaml" <<'YAML'
messages:
  - content: done msg
    read: true
  - content: pending msg
    read: false
YAML

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    local mf
    mf="$(metrics_file "$root")"
    [ -f "$mf" ]

    local total
    total="$(json_get "$mf" "d['archived_count']")"
    [ "$total" = "5" ]

    local ledger_archived tasks_archived reports_archived inbox_archived
    ledger_archived="$(json_get "$mf" "d['targets']['ledger']['archived']")"
    tasks_archived="$(json_get "$mf" "d['targets']['tasks']['archived']")"
    reports_archived="$(json_get "$mf" "d['targets']['reports']['archived']")"
    inbox_archived="$(json_get "$mf" "d['targets']['inbox']['archived']")"

    [ "$ledger_archived" = "2" ]
    [ "$tasks_archived" = "1" ]
    [ "$reports_archived" = "1" ]
    [ "$inbox_archived" = "1" ]

    rm -rf "$root"
}

@test "T-LR-003: 何も archive するものが無ければ archived_count=0 で before==after" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_lastrun_XXXXXX")"
    build_tmp_project "$root"

    printf 'commands:\n  - id: cmd_1\n    status: pending\n' > "$root/queue/shogun_to_karo.yaml"

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    local mf
    mf="$(metrics_file "$root")"
    local total
    total="$(json_get "$mf" "d['archived_count']")"
    [ "$total" = "0" ]

    local before after
    before="$(json_get "$mf" "d['targets']['ledger']['before_bytes']")"
    after="$(json_get "$mf" "d['targets']['ledger']['after_bytes']")"
    [ "$before" = "$after" ]

    rm -rf "$root"
}

@test "T-LR-004: --dry-run では last-run.json を書かない(実回収でないため)" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_lastrun_XXXXXX")"
    build_tmp_project "$root"

    cat > "$root/queue/shogun_to_karo.yaml" <<'YAML'
commands:
  - id: cmd_1
    status: done
YAML

    run run_slim_yaml "$root" karo --dry-run
    [ "$status" -eq 0 ]
    [ ! -f "$(metrics_file "$root")" ]

    rm -rf "$root"
}

@test "T-LR-005: timestamp フィールドが空でない" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_lastrun_XXXXXX")"
    build_tmp_project "$root"
    printf 'commands: []\n' > "$root/queue/shogun_to_karo.yaml"

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    local mf ts
    mf="$(metrics_file "$root")"
    ts="$(json_get "$mf" "d['timestamp']")"
    [ -n "$ts" ]

    rm -rf "$root"
}
