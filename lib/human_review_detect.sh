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
#     解析は本taskの射程外・cmd_789自身の次段課題(別Issueで追跡)である
#     ——★cmd_790はdevblog限定(S-A)に確定しておりdocs.geolonia.comを
#     永久に扱わないため、cmd_790へ委ねると誰も拾わぬ孤児になる
#     (gunshi QC 2026-09-09指摘・是正済み)。PR#195はこの理由からも
#     本libでは検知できない/しない設計である。
#
# ★★★★cmd_789拡張(2026-09-10・殿ご裁定): geonicdb-devblog PR#31にて
# 殿が2026-09-09T05:45:11Zに投稿したreviewコメント(state=COMMENTED)が
# 上記の2つの穴——①GraphQLクエリがreview bodyを取得していない
# ②parse_review_ball_holdersはCHANGES_REQUESTEDのみ対象——の両方に
# 落ちて誰にも拾われなかった。殿ご裁定(2026-09-10T07:36):
# 「わざわざ別フラグとか持たせなくていい。複雑になる。今後私はインライン
# で書くようにするから」——review body由来の指摘に対して「対応済みか」を
# 機械が判定する仕組み(resolve相当の状態管理)は作らない。
# ただし検知そのもの(同じGraphQLクエリで取れる・費用ほぼゼロ)は残す
# ——殿以外の人間(yuiseki氏等)は引き続きreview bodyで指摘を書くため
# (実例: PR#131のCHANGES_REQUESTEDはreview body経由)。
# → parse_review_body_mentions が body非空のreviewを対応済み判定なしで
#   ただ列挙する(「済」状態は無く、常に breakdown へ出続ける——設計どおり)。
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
#     → impure。gh api graphqlで state・author・createdAt・reviewDecision・
#       reviewThreads(各スレッド最大20コメント)・reviews・直近commit日時を
#       1回のクエリで取得しJSON文字列を返す。失敗時は空文字。
#       (author/createdAtは2026-09-12 cmd_793拡張で追加——上流PR追跡用の
#       check_unreviewed_authored_prのために必要な最小限のフィールド追加。
#       既存のparse_*関数は該当フィールドを参照しないため無害)。
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
#   parse_review_body_mentions <json> <bot_allowlist_csv>
#     → pure。bodyが非空(空白のみも空扱い)かつbot allowlist外のreviewを
#       対応済み判定なしで "review本文あり|<author>氏|<createdAt>" と
#       列挙する(2026-09-10拡張・殿ご裁定によりresolve相当の状態管理は
#       作らない——ただ日付を添えて出すだけ)。
#
#   summarize_ball_holders <lines>
#     → pure。"<count>|<oldest_changed_at>|<breakdown>" を返す。0件なら
#       "0||"。breakdownは "差し戻し中(足軽)x2,resolve待ち(yuiseki氏)x1"
#       のように状態×手番でグループ化した内訳。
#
#   check_pagination_shortfall <json>
#     → pure。reviewThreads/reviewsのfetch件数がtotalCountを下回る場合
#       (=ページネーション取りこぼし)、警告文字列を返す。無ければ空文字。
#       自動ページネーションは実装しない(殿「複雑にするな」の趣旨)。
#
#   detect_review_ball_holders_for_pr <owner> <repo> <pr_number> <pr_url> <bot_allowlist_csv>
#     → fetch+parse+summarizeを結合した実行用ラッパー。
#       state!=OPENなら常に空文字(merged/closedの誤検知防止)。
#       件数>0の場合のみ "<pr_url>|<count>|<oldest_changed_at>|<breakdown>" を返す。
#       totalCount不足を検知した場合は標準エラー出力へ警告を出す(戻り値は変えない)。
#
# ── cmd_793拡張(2026-09-12): 上流PR追跡 ─────────────────────────────────────
# 背景: 殿ご下問「上流へのPRがどうなったかトラッキングできるか」
# (addendum_20260911_2240)。既存のcheck_unresolved_human_reviewsは
# detect_review_ball_holders_for_prが空を返せば何も通知しない設計のため、
# 「誰も一度もレビューせず放置されたPR」(上流PRで最も起こりそうな事態)は
# 無反応のまま検知されない。以下の2関数でその穴を埋める
# (parse_thread_ball_holders等の既存判定へは一切手を入れない・純追加)。
#
#   count_business_days_since <created_epoch> <now_epoch>
#     → pure。createdからnowまでの経過日数のうち、平日(月〜金)の日数のみを
#       24時間刻みで数えて返す(週末を跨いでも実際の対応可能日数に近づける
#       簡易実装。祝日は考慮しない——過剰設計を避けるための意図的な簡略化)。
#
#   parse_unreviewed_authored_pr <json> <author_login> <threshold_business_days> <now_epoch>
#     → pure。state==OPEN かつ author.login==author_login かつ
#       reviews.totalCount==0 かつ経過営業日数がthreshold_business_days以上
#       の場合のみ "<created_at>|<elapsed_business_days>" を返す。
#       条件を満たさなければ空文字(state!=OPEN・著者違い・レビュー1件以上
#       いずれも非検知)。
#
#   detect_unreviewed_authored_pr_for_pr <owner> <repo> <pr_number> <pr_url> <author_login> <threshold_business_days>
#     → fetch+parseを結合した実行用ラッパー。該当する場合のみ
#       "<pr_url>|<created_at>|<elapsed_business_days>" を返す。

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
  query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){state author{login} createdAt reviewDecision reviewThreads(first:100){totalCount nodes{isResolved comments(first:20){nodes{author{login} createdAt}}}} reviews(last:50){totalCount nodes{author{login} state body createdAt}} commits(last:1){nodes{commit{committedDate}}}}}}'

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
# 「応答あり」と誤判定しうる。cmd_789自身(全リポ対象ゆえcmd_790=devblog
# 限定の範囲外)でのより精密な設計を妨げない。
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

# body本文が非空(空白のみも空扱い)のreviewを、対応済み判定なしでただ
# 列挙する(2026-09-10拡張・殿ご裁定)。既存のCHANGES_REQUESTED限定判定
# (parse_review_ball_holders)とは独立——同じreviewがstate問わず
# body非空なら二重に出ることもある(意図どおり・添加のみで既存判定へは
# 一切手を入れない)。
parse_review_body_mentions() {
  local json="$1"
  local allowlist="$2"

  [[ -z "$json" ]] && return

  local bots_jq
  bots_jq=$(printf '%s' "$allowlist" | jq -R 'split(",")')

  printf '%s' "$json" | jq -r --argjson bots "$bots_jq" '
    (.data.repository.pullRequest.reviews.nodes // [])[]
    | select(.author != null)
    | (.author.login) as $login
    | select(($bots | index($login)) == null)
    | select((.body // "") | test("\\S"))
    | "review本文あり|\($login)氏|\(.createdAt)"
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

# ④totalCount安全策: fetchしたnodes件数がtotalCountを下回る場合
# (=first/last指定によるページネーションで取りこぼしている場合)、
# 警告文字列を返す(将軍実測の教訓「全件を見たと言う前にtotalCountを
# 確かめよ」の再発防止)。自動ページネーション実装までは行わない
# (殿「複雑にするな」の趣旨・警告を出すだけで足りる)。
check_pagination_shortfall() {
  local json="$1"
  [[ -z "$json" ]] && return

  printf '%s' "$json" | jq -r '
    .data.repository.pullRequest as $pr
    | [
        (($pr.reviewThreads.nodes // []) | length) as $rt_fetched
        | ($pr.reviewThreads.totalCount // 0) as $rt_total
        | if $rt_total > $rt_fetched
          then "reviewThreads: fetched \($rt_fetched)/\($rt_total)"
          else empty end,
        (($pr.reviews.nodes // []) | length) as $rv_fetched
        | ($pr.reviews.totalCount // 0) as $rv_total
        | if $rv_total > $rv_fetched
          then "reviews: fetched \($rv_fetched)/\($rv_total)"
          else empty end
      ]
    | select(length > 0)
    | join(", ")
  ' 2>/dev/null
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

  local pagination_warning
  pagination_warning=$(check_pagination_shortfall "$json")
  [[ -n "$pagination_warning" ]] && echo "[WARN] ${owner}/${repo}#${pr_number}: totalCount不足(ページネーション取りこぼしの疑い) ${pagination_warning}" >&2

  local threads reviews bodies combined summary count rest oldest breakdown
  threads=$(parse_thread_ball_holders "$json" "$allowlist")
  reviews=$(parse_review_ball_holders "$json" "$allowlist")
  bodies=$(parse_review_body_mentions "$json" "$allowlist")
  combined=$(printf '%s\n%s\n%s' "$threads" "$reviews" "$bodies")
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

# ── cmd_793拡張: 上流PR追跡(著者=我ら・レビュー0件・OPEN放置の検知) ─────────

# createdからnowまでの経過"営業日数"を24時間刻みで数える(月〜金のみ加算)。
# 祝日は考慮しない簡易実装(過剰設計を避ける・将軍案の目安=3営業日を
# 満たせれば足りるとの判断)。UTC固定で計算する——macOSの`date -jf`は
# 末尾Zを無視し「変換したつもり」が起きる罠があるため、GitHubのISO8601
# (常にUTC・Z終端)はTZ=UTC明示で扱う(feedback_utc_jst_mixing_in_elapsed_time
# の教訓を踏襲)。
count_business_days_since() {
  local created_epoch="$1"
  local now_epoch="$2"

  [[ -z "$created_epoch" || "$created_epoch" == "0" ]] && { echo "0"; return; }
  [[ "$now_epoch" -le "$created_epoch" ]] && { echo "0"; return; }

  local count=0
  local cur=$created_epoch
  local dow
  while [[ "$cur" -lt "$now_epoch" ]]; do
    cur=$(( cur + 86400 ))
    # %u: 1=Monday .. 7=Sunday
    dow=$(TZ=UTC date -u -r "$cur" '+%u' 2>/dev/null || TZ=UTC date -u -d "@$cur" '+%u' 2>/dev/null)
    [[ -z "$dow" ]] && continue
    if [[ "$dow" -le 5 ]]; then
      count=$(( count + 1 ))
    fi
  done
  echo "$count"
}

# GitHubのISO8601(常にUTC・"2026-09-01T12:00:00Z"形式)をepoch秒へ変換する。
# TZ=UTC明示(末尾Zをdate -jfが無視する罠を踏まない・上記教訓と同じ)。
_github_iso_to_epoch() {
  local iso="$1"
  [[ -z "$iso" ]] && { echo "0"; return; }
  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null \
    || TZ=UTC date -u -d "$iso" '+%s' 2>/dev/null \
    || echo "0"
}

# state==OPEN かつ author.login==author_login かつ reviews.totalCount==0
# かつ経過営業日数がthreshold_business_days以上の場合のみ
# "<created_at>|<elapsed_business_days>" を返す。
parse_unreviewed_authored_pr() {
  local json="$1"
  local author_login="$2"
  local threshold_business_days="$3"
  local now_epoch="$4"

  [[ -z "$json" ]] && return

  local state pr_author review_count created_at
  state=$(printf '%s' "$json" | jq -r '.data.repository.pullRequest.state // "UNKNOWN"' 2>/dev/null)
  [[ "$state" != "OPEN" ]] && return

  pr_author=$(printf '%s' "$json" | jq -r '.data.repository.pullRequest.author.login // ""' 2>/dev/null)
  [[ "$pr_author" != "$author_login" ]] && return

  review_count=$(printf '%s' "$json" | jq -r '.data.repository.pullRequest.reviews.totalCount // 0' 2>/dev/null)
  [[ "$review_count" != "0" ]] && return

  created_at=$(printf '%s' "$json" | jq -r '.data.repository.pullRequest.createdAt // ""' 2>/dev/null)
  [[ -z "$created_at" ]] && return

  local created_epoch elapsed_days
  created_epoch=$(_github_iso_to_epoch "$created_at")
  [[ "$created_epoch" == "0" ]] && return
  elapsed_days=$(count_business_days_since "$created_epoch" "$now_epoch")

  if [[ "$elapsed_days" -ge "$threshold_business_days" ]]; then
    echo "${created_at}|${elapsed_days}"
  fi
}

# fetch+parseを結合した実行用ラッパー。該当する場合のみ
# "<pr_url>|<created_at>|<elapsed_business_days>" を返す。
detect_unreviewed_authored_pr_for_pr() {
  local owner="$1"
  local repo="$2"
  local pr_number="$3"
  local pr_url="$4"
  local author_login="$5"
  local threshold_business_days="$6"

  local json
  json=$(fetch_pr_review_data "$owner" "$repo" "$pr_number")
  [[ -z "$json" ]] && { echo ""; return; }

  local now_epoch
  now_epoch=$(date -u '+%s')

  local result
  result=$(parse_unreviewed_authored_pr "$json" "$author_login" "$threshold_business_days" "$now_epoch")
  [[ -z "$result" ]] && { echo ""; return; }

  echo "${pr_url}|${result}"
}
