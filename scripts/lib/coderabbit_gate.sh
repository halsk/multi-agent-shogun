#!/usr/bin/env bash
# scripts/lib/coderabbit_gate.sh — CodeRabbit commit status の未レビュー検知
#
# 背景(cmd_871、H1是正・cmd_871a2): 旧実装(除外リスト方式)は
# "Review skipped"/"Review rate limited"/"Reviews paused" の3文言だけを
# 未レビューとみなし、それ以外はすべて description の値に関わらず
# REVIEWED(合格)を返していた。state も引数に取っていなかった。
#
# 実測(cmd_870・および本is是正時に geolonia org の実PRへ gh api graphqlで
# 再確認)で、以下のように「未完了・未知の文言」が state=pending や
# state=success の両方で現れることが分かった:
#   - state=pending: "Review in progress" / "Review queued"
#   - state=success だが未完了: "Review skipped"(各種)・
#     "Review rate limited"・"Review paused"・"Reviews paused — ..."
# 除外リスト方式では、この上記いずれにも一致しない★未知の文言が来た場合
# (例: "Review failed"・"Pull request is closed" のような、CodeRabbit
# ドキュメント上は存在しうるが本diffの実測データセットには現れなかった
# 文言も含む)、無条件でREVIEWEDに倒れる。「検査の不在が検査の合格として
# 現れる」構造を、除外リストのまま残していた。
#
# 対策(許可リスト方式へ転換): state=success であり、かつ description が
# 「明示的にレビュー完了・承認を意味する既知の文言」に一致する場合★のみ
# REVIEWED とする。それ以外(state=success 以外・空・pending系・未知の
# 文言・failure/error系)はすべてUNREVIEWEDとする。

# coderabbit_gate_check <state> <description>
# stdout: "REVIEWED" または "UNREVIEWED: <reason>"
# 戻り値: 0 = レビュー済(mergeしてよい) / 1 = 未レビュー(mergeするな)
#
# ★state を必須の第1引数とする(旧実装にはこの引数自体が無かった)。
# state=success 以外は、description の中身を見るまでもなく無条件で
# UNREVIEWED とする。
coderabbit_gate_check() {
    local state="${1:-}"
    local description="${2:-}"

    if [[ "$state" != "success" ]]; then
        echo "UNREVIEWED: state=${state:-<empty>}"
        return 1
    fi

    # ★許可リスト: state=success かつ以下のいずれかに一致する場合のみ
    # REVIEWED。実測(geolonia org 実PR)で確認した「レビュー完了・承認」を
    # 意味する文言のみを列挙する。それ以外は description が何であれ
    # UNREVIEWED に倒す(default-deny)。
    case "$description" in
        "Review completed")
            echo "REVIEWED"
            return 0
            ;;
        "Review approved")
            echo "REVIEWED"
            return 0
            ;;
        "Approve command performed:"*)
            echo "REVIEWED"
            return 0
            ;;
    esac

    echo "UNREVIEWED: description not in allow-list: ${description:-<empty>}"
    return 1
}
