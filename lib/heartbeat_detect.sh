#!/usr/bin/env bash
# lib/heartbeat_detect.sh — cmd_767 第一層(心拍): 定期ジョブの last-run.json を
# 読み、実行が止まっている/失敗しているものを機械的に検知する純関数ライブラリ
#
# 背景: meeting-link sweep が2026-08-25〜09-05の13日間、一度も完走しなかったのに
# 誰も気づけなかった(cmd_749で修理済み・cmd_767は「なぜ気づけなかったか」が本題)。
# ★★★単独の新規監視機構を作らず、既存 scripts/stall_watchdog.sh (cmd_766/771で
# 同じ相乗り作法が確立済み: lib/ledger_mismatch_detect.sh 参照)へ相乗りする形で
# 使う前提のライブラリ。tmux/flock非依存・単体テスト可能(source して直接呼べる)。
#
# 各定期ジョブは lib/run_log.sh (本リポ) または halsk/automation
# scripts/lib/run-log.sh の規約で last-run.json を書く前提とする。
#
# 提供関数:
#   heartbeat_json_field <json_file> <field>
#     → last-run.json から1フィールドの値を1行で返す(無ければ空)
#
#   heartbeat_check_one <json_file> <max_interval_sec> <now_epoch>
#     → "<status>|<detail>" を返す。status は ok / stale / fail のいずれか
#       - stale: last-run.json が無い、または最終実行からmax_interval_secを
#         超えて経過している(実行自体が止まっている可能性)
#       - fail : last-run.json はあるが直近の exit が非0(実行はしたが失敗)
#
#   detect_stale_heartbeats <registry> <now_epoch>
#     → registry(複数行 "job_name|json_path|max_interval_sec")の各行を判定し、
#       ok でないものだけ "job_name|status|detail" で列挙する

heartbeat_json_field() {
  local json_file="$1"
  local field="$2"
  [[ -f "$json_file" ]] || return 0
  # 素朴なJSON("key": "value" または "key": number)を1行1値で拾う。
  # jq非依存(このMac機体にjqが常時入っている保証がないため・将軍実測方針に倣う)。
  grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"\|\"${field}\"[[:space:]]*:[[:space:]]*-\{0,1\}[0-9][0-9]*" "$json_file" \
    | head -1 \
    | sed -E 's/^"'"${field}"'"[[:space:]]*:[[:space:]]*"?//; s/"$//'
}

_hb_iso_to_epoch() {
  local iso="$1"
  [[ -z "$iso" ]] && { echo 0; return; }
  # macOS: date -j -f (末尾 %z オフセット付き ISO8601 前提)。Linux fallback は date -d。
  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$iso" '+%s' 2>/dev/null \
    || date -d "$iso" '+%s' 2>/dev/null \
    || echo 0
}

heartbeat_check_one() {
  local json_file="$1"
  local max_interval_sec="$2"
  local now_epoch="$3"

  if [[ ! -f "$json_file" ]]; then
    echo "stale|last-run.jsonが存在しない(一度も実行痕跡がない、またはpath設定誤り)"
    return
  fi

  local exit_code end_iso end_epoch age
  exit_code=$(heartbeat_json_field "$json_file" "exit")
  end_iso=$(heartbeat_json_field "$json_file" "end")
  end_epoch=$(_hb_iso_to_epoch "$end_iso")

  if [[ "$end_epoch" -eq 0 ]]; then
    echo "stale|last-run.jsonのendフィールドが読めない(壊れている可能性)"
    return
  fi

  age=$(( now_epoch - end_epoch ))

  if [[ -n "$exit_code" && "$exit_code" != "0" ]]; then
    echo "fail|直近の実行が失敗(exit=${exit_code}・終了から${age}s経過)"
    return
  fi

  if [[ "$age" -gt "$max_interval_sec" ]]; then
    echo "stale|最終実行終了から${age}s経過(許容${max_interval_sec}s超)・実行自体が止まっている可能性"
    return
  fi

  echo "ok|"
}

detect_stale_heartbeats() {
  local registry="$1"
  local now_epoch="$2"

  local job_name json_path max_interval result hb_status detail
  while IFS='|' read -r job_name json_path max_interval; do
    [[ -z "$job_name" ]] && continue
    result=$(heartbeat_check_one "$json_path" "$max_interval" "$now_epoch")
    hb_status="${result%%|*}"
    detail="${result#*|}"
    [[ "$hb_status" == "ok" ]] && continue
    printf '%s|%s|%s\n' "$job_name" "$hb_status" "$detail"
  done <<< "$registry"
}
