#!/usr/bin/env bash
# lib/dashboard_insert.sh — dashboard.md の指定行の直後へ1エントリを挿入する純関数
#
# cmd_974(B): BSD sed の a\ は本文1行が2048バイトを超えるとそこで行を切り、
# 残りを次のコマンドと読んで「invalid command code」で落ちる(台帳statusの
# 数KBの注記がentryへ混入した2026-10-17〜18に実際に踏んだ)。entry を
# 環境変数経由でawkへ渡し、sedのスクリプト文字列長に依存しない形にした。
# (awk -v は \ をエスケープ解釈するため使わず、ENVIRON で渡す)
#
#   dashboard_insert_after_line <line_no> <entry> <dashboard_file>
#     → <line_no> 行目の直後に <entry> を1行挿入し、結果を stdout へ返す
dashboard_insert_after_line() {
    local line_no="$1" entry="$2" file="$3"
    _DI_ENTRY="$entry" awk -v n="$line_no" '
        { print }
        NR == n { print ENVIRON["_DI_ENTRY"] }
    ' "$file"
}
