#!/usr/bin/env bash
# lib/stall_detect.sh — pane テキストからエージェントの固着シグネチャを分類する純関数ライブラリ
#
# 提供関数:
#   classify_pane <text>       → "busy" / "idle" / "context_bloat" / "parse_error" / "permission_prompt"
#   is_permission_prompt <text> → 0=許可プロンプト表示中 / 1=非該当
#
# tmux 非依存。単体テスト可能。

# is_permission_prompt <text>
# Claude Code の許可プロンプト(Bashコマンド等の実行確認ダイアログ)が表示
# されたままかを、agent の status(assigned/in_progress等)に依存せず、pane
# 内容そのものから判定する(cmd_771 fix_d)。
# 実例根拠: 9/5 ashigaru1 が guard.sh の D002 判定で rm コマンドの承認待ち
# となり4時間25分停止した際、実際に pane に表示されていた形式:
#   │ Do you want to proceed?                          │
#   │ ❯ 1. Yes                                          │
#   │   2. Yes, and don't ask again for rm commands     │
#   │   3. No, and tell Claude what to do differently   │
# 「Do you want to proceed?」の見出しと、選択肢カーソル「❯ 1.」の両方が
# 揃った場合のみ検知する(片方だけでは誤検知しうるため2条件の論理積)。
# ★★★本関数は検知のみを行う。y/n等の自動応答は一切行わない(呼び出し側
# も同様——絶対禁止)。
is_permission_prompt() {
    local text="$1"
    echo "$text" | grep -qE 'Do you want to proceed\?' || return 1
    echo "$text" | grep -qE '❯[[:space:]]*1\.' || return 1
    return 0
}

classify_pane() {
    local text="$1"

    # D: 許可プロンプト表示中 → permission_prompt (cmd_771 fix_d・最優先)
    # ★spinner(✻/⏺)チェックより前に置く。実際の Claude Code 画面では、
    # 確認ダイアログの直前行に直前ツール呼び出しの「⏺ Bash(...)」が残る
    # ため、⏺優先のままだと許可プロンプトが busy に取り違えられ検知漏れ
    # する(9/5 ashigaru1・4時間25分停止の再現で実測)。tmux capture-pane
    # は現在の画面内容そのものを返す(scrollbackではない)ため、"Do you
    # want to proceed?" が写っている時点でダイアログは今まさに表示中と
    # 確定でき、✻(生成中スピナー)と共存しない——先頭判定にしてよい。
    if is_permission_prompt "$text"; then
        echo "permission_prompt"
        return 0
    fi

    # E1: spinner が動いている → busy (誤検知防止)
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
