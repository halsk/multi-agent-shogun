#!/usr/bin/env bats
# tests/unit/test_coderabbit_gate.bats — cmd_871 / H1・H2是正(subtask_cmd871a2)
#
# 【H1是正】mergeゲート判定を除外リスト方式から許可リスト方式へ改めた。
# state=success かつ description が明示的にレビュー完了・承認を意味する
# 既知の文言(allow-list)に一致する場合★のみREVIEWEDとし、それ以外は
# すべてUNREVIEWEDとする(state=success以外は無条件でUNREVIEWED)。
#
# 【H2是正】RED対照は、テスト内で自作した仮想の旧実装に対してではなく、
# ★本物の旧実装(subtask_cmd871a・PR#164・commit 0ff2a98時点の
# scripts/lib/coderabbit_gate.sh)に対して行う。LEGACY_SRC(下記)は
# `git show 0ff2a98:scripts/lib/coderabbit_gate.sh` の出力をそのまま
# 貼り付けた★実物のコードのバイト単位コピーであり、テストのために新たに
# 書き起こしたものではない(git show の出力とdiffなしで一致することを
# 是正時に確認済み)。別ファイルに切り出さずテスト内に埋め込んでいるのは、
# tests/fixtures/ が .gitignore で *.yaml 以外を除外しており、かつCIの
# actions/checkout がデフォルトでshallow clone(fetch-depth省略時は1)の
# ため、commit SHA を実行時に `git show` で引く方式はCI環境でのhistory
# 到達性に依存してしまい脆いためである(関数名の衝突を避けるため、
# 埋め込んだ旧実装はサブシェルで実行する)。
#
# description の文言は、以下のいずれかの実測データに基づく(推測・仮想の
# 文言は使わない):
#   (a) queue/reports/cmd870_coderabbit_measurement.md — cmd_870の実測
#       ("Review completed"・"Review rate limited"・"Review skipped: ..."・
#       "Reviews paused"/"Review paused"・"Review in progress" の存在を記録)
#   (b) 本is是正時に gh api graphql / REST で geolonia org の実PR
#       (計 500件超・org:geolonia is:pr の open/closed/dependabot 由来)を
#       直接再取得して確認した、実際のCodeRabbit commit statusのdescription。
#       確認例(state・description・PR):
#         success | Review completed              | geonicdb#3211
#         success | Review approved                | japanese-addresses-v2#34
#         success | Approve command performed: Comments resolved. Approval completed
#                                                   | geonicdb-console#154
#         success | Review skipped: draft pull request        | sales-ai-context#26
#         success | Review skipped: automatic reviews are disabled
#                                                   | infradoctor-application#38
#         success | Review skipped: reviews are disabled for this base branch
#                                                   | minmap-frontend#621
#         success | Review skipped                 | people-flow-visualizer-dev#897
#         success | Review rate limited             | geonicdb-console#198
#         success | Review paused                   | citizen-report-demo#64
#         success | Reviews paused — CodeRabbit will not run on this PR
#                                                   | tokyo-road-manager-video-manager#5
#         pending | Review in progress              | geonicdb-models#31
#         pending | Review queued                   | geolonia-operations#298
#
# 【申し送り】"Review failed"・"Pull request is closed" は
# subtask_cmd871a2のtask context(軍師QC所見)で未知文言の例として
# 挙げられていたが、上記の実測(500件超のPR走査)では★一度も観測できな
# かった。実際にCodeRabbitが出しうる文言かは未確認である。ゆえに
# 「実測文言の固定表」には含めず、代わりに『測定データセットに存在しない
# 任意の未知文言』として別枠のテストケースで扱う(=許可リストのdefault-deny
# が、観測済みか否かに関わらず未知文言を等しく拒否することを示す)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/scripts/lib/coderabbit_gate.sh"
}

# ★★ commit 0ff2a98(subtask_cmd871a・PR#164)時点の
# scripts/lib/coderabbit_gate.sh を `git show 0ff2a98:scripts/lib/coderabbit_gate.sh`
# でそのまま取得し、一字一句貼り付けたもの(除外リスト方式・state引数なし)。
# テストのために書き起こした再現実装ではない。
LEGACY_SRC='#!/usr/bin/env bash
# scripts/lib/coderabbit_gate.sh — CodeRabbit commit status の未レビュー検知
#
# 背景(cmd_871): CodeRabbitのcommit statusは、レビューせぬ場合も
# state=success を返す。実測(30日分)で以下がいずれも state=success として
# 記録されていた:
#   - Review completed 3,021件 (正常)
#   - Review rate limited 42件
#   - Review skipped: ... 359件
#   - Reviews paused 4件
# 「検査の不在が、検査の合格として現れる」構造そのもの。state だけを見る
# merge前チェックは、この3種を「レビュー合格」と誤判定してしまう。
#
# 対策: state に加えて description 文字列を見て、以下のいずれかを含む
# 場合は state の値に関わらず「未レビュー」と判定する。

# coderabbit_gate_check <description>
# stdout: "REVIEWED" または "UNREVIEWED: <reason>"
# 戻り値: 0 = レビュー済(mergeしてよい) / 1 = 未レビュー(mergeするな)
#
# ★state は引数に取らない。実測どおり、この3種は state=success で
# 返ってくるため、state を見る意味がない(description だけが判定材料)。
coderabbit_gate_check() {
    local description="${1:-}"

    if [[ "$description" == *"Review skipped"* ]]; then
        echo "UNREVIEWED: Review skipped"
        return 1
    fi
    if [[ "$description" == *"Review rate limited"* ]]; then
        echo "UNREVIEWED: Review rate limited"
        return 1
    fi
    if [[ "$description" == *"Reviews paused"* || "$description" == *"Review paused"* ]]; then
        echo "UNREVIEWED: Reviews paused"
        return 1
    fi

    echo "REVIEWED"
    return 0
}
'

# 上記LEGACY_SRC(本物の旧実装)をサブシェルで実行する。現在source済みの
# 新実装(coderabbit_gate_check)と関数名が衝突するため、別プロセスで
# 分離する。
run_legacy() {
    bash -c 'source /dev/stdin; coderabbit_gate_check "$1"' _ "$1" <<< "$LEGACY_SRC"
}

# ─── RED対照: 本物の旧実装(除外リスト方式)は実測文言の多くを誤判定する ───
# 除外リストの3パターン(skipped/rate limited/paused)以外はすべて
# REVIEWEDに倒れてしまう欠陥を、本物のコードに対して実証する。

@test "RED(legacy/real): 'Review in progress' (state=pending) is misjudged REVIEWED" {
    run run_legacy "Review in progress"
    [ "$status" -eq 0 ]
    [ "$output" = "REVIEWED" ]
}

@test "RED(legacy/real): 'Review queued' (state=pending) is misjudged REVIEWED" {
    run run_legacy "Review queued"
    [ "$status" -eq 0 ]
    [ "$output" = "REVIEWED" ]
}

@test "RED(legacy/real): an unrecognized/unknown description is misjudged REVIEWED (no state arg exists at all)" {
    run run_legacy "some future CodeRabbit wording never seen before"
    [ "$status" -eq 0 ]
    [ "$output" = "REVIEWED" ]
}

@test "RED(legacy/real): still correctly flags 'Review skipped' (exclude-list happened to cover it)" {
    run run_legacy "Review skipped: draft pull request"
    [ "$status" -eq 1 ]
}

# ─── GREEN: 是正後(許可リスト方式・state必須)は実測文言の全種を正しく判定 ───

# 明示的にレビュー完了・承認を意味する既知の文言 → REVIEWED
@test "GREEN: state=success + 'Review completed' -> REVIEWED" {
    run coderabbit_gate_check "success" "Review completed"
    [ "$status" -eq 0 ]
    [ "$output" = "REVIEWED" ]
}

@test "GREEN: state=success + 'Review approved' -> REVIEWED" {
    run coderabbit_gate_check "success" "Review approved"
    [ "$status" -eq 0 ]
    [ "$output" = "REVIEWED" ]
}

@test "GREEN: state=success + 'Approve command performed: ...' -> REVIEWED" {
    run coderabbit_gate_check "success" "Approve command performed: Comments resolved. Approval completed"
    [ "$status" -eq 0 ]
    [ "$output" = "REVIEWED" ]
}

# state=success だが許可リストに無い(=未完了・未知) → UNREVIEWED
@test "GREEN: state=success + 'Review skipped: draft pull request' -> UNREVIEWED" {
    run coderabbit_gate_check "success" "Review skipped: draft pull request"
    [ "$status" -eq 1 ]
    [[ "$output" == UNREVIEWED:* ]]
}

@test "GREEN: state=success + 'Review skipped: automatic reviews are disabled' -> UNREVIEWED" {
    run coderabbit_gate_check "success" "Review skipped: automatic reviews are disabled"
    [ "$status" -eq 1 ]
    [[ "$output" == UNREVIEWED:* ]]
}

@test "GREEN: state=success + 'Review skipped: reviews are disabled for this base branch' -> UNREVIEWED" {
    run coderabbit_gate_check "success" "Review skipped: reviews are disabled for this base branch"
    [ "$status" -eq 1 ]
    [[ "$output" == UNREVIEWED:* ]]
}

@test "GREEN: state=success + bare 'Review skipped' -> UNREVIEWED" {
    run coderabbit_gate_check "success" "Review skipped"
    [ "$status" -eq 1 ]
    [[ "$output" == UNREVIEWED:* ]]
}

@test "GREEN: state=success + 'Review rate limited' -> UNREVIEWED" {
    run coderabbit_gate_check "success" "Review rate limited"
    [ "$status" -eq 1 ]
    [[ "$output" == UNREVIEWED:* ]]
}

@test "GREEN: state=success + 'Review paused' -> UNREVIEWED" {
    run coderabbit_gate_check "success" "Review paused"
    [ "$status" -eq 1 ]
    [[ "$output" == UNREVIEWED:* ]]
}

@test "GREEN: state=success + 'Reviews paused — CodeRabbit will not run on this PR' -> UNREVIEWED" {
    run coderabbit_gate_check "success" "Reviews paused — CodeRabbit will not run on this PR"
    [ "$status" -eq 1 ]
    [[ "$output" == UNREVIEWED:* ]]
}

# state=pending(未完了そのもの) → stateだけで無条件UNREVIEWED
@test "GREEN: state=pending + 'Review in progress' -> UNREVIEWED (state check alone rejects it)" {
    run coderabbit_gate_check "pending" "Review in progress"
    [ "$status" -eq 1 ]
    [[ "$output" == "UNREVIEWED: state=pending" ]]
}

@test "GREEN: state=pending + 'Review queued' -> UNREVIEWED (state check alone rejects it)" {
    run coderabbit_gate_check "pending" "Review queued"
    [ "$status" -eq 1 ]
    [[ "$output" == "UNREVIEWED: state=pending" ]]
}

# 未知の文言(測定データセットに存在しないもの)→ default-denyで拒否。
# 「Review failed」「Pull request is closed」はtask contextで挙げられた
# 例だが本is是正時の実測(500件超)では観測できなかった。観測済みか否かに
# 関わらず許可リストのdefault-denyが働くことを、別枠として示す。
@test "GREEN: state=success + 'Review failed' (unverified/unknown wording) -> UNREVIEWED" {
    run coderabbit_gate_check "success" "Review failed"
    [ "$status" -eq 1 ]
    [[ "$output" == UNREVIEWED:* ]]
}

@test "GREEN: state=success + 'Pull request is closed' (unverified/unknown wording) -> UNREVIEWED" {
    run coderabbit_gate_check "success" "Pull request is closed"
    [ "$status" -eq 1 ]
    [[ "$output" == UNREVIEWED:* ]]
}

@test "GREEN: state=success + a never-before-seen wording -> UNREVIEWED (default-deny)" {
    run coderabbit_gate_check "success" "some future CodeRabbit wording never seen before"
    [ "$status" -eq 1 ]
    [[ "$output" == UNREVIEWED:* ]]
}

# state自体が空・failure・error等 → 無条件でUNREVIEWED
@test "GREEN: empty state -> UNREVIEWED" {
    run coderabbit_gate_check "" "Review completed"
    [ "$status" -eq 1 ]
    [[ "$output" == "UNREVIEWED: state=<empty>" ]]
}

@test "GREEN: state=failure -> UNREVIEWED even with allow-listed description text" {
    run coderabbit_gate_check "failure" "Review completed"
    [ "$status" -eq 1 ]
    [[ "$output" == "UNREVIEWED: state=failure" ]]
}

@test "GREEN: empty description with state=success -> UNREVIEWED (no allow-list match)" {
    run coderabbit_gate_check "success" ""
    [ "$status" -eq 1 ]
    [[ "$output" == UNREVIEWED:* ]]
}
