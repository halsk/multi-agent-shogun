#!/usr/bin/env bash
# lib/ci_heartbeat_detect.sh — cmd_767/771拡張(subtask_767_771_self_ci_heartbeat):
# 自リポ(multi-agent-shogun)のGitHub Actions CI心拍検知。
#
# 背景: 殿がGitHub Actionsのパーミッションを許可(2026-09-06)するまで、
# .github/workflows/test.yml (Multi-CLI Test Suite) は state: active のまま
# 一度もrunが立っていなかった(total_count=0)——これは定期ジョブ(cmd_767)と
# 同型の「黙って死んでいる」状態であり、同じ心拍の考え方を適用する。
# ★★★単独の新規監視機構は作らず、既存 scripts/stall_watchdog.sh
# (cmd_766/771/767で確立済みの相乗り作法)へ相乗りする前提のライブラリ。
#
# 判定対象は「直近のPRが作られてから一定時間以内にrunが立ったか」
# (last-run.jsonのような実行痕跡ファイルがCIには無いため、
# heartbeat_detect.shとは違いgh api呼び出しが要る)。
# gh api呼び出し(impure)と判定ロジック(pure)を分離し、判定ロジックのみを
# 単体テスト対象とする(heartbeat_detect.shと同方針)。
#
# 提供関数:
#   ci_heartbeat_fetch <owner_repo> <workflow_file>
#     → gh api経由で "<pr_created_epoch>|<matched_run_epoch>" を返す
#       (impure・ネットワークアクセスあり)。PRが1件も無ければ "0|0"。
#       matched_run_epoch は直近PRに紐付くworkflow runが見つかった場合の
#       run created_at epoch、見つからなければ 0。
#       ★gh api呼び出し自体が失敗(認証切れ・レート制限・ネットワーク断等)
#       した場合は "-1|-1" を返す——"0|0"(PRが1件も無い正常な空)と区別し、
#       gh自体の不調をok扱いのまま握り潰さない(この検知の目的そのものが
#       「黙って死んでいる」を見つけることなので、検知器自身が黙って死ぬのは
#       本末転倒)。
#
#   ci_heartbeat_judge <pr_created_epoch> <matched_run_epoch> <grace_sec> <now_epoch>
#     → "<status>|<detail>" を返す。status は ok / stale のいずれか(pure関数・
#       単体テスト対象)
#
#   ci_heartbeat_check <owner_repo> <workflow_file> <grace_sec> <now_epoch>
#     → fetch+judgeを結合した実行用ラッパー

_ci_iso_to_epoch() {
  local iso="$1"
  [[ -z "$iso" ]] && { echo 0; return; }
  date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null \
    || date -d "$iso" '+%s' 2>/dev/null \
    || echo 0
}

ci_heartbeat_fetch() {
  local owner_repo="$1"
  local workflow_file="$2"

  local pr_line pr_rc pr_number pr_created_iso pr_created_epoch
  pr_line=$(gh api "repos/${owner_repo}/pulls?state=all&sort=created&direction=desc&per_page=1" \
    --jq '(.[0] // {}) | "\(.number // 0)|\(.created_at // "")"' 2>/dev/null)
  pr_rc=$?
  if [[ "$pr_rc" -ne 0 ]]; then
    echo "-1|-1"
    return
  fi
  pr_number="${pr_line%%|*}"
  pr_created_iso="${pr_line#*|}"
  pr_created_epoch=$(_ci_iso_to_epoch "$pr_created_iso")

  if [[ ! "$pr_number" =~ ^[0-9]+$ || "$pr_number" == "0" || "$pr_created_epoch" -eq 0 ]]; then
    echo "0|0"
    return
  fi

  # pr_numberは直前でGitHub API自身の.number(整数)であることを検証済み
  # (0でなければ数値)。gh api --jqは--argを受け付けない(gh api本体の引数と
  # 解釈され "accepts 1 arg(s)" で失敗する・将軍実測)ため、jqフィルタ文字列へ
  # 直接埋め込む。
  local matched_iso matched_epoch
  matched_iso=$(gh api "repos/${owner_repo}/actions/workflows/${workflow_file}/runs?per_page=20" \
    --jq ".workflow_runs[] | select((.pull_requests // []) | any(.number == ${pr_number})) | .created_at" \
    2>/dev/null | head -1)
  matched_epoch=$(_ci_iso_to_epoch "$matched_iso")

  echo "${pr_created_epoch}|${matched_epoch}"
}

ci_heartbeat_judge() {
  local pr_created_epoch="$1"
  local matched_run_epoch="$2"
  local grace_sec="$3"
  local now_epoch="$4"

  if [[ "$pr_created_epoch" -eq -1 ]]; then
    echo "stale|gh api呼び出し自体が失敗した(認証切れ・レート制限・ネットワーク断等の可能性)"
    return
  fi

  if [[ "$pr_created_epoch" -eq 0 ]]; then
    echo "ok|"
    return
  fi

  if [[ "$matched_run_epoch" -gt 0 ]]; then
    echo "ok|"
    return
  fi

  local age=$(( now_epoch - pr_created_epoch ))
  if [[ "$age" -gt "$grace_sec" ]]; then
    echo "stale|直近PR作成(${age}s前)に対しCI runが見つからない(許容${grace_sec}s超)"
    return
  fi

  echo "ok|"
}

ci_heartbeat_check() {
  local owner_repo="$1"
  local workflow_file="$2"
  local grace_sec="$3"
  local now_epoch="$4"

  local fetched pr_created_epoch matched_run_epoch
  fetched=$(ci_heartbeat_fetch "$owner_repo" "$workflow_file")
  IFS='|' read -r pr_created_epoch matched_run_epoch <<< "$fetched"

  ci_heartbeat_judge "$pr_created_epoch" "$matched_run_epoch" "$grace_sec" "$now_epoch"
}
