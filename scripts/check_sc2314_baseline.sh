#!/usr/bin/env bash
# tests/配下の.batsに含まれるSC2314(裸の`!`は最終行でなければ失敗を伝播しない)を
# 無条件検知する。1件でも見つかれば失敗する。
#
# 沿革: cmd_834時点では既存41箇所をtests/.shellcheck_sc2314_baseline.txtへ
# ファイル別の許容件数(ratchet baseline)として記録し、超過分のみ検知していた。
# ashigaru4/5によるtests配下41箇所の修正が完了したため(cmd_834後追い)、
# baseline方式を廃した——baselineに件数を書き戻せば検知を再び緩められてしまう
# 抜け穴があったため、以後は許容件数という概念自体を持たない。
set -euo pipefail

TESTS_DIR="${1:-tests}"

RAW=$(find "$TESTS_DIR" -name '*.bats' -type f -print0 \
  | xargs -0 shellcheck --shell=bash --include=SC2314 -f gcc 2>/dev/null || true)

if [ -n "$RAW" ]; then
  echo "$RAW" | while IFS= read -r line; do
    echo "::error::${line}"
  done
  echo "::error::SC2314違反を検知(tests/配下のbats、無条件検知)"
  exit 1
fi

echo "SC2314違反なし(tests/配下のbats、無条件検知)"
