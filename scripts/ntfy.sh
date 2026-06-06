#!/usr/bin/env bash
# SayTask通知 — ntfy.sh経由でスマホにプッシュ通知
# FR-066: ntfy認証対応 (Bearer token / Basic auth)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.yaml"

# ntfy_auth.sh読み込み
# shellcheck source=../lib/ntfy_auth.sh
source "$SCRIPT_DIR/lib/ntfy_auth.sh"

TOPIC=$(grep 'ntfy_topic:' "$SETTINGS" | awk '{print $2}' | tr -d '"')
if [ -z "$TOPIC" ]; then
  echo "ntfy_topic not configured in settings.yaml" >&2
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

# shellcheck disable=SC2086
curl -s "${AUTH_ARGS[@]}" \
  -H "Tags: outbound" \
  -H "Title: $HOST_TAG" \
  -d "$1" \
  "https://ntfy.sh/$TOPIC" > /dev/null
