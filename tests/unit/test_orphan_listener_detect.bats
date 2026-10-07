#!/usr/bin/env bats
#
# tests/unit/test_orphan_listener_detect.bats
#
# cmd_945事後是正③: 止め忘れサーバ(LANから届く口で待ち受け、家中の作業dirから
# 起きた node/python/vite等)を検知する純関数のユニットテスト。
#
# 出所: queue/reports/cmd945_orphan_listener_watchdog_design.md §2.4・§10。
# ashigaru3のbenchサーバ(node・*:8131・cwd=/private/tmp/claude-501/…/scratchpad/scen)が
# 殿のお言葉より広く解釈され約24分LANへ開いたまま放置された実例への対応。
# ★killは行わない(D006・殿の手)。本libはdashboardへ出すための検知のみを担う。

setup() {
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LIB_FILE="${PROJECT_ROOT}/lib/orphan_listener_detect.sh"
}

# ── T-OL-001: olisten_classify_host — 全ての口(*)は exposed_all ──

@test "T-OL-001: classify_host treats '*' as exposed_all" {
  source "$LIB_FILE"
  run olisten_classify_host '*'
  [ "$status" -eq 0 ]
  [[ "$output" == "exposed_all" ]]
}

@test "T-OL-001b: classify_host treats '0.0.0.0' and '[::]' as exposed_all" {
  source "$LIB_FILE"
  run olisten_classify_host '0.0.0.0'
  [[ "$output" == "exposed_all" ]]
  run olisten_classify_host '[::]'
  [[ "$output" == "exposed_all" ]]
}

# ── T-OL-002: olisten_classify_host — loopback(127.0.0.1/[::1])は対象外 ──

@test "T-OL-002: classify_host treats 127.0.0.1 and [::1] as loopback" {
  source "$LIB_FILE"
  run olisten_classify_host '127.0.0.1'
  [[ "$output" == "loopback" ]]
  run olisten_classify_host '[::1]'
  [[ "$output" == "loopback" ]]
}

# ── T-OL-003: olisten_classify_host — 具体のLAN/Tailscale IPはexposed_specific ──

@test "T-OL-003: classify_host treats a concrete LAN/Tailscale IP as exposed_specific" {
  source "$LIB_FILE"
  run olisten_classify_host '100.70.115.18'
  [[ "$output" == "exposed_specific" ]]
}

# ── T-OL-004: detect_orphan_listeners ① *:8131 + scratchpad由来 → 拾う(実インシデント再現) ──

@test "T-OL-004: detects *:8131 listener whose origin is under the scratchpad root (the actual incident)" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { printf 'p12345\ncnode\nn*:8131\n'; }
  _olisten_cwd() { echo "/private/tmp/claude-501/-Users-hal-tools-multi-agent-shogun/scratchpad/scen"; }
  _olisten_args() { echo "node server.js"; }
  _olisten_etime() { echo "00:24"; }
  _olisten_lstart() { echo "Tue Oct  7 13:00:00 2026"; }

  roots="/Users/hal/workspace/
/Users/hal/tools/multi-agent-shogun/
/private/tmp/claude-501/"

  run detect_orphan_listeners "$roots" "" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"12345|8131|exposed_all|node|/private/tmp/claude-501"* ]]
}

# ── T-OL-005: detect_orphan_listeners ② 127.0.0.1/[::1] → 拾わぬ ──

@test "T-OL-005: does not detect a loopback-only listener even when origin matches roots" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { printf 'p999\ncpython3\nn127.0.0.1:8787\n'; }
  _olisten_cwd() { echo "/Users/hal/tools/multi-agent-shogun"; }
  _olisten_args() { echo "python3 server.py"; }
  _olisten_etime() { echo "20-00:00"; }
  _olisten_lstart() { echo "Mon Sep 17 09:00:00 2026"; }

  roots="/Users/hal/tools/multi-agent-shogun/"

  run detect_orphan_listeners "$roots" "" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

# ── T-OL-006: detect_orphan_listeners ③ 具体のLAN IP → 拾う ──

@test "T-OL-006: detects a listener bound to a concrete LAN IP (not just '*')" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { printf 'p555\ncnode\nn100.70.115.18:3000\n'; }
  _olisten_cwd() { echo "/Users/hal/workspace/geonicdb-console-wt1"; }
  _olisten_args() { echo "node server.js"; }
  _olisten_etime() { echo "01:00:00"; }
  _olisten_lstart() { echo "Tue Oct  7 12:00:00 2026"; }

  roots="/Users/hal/workspace/"

  run detect_orphan_listeners "$roots" "" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"555|3000|exposed_specific|node|/Users/hal/workspace/geonicdb-console-wt1"* ]]
}

# ── T-OL-007: detect_orphan_listeners ④ cwd=/ の系の道具 → 拾わぬ ──

@test "T-OL-007: does not detect a system tool whose cwd is / and whose args carry no absolute path under roots" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { printf 'p1\ncControlCenter\nn*:7000\n'; }
  _olisten_cwd() { echo "/"; }
  _olisten_args() { echo "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"; }
  _olisten_etime() { echo "20-00:00"; }
  _olisten_lstart() { echo "Mon Sep 17 09:00:00 2026"; }

  roots="/Users/hal/workspace/
/Users/hal/tools/multi-agent-shogun/
/private/tmp/claude-501/"

  run detect_orphan_listeners "$roots" "" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

# ── T-OL-008: detect_orphan_listeners ⑤ 期限付き除外 — 期限内は拾わぬ、期限切れは拾う ──

@test "T-OL-008a: a registry entry whose expiry is in the future suppresses an otherwise-matching listener" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { printf 'p3500\ncnode\nn*:3500\n'; }
  _olisten_cwd() { echo "/Users/hal/workspace/yt2obsidian"; }
  _olisten_args() { echo "node index.js"; }
  _olisten_etime() { echo "20-00:00"; }
  _olisten_lstart() { echo "Mon Sep 17 09:00:00 2026"; }

  roots="/Users/hal/workspace/"
  future_date=$(date -v+90d '+%Y-%m-%d' 2>/dev/null || date -d '+90 days' '+%Y-%m-%d')
  registry="/Users/hal/workspace/yt2obsidian|3500|${future_date}|殿の常用道具(テスト用)"

  run detect_orphan_listeners "$roots" "$registry" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

@test "T-OL-008b: a registry entry whose expiry is in the past auto-resurfaces (cmd_787⑩)" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { printf 'p3500\ncnode\nn*:3500\n'; }
  _olisten_cwd() { echo "/Users/hal/workspace/yt2obsidian"; }
  _olisten_args() { echo "node index.js"; }
  _olisten_etime() { echo "20-00:00"; }
  _olisten_lstart() { echo "Mon Sep 17 09:00:00 2026"; }

  roots="/Users/hal/workspace/"
  past_date=$(date -v-5d '+%Y-%m-%d' 2>/dev/null || date -d '-5 days' '+%Y-%m-%d')
  registry="/Users/hal/workspace/yt2obsidian|3500|${past_date}|殿の常用道具(テスト用・期限切れ)"

  run detect_orphan_listeners "$roots" "$registry" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"3500|3500|exposed_all|node|/Users/hal/workspace/yt2obsidian"* ]]
}

# ── T-OL-009: ⑧ 出所の取得に失敗(cwdもargsも絶対パスが取れない) → 拾わぬ ──

@test "T-OL-009: does not detect when origin cannot be determined at all" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { printf 'p2\ncrapportd\nn*:1234\n'; }
  _olisten_cwd() { echo ""; }
  _olisten_args() { echo "rapportd"; }
  _olisten_etime() { echo "20-00:00"; }
  _olisten_lstart() { echo "Mon Sep 17 09:00:00 2026"; }

  roots="/Users/hal/workspace/"

  run detect_orphan_listeners "$roots" "" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

# ── T-OL-010: 「失敗が失敗として現れる」— lsofの実行自体が失敗した時に
# 黙って「異常なし」(空出力)とせず、ERROR行を残す ──

@test "T-OL-010: a failed lsof invocation surfaces as an ERROR line, not silent emptiness" {
  source "$LIB_FILE"

  # lsofコマンド自体が存在しない/実行できない状況を再現(戻り値127・出力なし)
  _olisten_lsof_listen() { return 127; }

  roots="/Users/hal/workspace/"

  run detect_orphan_listeners "$roots" "" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ "$output" == ERROR\|* ]]
}

# ── T-OL-011: lsofが正常実行され、かつ該当なし(本当に何も待ち受けていない)は
# ERRORと区別され空出力のまま(誤ってERROR扱いしない) ──

@test "T-OL-011: a successful lsof invocation with genuinely no listeners is empty output, not an ERROR" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { return 0; }

  roots="/Users/hal/workspace/"

  run detect_orphan_listeners "$roots" "" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

# ── T-OL-012: olisten_under_roots / olisten_is_excluded の単体境界確認 ──

@test "T-OL-012: olisten_under_roots matches a prefix among multiple roots" {
  source "$LIB_FILE"
  roots="/Users/hal/workspace/
/Users/hal/tools/multi-agent-shogun/"
  run olisten_under_roots "/Users/hal/tools/multi-agent-shogun/foo" "$roots"
  [ "$status" -eq 0 ]
  run olisten_under_roots "/etc/foo" "$roots"
  [ "$status" -eq 1 ]
}

@test "T-OL-013: olisten_is_excluded matches on origin-dir prefix and port, ignoring PID" {
  source "$LIB_FILE"
  future_date=$(date -v+90d '+%Y-%m-%d' 2>/dev/null || date -d '+90 days' '+%Y-%m-%d')
  registry="/Users/hal/workspace/yt2obsidian|3500|${future_date}|テスト"
  run olisten_is_excluded "/Users/hal/workspace/yt2obsidian" "3500" "$(date '+%s')" "$registry"
  [ "$status" -eq 0 ]
  run olisten_is_excluded "/Users/hal/workspace/yt2obsidian" "9999" "$(date '+%s')" "$registry"
  [ "$status" -eq 1 ]
}

# ── T-OL-014: stall_watchdog.sh がこのlibを実際に相乗りさせている(相乗り確認) ──

@test "T-OL-014: stall_watchdog.sh sources orphan_listener_detect.sh and invokes the check" {
  grep -q "orphan_listener_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_orphan_listeners|detect_orphan_listeners" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}
