#!/usr/bin/env bash
set -euo pipefail

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

mkdir -p logs queue/inbox

ensure_inbox_file() {
    local agent="$1"
    if [ ! -f "queue/inbox/${agent}.yaml" ]; then
        printf 'messages: []\n' > "queue/inbox/${agent}.yaml"
    fi
}

pane_exists() {
    local pane="$1"
    tmux list-panes -t "$pane" >/dev/null 2>&1
}

# Resolve pane address by @agent_id metadata — works with any pane-base-index
resolve_pane_by_agent_id() {
    local agent_id="$1"
    if [ "$agent_id" = "shogun" ]; then
        echo "shogun:main"
        return 0
    fi
    tmux list-panes -a -F '#{session_name}:#{window_name}.#{pane_index} #{@agent_id}' 2>/dev/null \
        | awk -v id="$agent_id" '$2 == id { print $1; exit }'
}

start_watcher_if_missing() {
    local agent="$1"
    local log_file="$2"
    local pane
    local cli

    ensure_inbox_file "$agent"

    pane=$(resolve_pane_by_agent_id "$agent")
    if [ -z "$pane" ] || ! pane_exists "$pane"; then
        return 0
    fi

    if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
        return 0
    fi

    cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null || echo "codex")
    nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 &
}

launch_ntfy_listener() {
    local log_file="$1"
    nohup bash scripts/ntfy_listener.sh >> "$log_file" 2>&1 &
}

start_ntfy_listener_if_missing() {
    local log_file="logs/ntfy_listener.log"
    if pgrep -f "bash scripts/ntfy_listener.sh" >/dev/null 2>&1; then
        return 0
    fi
    launch_ntfy_listener "$log_file"
}

ALL_AGENTS=(shogun karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7 gunshi gunshi2)

# ─── D006-safe watcher swap-in (cmd_760 item③) ───
# D006 (kill系統無条件禁止) を破らずに、稼働中の inbox_watcher.sh に新しい
# コードを反映させる仕組み。kill/pkill等でプロセスを終了させるのではなく、
# 「停止フラグファイル」を置くだけに留める — 実際にプロセスを終了させるのは
# 対象プロセス自身(inbox_watcher.shのメインループが自らフラグを検知しexit 0
# する、cooperative shutdown)。プロセスを外部から終了させる行為が一切無い
# ため、D006に抵触しない。
#
# 終了後は、このスクリプト自身(watcher_supervisor.sh)が既存のstart_watcher_
# if_missingループ(5秒毎pgrepポーリング)で「不在」を検知し、自動的に
# 最新のscripts/inbox_watcher.shを読み込んで再起動する。bashスクリプトは
# 起動のたびにファイルを読むため、これだけで新コードへの完全な入れ替えが
# 完了する — 明示的な「新版を起動する」ステップは不要。
#
# 使い方: bash scripts/watcher_supervisor.sh stop <agent_id|all>
WATCHER_STOP_FLAG_DIR="${WATCHER_STOP_FLAG_DIR:-${IDLE_FLAG_DIR:-/tmp}}"

request_watcher_stop() {
    local agent="$1"
    touch "${WATCHER_STOP_FLAG_DIR}/shogun_watcher_stop_${agent}"
    echo "[$(date)] [STOP-REQUEST] Stop flag placed for $agent (watcher will self-exit within one poll cycle, supervisor auto-restarts it with fresh code)" >&2
}

request_watcher_stop_all() {
    local agent
    for agent in "${ALL_AGENTS[@]}"; do
        request_watcher_stop "$agent"
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        stop)
            if [ -z "${2:-}" ]; then
                echo "Usage: $0 stop <agent_id|all>" >&2
                exit 1
            elif [ "$2" = "all" ]; then
                request_watcher_stop_all
            else
                request_watcher_stop "$2"
            fi
            exit 0
            ;;
        "")
            while true; do
                for agent in "${ALL_AGENTS[@]}"; do
                    start_watcher_if_missing "$agent" "logs/inbox_watcher_${agent}.log"
                done
                start_ntfy_listener_if_missing
                sleep 5
            done
            ;;
        *)
            echo "Usage: $0 [stop <agent_id|all>]" >&2
            exit 1
            ;;
    esac
fi
