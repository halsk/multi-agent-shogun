#!/usr/bin/env bash
# SayTask通知 — ntfy.sh経由でスマホにプッシュ通知
# FR-066: ntfy認証対応 (Bearer token / Basic auth)
# cmd_811: 送信記録の追加+失敗の黙殺防止(curl終了コード/HTTPステータス検査)

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

BODY_SUMMARY="$(summarize_body "${1:-}")"

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

# ホスト識別タグ — どの環境から送信されたか通知タイトルに表示
# tmux.conf の色分けと揃えた絵文字を使用 (Mac mini = 🍎、WSL2 = 🪟)
if [[ "$(uname)" == "Darwin" ]]; then
  HOST_TAG="🍎 Mac mini"
elif [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ "$(uname -r)" == *microsoft* ]]; then
  HOST_TAG="🪟 WSL2"
else
  HOST_TAG="$(hostname)"
fi

# ★失敗を黙って呑まない(cmd_811): curl自身の終了コード(DNS失敗・接続不能等)と
# HTTPステータス(4xx/5xx)の両方を検査する。従来はcurl -sの出力を/dev/nullへ
# 捨て終了コードも見ておらず、topic誤り・通信断のいずれでも「成功したかのように」
# 終了していた(本日のsettings.yaml消失時にntfyが死んでいたのに誰も気づかなかった
# 病根)。
# shellcheck disable=SC2086
HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${AUTH_ARGS[@]}" \
  -H "Tags: outbound" \
  -H "Title: $HOST_TAG" \
  -d "${1:-}" \
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
