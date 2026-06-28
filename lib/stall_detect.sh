#!/usr/bin/env bash
# lib/stall_detect.sh — pane テキストからエージェントの固着シグネチャを分類する純関数ライブラリ
#
# 提供関数:
#   classify_pane <text>  → "busy" / "idle" / "context_bloat" / "parse_error"
#
# tmux 非依存。単体テスト可能。

classify_pane() {
    local text="$1"

    # E1: spinner が動いている → busy (最優先・誤検知防止)
    # ✻ (Claude Code thinking) / ⏺ (recording/active) が末尾付近に存在
    if echo "$text" | grep -qE '✻|⏺'; then
        echo "busy"
        return 0
    fi

    # E1: status bar 'esc to' → 処理中 (agent_is_busy_check と同等の一次チェック)
    local last_line
    last_line=$(echo "$text" | grep -v '^[[:space:]]*$' | tail -1)
    if echo "$last_line" | grep -qiF 'esc to'; then
        echo "busy"
        return 0
    fi

    # B3: parse/error 痕 → parse_error
    if echo "$text" | grep -qE 'could not be parsed|Churned|API Error|tool_use.*error|Request failed|rate limit'; then
        echo "parse_error"
        return 0
    fi

    # B2: context 肥大警告 → context_bloat
    if echo "$text" | grep -qE '/clear to save|[0-9]+k tokens'; then
        echo "context_bloat"
        return 0
    fi

    # B1: ❯ プロンプト待ちのみ → idle
    if echo "$text" | grep -qE '^(❯|›)\s*$'; then
        echo "idle"
        return 0
    fi

    # Codex / OpenCode idle prompt
    if echo "$text" | grep -qE '(\? for shortcuts|context left)'; then
        echo "idle"
        return 0
    fi

    # 何も一致しなければ busy 扱い (誤検知を優先的に避ける)
    echo "busy"
}
