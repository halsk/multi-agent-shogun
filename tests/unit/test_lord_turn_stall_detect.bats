#!/usr/bin/env bats
#
# tests/unit/test_lord_turn_stall_detect.bats
#
# cmd_827 案4(最優先): dashboard.md🚨要対応節の「殿/将軍の手番待ち」自由記述
# entryが放置されていないかを検知する純関数のユニットテスト。
#
# HC_PING_URL_SWEEP(Healthchecks.io Keychain登録)が「殿/将軍の手番待ち」
# としてdashboard.mdに置かれたまま9日以上放置され誰も気づかなかった件
# (cmd_824調査)への対応。★実測で判明した重要な前提: 🚨要対応節内の
# 自由記述entry(- 🚨【...】形式)には機械可読なISO8601タイムスタンプが
# 1件も付いていない(既存の[heartbeat]等の機械生成entryのみ付いている)。
# よって本ライブラリはentry本文をparseするのではなく、呼出側
# (scripts/stall_watchdog.sh)が管理するstateへ「初めて観測した時刻」を
# 記録し経過時間を計算する設計を採る——lord_turn_check_oneはその
# 計算だけを担う純関数。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/lord_turn_stall_detect.sh"

  TMP_DIR="$(mktemp -d "$BATS_TMPDIR/lord_turn_stall_detect.XXXXXX")"
}

teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

# ── T-LT-001: 機械生成entry([tag]形式)は候補から除外される ──

@test "T-LT-001: auto-tag entries (半角角括弧) are excluded from candidates" {
  source "$LIB_FILE"

  run lord_turn_is_candidate "- 🚨 [orphan_cmd] cmd_824: 台帳status=in_progressだが誰にも割り当てられていない(孤児cmd) @ 2026-09-15T18:11:11+0900"
  [ "$status" -eq 1 ]
}

# ── T-LT-002: 自由記述の殿/将軍手番待ちentryは候補として検知される(実例) ──

@test "T-LT-002: free-text lord-turn entry (実際のcmd_824 dashboard文言) is a candidate" {
  source "$LIB_FILE"

  run lord_turn_is_candidate "- 🚨【cmd_824・道筋の採否をお願いしたい】検知の道筋4案を提示済み。作るか否かは将軍/殿のご判断。"
  [ "$status" -eq 0 ]
}

# ── T-LT-003: 「殿」「将軍」を含まない🚨entryは候補にならない(過検知防止) ──

@test "T-LT-003: entries without 殿/将軍 are not candidates (avoid over-broad match)" {
  source "$LIB_FILE"

  run lord_turn_is_candidate "- 🚨【discipline・cmd_800派生】ashigaru1がD006を回避——実害は無かったが看過してよいか。"
  [ "$status" -eq 1 ]
}

# ── T-LT-004: 「殿」を含んでも手番/裁可等のキーワードが無ければ候補にならない ──

@test "T-LT-004: mentioning 殿 without a decision keyword is not a candidate" {
  source "$LIB_FILE"

  run lord_turn_is_candidate "- ✅【殿の指示どおり実施済み】完了報告のみで判断待ちではない。"
  [ "$status" -eq 1 ]
}

# ── T-LT-005: lord_turn_extract_section が見出し直後〜次の見出し直前のみを抽出する ──

@test "T-LT-005: lord_turn_extract_section stops at the next '## ' heading" {
  source "$LIB_FILE"

  cat > "${TMP_DIR}/dashboard.md" <<'EOF'
# ダッシュボード

## 🚨 要対応 - 殿のご判断をお待ちしております (Action Required)
- 🚨【cmd_1・お願い】殿のご判断を仰ぐ。
- 🚨 [heartbeat] job-x: stale @ 2026-09-15T00:00:00+0900

## ❓ 伺い事項 (Questions for Lord)
なし (None)
EOF

  run lord_turn_extract_section "${TMP_DIR}/dashboard.md" '^## .*要対応.*殿のご判断|^## .*🚨.*要対応'
  [ "$status" -eq 0 ]
  [[ "$output" == *"cmd_1・お願い"* ]]
  [[ "$output" != *"伺い事項"* ]]
  [[ "$output" != *"なし (None)"* ]]
}

# ── T-LT-006: lord_turn_candidates が実際のdashboard構造から正しい候補のみ抽出する(統合) ──

@test "T-LT-006: lord_turn_candidates extracts only genuine lord-turn entries from a realistic fixture" {
  source "$LIB_FILE"

  cat > "${TMP_DIR}/dashboard.md" <<'EOF'
# ダッシュボード

## 🚨 要対応 - 殿のご判断をお待ちしております (Action Required)
- 🚨 [mgmt_bloat_watchdog] queue/reports/x.yaml がサイズ上限超過 @ 2026-09-15T18:42:24+0900
- 🚨【cmd_824・道筋の採否をお願いしたい】作るか否かは将軍/殿のご判断。
- 🚨 [orphan_cmd] cmd_826: 台帳status=in_progress @ 2026-09-15T18:28:55+0900
- ✅【家老確認】上記4件はいずれも誤検知。

## ⏳ 殿のご判断待ち (Pending Lord's Decision — No Action Needed from Karo)
なし (None)
EOF

  run lord_turn_candidates "${TMP_DIR}/dashboard.md"
  [ "$status" -eq 0 ]
  # 1行のみ候補として残る(自由記述の殿手番待ちentry)
  local candidate_count
  candidate_count=$(echo "$output" | grep -c '.' || true)
  [ "$candidate_count" -eq 1 ]
  [[ "$output" == *"cmd_824・道筋の採否"* ]]
  [[ "$output" != *"mgmt_bloat_watchdog"* ]]
  [[ "$output" != *"orphan_cmd"* ]]
}

# ── T-LT-007: "## ⏳ 殿のご判断待ち" 節内の非空entryは無条件で候補になる ──

@test "T-LT-007: non-empty bullets in the dedicated pending-decision section are candidates regardless of wording" {
  source "$LIB_FILE"

  cat > "${TMP_DIR}/dashboard.md" <<'EOF'
# ダッシュボード

## 🚨 要対応 - 殿のご判断をお待ちしております (Action Required)
- 🚨 [heartbeat] job-x: stale @ 2026-09-15T00:00:00+0900

## ⏳ 殿のご判断待ち (Pending Lord's Decision — No Action Needed from Karo)
- 予算超過の是非についてご検討ください(キーワード無し・文脈は本節にあることで判定)

## 🎯 スキル化候補 - 承認待ち (Skill Candidates - Pending Approval)
EOF

  run lord_turn_candidates "${TMP_DIR}/dashboard.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"予算超過の是非"* ]]
}

# ── T-LT-008: lord_turn_check_one — first_seen未設定 → new ──

@test "T-LT-008: lord_turn_check_one returns new when first_seen_iso is empty" {
  source "$LIB_FILE"

  run lord_turn_check_one "" "$(date '+%s')" 2
  [ "$status" -eq 0 ]
  [[ "$output" == "new|0" ]]
}

# ── T-LT-009: lord_turn_check_one — 閾値未満の経過 → waiting ──

@test "T-LT-009: lord_turn_check_one returns waiting when elapsed is below threshold" {
  source "$LIB_FILE"

  local_now=$(date '+%s')
  recent_iso=$(date -j -f '%s' "$((local_now - 3600))" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$((local_now - 3600))" '+%Y-%m-%dT%H:%M:%S%z')

  run lord_turn_check_one "$recent_iso" "$local_now" 2
  [ "$status" -eq 0 ]
  [[ "$output" == waiting\|* ]]
}

# ── T-LT-010(★最重要・擬似的に古いentryを置いて実際に発火することの実測): ──
# first_seenを2日以上前に設定すると stale になる

@test "T-LT-010: lord_turn_check_one fires 'stale' for an entry seeded 3 days in the past (threshold=2 days)" {
  source "$LIB_FILE"

  local_now=$(date '+%s')
  old_iso=$(date -j -f '%s' "$((local_now - 3 * 86400))" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$((local_now - 3 * 86400))" '+%Y-%m-%dT%H:%M:%S%z')

  run lord_turn_check_one "$old_iso" "$local_now" 2
  [ "$status" -eq 0 ]
  [[ "$output" == stale\|3 ]]
}

# ── T-LT-011(誤検知の実測・最重要): 正常な(閾値未満の)状態では絶対にstaleを返さない ──

@test "T-LT-011: lord_turn_check_one never fires 'stale' for a genuinely fresh entry (false-positive check)" {
  source "$LIB_FILE"

  local_now=$(date '+%s')
  fresh_iso=$(date -j -f '%s' "$((local_now - 60))" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$((local_now - 60))" '+%Y-%m-%dT%H:%M:%S%z')

  run lord_turn_check_one "$fresh_iso" "$local_now" 2
  [ "$status" -eq 0 ]
  [[ "$output" != stale\|* ]]
  [[ "$output" == "waiting|0" ]]
}

# ── T-LT-012: stall_watchdog.sh がこの check を実際に呼び出している(相乗り確認) ──

@test "T-LT-012: stall_watchdog.sh sources lord_turn_stall_detect.sh and invokes the check" {
  grep -q "lord_turn_stall_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_lord_turn_stalls|lord_turn_candidates" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}

# ── T-LT-013: 新規常駐機構(独自launchdジョブ)を作っていないことの確認 ──

@test "T-LT-013: no new standalone daemon/launchd job was introduced (piggyback-only check)" {
  run grep -qE 'launchctl (load|bootstrap)' "${LIB_FILE}"
  [ "$status" -ne 0 ]
}

# ── cmd_827 軍師QC N1是正: 語彙表の穴(「待ち」欠如・「判断」の裸形不一致) ──
# 実害2件(cmd_740・cmd_748)の実際のdashboard.md文言(家老が✅解決済みへ
# 書き換える★前)を再現して検証する。

@test "T-LT-014: cmd_740 wording (bare 判断, no ご/要 prefix) is now a candidate" {
  source "$LIB_FILE"

  run lord_turn_is_candidate "- 🚨【cmd_740・将軍判断求む】PR#125 mergeコンフリクト解消済み・残る判断は「main既存の赤10件」の扱い"
  [ "$status" -eq 0 ]
}

@test "T-LT-015: cmd_748 wording (待ち, no 判断/裁可/承認 keyword) is now a candidate" {
  source "$LIB_FILE"

  run lord_turn_is_candidate "- 🚨【cmd_748】Cursor Composer 2.5実測・殿のブラウザログイン待ち(1回のみ・金銭発生なし)"
  [ "$status" -eq 0 ]
}

@test "T-LT-016: bare 判断/待ち keywords still require 殿/将軍 (no over-broad match)" {
  source "$LIB_FILE"

  # 「判断」「待ち」を含むが「殿」「将軍」を含まない → 依然として非候補
  run lord_turn_is_candidate "- 🚨【discipline・cmd_800派生】レビュー待ち。マージ判断はチームで行う。"
  [ "$status" -eq 1 ]
}

@test "T-LT-017: auto-tag entries with 判断/待ち in body are still excluded (regression)" {
  source "$LIB_FILE"

  # 機械生成entry([tag]形式)は「殿」「判断」「待ち」を含んでいても除外され続ける
  run lord_turn_is_candidate "- 🚨 [orphan_cmd] cmd_999: 殿の判断待ちタグ付きだが機械生成のため除外 @ 2026-09-15T18:11:11+0900"
  [ "$status" -eq 1 ]
}
