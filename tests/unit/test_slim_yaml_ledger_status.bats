#!/usr/bin/env bats
#
# tests/unit/test_slim_yaml_ledger_status.bats
#
# cmd_777(上流D区分決着)⑥ slim硬化の実測確認で発見した回帰テスト。
# instructions/common/task_flow.md の Archive Rule は「done/cancelled/paused
# はterminalでarchive対象」と定めているが、slim_yaml.py の
# slim_shugun_to_karo() は 'done'/'cancelled' しかterminal扱いしておらず、
# 'paused' が未archiveのまま台帳(queue/shogun_to_karo.yaml)に残り続けて
# いた。加えて、正本が禁じる non-canonical status(superseded/hold/shelved等)
# が実データに現に存在するにもかかわらず、slim_yaml.py には見える化の
# 手立てが無かった。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    [ -f "$PROJECT_ROOT/scripts/slim_yaml.py" ] || skip "slim_yaml.py not found"
    command -v python3 &>/dev/null || skip "python3 not available"
}

build_tmp_project() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/queue"/{inbox,tasks,reports,archive,archive/reports,archive/tasks}
    cp "$PROJECT_ROOT/scripts/slim_yaml.py" "$root/scripts/"
}

run_slim_yaml() {
    local root="$1"
    shift
    python3 "$root/scripts/slim_yaml.py" "$@"
}

@test "T-LSTAT-001: statusがpausedの台帳エントリはterminalとしてarchiveされる(task_flow.md Archive Rule)" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_ledger_XXXXXX")"
    build_tmp_project "$root"

    cat > "$root/queue/shogun_to_karo.yaml" <<'YAML'
commands:
  - id: cmd_1
    status: paused
  - id: cmd_2
    status: pending
YAML

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]

    run grep -c "cmd_1" "$root/queue/shogun_to_karo.yaml"
    [ "$output" = "0" ]

    run grep -c "cmd_2" "$root/queue/shogun_to_karo.yaml"
    [ "$output" = "1" ]

    rm -rf "$root"
}

@test "T-LSTAT-002: non-canonical status(superseded等)は台帳に残るがINVENTORY警告に出る" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_ledger_XXXXXX")"
    build_tmp_project "$root"

    cat > "$root/queue/shogun_to_karo.yaml" <<'YAML'
commands:
  - id: cmd_1
    status: superseded
  - id: cmd_2
    status: pending
YAML

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]
    [[ "$output" == *"INVENTORY"* ]]
    [[ "$output" == *"cmd_1:superseded"* ]]

    # 自動で書き換えない — 家老の判断事項なので黙って正規化しない
    run grep -c "cmd_1" "$root/queue/shogun_to_karo.yaml"
    [ "$output" = "1" ]

    rm -rf "$root"
}

@test "T-LSTAT-003: canonical statusのみなら INVENTORY警告は出ない" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_ledger_XXXXXX")"
    build_tmp_project "$root"

    cat > "$root/queue/shogun_to_karo.yaml" <<'YAML'
commands:
  - id: cmd_1
    status: pending
  - id: cmd_2
    status: in_progress
YAML

    run run_slim_yaml "$root" karo
    [ "$status" -eq 0 ]
    [[ "$output" != *"INVENTORY"* ]]

    rm -rf "$root"
}

@test "T-LSTAT-004: --dry-run では paused も書き換えず件数のみ報告する" {
    local root
    root="$(mktemp -d "/tmp/e2e_slim_ledger_XXXXXX")"
    build_tmp_project "$root"

    cat > "$root/queue/shogun_to_karo.yaml" <<'YAML'
commands:
  - id: cmd_1
    status: paused
YAML

    run run_slim_yaml "$root" karo --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] would archive 1 commands"* ]]

    run grep -c "cmd_1" "$root/queue/shogun_to_karo.yaml"
    [ "$output" = "1" ]

    rm -rf "$root"
}
