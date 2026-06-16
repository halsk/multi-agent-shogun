#!/bin/bash
# migrate-secrets-to-op.sh
# WSL2 (hal-local-linux) で op unlock 後に実行:
#   bash ~/migrate-secrets-to-op.sh
# または (このファイルを scp してから):
#   scp <mac>:/Users/hal/tools/multi-agent-shogun/scripts/migrate-secrets-to-op.sh ~/
set -euo pipefail

ENV_FILE="${HOME}/services/ai-worker/.env"
VAULT_NAME="ai-worker"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found"; exit 1; }
op vault get "${VAULT_NAME}" > /dev/null 2>&1 || { echo "ERROR: vault '${VAULT_NAME}' not found. Run: op signin"; exit 1; }

get_env_value() {
    local key="$1"
    grep -E "^${key}=" "${ENV_FILE}" 2>/dev/null | head -1 | cut -d'=' -f2- | sed "s/^['\"]//;s/['\"]$//"
}

upsert_op_item() {
    local name="$1"
    local value="$2"
    local item_name="ai-worker-${name}"
    if [[ -z "$value" ]]; then
        echo "SKIP: ${item_name} (empty)"
        return
    fi
    if op item get "${item_name}" --vault "${VAULT_NAME}" > /dev/null 2>&1; then
        echo "UPDATE: ${item_name}"
        op item edit "${item_name}" --vault "${VAULT_NAME}" "password=${value}" > /dev/null
    else
        echo "CREATE: ${item_name}"
        op item create \
            --vault "${VAULT_NAME}" \
            --category "Login" \
            --title "${item_name}" \
            "username=${name}" \
            "password=${value}" > /dev/null
    fi
}

for KEY in PULL_TOKEN CLOUDFLARE_TUNNEL_TOKEN SLACK_BOT_TOKEN SLACK_SIGNING_SECRET \
           NOTION_TOKEN BOARD_API_KEY BOARD_TOKEN GITHUB_TOKEN ANTHROPIC_API_KEY N8N_API_KEY; do
    upsert_op_item "${KEY}" "$(get_env_value "${KEY}")"
done

# POSTGRES_PASSWORD: .env の値 or 新規生成
PG_PASS=$(get_env_value "POSTGRES_PASSWORD")
if [[ -z "$PG_PASS" ]]; then
    PG_PASS=$(openssl rand -base64 32)
    echo "GENERATE: ai-worker-POSTGRES_PASSWORD (新規生成)"
fi
upsert_op_item "POSTGRES_PASSWORD" "${PG_PASS}"
unset PG_PASS

# ★ N8N_ENCRYPTION_KEY (温存確定 — rotate 禁止): .env から読む。未設定なら対話入力。
# 事前確認コマンド:
#   docker compose -f ~/services/ai-worker/docker-compose.yml exec n8n printenv N8N_ENCRYPTION_KEY
ENC_KEY=$(get_env_value "N8N_ENCRYPTION_KEY")
if [[ -z "$ENC_KEY" ]]; then
    echo ""
    echo "★ N8N_ENCRYPTION_KEY が ${ENV_FILE} に見つかりません。"
    echo "  実行前に以下で実値を確認してください:"
    echo "    docker compose -f ~/services/ai-worker/docker-compose.yml exec n8n printenv N8N_ENCRYPTION_KEY"
    read -rsp "N8N_ENCRYPTION_KEY の実値を入力してください (非表示): " ENC_KEY
    echo ""
fi
upsert_op_item "N8N_ENCRYPTION_KEY" "${ENC_KEY}"
unset ENC_KEY

echo ""
echo "Done. 1Password ai-worker vault への 12 secrets 投入が完了しました。"
echo "op item list --vault ai-worker で確認ください (12 items が表示されること)。"
