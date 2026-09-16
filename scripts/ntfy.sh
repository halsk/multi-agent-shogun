#!/usr/bin/env bash
# SayTask通知 — ntfy.sh経由でスマホにプッシュ通知
# FR-066: ntfy認証対応 (Bearer token / Basic auth)
# cmd_811: 送信記録の追加+失敗の黙殺防止(curl終了コード/HTTPステータス検査)
# cmd_832: Title自動組立(機体/cmd番号/手番種別/所要)+型検証。
#
# 新インターフェース(推奨):
#   scripts/ntfy.sh --cmd cmd_NNN --kind <要承認|要操作|要確認|報告> \
#     --eta <所要見込み> --body <一文で中身> [--detail <詳細の在処>]
#
#   --cmd は省略可(cmdに紐づかぬ運用通知はTitleが「運用」表記になる。
#   これは型違反ではない)。--kind/--eta/--body を欠く、または --kind が
#   4種の外の値である場合は「型を欠いた呼び出し」として扱い、Titleに
#   ⚠️型未指定 マーカーを付けたうえで最も安全側(要確認)へ倒して送信する。
#   ★型を欠いていても送信そのものは止めない(通知が飛ばぬことの方が悪い)。
#
# 旧インターフェース(位置引数1つ・後方互換): scripts/ntfy.sh "本文"
#   これは常に「型を欠いた呼び出し」として扱われ、⚠️型未指定 マーカー付きで
#   送信される(呼び出し元の移行漏れがそうと判るようにするため)。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# NTFY_SETTINGS_FILE / NTFY_LOG_FILE / NTFY_BASE_URL: 回帰テストが本番の
# config/settings.yaml・logs/ntfy_send.log・実ntfy.shサーバへ触れずに
# 差し替えるための上書き口(deadman_switch.shのDEADMAN_*と同じ流儀)。
# 未指定時は本番と同じ既定値になり挙動は変わらない。
SETTINGS="${NTFY_SETTINGS_FILE:-$SCRIPT_DIR/config/settings.yaml}"
LOG_FILE="${NTFY_LOG_FILE:-$SCRIPT_DIR/logs/ntfy_send.log}"
BASE_URL="${NTFY_BASE_URL:-https://ntfy.sh}"

# ntfy_auth.sh読み込み
# shellcheck source=../lib/ntfy_auth.sh
source "$SCRIPT_DIR/lib/ntfy_auth.sh"

# ★送信記録にntfy_topicの値を書いてはならない(2026-09-13にlogs/ntfy_listener.log
# へ平文で3回漏れていた件・殿ご裁定=甲(topic継続使用)を前提に、今後も漏らさぬ)。
# 記録するのは時刻・本文の要約・成否のみ。
log_send() {
    local status="$1"
    local body_summary="$2"
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s status=%s body="%s"\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$status" "$body_summary" >> "$LOG_FILE"
}

# ログ用に本文を要約(改行除去+60文字丸め。topicは含まれない)
summarize_body() {
    local body="$1"
    body="${body//$'\n'/ }"
    if [ "${#body}" -gt 60 ]; then
        body="${body:0:60}…"
    fi
    printf '%s' "$body"
}

# --- 引数解析 ---
# 第一引数が "--" で始まらなければ旧インターフェース(位置引数1つ)とみなす。
CMD_ID=""
KIND=""
ETA=""
BODY=""
DETAIL=""
LEGACY_CALL=false

if [ $# -ge 1 ] && [[ "$1" != --* ]]; then
    LEGACY_CALL=true
    BODY="${1:-}"
else
    while [ $# -gt 0 ]; do
        case "$1" in
            --cmd)
                CMD_ID="${2:-}"
                shift 2 2>/dev/null || shift 1
                ;;
            --kind)
                KIND="${2:-}"
                shift 2 2>/dev/null || shift 1
                ;;
            --eta)
                ETA="${2:-}"
                shift 2 2>/dev/null || shift 1
                ;;
            --body)
                BODY="${2:-}"
                shift 2 2>/dev/null || shift 1
                ;;
            --detail)
                DETAIL="${2:-}"
                shift 2 2>/dev/null || shift 1
                ;;
            *)
                echo "ntfy.sh: 未知の引数を無視: $1" >&2
                shift 1
                ;;
        esac
    done
fi

# --- 型検証(★送信は止めない・欠けをそうと判る形にするだけ) ---
TYPE_INCOMPLETE=false
$LEGACY_CALL && TYPE_INCOMPLETE=true

if [ -z "$BODY" ]; then
    TYPE_INCOMPLETE=true
    BODY="(本文なし)"
fi

# cmd番号: 省略は「運用」(型違反ではない)。値はあるが cmd_NNN 形式でなければ型違反。
if [ -z "$CMD_ID" ]; then
    CMD_LABEL="運用"
elif [[ "$CMD_ID" =~ ^cmd_[0-9]+$ ]]; then
    CMD_LABEL="$CMD_ID"
else
    CMD_LABEL="$CMD_ID"
    TYPE_INCOMPLETE=true
fi

# 手番種別: 4つ以外(未指定含む)は型違反 → 最も安全側(要確認)へ倒す
KIND_VALID=false
for k in "要承認" "要操作" "要確認" "報告"; do
    [ "$KIND" = "$k" ] && KIND_VALID=true && break
done
if ! $KIND_VALID; then
    TYPE_INCOMPLETE=true
    KIND="要確認"
fi

# 所要見込み: 未指定は型違反。"-"(所要なし・報告向け)は明示値として許容する。
if [ -z "$ETA" ]; then
    TYPE_INCOMPLETE=true
    ETA="?"
fi

if $TYPE_INCOMPLETE; then
    echo "ntfy.sh: 型を欠いた呼び出し(cmd/kind/eta/bodyのいずれかが不足または不正)。Titleに⚠️マーカーを付けて送信を継続する。" >&2
fi

# 本文は「結論(--body)を先頭・詳細の在処(--detail)を後ろ」の順で固定合成する
# (末尾切り詰めに耐えるための強制)。
if [ -n "$DETAIL" ]; then
    MESSAGE="$BODY $DETAIL"
else
    MESSAGE="$BODY"
fi

BODY_SUMMARY="$(summarize_body "$MESSAGE")"

TOPIC=$(grep 'ntfy_topic:' "$SETTINGS" | awk '{print $2}' | tr -d '"')
if [ -z "$TOPIC" ]; then
  echo "ntfy_topic not configured in settings.yaml" >&2
  log_send "fail_no_topic" "$BODY_SUMMARY"
  exit 1
fi

# 認証引数を取得（設定がなければ空 = 後方互換）
AUTH_ARGS=()
while IFS= read -r line; do
    [ -n "$line" ] && AUTH_ARGS+=("$line")
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/ntfy_auth.env")

# ホスト識別絵文字 — どの環境から送信されたかTitleに表示
# tmux.conf の色分けと揃えた絵文字を使用 (Mac mini = 🍎、WSL2 = 🪟)
if [[ "$(uname)" == "Darwin" ]]; then
  HOST_EMOJI="🍎"
elif [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ "$(uname -r)" == *microsoft* ]]; then
  HOST_EMOJI="🪟"
else
  HOST_EMOJI="$(hostname)"
fi

# Titleの組み立ては本スクリプト側で行う(呼び出し側に文字列を組ませない)。
# 型: 機体 / cmd番号(または「運用」) / 手番種別(所要見込み)
WARN_MARK=""
$TYPE_INCOMPLETE && WARN_MARK="⚠️型未指定 "
TITLE="${HOST_EMOJI} ${WARN_MARK}${CMD_LABEL} ${KIND}(${ETA})"

# ★失敗を黙って呑まない(cmd_811): curl自身の終了コード(DNS失敗・接続不能等)と
# HTTPステータス(4xx/5xx)の両方を検査する。従来はcurl -sの出力を/dev/nullへ
# 捨て終了コードも見ておらず、topic誤り・通信断のいずれでも「成功したかのように」
# 終了していた(本日のsettings.yaml消失時にntfyが死んでいたのに誰も気づかなかった
# 病根)。
# shellcheck disable=SC2086
HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${AUTH_ARGS[@]}" \
  -H "Tags: outbound" \
  -H "Title: $TITLE" \
  -d "$MESSAGE" \
  "$BASE_URL/$TOPIC")
CURL_RC=$?

if [ "$CURL_RC" -ne 0 ]; then
  echo "ntfy send failed: curl exit code $CURL_RC (host unreachable or timed out)" >&2
  log_send "fail_curl_rc${CURL_RC}" "$BODY_SUMMARY"
  exit 1
fi

if [[ ! "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
  echo "ntfy send failed: HTTP $HTTP_STATUS" >&2
  log_send "fail_http${HTTP_STATUS}" "$BODY_SUMMARY"
  exit 1
fi

log_send "ok" "$BODY_SUMMARY"
