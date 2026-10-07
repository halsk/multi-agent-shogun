#!/usr/bin/env bash
# lib/orphan_listener_detect.sh — cmd_945事後是正③: 止め忘れサーバ(orphan listener)の
# 見回りを行う純関数ライブラリ。
#
# 背景: 殿のご指示(2026-10-07・将軍経由)「止め忘れの見回り(全ての口で待ち受ける
# node/vite/python等で、家中の作業のdirから起きたものを見つけてdashboardに出す。
# killは殿の手)を仕組みとして作る」を受け、設計
# (queue/reports/cmd945_orphan_listener_watchdog_design.md)に基づき実装する。
# ★単独の新規監視機構は作らず、既存 scripts/stall_watchdog.sh
# (lib/stale_errlog_detect.sh 等と同じ相乗り作法)へ相乗りする前提のライブラリ。
# tmux/flock非依存・単体テスト可能(source して直接呼べる)。
#
# 検知条件は「LANから届く口で待ち受けている」かつ「家中の作業dirから起きた」の
# 両方を満たすことで、kill は一切行わない(D006・殿の手)。
#
# 提供関数:
#   olisten_classify_host <host>
#     → "exposed_all"(*・0.0.0.0・[::]) / "exposed_specific"(具体のLAN/Tailscale IP) /
#       "loopback"(127.*・[::1]・localhost)
#
#   olisten_origin <pid>
#     → 出所の絶対パス。cwdが取れてそれが"/"でなければcwdを使う。
#       そうでなければコマンド行(args)に現れる最初の絶対パストークンを使う。
#       いずれも取れなければ空文字を返す(系の道具を誤って拾わない側に倒す)。
#
#   olisten_under_roots <path> <roots>
#     → roots(改行区切りの前方一致パターン)のいずれかにpathが前方一致すれば0、
#       しなければ1を返す。
#
#   olisten_is_excluded <origin> <port> <now_epoch> <registry>
#     → registry(各行 "出所dirの前方一致|port(または*)|期限YYYY-MM-DD|裁可の出所")の
#       いずれかに一致し、かつ期限が未来であれば0(除外する)、そうでなければ1。
#       ★cmd_787⑩: 除外は期限付きのみ許可する(恒久除外の温床にしない)。
#       期限が過ぎれば自動的に判定対象へ再浮上する。
#
#   detect_orphan_listeners <roots> <registry> <now_epoch>
#     → 該当ごとに "<pid>|<port>|<scope>|<cmd>|<origin>|<etime>|<lstart>" を1行出力する。
#       lsofの実行自体が失敗した(コマンドが無い等)場合は、黙って「異常なし」
#       (空出力)とせず "ERROR|<detail>" を1行だけ出力する(失敗が失敗として
#       現れるようにする・殿6条)。lsofが正常実行され単に該当が無い場合は
#       空出力のままとし、ERRORと区別する。
#
# 試験で差し替える包み(既定は実コマンド。試験ではこれらを再定義して差し替える):
_olisten_lsof_listen() { lsof -nP -iTCP -sTCP:LISTEN -F pcn 2>/dev/null; }
_olisten_cwd()        { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }
_olisten_args()       { ps -o args= -p "$1" 2>/dev/null; }
_olisten_etime()      { ps -o etime= -p "$1" 2>/dev/null | tr -d ' '; }
_olisten_lstart()     { ps -o lstart= -p "$1" 2>/dev/null; }   # PIDの使い回しを見分ける

olisten_classify_host() {
  local host="$1"
  case "$host" in
    '*'|'0.0.0.0'|'[::]')
      echo "exposed_all"
      ;;
    127.*|'[::1]'|localhost)
      echo "loopback"
      ;;
    *)
      echo "exposed_specific"
      ;;
  esac
}

olisten_origin() {
  local pid="$1"
  local cwd
  cwd=$(_olisten_cwd "$pid")
  if [[ -n "$cwd" && "$cwd" != "/" ]]; then
    echo "$cwd"
    return
  fi

  local args tok
  args=$(_olisten_args "$pid")
  for tok in $args; do
    if [[ "$tok" == /* ]]; then
      echo "$tok"
      return
    fi
  done

  echo ""
}

olisten_under_roots() {
  local path="$1" roots="$2"
  local root
  while IFS= read -r root; do
    [[ -z "$root" ]] && continue
    [[ "$path" == "$root"* ]] && return 0
  done <<< "$roots"
  return 1
}

_olisten_iso_date_to_epoch() {
  local iso="$1"
  [[ -z "$iso" ]] && { echo 0; return; }
  date -j -f '%Y-%m-%d' "$iso" '+%s' 2>/dev/null \
    || date -d "$iso" '+%s' 2>/dev/null \
    || echo 0
}

olisten_is_excluded() {
  local origin="$1" port="$2" now_epoch="$3" registry="$4"

  local prefix reg_port until_date _rest
  while IFS='|' read -r prefix reg_port until_date _rest; do
    [[ -z "$prefix" ]] && continue
    [[ "$origin" == "$prefix"* ]] || continue
    [[ "$reg_port" == "*" || "$reg_port" == "$port" ]] || continue

    local until_epoch
    until_epoch=$(_olisten_iso_date_to_epoch "$until_date")
    if [[ "$until_epoch" -gt 0 && "$now_epoch" -lt "$until_epoch" ]]; then
      return 0
    fi
  done <<< "$registry"
  return 1
}

detect_orphan_listeners() {
  local roots="$1" registry="$2" now="$3"

  local raw
  if ! raw=$(_olisten_lsof_listen); then
    echo "ERROR|lsofの実行に失敗した(コマンド無し・権限不足等の疑い)"
    return 0
  fi
  [[ -z "$raw" ]] && return 0

  local pid cmd name
  echo "$raw" | awk '
      /^p/ {pid=substr($0,2)} /^c/ {cmd=substr($0,2)}
      /^n/ {print pid "|" cmd "|" substr($0,2)}' |
  sort -u |
  while IFS='|' read -r pid cmd name; do
    [[ -z "$pid" ]] && continue
    local host port scope origin
    host="${name%:*}"
    port="${name##*:}"
    scope=$(olisten_classify_host "$host")
    [[ "$scope" == "loopback" ]] && continue
    origin=$(olisten_origin "$pid")
    [[ -z "$origin" ]] && continue
    olisten_under_roots "$origin" "$roots" || continue
    olisten_is_excluded "$origin" "$port" "$now" "$registry" && continue
    echo "$pid|$port|$scope|$cmd|$origin|$(_olisten_etime "$pid")|$(_olisten_lstart "$pid")"
  done
}
