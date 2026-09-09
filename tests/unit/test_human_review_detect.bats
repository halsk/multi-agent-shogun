#!/usr/bin/env bats
#
# tests/unit/test_human_review_detect.bats
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

# ── T-HREV-014: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-HREV-014: stall_watchdog.sh sources human_review_detect.sh and invokes the check" {
  grep -q "human_review_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_unresolved_human_reviews" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "detect_review_ball_holders_for_pr" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}
