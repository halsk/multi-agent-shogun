#!/usr/bin/env bash
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
