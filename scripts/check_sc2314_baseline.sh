#!/usr/bin/env bash
# tests/配下の.batsに含まれるSC2314(裸の`!`は最終行でなければ失敗を伝播しない)を
# ファイル別の許容件数(ratchet baseline)と比較し、超過があれば失敗する。
#
# baselineは「ファイル=件数」形式(行番号を持たない)。行番号キーだと、既存箇所を
# 1件でも直すと同一ファイル内の後続違反の行番号がずれ、baselineと一致せず
# 「新規違反」と誤検知する(cmd_834 F-1・軍師QC実測: 1行追加で31件誤検知)。
#
# 検知ロジック:
#   - 現状の各ファイルのSC2314件数を実測
#   - baselineの許容件数を1件でも上回るファイルがあれば失敗
#   - baselineに無いファイルにSC2314が現れても(許容件数=0扱いのため)失敗
#
# 既知の弱点(軍師も認識・暫定): 同一ファイル内で1件直し1件新たに紛れ込ませれば
# 件数が相殺され見逃す。ashigaru4/5によるtests配下41箇所の修正が完了し次第、
# baselineを空にした上で「1件でも検知したら落とす」無条件検知へ昇格させること。
set -euo pipefail

BASELINE="${1:-tests/.shellcheck_sc2314_baseline.txt}"
TESTS_DIR="${2:-tests}"

[ -f "$BASELINE" ] || : > "$BASELINE"

RAW=$(find "$TESTS_DIR" -name '*.bats' -type f -print0 \
  | xargs -0 shellcheck --shell=bash --include=SC2314 -f gcc 2>/dev/null || true)

declare -A CURRENT_COUNT
while IFS=: read -r file _rest; do
  [ -n "$file" ] || continue
  CURRENT_COUNT["$file"]=$(( ${CURRENT_COUNT["$file"]:-0} + 1 ))
done <<< "$RAW"

declare -A ALLOWED_COUNT
while IFS='=' read -r file count; do
  [ -n "$file" ] || continue
  ALLOWED_COUNT["$file"]=$count
done < "$BASELINE"

FAIL=0
for file in "${!CURRENT_COUNT[@]}"; do
  cur=${CURRENT_COUNT["$file"]}
  allowed=${ALLOWED_COUNT["$file"]:-0}
  if [ "$cur" -gt "$allowed" ]; then
    echo "::error::${file}: SC2314 ${cur}件検出(baseline許容${allowed}件を超過)"
    FAIL=1
  fi
done

if [ "$FAIL" -eq 1 ]; then
  echo "::error::新規のSC2314違反を検知(tests/配下のbats、baseline許容件数超過)"
  exit 1
fi

echo "新規SC2314違反なし(baselineファイル数: ${#ALLOWED_COUNT[@]}、検出ファイル数: ${#CURRENT_COUNT[@]})"
