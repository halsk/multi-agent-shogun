#!/usr/bin/env bats
#
# tests/unit/test_yaml_scalar.bats
#
# cmd_942派生: lib/yaml_scalar.sh の task_scalar() 単体テスト。
# scripts/deadman_switch.sh から移植した共通helper(PR#199でQC PASS済みの
# 抽出ロジック)が、移植後も同じ振る舞いを保っていることを確かめる。
# 各呼び出し元(stall_watchdog/inbox_watcher/console_stall_watchdog/
# start_task/deadman_switch)での統合的な確認は各scriptの既存testが担う。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB="${PROJECT_ROOT}/lib/yaml_scalar.sh"
  export TMP_DIR
  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/yaml_scalar.XXXXXX")"
  export F="$TMP_DIR/task.yaml"
}

teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

_scalar() {
  bash -c "source '$LIB' && task_scalar '$1' '$F'"
}

@test "T-YS-001: 素のstatus行は値のみ返る" {
  printf 'task:\n  task_id: subtask_x\n  status: assigned\n' > "$F"
  run _scalar status
  [ "$output" = "assigned" ]
}

@test "T-YS-002: inline comment(空白2つ+#)は切り捨てられる" {
  printf 'task:\n  status: assigned  # 家老が割当\n' > "$F"
  run _scalar status
  [ "$output" = "assigned" ]
}

@test "T-YS-003: 空白1つ+#・クォート付き値・末尾TAB/CRの揺れでも素の値になる" {
  printf 'task:\n  status: done # 完了\n' > "$F"
  run _scalar status
  [ "$output" = "done" ]
  printf 'task:\n  status: "blocked"  # 理由\n' > "$F"
  run _scalar status
  [ "$output" = "blocked" ]
  printf 'task:\n  status: in_progress\t\r\n' > "$F"
  run _scalar status
  [ "$output" = "in_progress" ]
}

@test "T-YS-004: コメント内にstatus:の語があっても行頭錨で本物の値を読む" {
  printf 'task:\n  status: assigned  # 旧status: done から戻した\n' > "$F"
  run _scalar status
  [ "$output" = "assigned" ]
}

@test "T-YS-005: 鍵はstatus以外(task_id)も第一引数で指定できる" {
  printf 'task:\n  task_id: subtask_real  # 旧task_id: subtask_fake\n  status: assigned\n' > "$F"
  run _scalar task_id
  [ "$output" = "subtask_real" ]
}

@test "T-YS-006: 値が空でコメントだけの行は空文字(コメント残骸を値にしない)" {
  printf 'task:\n  status:  # TODO\n' > "$F"
  run _scalar status
  [ "$output" = "" ]
}

@test "T-YS-007: 空白を伴わぬ#はコメントでない(クォート内の#を壊さない)" {
  printf 'task:\n  task_id: "issue#12"\n' > "$F"
  run _scalar task_id
  [ "$output" = "issue#12" ]
}

@test "T-YS-008: 写しが残っていない—5つの呼び出し元が全てlib/yaml_scalar.shをsourceし、独自のstatus抽出パイプラインを持たない" {
  for s in scripts/deadman_switch.sh scripts/stall_watchdog.sh scripts/inbox_watcher.sh scripts/console_stall_watchdog.sh scripts/start_task.sh; do
    run grep -c 'lib/yaml_scalar.sh' "$PROJECT_ROOT/$s"
    [ "$output" -ge 1 ]
    # 旧来の写し: grep で status: を拾って sed '.*status:' で切る形
    run bash -c "grep -E \"status:.*\\| *sed\" '$PROJECT_ROOT/$s' | grep -v '^ *#'"
    [ "$status" -ne 0 ]
  done
  # task_scalar() の定義は lib に1つだけ
  run bash -c "grep -l '^task_scalar()' '$PROJECT_ROOT'/scripts/*.sh"
  [ "$status" -ne 0 ]
}
