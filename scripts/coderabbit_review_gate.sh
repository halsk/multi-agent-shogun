#!/usr/bin/env bash
# scripts/coderabbit_review_gate.sh — merge前にCodeRabbitのレビューが
# 実際に行われたかを判定する(cmd_871)。
#
# state=success だけでは「Review skipped」「Review rate limited」
# 「Reviews paused」も合格に見えてしまう(scripts/lib/coderabbit_gate.sh
# 参照)。本スクリプトはPRのhead commitに対するCodeRabbitのcommit status
# を取得し、description まで見て正しく判定する。
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

DESCRIPTION=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/status" --jq \
    '[.statuses[] | select(.context | test("coderabbit"; "i"))][0].description // empty')

if [[ -z "$DESCRIPTION" ]]; then
    echo "UNREVIEWED: no coderabbit status found"
    exit 1
fi

coderabbit_gate_check "$DESCRIPTION"
