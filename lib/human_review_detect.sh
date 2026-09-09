#!/usr/bin/env bash
# lib/human_review_detect.sh — cmd_789 相乗り: PR上の人間レビュアー(bot除く)による
# 未解決の指摘を検知し、「次にどちらの手番か」(ball-holder)まで判定する
# 純関数ライブラリ。
#
# 背景: 殿(halsk)が2026-06-27にPR#31(geonicdb-devblog)へ書いた18件の指摘が
# 2ヶ月半誰にも届かなかった(本人が対話で仰せになるまで)。原因は「対話」
# 「ntfy」経路はあったが「GitHubのPRレビュー」を聞く経路が無かったこと。
# ★★★殿ご自身の射程訂正(2026-09-09): 検知対象はhalsk限定ではなく
# 人間レビュアー全般(yuiseki氏等・bot=CodeRabbit等を除く)。
# ★★★★殿ご裁定(2026-09-09・恒久化): cmd_790はdevblog限定UIへ縮小され、
# cmd_789(本ファイル)がswarm全体(全リポ)のレビュー検知を恒久的に担う。
# 「軽く作れ」の制約は撤回されたが過剰設計は禁物——gunshiのball-holder設計
# (cmd_790の前回設計で導いたもの)を踏襲し、以下の3状態を区別する:
#   差し戻し中(awaiting-author):   最新のreviewer側シグナル以降、著者の
#     応答(threadへの追加コメント、またはPRへの新規commit)が無い
#     → 手番=足軽(PR著者)
#   resolve待ち(awaiting-reviewer-resolve): 著者の応答は有るが、
#     thread未resolve/reviewのCHANGES_REQUESTEDが未解消
#     → 手番=そのreviewer本人(resolveボタン・再レビューは本人にしか押せぬ)
#   済(resolved): thread resolved、またはCHANGES_REQUESTEDが後続レビューで
#     解消済み — 本libの出力対象外(手番が発生しないため)
# 経過時間は「手番が最後に変わった時刻」を用いる(単純なスレッド作成日でない)。
#
# ★実測(2026-09-09・cmd_789着手時、gh api graphqlで直接確認):
#   - PR#31(geonicdb-devblog): OPEN/draft。18件のreviewThreadsが
#     isResolved=falseのまま — ★★全スレッドに実は2件目のコメント
#     (返信)が既に存在する(2026-06-27同日中)。PRの著者もコメント投稿者も
#     ともにGitHubログイン上は"halsk"(swarmがhalskのgh認証で動くため・
#     殿ご自身がレビューする際も同一アカウント——lesson_shared 2026-09-08
#     参照)であり、ログイン比較だけでは著者本人の応答か殿の追加コメントかを
#     区別できない。★そこで「著者と同一ログインか」ではなく「スレッド内の
#     コメント数が1件超か」を応答判定に用いる(ログインに依存しない設計。
#     詳細はparse_thread_ball_holdersのコメント参照)。この判定により
#     PR#31は全件「resolve待ち・手番=halsk氏」となる——まさに本taskが
#     拾いたかった穴(swarmは応答済みだが指摘者本人の確認+resolveだけが
#     忘れられていた)を正しく可視化する。
#   - PR#131(geonicdb-console): OPEN。reviewThreadsは3件ともcoderabbitai発
#     かつisResolved=trueで、reviewThreads側では0件。ところがyuiseki氏の
#     指摘(CHANGES_REQUESTED)はPR review本体の状態にあり、
#     reviewDecision=CHANGES_REQUESTED・yuiseki氏の最新レビューが
#     CHANGES_REQUESTEDのまま未解消であることをgh api graphqlで確認。
#     さらに直近commit(2026-09-08)がyuiseki氏のレビュー(2026-08-25)より
#     後にあるため「著者は既に対応済み・yuiseki氏の再確認待ち」と判定できる
#     → resolve待ち・手番=yuiseki氏。
#   - PR#195(docs.geolonia.com): 既にMERGED(cmd_782で殿の指摘=404是正が
#     完了・PR#216でmerge済み)。state!=OPENは検知しない(誤報防止・
#     acceptance_criteria⑤どおり)。yuiseki氏のAPPROVEDレビュー本文中の
#     「150箇所404」の指摘はレビュー本体(body)にのみ存在し、body本文の
#     解析は本taskの射程外(cmd_790側の課題)——PR#195はこの理由からも
#     本libでは検知できない/しない設計である。
#
# ★★★body本文(review body・inline commentの文面)は一切読まない。
# 読むのは isResolved / state / author.login / createdAt / commit日時のみ
# (メタデータ)。「PRレビュー本文への射程拡大は次段の課題」という制約は守る。
#
# ★単独の新規監視機構は作らず、既存 scripts/stall_watchdog.sh
# (lib/stale_errlog_detect.sh 等と同じ相乗り作法)へ相乗りする前提の
# ライブラリ。gh api呼び出し(impure)と判定ロジック(pure)を分離し、
# 判定ロジックのみを単体テスト対象とする(ci_heartbeat_detect.shと同方針)。
#
# 提供関数:
#   fetch_open_prs <owner/repo>
#     → impure。OPENなPR(draft含む)を "<number>|<url>" で列挙。
#
#   fetch_pr_review_data <owner> <repo> <pr_number>
#     → impure。gh api graphqlで state・reviewDecision・reviewThreads
#       (各スレッド最大20コメント)・reviews・直近commit日時 を1回の
#       クエリで取得しJSON文字列を返す。失敗時は空文字。
#
#   parse_thread_ball_holders <json> <bot_allowlist_csv>
#     → pure。isResolved=false かつ最初のコメント投稿者がbot allowlist外の
#       スレッドを対象に "<status>|<turn_label>|<changed_at>" で列挙。
#       statusは 差し戻し中 / resolve待ち のいずれか。
#
#   parse_review_ball_holders <json> <bot_allowlist_csv>
#     → pure。投稿者ごとの最新レビュー(createdAt最大)がCHANGES_REQUESTED
#       かつbot allowlist外の場合、直近commit日時と比較し
#       "<status>|<turn_label>|<changed_at>" で列挙。
#
#   summarize_ball_holders <lines>
#     → pure。"<count>|<oldest_changed_at>|<breakdown>" を返す。0件なら
#       "0||"。breakdownは "差し戻し中(足軽)x2,resolve待ち(yuiseki氏)x1"
#       のように状態×手番でグループ化した内訳。
#
#   detect_review_ball_holders_for_pr <owner> <repo> <pr_number> <pr_url> <bot_allowlist_csv>
#     → fetch+parse+summarizeを結合した実行用ラッパー。
#       state!=OPENなら常に空文字(merged/closedの誤検知防止)。
#       件数>0の場合のみ "<pr_url>|<count>|<oldest_changed_at>|<breakdown>" を返す。

fetch_open_prs() {
  local owner_repo="$1"
  gh pr list --repo "$owner_repo" --state open --json number,url --limit 100 \
    --jq '.[] | "\(.number)|\(.url)"' 2>/dev/null
}

fetch_pr_review_data() {
  local owner="$1"
  local repo="$2"
  local pr_number="$3"

  local query
  query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){state reviewDecision reviewThreads(first:100){nodes{isResolved comments(first:20){nodes{author{login} createdAt}}}} reviews(last:30){nodes{author{login} state createdAt}} commits(last:1){nodes{commit{committedDate}}}}}}'

  gh api graphql -f query="$query" -f owner="$owner" -f repo="$repo" -F pr="$pr_number" 2>/dev/null
}

# スレッド内のコメント数が1件超であることを「著者が応答した」の判定に使う
# (ログイン比較を使わない)。理由: PR#31のようにswarmが著者かつ殿ご自身が
# 同一GitHubアカウント(halsk)でレビューする場合、"最後のコメント投稿者==
# PR著者login" という比較ではswarmの返信と殿の追加コメントを区別できず
# 恒久的に破綻する(lesson_shared 2026-09-08)。一方コメント数(=スレッドに
# 誰かが追加で書き込んだか)はログインに依存せず判定できる。
# ★既知の限界(過剰設計を避けるため受容する簡略化・報告に明記):
# 同一reviewerが応答なしに連続して2件目を書き込んだだけの場合も
# 「応答あり」と誤判定しうる。cmd_790側でのより精密な設計を妨げない。
parse_thread_ball_holders() {
  local json="$1"
  local allowlist="$2"

  [[ -z "$json" ]] && return

  local bots_jq
  bots_jq=$(printf '%s' "$allowlist" | jq -R 'split(",")')

  printf '%s' "$json" | jq -r --argjson bots "$bots_jq" '
    (.data.repository.pullRequest.reviewThreads.nodes // [])[]
    | select(.isResolved == false)
    | (.comments.nodes // []) as $comments
    | ($comments[0]) as $first
    | select($first != null and $first.author != null)
    | ($first.author.login) as $reviewer
    | select(($bots | index($reviewer)) == null)
    | ($comments[-1]) as $last
    | if ($comments | length) > 1
      then "resolve待ち|\($reviewer)氏|\($last.createdAt)"
      else "差し戻し中|足軽|\($first.createdAt)"
      end
  ' 2>/dev/null
}

# reviewDecision由来(PR#131実例)。CHANGES_REQUESTEDのまま解消されていない
# 人間レビュアーごとに、直近commitがそのレビューより後か(=著者が既に対応
# した形跡があるか)を見て手番を判定する。
parse_review_ball_holders() {
  local json="$1"
  local allowlist="$2"

  [[ -z "$json" ]] && return

  local bots_jq
  bots_jq=$(printf '%s' "$allowlist" | jq -R 'split(",")')

  printf '%s' "$json" | jq -r --argjson bots "$bots_jq" '
    (.data.repository.pullRequest.commits.nodes[0].commit.committedDate // "") as $latest_commit
    | (.data.repository.pullRequest.reviews.nodes // [])
    | group_by(.author.login)
    | map(max_by(.createdAt))
    | .[]
    | select(.author != null)
    | (.author.login) as $login
    | select(($bots | index($login)) == null)
    | select(.state == "CHANGES_REQUESTED")
    | if ($latest_commit != "" and $latest_commit > .createdAt)
      then "resolve待ち|\($login)氏|\($latest_commit)"
      else "差し戻し中|足軽|\(.createdAt)"
      end
  ' 2>/dev/null
}

summarize_ball_holders() {
  local items="$1"
  local count=0
  local oldest=""
  local -a group_keys=()
  local -a group_counts=()

  local ball_status turn changed_at
  while IFS='|' read -r ball_status turn changed_at; do
    [[ -z "$ball_status" ]] && continue
    count=$((count + 1))
    if [[ -z "$oldest" || "$changed_at" < "$oldest" ]]; then
      oldest="$changed_at"
    fi

    local key="${ball_status}(${turn})"
    local found=false
    local i
    for i in "${!group_keys[@]}"; do
      if [[ "${group_keys[$i]}" == "$key" ]]; then
        group_counts[$i]=$((group_counts[$i] + 1))
        found=true
        break
      fi
    done
    if [[ "$found" == false ]]; then
      group_keys+=("$key")
      group_counts+=(1)
    fi
  done <<< "$items"

  local breakdown=""
  local i
  for i in "${!group_keys[@]}"; do
    breakdown="${breakdown:+${breakdown},}${group_keys[$i]}x${group_counts[$i]}"
  done

  echo "${count}|${oldest}|${breakdown}"
}

detect_review_ball_holders_for_pr() {
  local owner="$1"
  local repo="$2"
  local pr_number="$3"
  local pr_url="$4"
  local allowlist="$5"

  local json
  json=$(fetch_pr_review_data "$owner" "$repo" "$pr_number")
  [[ -z "$json" ]] && { echo ""; return; }

  local state
  state=$(printf '%s' "$json" | jq -r '.data.repository.pullRequest.state // "UNKNOWN"' 2>/dev/null)
  if [[ "$state" != "OPEN" ]]; then
    echo ""
    return
  fi

  local threads reviews combined summary count rest oldest breakdown
  threads=$(parse_thread_ball_holders "$json" "$allowlist")
  reviews=$(parse_review_ball_holders "$json" "$allowlist")
  combined=$(printf '%s\n%s' "$threads" "$reviews")
  summary=$(summarize_ball_holders "$combined")
  count="${summary%%|*}"
  rest="${summary#*|}"
  oldest="${rest%%|*}"
  breakdown="${rest#*|}"

  if [[ -z "$count" || "$count" -eq 0 ]]; then
    echo ""
    return
  fi

  echo "${pr_url}|${count}|${oldest}|${breakdown}"
}
