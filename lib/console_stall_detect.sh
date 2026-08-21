#!/usr/bin/env bash
# lib/console_stall_detect.sh — geonicdb-console「仕事の停滞」判定の純関数ライブラリ
#
# 既存 lib/stall_detect.sh (エージェントの無音固着検知) とは別物。
# こちらは「consoleという仕事そのものが動いていない」ことを見る (cmd_725第三段)。
#
# 提供関数:
#   max_epoch <e1> <e2> <e3>                                   → 最大値 (最終活動時刻の合成)
#   in_night_window <hour> <night_start_hour> <night_end_hour> → 0=夜間帯 / 1=昼間帯
#   classify_stall_reason <dash_text> <reports_text> <task_status> <task_reason>
#       → "a" | "b" | "c" | "d" | "e" (判定できなければ "unknown")
#   notification_body <category> <detail>                      → 通知本文 (区分+依頼内容 必須同梱)
#
# tmux/git/gh 非依存。単体テスト可能。

max_epoch() {
    local a="${1:-0}" b="${2:-0}" c="${3:-0}"
    local m="$a"
    [[ "$b" -gt "$m" ]] && m="$b"
    [[ "$c" -gt "$m" ]] && m="$c"
    echo "$m"
}

# 夜間帯判定: night_start(例22)〜24時またぎ〜night_end(例8) の間なら 0 (夜間)
in_night_window() {
    local hour="$1" night_start="$2" night_end="$3"
    if [[ "$hour" -ge "$night_start" || "$hour" -lt "$night_end" ]]; then
        return 0
    fi
    return 1
}

# 停滞理由の区分判定。優先順位 a > b > c > d > e (task記載の判定方法節に準拠)
classify_stall_reason() {
    local dash_text="$1" reports_text="$2" task_status="$3" task_reason="$4"

    if echo "$dash_text" | grep -qiE 'console|geonicdb-console'; then
        echo "a"
        return 0
    fi

    if echo "$reports_text" | grep -qiE '1Password|認証|ログイン待ち|殿手番|殿の手番|op signin|Touch ID|op read'; then
        echo "b"
        return 0
    fi

    if [[ "$task_status" == "blocked" && -n "$task_reason" ]]; then
        echo "c"
        return 0
    fi

    if echo "$reports_text" | grep -qiE 'backend実装|backend側|backend待ち|backend依存'; then
        echo "d"
        return 0
    fi

    echo "e"
}

# 通知本文生成。★区分と依頼内容(または不要である旨)を必ず含める。
notification_body() {
    local category="$1" detail="$2"

    case "$category" in
        a)
            printf '[区分a: 殿の裁可待ち]\n何を裁可すべきか: %s\n' "$detail"
            ;;
        b)
            printf '[区分b: 認証・殿の手番待ち]\n何の操作か: %s\n' "$detail"
            ;;
        c)
            printf '[区分c: 技術的に詰まった]\n何が詰まり選択肢が何か: %s\n' "$detail"
            ;;
        d)
            printf '[区分d: backend依存でconsole側では進められぬ]\n何が要るか: %s\n' "$detail"
            ;;
        e)
            printf '[区分e: 単に人手が空かなかった]\n殿は何もせずともよい。手番はござらぬ。詳細: %s\n' "$detail"
            ;;
        *)
            printf '[区分不明]\n判定できず。詳細不明のまま生の状況を伝える: %s\n' "$detail"
            ;;
    esac
}
