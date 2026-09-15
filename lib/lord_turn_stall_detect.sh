#!/usr/bin/env bash
# lib/lord_turn_stall_detect.sh — cmd_827 案4(検知の道筋・最優先): dashboard.md
# 内の「殿/将軍の手番待ち」entryが放置されていないかを機械的に検知する
# 純関数ライブラリ。
#
# 背景(cmd_824調査・queue/reports/ashigaru5_report.yaml): meeting-link-sweep
# の停止は一次(stall_watchdog心拍)・二次(Healthchecks.io外部監視)いずれの
# 検知層でも実は検知に成功していたが、その後「殿/将軍の手番待ち」として
# dashboard.mdの🚨要対応節に置かれたまま9日以上放置され、誰にも再エスカレー
# ションされなかった。★実測(cmd_827)で判明した重要な訂正: 当初cmd_824報告は
# 「多くは@ISO8601形式で既に付与されている」としていたが、実測すると
# 🚨要対応節内でISO8601の「@ タイムスタンプ」を持つのは全て機械生成の
# 定型entry([heartbeat]・[orphan_cmd]等・110件)であり、家老が手書きする
# 「殿/将軍の手番待ち」自由記述entry(21件)には★1件もISO8601タグが
# 付いていなかった(2026-09-15実測)。よって本ライブラリは「entry本文の
# タイムスタンプをparseする」設計を採らず、★watchdog自身が候補entryを
# 初めて観測した時刻をqueue/stall_watchdog/配下の既存stateファイルへ
# 記録し、以後同一entryが存在し続ける限りの経過時間を計測する」という
# 自己参照型の設計に変更した(cmd_766のledger_mismatch・cmd_767の
# heartbeat・cmd_771のE4_SUPPRESS_LIMITと全く同じ「first_seen/first_bad_at
# を自state記録し経過時間を計算する」既存idiomへの相乗り)。
# ★★★単独の新規常駐監視機構は作らず、scripts/stall_watchdog.sh
# (5分毎launchd起動・既存)へsourceされ、そのstate_get/state_set関数
# (呼出側で定義済み)を使って呼び出される前提。
#
# 提供関数:
#   lord_turn_is_section_marker <line>
#     → dashboard.md の🚨要対応 節の見出し行かどうか(既存stall_watchdog.sh
#       の見出し正規表現と同一パターンを流用)
#
#   lord_turn_extract_section <dashboard_file> <marker_regex>
#     → marker_regexに一致する見出し行の次行から、次の "^## " 見出し行の
#       直前まで(またはEOFまで)を1行ずつ出力する
#
#   lord_turn_is_candidate <line>
#     → 🚨要対応節内の自由記述行(- 🚨【...】形式)のうち「殿」または
#       「将軍」+ 手番/裁可/判断/待ち等のキーワードを含む行を候補として true
#       を返す。既存の機械生成entry(- 🚨 [tag] 形式・半角角括弧)は
#       「殿」「将軍」を含んでいても除外する(それらは既にheartbeat等の
#       別チェックが個別に扱っており、二重計上を避ける)。
#       ★cmd_827軍師QC N1是正: 当初「ご判断」の完全形でしか一致せず裸の
#       「判断」(例: 「将軍判断求む」)を取りこぼしていた。また「待ち」
#       (例: 「殿のブラウザログイン待ち」)も語彙に無かった。両方を追加し、
#       「ご判断」は「判断」へ緩める形で包含した(「要判断」「ご判断」は
#       いずれも部分文字列として引き続き一致する)。
#
#   lord_turn_is_pending_bullet <line>
#     → "## ⏳ 殿のご判断待ち" 節(現状は運用上ほぼ「なし」だが、将来
#       ここへ書かれた場合は自由記述キーワード判定なしに全件を候補とする
#       専用節)内の非空行を候補として true を返す。
#
#   lord_turn_candidates <dashboard_file>
#     → 上記2節を走査し、候補行ごとに "<hash>|<line>" を1行ずつ出力する
#       (hashはmd5sum/shasumフォールバックの決定論的短縮ハッシュ)
#
#   lord_turn_check_one <first_seen_iso> <now_epoch> <threshold_days>
#     → "<status>|<elapsed_days>" を返す。statusは new(first_seen未設定・
#       呼出側が初回登録すべき) / waiting(経過中・未到達) / stale(閾値超過)
#       のいずれか。

LORD_TURN_SECTION_MARKER_REGEX='^## .*要対応.*殿のご判断|^## .*🚨.*要対応'
LORD_TURN_PENDING_MARKER_REGEX='^## .*⏳.*殿のご判断待ち'

lord_turn_is_section_marker() {
  local line="$1"
  [[ "$line" =~ 要対応.*殿のご判断 ]] && [[ "$line" == "## "* ]] && return 0
  [[ "$line" =~ 🚨.*要対応 ]] && [[ "$line" == "## "* ]] && return 0
  return 1
}

# marker_regex に一致する行の次行から、次の "^## " 見出しの直前まで(または
# EOFまで)を出力する。GNU/BSD 両awkのPOSIX ERE `~` 演算子のみに依存する。
lord_turn_extract_section() {
  local dashboard_file="$1"
  local marker_regex="$2"
  [[ -f "$dashboard_file" ]] || return 0
  awk -v pat="$marker_regex" '
    BEGIN { infound = 0 }
    $0 ~ pat { infound = 1; next }
    infound && /^## / { exit }
    infound { print }
  ' "$dashboard_file"
}

# 機械生成entry(半角角括弧 "🚨 [tag]" または "🚨[tag]")かどうか。
_lord_turn_is_auto_tag_line() {
  local line="$1"
  [[ "$line" =~ 🚨[[:space:]]*\[ ]]
}

lord_turn_is_candidate() {
  local line="$1"
  [[ "$line" == *"🚨"* ]] || return 1
  _lord_turn_is_auto_tag_line "$line" && return 1
  [[ "$line" == *"殿"* || "$line" == *"将軍"* ]] || return 1
  [[ "$line" =~ (手番|裁可|判断|お伺い|承認|仰ぐ|お願いしたい|確認願う|ご確認|ご下命|待ち) ]] || return 1
  [[ "$line" =~ ^[[:space:]]*(-|##)[[:space:]] ]] || return 1
  return 0
}

lord_turn_is_pending_bullet() {
  local line="$1"
  local trimmed="${line#"${line%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  [[ -z "$trimmed" ]] && return 1
  [[ "$trimmed" == "なし"* ]] && return 1
  return 0
}

# macOS: md5 は launchd PATH に無いため shasum を優先(scripts/stall_watchdog.sh
# の md5_short と同じフォールバック方針)。
_lord_turn_hash() {
  if command -v md5sum >/dev/null 2>&1; then
    echo "$1" | md5sum | cut -c1-12
  else
    echo "$1" | shasum | cut -c1-12
  fi
}

lord_turn_candidates() {
  local dashboard_file="$1"

  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    lord_turn_is_candidate "$line" || continue
    printf '%s|%s\n' "$(_lord_turn_hash "$line")" "$line"
  done < <(lord_turn_extract_section "$dashboard_file" "$LORD_TURN_SECTION_MARKER_REGEX")

  while IFS= read -r line; do
    lord_turn_is_pending_bullet "$line" || continue
    printf '%s|%s\n' "$(_lord_turn_hash "pending:$line")" "$line"
  done < <(lord_turn_extract_section "$dashboard_file" "$LORD_TURN_PENDING_MARKER_REGEX")
}

_lt_iso_to_epoch() {
  local iso="$1"
  [[ -z "$iso" ]] && { echo 0; return; }
  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$iso" '+%s' 2>/dev/null \
    || date -d "$iso" '+%s' 2>/dev/null \
    || echo 0
}

lord_turn_check_one() {
  local first_seen_iso="$1"
  local now_epoch="$2"
  local threshold_days="$3"

  if [[ -z "$first_seen_iso" ]]; then
    echo "new|0"
    return
  fi

  local first_epoch elapsed elapsed_days threshold_sec
  first_epoch=$(_lt_iso_to_epoch "$first_seen_iso")
  if [[ "$first_epoch" -eq 0 ]]; then
    echo "new|0"
    return
  fi

  elapsed=$(( now_epoch - first_epoch ))
  [[ "$elapsed" -lt 0 ]] && elapsed=0
  elapsed_days=$(( elapsed / 86400 ))
  threshold_sec=$(( threshold_days * 86400 ))

  if [[ "$elapsed" -ge "$threshold_sec" ]]; then
    echo "stale|${elapsed_days}"
  else
    echo "waiting|${elapsed_days}"
  fi
}
