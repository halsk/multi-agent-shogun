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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    while true; do
        for agent in "${ALL_AGENTS[@]}"; do
            start_watcher_if_missing "$agent" "logs/inbox_watcher_${agent}.log"
        done
        start_ntfy_listener_if_missing
        sleep 5
    done
fi
