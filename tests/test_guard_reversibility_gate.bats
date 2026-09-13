#!/usr/bin/env bats
# test_guard_reversibility_gate.bats — guard.sh Hook 9(可逆性ゲート)回帰テスト
# cmd_813 / subtask_813_night_rule_reversibility_gate
#
# 背景: 2026-09-13 02:10、config/settings.yaml が消失した実タスク
# (subtask_pr129_followups_f1_f2_f3・bloom_level=L3・risk_flag=false)。
# 旧来の夜間ルールは「重さ」(bloom_level/risk_flag)で新規着手の可否を
# 判じており、この事故そのものを「軽い」として夜間発注を許していた。
# 本テストは、殿ご裁可により guard.sh へ新設した「可逆性」軸のHook
# (④常駐設定ファイル・②worktree外・③外部不可逆操作・裁可オーバーライド)
# を、実際のインシデント再現(隔離複製・本物のsettings.yamlには一切触れない)
# を含めて検証する。
#
# CI wiring: このファイルは tests/*.bats に置かれており、
# .github/workflows/test.yml の "Run root-level tests (except
# agent_selfwatch)" ステップ(ROOT_TESTS=$(ls tests/*.bats ...))が
# 自動的に拾って実行する(ワークフロー変更不要・orphan testにならない)。

setup_file() {
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export GUARD="$PROJECT_ROOT/scripts/hooks/guard.sh"
    [ -f "$GUARD" ] || return 1
}

setup() {
    export TEST_TMPDIR
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/guard_reversibility_test.XXXXXX")"
    # 隔離複製リポ(本物のconfig/settings.yamlには一切触れない)
    export ISO_REPO="$TEST_TMPDIR/iso_repo"
    mkdir -p "$ISO_REPO"
    git -C "$ISO_REPO" init -q -b main
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# guard.sh へコマンド文字列を渡しexit codeを返す(jq -Rsで安全にJSONエンコード)。
# bats の `run` と組み合わせて使う前提(素で呼ぶとexit 2でテスト自体がabortする)。
guard_rc() {
    local cmd="$1" json
    json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$cmd" | jq -Rs .)}}"
    echo "$json" | bash "$GUARD"
}

# --- (a) 実インシデント再現: サンプル上書き→rm -f (acceptance_criteria①) ---

@test "reversibility gate: cp config/settings.yaml.sample -> config/settings.yaml is blocked" {
    mkdir -p "$ISO_REPO/config"
    echo "custom_value: real_data" > "$ISO_REPO/config/settings.yaml"
    echo "sample_value: template" > "$ISO_REPO/config/settings.yaml.sample"

    run guard_rc "cd $ISO_REPO && cp config/settings.yaml.sample config/settings.yaml"
    [ "$status" -eq 2 ]
}

@test "reversibility gate: rm -f config/settings.yaml is blocked (2026-09-13 02:10 incident reproduction)" {
    mkdir -p "$ISO_REPO/config"
    echo "custom_value: real_data" > "$ISO_REPO/config/settings.yaml"

    run guard_rc "cd $ISO_REPO && rm -f config/settings.yaml"
    [ "$status" -eq 2 ]
}

@test "reversibility gate: full incident sequence (sample overwrite then rm -f) both blocked" {
    mkdir -p "$ISO_REPO/config"
    echo "custom_value: real_data" > "$ISO_REPO/config/settings.yaml"
    echo "sample_value: template" > "$ISO_REPO/config/settings.yaml.sample"

    run guard_rc "cd $ISO_REPO && cp config/settings.yaml.sample config/settings.yaml"
    [ "$status" -eq 2 ]

    run guard_rc "cd $ISO_REPO && rm -f config/settings.yaml"
    [ "$status" -eq 2 ]

    # 実データはブロックにより一度も上書き/削除されず残っている(実出力での確認)
    run cat "$ISO_REPO/config/settings.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"real_data"* ]]
}

@test "reversibility gate: .claude/settings.json deletion is blocked" {
    mkdir -p "$ISO_REPO/.claude"
    echo '{"hooks":{}}' > "$ISO_REPO/.claude/settings.json"

    run guard_rc "cd $ISO_REPO && rm -f .claude/settings.json"
    [ "$status" -eq 2 ]
}

# --- 軍師QC是正の回帰テスト(初版レビューで発見された実バイパス3件) ---

@test "QC fix: rm -rf on the parent directory containing a guarded config file is blocked" {
    mkdir -p "$ISO_REPO/config"
    echo "custom_value: real_data" > "$ISO_REPO/config/settings.yaml"

    run guard_rc "cd $ISO_REPO && rm -rf config/"
    [ "$status" -eq 2 ]
}

@test "QC fix: rm with a glob pattern matching a guarded config file (same directory) is blocked" {
    mkdir -p "$ISO_REPO/config"
    echo "custom_value: real_data" > "$ISO_REPO/config/settings.yaml"

    run guard_rc "cd $ISO_REPO && rm -f config/*.yaml"
    [ "$status" -eq 2 ]
}

@test "QC fix: mv -t DIR (GNU target-directory form) writing outside the worktree is blocked" {
    echo x > "$ISO_REPO/src1.txt"
    echo y > "$ISO_REPO/src2.txt"
    local outside="$TEST_TMPDIR/outside_target_dir"
    mkdir -p "$outside"

    run guard_rc "cd $ISO_REPO && mv -t $outside src1.txt src2.txt"
    [ "$status" -eq 2 ]
}

@test "QC fix regression guard: bare 'rm -rf *' at repo root (pre-existing allowed pattern) is still allowed" {
    # config/settings.yaml が存在してもディレクトリを跨ぐ裸ワイルドカードは
    # 本Hookの対象外(既存test_hooks.shの「相対glob」allowテストと同じ前提)。
    mkdir -p "$ISO_REPO/config"
    echo "custom_value: real_data" > "$ISO_REPO/config/settings.yaml"

    run guard_rc "cd $ISO_REPO && rm -rf *"
    [ "$status" -eq 0 ]
}

# --- 軍師QC是正の回帰テスト(2巡目レビューで発見されたバイパス3件) ---

@test "QC fix round2: rm -rf on a glob matching the guarded directory's own name is blocked" {
    mkdir -p "$ISO_REPO/config"
    echo "custom_value: real_data" > "$ISO_REPO/config/settings.yaml"

    run guard_rc "cd $ISO_REPO && rm -rf con*"
    [ "$status" -eq 2 ]
}

@test "QC fix round2: heredoc prose merely mentioning 'rm -f config/settings.yaml' is NOT blocked" {
    run guard_rc $'cat > /tmp/qc2_test_notes.md <<EOF\n手順: rm -f config/settings.yaml を実行して初期化する\nEOF'
    [ "$status" -eq 0 ]
    rm -f /tmp/qc2_test_notes.md
}

@test "QC fix round2: heredoc prose merely mentioning 'gh pr merge' is NOT blocked" {
    run guard_rc $'cat > /tmp/qc2_test_notes2.md <<EOF\n参考: 承認後は gh pr merge 42 --squash を実行すること\nEOF'
    [ "$status" -eq 0 ]
    rm -f /tmp/qc2_test_notes2.md
}

@test "QC fix round2: a guarded-config-named file in an unrelated external repo is NOT blocked" {
    git -C "$ISO_REPO" remote add origin "https://github.com/example/some-other-app.git"
    mkdir -p "$ISO_REPO/config"
    echo "unrelated_app_config: true" > "$ISO_REPO/config/settings.yaml"

    run guard_rc "cd $ISO_REPO && rm -f config/settings.yaml"
    [ "$status" -eq 0 ]
}

@test "QC fix round2: the guarded-config gate still applies when this repo's own origin remote is set" {
    git -C "$ISO_REPO" remote add origin "https://github.com/halsk/multi-agent-shogun.git"
    mkdir -p "$ISO_REPO/config"
    echo "custom_value: real_data" > "$ISO_REPO/config/settings.yaml"

    run guard_rc "cd $ISO_REPO && rm -f config/settings.yaml"
    [ "$status" -eq 2 ]
}

# --- (b) worktree内の通常作業は従来通り通ること(acceptance_criteria②・過剰ブロック防止) ---

@test "normal work: rm -rf build (in-tree, gitignore-typical) is still allowed" {
    run guard_rc "cd $ISO_REPO && rm -rf build"
    [ "$status" -eq 0 ]
}

@test "normal work: rm -r node_modules (in-tree, gitignore-typical) is still allowed" {
    run guard_rc "cd $ISO_REPO && rm -r node_modules"
    [ "$status" -eq 0 ]
}

@test "normal work: rm -f README.md (tracked in-tree file) is still allowed" {
    run guard_rc "cd $ISO_REPO && rm -f README.md"
    [ "$status" -eq 0 ]
}

@test "normal work: cp src.txt dest.txt within worktree is still allowed" {
    run guard_rc "cd $ISO_REPO && cp src.txt dest.txt"
    [ "$status" -eq 0 ]
}

# --- ②worktree外への書込み(新しい捕捉: 非再帰rmはD002が見落としていた) ---

@test "outside-worktree gate: non-recursive rm targeting a path outside the git toplevel is blocked" {
    local outside="$TEST_TMPDIR/outside_dir"
    mkdir -p "$outside"
    echo x > "$outside/somefile"

    run guard_rc "cd $ISO_REPO && rm -f $outside/somefile"
    [ "$status" -eq 2 ]
}

@test "outside-worktree gate: mv destination outside the git toplevel is blocked" {
    echo x > "$ISO_REPO/localfile.txt"
    local outside="$TEST_TMPDIR/outside_dir2"
    mkdir -p "$outside"

    run guard_rc "cd $ISO_REPO && mv localfile.txt $outside/localfile.txt"
    [ "$status" -eq 2 ]
}

@test "outside-worktree gate: rm within session scratchpad allow-zone is still allowed" {
    local scratch="/private/tmp/claude-999/fake-session-guardtest/scratchpad/tmpdir"
    mkdir -p "$scratch"
    echo x > "$scratch/f.txt"

    run guard_rc "cd $ISO_REPO && rm -f $scratch/f.txt"
    [ "$status" -eq 0 ]
    rm -rf "/private/tmp/claude-999/fake-session-guardtest"
}

# --- ③外部への不可逆操作 ---

@test "irreversible external op: gh pr merge is blocked" {
    run guard_rc "gh pr merge 42 --squash"
    [ "$status" -eq 2 ]
}

@test "irreversible external op: gh pr close is blocked" {
    run guard_rc "gh pr close 42"
    [ "$status" -eq 2 ]
}

@test "irreversible external op: gh issue close is blocked" {
    run guard_rc "gh issue close 7"
    [ "$status" -eq 2 ]
}

@test "irreversible external op: gh repo archive is blocked" {
    run guard_rc "gh repo archive halsk/some-repo"
    [ "$status" -eq 2 ]
}

@test "read-only gh ops (pr view / issue list) are not affected" {
    run guard_rc "gh pr view 42"
    [ "$status" -eq 0 ]
}

# --- ④常駐機構(daemon)設定変更 ---

@test "daemon config: launchctl load is blocked" {
    run guard_rc "launchctl load ~/Library/LaunchAgents/com.example.plist"
    [ "$status" -eq 2 ]
}

@test "daemon config: crontab -e is blocked" {
    run guard_rc "crontab -e"
    [ "$status" -eq 2 ]
}

@test "daemon config: crontab -l (read-only) is still allowed" {
    run guard_rc "crontab -l"
    [ "$status" -eq 0 ]
}

# --- 裁可(門であって禁止でないこと・acceptance_criteria③) ---

@test "override: valid unexpired .guard-authorized lets a guarded-config rm through" {
    mkdir -p "$ISO_REPO/config"
    echo "custom_value: real_data" > "$ISO_REPO/config/settings.yaml"
    cat > "$ISO_REPO/.guard-authorized" <<'EOF'
task_id: cmd_813
expires: 2099-01-01T00:00:00Z
EOF

    run guard_rc "cd $ISO_REPO && rm -f config/settings.yaml"
    [ "$status" -eq 0 ]
}

@test "override: expired .guard-authorized does NOT let a guarded-config rm through" {
    mkdir -p "$ISO_REPO/config"
    echo "custom_value: real_data" > "$ISO_REPO/config/settings.yaml"
    cat > "$ISO_REPO/.guard-authorized" <<'EOF'
task_id: cmd_813
expires: 2020-01-01T00:00:00Z
EOF

    run guard_rc "cd $ISO_REPO && rm -f config/settings.yaml"
    [ "$status" -eq 2 ]
}

@test "override: .guard-authorized missing expires field does NOT authorize" {
    mkdir -p "$ISO_REPO/config"
    echo "custom_value: real_data" > "$ISO_REPO/config/settings.yaml"
    cat > "$ISO_REPO/.guard-authorized" <<'EOF'
task_id: cmd_813
EOF

    run guard_rc "cd $ISO_REPO && rm -f config/settings.yaml"
    [ "$status" -eq 2 ]
}

@test "override: valid .guard-authorized also lets gh pr merge through" {
    cat > "$ISO_REPO/.guard-authorized" <<'EOF'
task_id: cmd_813
expires: 2099-01-01T00:00:00Z
EOF
    run guard_rc "cd $ISO_REPO && gh pr merge 42 --squash"
    [ "$status" -eq 0 ]
}

# --- 通常のgit/ls/cat等が引き続き無関係に通ること(退行防止) ---

@test "sanity: git status is unaffected by Hook 9" {
    run guard_rc "cd $ISO_REPO && git status"
    [ "$status" -eq 0 ]
}
