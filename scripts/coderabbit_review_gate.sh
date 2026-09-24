#!/usr/bin/env bash
# scripts/coderabbit_review_gate.sh — merge前にCodeRabbitのレビューが
# 実際に行われたかを判定する(cmd_871、H1是正・cmd_871a2で許可リスト方式へ)。
#
# state=success だけでは「Review skipped」「Review rate limited」
# 「Reviews paused」は元より、"Review in progress"・"Review queued"等の
# ★未完了状態(state=pending)や、その他の未知の文言も合格に見えてしまう
# (scripts/lib/coderabbit_gate.sh 参照)。本スクリプトはPRのhead commitに
# 対するCodeRabbitのcommit status を取得し、state と description の
# 両方を見て正しく判定する。
#
# 家老の「コード変更 PR のマージ必須条件」(instructions/karo.md)から
# merge前に手動実行する想定。新規の常駐監視は追加しない。
#
# Usage:
#   bash scripts/coderabbit_review_gate.sh <owner/repo> <pr_number>
#
# 出力: "REVIEWED" (exit 0) または "UNREVIEWED: <reason>" (exit 1)
# CodeRabbitのcommit statusが見つからない場合は "UNREVIEWED: no coderabbit status found" (exit 1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/coderabbit_gate.sh"

REPO="${1:?Usage: coderabbit_review_gate.sh <owner/repo> <pr_number>}"
PR_NUMBER="${2:?Usage: coderabbit_review_gate.sh <owner/repo> <pr_number>}"

HEAD_SHA=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid --jq '.headRefOid')

STATUS_LINE=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/status" --jq \
    '[.statuses[] | select(.context | test("coderabbit"; "i"))][0] | if . then "\(.state)\t\(.description // "")" else empty end')

if [[ -z "$STATUS_LINE" ]]; then
    echo "UNREVIEWED: no coderabbit status found"
    exit 1
fi

IFS=$'\t' read -r STATE DESCRIPTION <<< "$STATUS_LINE"

coderabbit_gate_check "$STATE" "$DESCRIPTION"
