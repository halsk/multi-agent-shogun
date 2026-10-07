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
#     → "<出所の絶対パス>|<kind>" の形で返す(kind は cwd または args)。
#       cwdが取れてそれが"/"でなければcwdを使う(kind=cwd)。
#       そうでなければコマンド行(args)の2番目以降(argv[0]=interpreterの絶対パスは
#       飛ばす・cmd_945事後是正B2)に現れる最初の絶対パストークンを使う(kind=args)。
#       いずれも取れなければ空文字を返す(系の道具を誤って拾わない側に倒す)。
#
#   olisten_under_roots <path> <roots>
#     → roots(改行区切り)のいずれかにpathが一致すれば0、しなければ1を返す。
#       根が"/"で終わる場合はdir境界判定(pathが根そのもの、または根/配下)、
#       根が"/"で終わらない場合は従来どおりの文字列前方一致とする
#       (/tmp/claude-のように意図して途中で切った根を壊さないため・cmd_945事後是正B1)。
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
#
# cmd_945事後是正B3: 実物のlsofは該当(待ち受け)が一つも無い時exit 1を返す([実測])。
# これを「lsof実行自体の失敗」と誤認しない三通りに分ける:
#   ① lsofコマンド自体が無い            → 失敗(非ゼロ・呼出元がERROR扱い)
#   ② exit 1 かつ 出力なし(=該当なし)  → 成功扱い(exit 0・空出力)
#   ③ それ以外の非ゼロ(権限不足等)     → 失敗(非ゼロ・呼出元がERROR扱い)
_olisten_lsof_listen() {
  command -v lsof >/dev/null 2>&1 || return 127
  local out rc
  out=$(lsof -nP -iTCP -sTCP:LISTEN -F pcn 2>/dev/null)
  rc=$?
  if [[ "$rc" -eq 1 && -z "$out" ]]; then
    return 0
  fi
  [[ "$rc" -ne 0 ]] && return "$rc"
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}
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
    printf '%s|cwd' "$cwd"
    return
  fi

  # cmd_945事後是正B2: argv[0](interpreterの絶対パス。例 /opt/homebrew/.../node)は
  # 出所として採らない。npx・vite・PM2等はprocess.execPath(絶対パス)で子のnodeを
  # 起こすため、argv[0]を採ると本当のscriptのパスを見逃す。2番目以降の絶対パス
  # トークンを見る。
  local args
  args=$(_olisten_args "$pid")
  local -a toks
  read -ra toks <<< "$args"
  local i tok
  for (( i=1; i<${#toks[@]}; i++ )); do
    tok="${toks[$i]}"
    if [[ "$tok" == /* ]]; then
      printf '%s|args' "$tok"
      return
    fi
  done

  echo ""
}

# dir境界での一致判定: pathがprefixそのもの、またはprefix/配下であればtrue。
# prefixの末尾に/があっても無くても同じ判定になるよう正規化する。
_olisten_dir_boundary_match() {
  local path="$1" prefix="$2"
  local prefix_noslash="${prefix%/}"
  [[ "$path" == "$prefix_noslash" || "$path" == "$prefix_noslash"/* ]]
}

olisten_under_roots() {
  local path="$1" roots="$2"
  local root
  while IFS= read -r root; do
    [[ -z "$root" ]] && continue
    if [[ "$root" == */ ]]; then
      _olisten_dir_boundary_match "$path" "$root" && return 0
    else
      [[ "$path" == "$root"* ]] && return 0
    fi
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
    # cmd_945事後是正N1: ここもB1と同じdir境界判定へ揃える。素の前方一致だと
    # 例えばyt2obsidianの登録がyt2obsidian-other(別物・同port)も誤って除外する。
    _olisten_dir_boundary_match "$origin" "$prefix" || continue
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
    local host port scope origin_raw origin origin_kind
    host="${name%:*}"
    port="${name##*:}"
    scope=$(olisten_classify_host "$host")
    [[ "$scope" == "loopback" ]] && continue
    origin_raw=$(olisten_origin "$pid")
    [[ -z "$origin_raw" ]] && continue
    origin="${origin_raw%|*}"
    origin_kind="${origin_raw##*|}"
    olisten_under_roots "$origin" "$roots" || continue
    olisten_is_excluded "$origin" "$port" "$now" "$registry" && continue
    # cmd_945事後是正N2: 出所の種(cwd/args)を末尾に足す。呼出元(dashboard文面)が
    # 書き分けられるようにする(既存フィールドの並びは変えない)。
    echo "$pid|$port|$scope|$cmd|$origin|$(_olisten_etime "$pid")|$(_olisten_lstart "$pid")|$origin_kind"
  done
}
