#!/usr/bin/env bash
# lib/stale_errlog_detect.sh — cmd_767 相乗り: 常駐ジョブの StandardErrorPath が
# 非空のまま長期間放置されていないかを検知する純関数ライブラリ
#
# 背景 (cmd_786/787): logs/stall_watchdog.err.log に
# "md5sum: command not found" が4件残っており、最終更新日は2026-06-29。
# 実際のバグ(md5sum直呼び)は2026-06-30のcommit 656b838cで修理済みだったが、
# err.log自体は2ヶ月以上誰にも触られず放置されていた——「検知が無かったのでは
# なく、出ている声を聞く仕組みが無かった」。
#
# ★単独の新規監視機構は作らず、既存 scripts/stall_watchdog.sh
# (lib/heartbeat_detect.sh と同じ相乗り作法)へ相乗りする前提のライブラリ。
# tmux/flock非依存・単体テスト可能(source して直接呼べる)。
#
# 提供関数:
#   errlog_check_one <err_log_path> <max_age_sec> <now_epoch>
#     → "<status>|<detail>" を返す。status は ok / stale のいずれか
#       - ok   : ファイルが存在しない、または空、または最終更新から
#                max_age_sec 以内
#       - stale: 非空 かつ 最終更新から max_age_sec を超えて経過
#                (「非空のまま長期間触れられていない」= 誰も見ていない疑い)
#
#   detect_stale_errlogs <registry> <now_epoch>
#     → registry(複数行 "job_name|err_log_path|max_age_sec|excluded_until_iso")
#       の各行を判定し、excluded_until_iso が未来なら無視、そうでなくstaleの
#       ものだけ "job_name|status|detail" で列挙する。
#       excluded_until_iso は省略可(空なら常に判定対象)。
#       ★cmd_787⑩: 除外は期限付きのみ許可する(恒久除外の温床にしない・
#       gunshi2の轍を踏まない)。期限が過ぎれば自動的に判定対象へ再浮上する。

_errlog_mtime_epoch() {
  local file="$1"
  # macOS: stat -f %m。Linux(CI ubuntu-latest): stat -c %Y。
  stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null
}

_errlog_iso_to_epoch() {
  local iso="$1"
  [[ -z "$iso" ]] && { echo 0; return; }
  date -j -f '%Y-%m-%d' "$iso" '+%s' 2>/dev/null \
    || date -d "$iso" '+%s' 2>/dev/null \
    || echo 0
}

errlog_check_one() {
  local err_log_path="$1"
  local max_age_sec="$2"
  local now_epoch="$3"

  if [[ ! -f "$err_log_path" ]]; then
    echo "ok|"
    return
  fi

  local size
  size=$(wc -c < "$err_log_path" 2>/dev/null | tr -d ' ')
  if [[ -z "$size" || "$size" -eq 0 ]]; then
    echo "ok|"
    return
  fi

  local mtime age
  mtime=$(_errlog_mtime_epoch "$err_log_path")
  if [[ -z "$mtime" ]]; then
    echo "stale|mtimeが読めない(壊れている可能性)"
    return
  fi

  age=$(( now_epoch - mtime ))
  if [[ "$age" -gt "$max_age_sec" ]]; then
    local age_days=$(( age / 86400 ))
    echo "stale|非空(${size}B)のまま最終更新から${age_days}日経過(許容$(( max_age_sec / 86400 ))日超)・誰も確認していない疑い"
    return
  fi

  echo "ok|"
}

detect_stale_errlogs() {
  local registry="$1"
  local now_epoch="$2"

  local job_name err_log_path max_age_sec excluded_until
  while IFS='|' read -r job_name err_log_path max_age_sec excluded_until; do
    [[ -z "$job_name" ]] && continue

    if [[ -n "$excluded_until" ]]; then
      local excluded_until_epoch
      excluded_until_epoch=$(_errlog_iso_to_epoch "$excluded_until")
      if [[ "$excluded_until_epoch" -gt 0 && "$now_epoch" -lt "$excluded_until_epoch" ]]; then
        continue
      fi
    fi

    local result errlog_status detail
    result=$(errlog_check_one "$err_log_path" "$max_age_sec" "$now_epoch")
    errlog_status="${result%%|*}"
    detail="${result#*|}"
    [[ "$errlog_status" == "ok" ]] && continue
    printf '%s|%s|%s\n' "$job_name" "$errlog_status" "$detail"
  done <<< "$registry"
}
