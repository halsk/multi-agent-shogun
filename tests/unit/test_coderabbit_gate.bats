#!/usr/bin/env bats
# tests/unit/test_coderabbit_gate.bats — cmd_871
#
# CodeRabbitのcommit statusは、レビューせぬ場合も state=success を返す
# (実測: Review rate limited / Review skipped: ... / Reviews paused の
# いずれも state=success)。state だけを見る merge前チェックはこの3種を
# 「レビュー合格」と誤判定してしまう。
#
# 本テストは二段構えで、それを「実装をなぞるだけ」にせず実証する:
#   1. legacy_state_only_check() — 是正前の実装を模した「state だけ見る」
#      判定を、テスト内に独立して再現する(production コードは一切
#      importしない)。3種のdescriptionに対し、stateがsuccessである限り
#      "PASS"(誤判定)を返すことをRED対照として示す。
#   2. coderabbit_gate_check() — scripts/lib/coderabbit_gate.sh の実装を
#      source し、同じ3種のdescriptionに対し正しく "UNREVIEWED" を
#      返すことを示す(GREEN)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/scripts/lib/coderabbit_gate.sh"
}

# 是正前の実装を模した baseline(state のみで判定・description は見ない)。
# CodeRabbitのcommit statusは未レビュー時も state=success を返すため、
# この実装は常に "PASS" を返してしまう。
legacy_state_only_check() {
    local state="$1"
    if [[ "$state" == "success" ]]; then
        echo "PASS"
        return 0
    fi
    echo "FAIL"
    return 1
}

# ─── RED対照: 是正前ロジック(state のみ)は3種いずれも誤判定する ───

@test "RED: legacy state-only check misjudges 'Review skipped' as PASS" {
    run legacy_state_only_check "success"
    [ "$status" -eq 0 ]
    [ "$output" = "PASS" ]
}

@test "RED: legacy state-only check misjudges 'Review rate limited' as PASS" {
    run legacy_state_only_check "success"
    [ "$status" -eq 0 ]
    [ "$output" = "PASS" ]
}

@test "RED: legacy state-only check misjudges 'Reviews paused' as PASS" {
    run legacy_state_only_check "success"
    [ "$status" -eq 0 ]
    [ "$output" = "PASS" ]
}

# ─── GREEN: 是正後ロジック(description も見る)は正しく未レビューと判定 ───

@test "GREEN: coderabbit_gate_check detects 'Review skipped: ...' as unreviewed" {
    run coderabbit_gate_check "Review skipped: Files not eligible for review."
    [ "$status" -eq 1 ]
    [[ "$output" == "UNREVIEWED: Review skipped" ]]
}

@test "GREEN: coderabbit_gate_check detects 'Review rate limited' as unreviewed" {
    run coderabbit_gate_check "Review rate limited due to Adaptive Fair Usage."
    [ "$status" -eq 1 ]
    [[ "$output" == "UNREVIEWED: Review rate limited" ]]
}

@test "GREEN: coderabbit_gate_check detects 'Reviews paused' as unreviewed" {
    run coderabbit_gate_check "Reviews paused for this pull request."
    [ "$status" -eq 1 ]
    [[ "$output" == "UNREVIEWED: Reviews paused" ]]
}

@test "GREEN: coderabbit_gate_check detects 'Review paused' (singular) as unreviewed" {
    run coderabbit_gate_check "Review paused by user request."
    [ "$status" -eq 1 ]
    [[ "$output" == "UNREVIEWED: Reviews paused" ]]
}

# ─── 正常系: 実際にレビューが完了した場合は REVIEWED を返す ───

@test "coderabbit_gate_check returns REVIEWED for a completed review" {
    run coderabbit_gate_check "Review completed: 3 suggestions posted."
    [ "$status" -eq 0 ]
    [ "$output" = "REVIEWED" ]
}

@test "coderabbit_gate_check returns REVIEWED for an empty description with no red-flag text" {
    run coderabbit_gate_check ""
    [ "$status" -eq 0 ]
    [ "$output" = "REVIEWED" ]
}
