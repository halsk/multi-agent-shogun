#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
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
#
# ★cmd_945事後是正B1是正の一環: cwdは根の「配下」(根そのものと等しい、ではなく)
# に正しく置く。旧実装は根が末尾/付きの文字列前方一致で、cwdが根そのもの
# (末尾/無し)だと根の不一致で落ちてしまい、本試験が守りたいloopback判定を
# 一切検めていなかった(軍師QC実測・M2=loopback skip行を消す変異でも16件
# 全て緑のまま)。cwdを根の配下の子pathへ置き直すことで、M2変異を当てれば
# 本試験が確実に落ちるようにする。

@test "T-OL-005: does not detect a loopback-only listener even when origin matches roots" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { printf 'p999\ncpython3\nn127.0.0.1:8787\n'; }
  _olisten_cwd() { echo "/Users/hal/tools/multi-agent-shogun/subproj"; }
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

# ── T-OL-015: cmd_945事後是正B1(a) — cwdが根そのもの(末尾/無し)でも拾う ──
# 軍師QC実測: lsofのcwdは末尾/を付けない。根がちょうどそのdir直下で動いている
# サーバを見逃さないことを確かめる。

@test "T-OL-015: detects a listener whose cwd equals the root directory itself (no trailing path)" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { printf 'p777\ncpython3\nn*:8787\n'; }
  _olisten_cwd() { echo "/Users/hal/tools/multi-agent-shogun"; }
  _olisten_args() { echo "python3 server.py"; }
  _olisten_etime() { echo "00:05"; }
  _olisten_lstart() { echo "Tue Oct  7 14:00:00 2026"; }

  roots="/Users/hal/tools/multi-agent-shogun/"

  run detect_orphan_listeners "$roots" "" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"777|8787|exposed_all|python3|/Users/hal/tools/multi-agent-shogun|"* ]]
}

# ── T-OL-016: cmd_945事後是正B1 回帰防止 — 根の末尾/で揃えた境界判定が
# 字面が似た兄弟dirまで誤って拾わないこと(exposed_all境界の負例) ──

@test "T-OL-016: a sibling directory whose name merely starts with the root string is not matched" {
  source "$LIB_FILE"
  roots="/Users/hal/tools/multi-agent-shogun/"
  run olisten_under_roots "/Users/hal/tools/multi-agent-shogun-evil-twin" "$roots"
  [ "$status" -eq 1 ]
}

# ── T-OL-017: cmd_945事後是正B1 回帰防止 — /tmp/claude-のように意図して
# 途中で切った根(末尾/無し)は従来どおり素の前方一致のままであること ──

@test "T-OL-017: a deliberately truncated root (no trailing slash) still matches by plain prefix" {
  source "$LIB_FILE"
  roots="/tmp/claude-"
  run olisten_under_roots "/tmp/claude-501/x/scratchpad" "$roots"
  [ "$status" -eq 0 ]
}

# ── T-OL-018: cmd_945事後是正B2 — interpreterをargv[0]の絶対パスで起こした時、
# argv[0]でなく2番目以降のscript絶対パスを出所として拾う(npx/vite/PM2等の実際の形) ──

@test "T-OL-018: picks the script's absolute path, not argv[0]'s interpreter path, as origin" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { printf 'p8131\ncnode\nn*:8131\n'; }
  _olisten_cwd() { echo "/"; }
  _olisten_args() { echo "/opt/homebrew/Cellar/node/26.0.0/bin/node /private/tmp/claude-501/x/scen/server.mjs"; }
  _olisten_etime() { echo "00:10"; }
  _olisten_lstart() { echo "Tue Oct  7 13:50:00 2026"; }

  roots="/private/tmp/claude-501/"

  run detect_orphan_listeners "$roots" "" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"8131|8131|exposed_all|node|/private/tmp/claude-501/x/scen/server.mjs|"* ]]
}

# ── T-OL-019: cmd_945事後是正N1 — 除外登録のdir境界判定が、字面が似た
# 兄弟dir(例 yt2obsidian-other・同port)まで誤って除外しないこと ──

@test "T-OL-019: an exclusion registered for one dir does not also suppress a sibling dir with a similar name" {
  source "$LIB_FILE"
  future_date=$(date -v+90d '+%Y-%m-%d' 2>/dev/null || date -d '+90 days' '+%Y-%m-%d')
  registry="/Users/hal/workspace/yt2obsidian|3500|${future_date}|テスト"
  run olisten_is_excluded "/Users/hal/workspace/yt2obsidian-other" "3500" "$(date '+%s')" "$registry"
  [ "$status" -eq 1 ]
}

# ── T-OL-020: cmd_945事後是正B3 — 実物のlsofがexit 1(該当なし)を返す場面でも
# ERRORにならず、正常に空出力として扱われること(_olisten_lsof_listen本体の検証・
# モックで上書きせず実装そのものを呼ぶ) ──

@test "T-OL-020: a genuine lsof exit-1-with-no-output (no listeners) is treated as success, not ERROR" {
  source "$LIB_FILE"
  lsof() { return 1; }
  run _olisten_lsof_listen
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

# ── T-OL-021: cmd_945事後是正B3 回帰防止 — lsofコマンド自体が存在しない場合は
# 引き続き失敗(非ゼロ)として扱われること ──

@test "T-OL-021: a missing lsof command still surfaces as a failure (non-zero exit)" {
  source "$LIB_FILE"
  command() {
    if [[ "$1" == "-v" && "$2" == "lsof" ]]; then
      return 1
    fi
    builtin command "$@"
  }
  run -127 _olisten_lsof_listen
}

# ── T-OL-022: cmd_945事後是正N2 — detect_orphan_listenersの出力が出所の種
# (cwd/args)を末尾フィールドへ書き分けること ──

@test "T-OL-022: detect_orphan_listeners appends the origin kind (cwd vs args) as the trailing field" {
  source "$LIB_FILE"

  _olisten_lsof_listen() { printf 'p1\ncnode\nn*:9001\n'; }
  _olisten_cwd() { echo "/Users/hal/workspace/proj"; }
  _olisten_args() { echo "node server.js"; }
  _olisten_etime() { echo "00:01"; }
  _olisten_lstart() { echo "Tue Oct  7 13:00:00 2026"; }
  roots="/Users/hal/workspace/"
  run detect_orphan_listeners "$roots" "" "$(date '+%s')"
  [[ "$output" == *"|cwd" ]]

  _olisten_lsof_listen() { printf 'p2\ncnode\nn*:9002\n'; }
  _olisten_cwd() { echo "/"; }
  _olisten_args() { echo "/opt/homebrew/bin/node /Users/hal/workspace/proj/server.js"; }
  run detect_orphan_listeners "$roots" "" "$(date '+%s')"
  [[ "$output" == *"|args" ]]
}

# ── T-OL-014: stall_watchdog.sh がこのlibを実際に相乗りさせている(相乗り確認) ──

@test "T-OL-014: stall_watchdog.sh sources orphan_listener_detect.sh and invokes the check" {
  grep -q "orphan_listener_detect.sh" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
  grep -qE "check_orphan_listeners|detect_orphan_listeners" "${PROJECT_ROOT}/scripts/stall_watchdog.sh"
}

# ── T-OL-023: cmd_945事後是正B4 — 根の列がmulti-agent-shogunのworktree
# 置き場所(/Users/hal/tools/multi-agent-shogun-wt-*・足軽の作業dir)を覆うこと。
# ★軍師QC2実測(queue/reports/gunshi_report_cmd945_orphan_listener_impl_qc2.yaml
# issue B4): B1の是正でdir境界判定になったため、/Users/hal/tools/
# multi-agent-shogun/の根は兄弟dir(-wt-*)に当たらない
# (cwd=/Users/hal/tools/multi-agent-shogun-wt-xで検知0件)。
# /tmp/claude-と同じく、意図して途中で切る前方一致の根を一行足す。

@test "T-OL-023: the real ORPHAN_LISTENER_ROOTS in stall_watchdog.sh detects a listener whose cwd is under a multi-agent-shogun-wt-* ashigaru worktree" {
  source "$LIB_FILE"

  # ★本番のORPHAN_LISTENER_ROOTS代入をstall_watchdog.shから直に切り出して使う
  # (スクリプト全体をsourceすると見回り本体が走ってしまうため、grepで安全に
  # 代入文だけを取り出すT-OL-014と同じ作法)。これにより、根の列へ一行足す
  # 前は実際に検知0件(RED)となり、足した後にのみ緑になる——手書きの根の列を
  # テスト内に複製するとテストが本番の値から乖離し続ける(今回のB4がまさに
  # それだった)ため、ここだけは本番の値そのものを読む。
  eval "$(sed -n '/^ORPHAN_LISTENER_ROOTS=/,/"$/p' "${PROJECT_ROOT}/scripts/stall_watchdog.sh")"
  [[ -n "$ORPHAN_LISTENER_ROOTS" ]]

  _olisten_lsof_listen() { printf 'p8131\ncnode\nn*:8131\n'; }
  _olisten_cwd() { echo "/Users/hal/tools/multi-agent-shogun-wt-ashigaru1-x"; }
  _olisten_args() { echo "node server.js"; }
  _olisten_etime() { echo "00:03"; }
  _olisten_lstart() { echo "Tue Oct  7 14:30:00 2026"; }

  run detect_orphan_listeners "$ORPHAN_LISTENER_ROOTS" "" "$(date '+%s')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"8131|8131|exposed_all|node|/Users/hal/tools/multi-agent-shogun-wt-ashigaru1-x|"* ]]
}

@test "T-OL-024: ORPHAN_LISTENER_ROOTS does not blanket the whole /Users/hal/tools/ tree (false-positive guard)" {
  eval "$(sed -n '/^ORPHAN_LISTENER_ROOTS=/,/"$/p' "${PROJECT_ROOT}/scripts/stall_watchdog.sh")"
  [[ "$ORPHAN_LISTENER_ROOTS" != *$'\n/Users/hal/tools/\n'* ]]
  [[ "$ORPHAN_LISTENER_ROOTS" != *$'\n/Users/hal/tools/'$'\n'* ]]
  ! grep -qx "/Users/hal/tools/" <<< "$ORPHAN_LISTENER_ROOTS"
}
