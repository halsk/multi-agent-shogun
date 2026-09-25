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
#       ★2026-09-25是正(家老起票): 直近PRとworkflow runの紐付けは、以前は
#       runの`pull_requests`フィールド(any(.number == N))で行っていたが、
#       ★このフィールドはPRがmerge/close済みだと常に空配列`[]`になる
#       (GitHubの既知挙動・event=pull_requestで発火したrunであっても同様・
#       実物PR#149/run 35058504745で実証済み)。この家はPRを作ってすぐmerge
#       する運用のため、heartbeatチェックが実行される頃には対象PRはほぼ
#       常にmerge済みであり、旧方式は実質ほぼ常に「stale」を誤って報告する
#       構造だった。★PRのhead_sha(`.head.sha`)とworkflow runの`head_sha`を
#       直接突き合わせる方式に変更。PRがmerge済みでも、そのheadのcommitが
#       runに使われた事実は変わらないため正しく突き合わせられる。
#
#   _ci_heartbeat_match_head_sha <pr_head_sha> <runs_json>
#     → runs_json([{head_sha,created_at}, ...]の配列)からpr_head_shaに一致する
#       最初のrunのcreated_atを返す(見つからなければ空文字)。gh apiを叩かず
#       単体テスト可能な純関数(ci_heartbeat_judgeと同方針)。
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
  # ★TZ=UTC必須: BSD date -j -f は書式中の"Z"をリテラル文字として消費するのみで
  # 「UTCとして解釈せよ」の指示にならず、TZ未指定だとローカルTZとして解釈され
  # 実際のepochより(ローカルTZ分)ずれる(cmd_new_utc_jst F1・将軍実測)。
  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null \
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

  local pr_head_sha
  pr_head_sha=$(gh api "repos/${owner_repo}/pulls/${pr_number}" --jq '.head.sha // ""' 2>/dev/null)
  if [[ ! "$pr_head_sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    # PR詳細取得失敗・head_sha取得不能 → runとの突き合わせ不能。
    # pr_created_epochはそのまま返しjudge側のgrace_secに委ねる(gh api全体の
    # 断ではないため-1|-1にはしない)。
    echo "${pr_created_epoch}|0"
    return
  fi

  local runs_json matched_iso matched_epoch
  runs_json=$(gh api "repos/${owner_repo}/actions/workflows/${workflow_file}/runs?per_page=20" \
    --jq '[.workflow_runs[] | {head_sha, created_at}]' 2>/dev/null)
  matched_iso=$(_ci_heartbeat_match_head_sha "$pr_head_sha" "$runs_json")
  matched_epoch=$(_ci_iso_to_epoch "$matched_iso")

  echo "${pr_created_epoch}|${matched_epoch}"
}

_ci_heartbeat_match_head_sha() {
  local pr_head_sha="$1"
  local runs_json="$2"
  [[ -z "$runs_json" ]] && { echo ""; return; }
  echo "$runs_json" | jq -r --arg sha "$pr_head_sha" \
    '[.[] | select(.head_sha == $sha)] | (.[0].created_at // "")' 2>/dev/null
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
