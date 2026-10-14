#!/usr/bin/env bats
# test_snapshot.bats — scripts/snapshot.sh / snapshot_init.sh / guard.sh P2連携の回帰試験
# 軍師設計P1/P2。控えは独立ローカルgit。本物の台帳・控え置き場には一切触れない(全て隔離tmp)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    T="$(mktemp -d "$BATS_TMPDIR/snap.XXXXXX")"
    export SNAPSHOT_SRC="$T/src" SNAPSHOT_DEST="$T/dest" SNAPSHOT_LOG="$T/err.log"
    mkdir -p "$SNAPSHOT_SRC/queue/tasks" "$SNAPSHOT_SRC/queue/inbox" "$SNAPSHOT_SRC/config"
    printf -- '- id: cmd_1\n  status: done\n' > "$SNAPSHOT_SRC/queue/shogun_to_karo.yaml"
    printf '# dash\n' > "$SNAPSHOT_SRC/dashboard.md"
    printf 'a: 1\n' > "$SNAPSHOT_SRC/config/settings.yaml"
    printf 'task: {id: t1}\n' > "$SNAPSHOT_SRC/queue/tasks/ashigaru1.yaml"
    printf 'messages: []\n' > "$SNAPSHOT_SRC/queue/inbox/ashigaru1.yaml"
    SNAP="$PROJECT_ROOT/scripts/snapshot.sh"
    INIT="$PROJECT_ROOT/scripts/snapshot_init.sh"
    bash "$INIT" "$SNAPSHOT_DEST" >/dev/null
}

teardown() { rm -rf "$T"; }

ncommits() { git -C "$SNAPSHOT_DEST" rev-list --count HEAD; }

@test "init: remote無し・pre-pushは必ず失敗・READMEに厳禁明記" {
    [ -z "$(git -C "$SNAPSHOT_DEST" remote)" ]
    run bash "$SNAPSHOT_DEST/.git/hooks/pre-push"
    [ "$status" -eq 1 ]
    grep -q "push厳禁" "$SNAPSHOT_DEST/README.md"
}

@test "init: 本物のpre-pushがgit pushを実際に拒否する(remoteを足した場合の二重の止め)" {
    git init -q --bare "$T/bare.git"
    git -C "$SNAPSHOT_DEST" remote add x "$T/bare.git"
    run git -C "$SNAPSHOT_DEST" push x HEAD:refs/heads/main
    [ "$status" -ne 0 ]
    [ -z "$(git -C "$T/bare.git" for-each-ref)" ]
}

@test "snapshot: 実行前は台帳が控えに無く、実行後は内容一致で存在しcommitが増える" {
    [ ! -e "$SNAPSHOT_DEST/queue/shogun_to_karo.yaml" ]
    before=$(ncommits)
    run bash "$SNAP"
    [ "$status" -eq 0 ]
    cmp "$SNAPSHOT_SRC/queue/shogun_to_karo.yaml" "$SNAPSHOT_DEST/queue/shogun_to_karo.yaml"
    cmp "$SNAPSHOT_SRC/dashboard.md" "$SNAPSHOT_DEST/dashboard.md"
    cmp "$SNAPSHOT_SRC/config/settings.yaml" "$SNAPSHOT_DEST/config/settings.yaml"
    cmp "$SNAPSHOT_SRC/queue/tasks/ashigaru1.yaml" "$SNAPSHOT_DEST/queue/tasks/ashigaru1.yaml"
    cmp "$SNAPSHOT_SRC/queue/inbox/ashigaru1.yaml" "$SNAPSHOT_DEST/queue/inbox/ashigaru1.yaml"
    [ "$(ncommits)" -eq $((before + 1)) ]
}

@test "snapshot: 差分が無ければcommitしない・変更すれば1件増える" {
    bash "$SNAP"
    n=$(ncommits)
    bash "$SNAP"
    [ "$(ncommits)" -eq "$n" ]
    [ ! -s "$SNAPSHOT_LOG" ]   # 空commitを試みて失敗した痕跡も無い
    printf -- '- id: cmd_2\n' >> "$SNAPSHOT_SRC/queue/shogun_to_karo.yaml"
    bash "$SNAP"
    [ "$(ncommits)" -eq $((n + 1)) ]
    git -C "$SNAPSHOT_DEST" show HEAD:queue/shogun_to_karo.yaml | grep -q cmd_2
}

@test "snapshot: 0バイトの台帳は[BROKEN]付きでcommitされ、直前の健全な版も履歴に残る" {
    bash "$SNAP"
    : > "$SNAPSHOT_SRC/queue/shogun_to_karo.yaml"
    bash "$SNAP"
    git -C "$SNAPSHOT_DEST" log -1 --format=%s | grep -q '^\[BROKEN\]'
    git -C "$SNAPSHOT_DEST" log -1 --format=%s | grep -q shogun_to_karo.yaml
    # 健全な版は一つ前のcommitに残る
    git -C "$SNAPSHOT_DEST" show HEAD~1:queue/shogun_to_karo.yaml | grep -q cmd_1
}

@test "snapshot: 構文の壊れたYAMLも[BROKEN]・健全なら付かない" {
    bash "$SNAP"
    git -C "$SNAPSHOT_DEST" log -1 --format=%s | grep -qv BROKEN
    printf 'a: [unclosed\n' > "$SNAPSHOT_SRC/config/settings.yaml"
    bash "$SNAP"
    git -C "$SNAPSHOT_DEST" log -1 --format=%s | grep -q '^\[BROKEN\]'
}

@test "snapshot: PyYAMLが使えない環境でも0バイトは[BROKEN]・エラーログは空(縮退判定)" {
    export SNAPSHOT_PYTHON=/usr/bin/false
    bash "$SNAP"
    git -C "$SNAPSHOT_DEST" log -1 --format=%s | grep -qv BROKEN
    : > "$SNAPSHOT_SRC/queue/shogun_to_karo.yaml"
    bash "$SNAP"
    git -C "$SNAPSHOT_DEST" log -1 --format=%s | grep -q '^\[BROKEN\]'
    [ ! -s "$SNAPSHOT_LOG" ]
}

@test "snapshot: DESTがgit repoでなくても異常終了せずエラーログへ記録する" {
    export SNAPSHOT_DEST="$T/nonexistent"
    run bash "$SNAP"
    [ "$status" -eq 0 ]
    grep -q "not a git repo" "$SNAPSHOT_LOG"
}

@test "snapshot: DESTにremoteが付いていたら中止する(公開漏洩防止)" {
    git init -q --bare "$T/bare.git"
    git -C "$SNAPSHOT_DEST" remote add x "$T/bare.git"
    n=$(ncommits)
    run bash "$SNAP"
    [ "$status" -eq 0 ]
    [ "$(ncommits)" -eq "$n" ]
    grep -q "remote" "$SNAPSHOT_LOG"
}

@test "snapshot: 並行実行してもcommitが壊れず最終状態が一致する" {
    for i in 1 2 3 4 5; do bash "$SNAP" & done
    wait
    git -C "$SNAPSHOT_DEST" fsck --no-progress >/dev/null 2>&1
    [ -z "$(git -C "$SNAPSHOT_DEST" status --porcelain)" ]
    cmp "$SNAPSHOT_SRC/queue/shogun_to_karo.yaml" "$SNAPSHOT_DEST/queue/shogun_to_karo.yaml"
}

# --- P2: guard.sh連携 ---------------------------------------------------

run_guard() {  # $1=JSON
    printf '%s' "$1" | bash "$PROJECT_ROOT/scripts/hooks/guard.sh"
}

@test "guard: Edit(台帳のfile_path)で控えが取られる(ツール実行は許可=exit 0)" {
    run run_guard "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$SNAPSHOT_SRC/queue/shogun_to_karo.yaml\"}}"
    [ "$status" -eq 0 ]
    [ -e "$SNAPSHOT_DEST/queue/shogun_to_karo.yaml" ]
}

@test "guard: Bashコマンド文字列に台帳ファイル名があれば控えが取られる" {
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"grep -c id queue/shogun_to_karo.yaml"}}'
    [ "$status" -eq 0 ]
    [ -e "$SNAPSHOT_DEST/queue/shogun_to_karo.yaml" ]
}

@test "guard RED対照: 無関係なEdit/Bashでは控えを取らない" {
    run run_guard "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$SNAPSHOT_SRC/README.md\"}}"
    [ "$status" -eq 0 ]
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
    [ "$status" -eq 0 ]
    [ ! -e "$SNAPSHOT_DEST/queue/shogun_to_karo.yaml" ]
}

@test "guard: snapshot.shが失敗(DEST不正)してもツール実行は止めない" {
    export SNAPSHOT_DEST="$T/nonexistent"
    run run_guard "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$SNAPSHOT_SRC/dashboard.md\"}}"
    [ "$status" -eq 0 ]
    run run_guard '{"tool_name":"Bash","tool_input":{"command":"cat dashboard.md"}}'
    [ "$status" -eq 0 ]
}

@test "plist: 10分間隔でsnapshot.shを呼ぶ・構文が正しい" {
    P="$PROJECT_ROOT/scripts/com.swarm.ledger-snapshot.plist"
    python3 -c "import plistlib,sys;d=plistlib.load(open(sys.argv[1],'rb'));assert d['StartInterval']==600;assert d['ProgramArguments'][-1].endswith('scripts/snapshot.sh')" "$P"
}
