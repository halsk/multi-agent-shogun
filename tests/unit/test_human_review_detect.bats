#!/usr/bin/env bats
#
# tests/unit/test_human_review_detect.bats
bats_require_minimum_version 1.5.0
#
# cmd_789相乗り: PR上の人間レビュアー(bot除く)による未解決の指摘を検知し、
# 「差し戻し中/resolve待ち/済」の3状態・手番(ball-holder)を判定する純関数の
# ユニットテスト(gh api呼び出しは fetch_open_prs / fetch_pr_review_data に
# 分離済みでここでは対象外・detect_review_ball_holders_for_prのみ
# fetch_pr_review_data をスタブ差し替えして状態ゲートを検証する)。
#
# フィクスチャは実PRの実測データ(2026-09-09・gh api graphql直接確認)を
# 模して作成: PR#31(geonicdb-devblog・reviewThreads側・著者とレビュアーが
# 同一GitHubログイン"halsk"という特殊ケース)、PR#131(geonicdb-console・
# reviewDecision側・yuiseki氏)、PR#195(docs.geolonia.com・既にMERGED→
# 非検知が正)。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/human_review_detect.sh"
  export BOTS="coderabbitai,coderabbitai[bot],dependabot,dependabot[bot],github-actions,github-actions[bot],copilot-pull-request-reviewer,copilot-pull-request-reviewer[bot]"
}

# ── T-HREV-001: reviewThreads — コメント1件のみ(未応答) → 差し戻し中・手番=足軽 ──

@test "T-HREV-001: parse_thread_ball_holders marks a single-comment unresolved thread as awaiting-author" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[{"author":{"login":"yuiseki"},"createdAt":"2026-06-27T06:19:54Z"}]}}
  ]}}}}}'

  run parse_thread_ball_holders "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [[ "$output" == "差し戻し中|足軽|2026-06-27T06:19:54Z" ]]
}

# ── T-HREV-002: reviewThreads — 2件目のコメントあり(応答済み) → resolve待ち・手番=reviewer氏 ──
# (PR#31実測: 著者とレビュアーが同一ログイン"halsk"のため、ログイン比較でなく
# コメント数で応答を判定する設計の核心テスト)

@test "T-HREV-002: parse_thread_ball_holders marks a replied-to unresolved thread as awaiting-reviewer-resolve (PR#31-like same-login case)" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[
      {"author":{"login":"halsk"},"createdAt":"2026-06-26T22:55:12Z"},
      {"author":{"login":"halsk"},"createdAt":"2026-06-27T00:45:28Z"}
    ]}}
  ]}}}}}'

  run parse_thread_ball_holders "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [[ "$output" == "resolve待ち|halsk氏|2026-06-27T00:45:28Z" ]]
}

# ── T-HREV-003: reviewThreads — bot発のunresolvedは検知しない(誤報厳禁) ──

@test "T-HREV-003: parse_thread_ball_holders excludes bot-authored unresolved threads" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"createdAt":"2026-08-24T00:00:00Z"}]}}
  ]}}}}}'

  run parse_thread_ball_holders "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-004: reviewThreads — 全件resolved → 0件 ──

@test "T-HREV-004: parse_thread_ball_holders returns nothing when all threads resolved" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"author":{"login":"halsk"},"createdAt":"2026-06-27T04:23:32Z"}]}}
  ]}}}}}'

  run parse_thread_ball_holders "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-005: reviews — CHANGES_REQUESTED後に新規commitが無い → 差し戻し中・手番=足軽 ──

@test "T-HREV-005: parse_review_ball_holders marks an outstanding CHANGES_REQUESTED with no later commit as awaiting-author" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"committedDate":"2026-08-20T00:00:00Z"}}]},"reviews":{"nodes":[
    {"author":{"login":"yuiseki"},"state":"CHANGES_REQUESTED","createdAt":"2026-08-25T00:32:44Z"}
  ]}}}}}'

  run parse_review_ball_holders "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [[ "$output" == "差し戻し中|足軽|2026-08-25T00:32:44Z" ]]
}

# ── T-HREV-006: reviews — CHANGES_REQUESTED後に新規commitが有る → resolve待ち・手番=reviewer氏 ──
# (PR#131実測を模したフィクスチャ。yuiseki氏の指摘後にswarmが対応commitを
# 積んだが、yuiseki氏の再レビュー待ちのまま——本taskの核心的な発見)

@test "T-HREV-006: parse_review_ball_holders marks an outstanding CHANGES_REQUESTED with a later commit as awaiting-reviewer-resolve (PR#131-like)" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"committedDate":"2026-09-08T01:04:55Z"}}]},"reviews":{"nodes":[
    {"author":{"login":"coderabbitai"},"state":"COMMENTED","createdAt":"2026-08-21T06:52:50Z"},
    {"author":{"login":"yuiseki"},"state":"CHANGES_REQUESTED","createdAt":"2026-08-25T00:32:44Z"},
    {"author":{"login":"coderabbitai"},"state":"CHANGES_REQUESTED","createdAt":"2026-08-25T02:19:15Z"},
    {"author":{"login":"coderabbitai"},"state":"APPROVED","createdAt":"2026-09-06T14:00:20Z"}
  ]}}}}}'

  run parse_review_ball_holders "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [[ "$output" == "resolve待ち|yuiseki氏|2026-09-08T01:04:55Z" ]]
}

# ── T-HREV-007: reviews — botの最新レビューがCHANGES_REQUESTEDでも(bot故に)検知しない ──

@test "T-HREV-007: parse_review_ball_holders never counts a bot even if its latest review is CHANGES_REQUESTED" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"commits":{"nodes":[]},"reviews":{"nodes":[
    {"author":{"login":"coderabbitai"},"state":"CHANGES_REQUESTED","createdAt":"2026-08-25T02:19:15Z"}
  ]}}}}}'

  run parse_review_ball_holders "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-008: reviews — 人間の最新レビューがCOMMENTED(解消済み相当)なら検知しない ──

@test "T-HREV-008: parse_review_ball_holders does not count a human whose latest review is COMMENTED" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"commits":{"nodes":[]},"reviews":{"nodes":[
    {"author":{"login":"dkastl"},"state":"CHANGES_REQUESTED","createdAt":"2026-08-01T00:00:00Z"},
    {"author":{"login":"dkastl"},"state":"COMMENTED","createdAt":"2026-08-02T00:00:00Z"}
  ]}}}}}'

  run parse_review_ball_holders "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-009: summarize_ball_holders — count/oldest/内訳を正しく集計する ──

@test "T-HREV-009: summarize_ball_holders aggregates count, oldest changed_at, and a status x turn breakdown" {
  source "$LIB_FILE"

  items=$'差し戻し中|足軽|2026-06-27T06:19:54Z\nresolve待ち|yuiseki氏|2026-08-25T00:32:44Z\n差し戻し中|足軽|2026-06-27T11:44:39Z'

  run summarize_ball_holders "$items"
  [ "$status" -eq 0 ]
  [[ "$output" == "3|2026-06-27T06:19:54Z|差し戻し中(足軽)x2,resolve待ち(yuiseki氏)x1" ]]
}

# ── T-HREV-010: summarize_ball_holders — 空入力は0件 ──

@test "T-HREV-010: summarize_ball_holders returns 0 for empty input" {
  source "$LIB_FILE"

  run summarize_ball_holders ""
  [ "$status" -eq 0 ]
  [[ "$output" == "0||" ]]
}

# ── T-HREV-011: detect_review_ball_holders_for_pr — state!=OPEN(MERGED)は
# 誤検知しない(PR#195実例: cmd_782でmerge済み) ──

@test "T-HREV-011: detect_review_ball_holders_for_pr never flags a MERGED PR (PR#195 regression guard)" {
  source "$LIB_FILE"

  fetch_pr_review_data() {
    echo '{"data":{"repository":{"pullRequest":{"state":"MERGED","reviewDecision":"APPROVED","commits":{"nodes":[]},"reviewThreads":{"nodes":[
      {"isResolved":false,"comments":{"nodes":[{"author":{"login":"halsk"},"createdAt":"2026-06-27T00:00:00Z"}]}}
    ]},"reviews":{"nodes":[
      {"author":{"login":"yuiseki"},"state":"CHANGES_REQUESTED","createdAt":"2026-09-07T00:53:10Z"}
    ]}}}}}'
  }

  run detect_review_ball_holders_for_pr "geolonia" "docs.geolonia.com" 195 \
    "https://github.com/geolonia/docs.geolonia.com/pull/195" "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-012: detect_review_ball_holders_for_pr — OPENなPRでthread側+review側
# 双方に未解決あり → 合算しURL+件数+最古手番変更日時+内訳を返す ──

@test "T-HREV-012: detect_review_ball_holders_for_pr combines thread and review signals for an OPEN PR" {
  source "$LIB_FILE"

  fetch_pr_review_data() {
    echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","reviewDecision":"CHANGES_REQUESTED","commits":{"nodes":[{"commit":{"committedDate":"2026-08-20T00:00:00Z"}}]},"reviewThreads":{"nodes":[
      {"isResolved":false,"comments":{"nodes":[{"author":{"login":"halsk"},"createdAt":"2026-06-27T06:19:54Z"}]}},
      {"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"createdAt":"2026-08-21T06:52:50Z"}]}}
    ]},"reviews":{"nodes":[
      {"author":{"login":"coderabbitai"},"state":"COMMENTED","createdAt":"2026-08-21T06:52:50Z"},
      {"author":{"login":"yuiseki"},"state":"CHANGES_REQUESTED","createdAt":"2026-08-25T00:32:44Z"}
    ]}}}}}'
  }

  run detect_review_ball_holders_for_pr "geolonia" "geonicdb-console" 131 \
    "https://github.com/geolonia/geonicdb-console/pull/131" "$BOTS"
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/geolonia/geonicdb-console/pull/131|2|2026-06-27T06:19:54Z|差し戻し中(足軽)x2" ]]
}

# ── T-HREV-013: detect_review_ball_holders_for_pr — bot発のみ(人間の未解決0件)
# → 空を返す ──

@test "T-HREV-013: detect_review_ball_holders_for_pr returns empty when only bots are unresolved" {
  source "$LIB_FILE"

  fetch_pr_review_data() {
    echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","reviewDecision":null,"commits":{"nodes":[]},"reviewThreads":{"nodes":[
      {"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"createdAt":"2026-08-21T06:52:50Z"}]}}
    ]},"reviews":{"nodes":[
      {"author":{"login":"coderabbitai"},"state":"COMMENTED","createdAt":"2026-08-21T06:52:50Z"}
    ]}}}}}'
  }

  run detect_review_ball_holders_for_pr "geolonia" "somewhere" 1 \
    "https://github.com/geolonia/somewhere/pull/1" "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-015: parse_review_body_mentions — body非空の人間reviewを
# 対応済み判定なしで列挙する(2026-09-10拡張・PR#31実例=殿の05:45コメント) ──

@test "T-HREV-015: parse_review_body_mentions lists a non-empty human review body without any resolved judgement" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[
    {"author":{"login":"halsk"},"state":"COMMENTED","body":"文字ばかりで読みにくいので、適切に画像を入れたり、構造化した図を入れて(細かすぎないように)","createdAt":"2026-09-09T05:45:11Z"}
  ]}}}}}'

  run parse_review_body_mentions "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [[ "$output" == "review本文あり|halsk氏|2026-09-09T05:45:11Z" ]]
}

# ── T-HREV-016: parse_review_body_mentions — 空白のみのbodyは空扱い(除外) ──

@test "T-HREV-016: parse_review_body_mentions treats a whitespace-only body as empty" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[
    {"author":{"login":"halsk"},"state":"COMMENTED","body":"   \n\t  ","createdAt":"2026-09-09T05:45:11Z"}
  ]}}}}}'

  run parse_review_body_mentions "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-017: parse_review_body_mentions — bodyがnullの場合も除外 ──

@test "T-HREV-017: parse_review_body_mentions excludes a null body" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[
    {"author":{"login":"halsk"},"state":"COMMENTED","body":null,"createdAt":"2026-09-09T05:45:11Z"}
  ]}}}}}'

  run parse_review_body_mentions "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-018: parse_review_body_mentions — bot発のreview bodyは(非空でも)除外 ──

@test "T-HREV-018: parse_review_body_mentions never counts a bot even with a non-empty body" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[
    {"author":{"login":"coderabbitai"},"state":"COMMENTED","body":"some suggestion","createdAt":"2026-08-25T02:19:15Z"}
  ]}}}}}'

  run parse_review_body_mentions "$json" "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-019: check_pagination_shortfall — fetch件数がtotalCountを下回れば警告 ──

@test "T-HREV-019: check_pagination_shortfall warns when fetched nodes fall short of totalCount" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":5,"nodes":[{},{}]},"reviews":{"totalCount":3,"nodes":[{}]}}}}}'

  run check_pagination_shortfall "$json"
  [ "$status" -eq 0 ]
  [[ "$output" == "reviewThreads: fetched 2/5, reviews: fetched 1/3" ]]
}

# ── T-HREV-020: check_pagination_shortfall — fetch件数がtotalCountと一致すれば空 ──

@test "T-HREV-020: check_pagination_shortfall returns empty when fetched nodes match totalCount" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"nodes":[{},{}]},"reviews":{"totalCount":1,"nodes":[{}]}}}}}'

  run check_pagination_shortfall "$json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-021: detect_review_ball_holders_for_pr — review本文カテゴリが
# 既存の差し戻し中/resolve待ちと並列にbreakdownへ混ざり、既存判定へは
# 非干渉であること(PR#131実例を拡張したフィクスチャ) ──

@test "T-HREV-021: detect_review_ball_holders_for_pr mixes review-body-present category alongside existing categories without altering them" {
  source "$LIB_FILE"

  fetch_pr_review_data() {
    echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","reviewDecision":"CHANGES_REQUESTED","commits":{"nodes":[{"commit":{"committedDate":"2026-08-20T00:00:00Z"}}]},"reviewThreads":{"totalCount":2,"nodes":[
      {"isResolved":false,"comments":{"nodes":[{"author":{"login":"halsk"},"createdAt":"2026-06-27T06:19:54Z"}]}},
      {"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"createdAt":"2026-08-21T06:52:50Z"}]}}
    ]},"reviews":{"totalCount":2,"nodes":[
      {"author":{"login":"coderabbitai"},"state":"COMMENTED","body":null,"createdAt":"2026-08-21T06:52:50Z"},
      {"author":{"login":"yuiseki"},"state":"CHANGES_REQUESTED","body":"直してください","createdAt":"2026-08-25T00:32:44Z"}
    ]}}}}}'
  }

  run detect_review_ball_holders_for_pr "geolonia" "geonicdb-console" 131 \
    "https://github.com/geolonia/geonicdb-console/pull/131" "$BOTS"
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/geolonia/geonicdb-console/pull/131|3|2026-06-27T06:19:54Z|差し戻し中(足軽)x2,review本文あり(yuiseki氏)x1" ]]
}

# ── T-HREV-022: detect_review_ball_holders_for_pr — totalCount不足時は
# 標準エラー出力へ警告を出す(戻り値=stdoutは変えない) ──

@test "T-HREV-022: detect_review_ball_holders_for_pr emits a pagination warning to stderr without altering stdout" {
  source "$LIB_FILE"

  fetch_pr_review_data() {
    echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","reviewDecision":null,"commits":{"nodes":[]},"reviewThreads":{"totalCount":5,"nodes":[]},"reviews":{"totalCount":3,"nodes":[]}}}}}'
  }

  run --separate-stderr detect_review_ball_holders_for_pr "geolonia" "somewhere" 1 \
    "https://github.com/geolonia/somewhere/pull/1" "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"totalCount不足"* ]]
  [[ "$stderr" == *"reviewThreads: fetched 0/5"* ]]
  [[ "$stderr" == *"reviews: fetched 0/3"* ]]
}

# ── T-HREV-014: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-HREV-014: stall_watchdog.sh sources human_review_detect.sh and invokes the check" {
  grep -q "human_review_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_unresolved_human_reviews" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "detect_review_ball_holders_for_pr" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}

# ── cmd_793拡張: 上流PR追跡(著者=我ら・レビュー0件・OPEN放置の検知) ─────────
# フィクスチャの日付は実測固定値: 2026-09-07T00:00:00Zは月曜日、
# 2026-09-09T00:00:00Zは水曜日(2営業日後)、2026-09-10T00:00:00Zは木曜日
# (3営業日後)——`TZ=UTC date -j -f`で確認済み(epoch: 1788739200 / 1788912000
# / 1788998400)。

# ── T-HREV-023: count_business_days_since — 月曜0時から木曜0時まで3営業日 ──

@test "T-HREV-023: count_business_days_since counts Mon 00:00 to Thu 00:00 as 3 business days" {
  source "$LIB_FILE"

  run count_business_days_since 1788739200 1788998400
  [ "$status" -eq 0 ]
  [[ "$output" == "3" ]]
}

# ── T-HREV-024: count_business_days_since — 週末(土)を跨いでも土日は加算しない ──

@test "T-HREV-024: count_business_days_since skips weekend days when spanning Mon to Sat" {
  source "$LIB_FILE"

  # Mon 00:00 → Sat 00:00 (5 calendar days later, epoch 1789171200):
  # 加算されるのは Tue/Wed/Thu/Fri の4日のみ(Satは含めない)
  run count_business_days_since 1788739200 1789171200
  [ "$status" -eq 0 ]
  [[ "$output" == "4" ]]
}

# ── T-HREV-025: count_business_days_since — 同一時刻(経過0)は0 ──

@test "T-HREV-025: count_business_days_since returns 0 for zero elapsed time" {
  source "$LIB_FILE"

  run count_business_days_since 1788739200 1788739200
  [ "$status" -eq 0 ]
  [[ "$output" == "0" ]]
}

# ── T-HREV-026: parse_unreviewed_authored_pr — OPEN・著者一致・レビュー0件・
# 閾値到達 → created_at|elapsed_daysを返す ──

@test "T-HREV-026: parse_unreviewed_authored_pr flags an OPEN, zero-review, authored PR past the threshold" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"state":"OPEN","author":{"login":"halsk"},"createdAt":"2026-09-07T00:00:00Z","reviews":{"totalCount":0,"nodes":[]}}}}}'

  run parse_unreviewed_authored_pr "$json" "halsk" 3 1788998400 "$BOTS"
  [ "$status" -eq 0 ]
  [[ "$output" == "2026-09-07T00:00:00Z|3" ]]
}

# ── T-HREV-027: parse_unreviewed_authored_pr — 閾値未到達(2営業日<3)は非検知 ──

@test "T-HREV-027: parse_unreviewed_authored_pr does not flag before the threshold is reached" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"state":"OPEN","author":{"login":"halsk"},"createdAt":"2026-09-07T00:00:00Z","reviews":{"totalCount":0,"nodes":[]}}}}}'

  run parse_unreviewed_authored_pr "$json" "halsk" 3 1788912000 "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-028: parse_unreviewed_authored_pr — state!=OPEN(MERGED)は非検知 ──

@test "T-HREV-028: parse_unreviewed_authored_pr never flags a non-OPEN PR" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"state":"MERGED","author":{"login":"halsk"},"createdAt":"2026-09-07T00:00:00Z","reviews":{"totalCount":0,"nodes":[]}}}}}'

  run parse_unreviewed_authored_pr "$json" "halsk" 3 1788998400 "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-029: parse_unreviewed_authored_pr — 著者が違えば非検知(同僚のPRは対象外) ──

@test "T-HREV-029: parse_unreviewed_authored_pr does not flag a PR authored by someone else" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"state":"OPEN","author":{"login":"dkastl"},"createdAt":"2026-09-07T00:00:00Z","reviews":{"totalCount":0,"nodes":[]}}}}}'

  run parse_unreviewed_authored_pr "$json" "halsk" 3 1788998400 "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-030: parse_unreviewed_authored_pr — reviews.totalCount>=1なら非検知
# (誰かがレビュー済みならこの検知の射程外・既存check_unresolved_human_reviewsの範疇) ──

@test "T-HREV-030: parse_unreviewed_authored_pr does not flag a PR that already has at least one review" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"state":"OPEN","author":{"login":"halsk"},"createdAt":"2026-09-07T00:00:00Z","reviews":{"totalCount":1,"nodes":[{"author":{"login":"dkastl"},"state":"COMMENTED"}]}}}}}'

  run parse_unreviewed_authored_pr "$json" "halsk" 3 1788998400 "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-034: parse_unreviewed_authored_pr — FU-A是正回帰: レビューが
# bot(coderabbitai)のみでも「人間レビュー0件」として検知すること
# (workflow-portal#166実例の再現・totalCount==1だがbot専任だった) ──

@test "T-HREV-034: parse_unreviewed_authored_pr flags a PR whose only review is from a bot (FU-A regression guard)" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"state":"OPEN","author":{"login":"halsk"},"createdAt":"2026-09-07T00:00:00Z","reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai"},"state":"COMMENTED"}]}}}}}'

  run parse_unreviewed_authored_pr "$json" "halsk" 3 1788998400 "$BOTS"
  [ "$status" -eq 0 ]
  [[ "$output" == "2026-09-07T00:00:00Z|3" ]]
}

# ── T-HREV-035: parse_unreviewed_authored_pr — bot+人間の混在なら
# 人間レビューが1件でもあれば非検知(bot除外のロジックが人間まで
# 巻き込まないことの確認) ──

@test "T-HREV-035: parse_unreviewed_authored_pr does not flag when a bot review is mixed with a human review" {
  source "$LIB_FILE"

  json='{"data":{"repository":{"pullRequest":{"state":"OPEN","author":{"login":"halsk"},"createdAt":"2026-09-07T00:00:00Z","reviews":{"totalCount":2,"nodes":[{"author":{"login":"coderabbitai"},"state":"COMMENTED"},{"author":{"login":"dkastl"},"state":"COMMENTED"}]}}}}}'

  run parse_unreviewed_authored_pr "$json" "halsk" 3 1788998400 "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-031: detect_unreviewed_authored_pr_for_pr — fetch+parseを結合し
# pr_url付きで返す ──

@test "T-HREV-031: detect_unreviewed_authored_pr_for_pr prefixes the match with pr_url" {
  source "$LIB_FILE"

  fetch_pr_review_data() {
    echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","author":{"login":"halsk"},"createdAt":"2026-09-07T00:00:00Z","reviews":{"totalCount":0,"nodes":[]}}}}}'
  }

  # now_epochは関数内部でdate -u +%sを実測するため、遠い過去日付
  # (2026-09-07)を使い、実行時刻が何であってもthreshold=3を確実に超える
  # ようにする(テストの実行日に依存しないための設計)。
  run detect_unreviewed_authored_pr_for_pr "geolonia" "geonicdb" 999 \
    "https://github.com/geolonia/geonicdb/pull/999" "halsk" 3 "$BOTS"
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/geolonia/geonicdb/pull/999|2026-09-07T00:00:00Z|"* ]]
}

# ── T-HREV-032: detect_unreviewed_authored_pr_for_pr — fetch失敗(空JSON)は空 ──

@test "T-HREV-032: detect_unreviewed_authored_pr_for_pr returns empty when fetch fails" {
  source "$LIB_FILE"

  fetch_pr_review_data() { echo ""; }

  run detect_unreviewed_authored_pr_for_pr "geolonia" "geonicdb" 999 \
    "https://github.com/geolonia/geonicdb/pull/999" "halsk" 3 "$BOTS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── T-HREV-036: detect_unreviewed_authored_pr_for_pr — FU-1是正回帰: reviews
# のfetch件数がtotalCountを下回る(50件超のpagination取りこぼし)場合、
# stderrへ警告を出しつつstdout(判定結果)は変えないこと ──

@test "T-HREV-036: detect_unreviewed_authored_pr_for_pr emits a pagination warning to stderr without altering stdout (FU-1 regression guard)" {
  source "$LIB_FILE"

  fetch_pr_review_data() {
    echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","author":{"login":"halsk"},"createdAt":"2026-09-07T00:00:00Z","reviewThreads":{"totalCount":0,"nodes":[]},"reviews":{"totalCount":51,"nodes":[]}}}}}'
  }

  run --separate-stderr detect_unreviewed_authored_pr_for_pr "geolonia" "geonicdb" 999 \
    "https://github.com/geolonia/geonicdb/pull/999" "halsk" 3 "$BOTS"
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/geolonia/geonicdb/pull/999|2026-09-07T00:00:00Z|"* ]]
  [[ "$stderr" == *"totalCount不足"* ]]
  [[ "$stderr" == *"reviews: fetched 0/51"* ]]
}

# ── T-HREV-033: stall_watchdog.sh が新検知を実際に呼び出し、REVIEW_REPO_REGISTRY
# に geolonia/geonicdb を含んでいる(cmd_793相乗り確認) ──

@test "T-HREV-033: stall_watchdog.sh wires up check_unreviewed_authored_prs and registers geolonia/geonicdb" {
  grep -qE "check_unreviewed_authored_prs" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "detect_unreviewed_authored_pr_for_pr" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "^geolonia/geonicdb" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}
