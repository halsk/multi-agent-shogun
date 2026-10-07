#!/usr/bin/env bash
# lib/yaml_scalar.sh — task YAML の task: 直下 scalar を1つ読む純関数ライブラリ
#
# 提供関数:
#   task_scalar <key> <file>  → 字下げ2つの `  <key>:` 行(当家のtask YAMLでは
#                               task: 直下)の最初の1つの値(コメント・クォート・
#                               空白を落とした素の文字列)。無ければ空文字、
#                               戻り値は常に0(理由は関数直上の註)
#
# 出自: scripts/deadman_switch.sh の task_scalar()(cmd_942派生・PR#199で
# QC PASS済み)。軍師QC(queue/reports/gunshi_report_deadman_trailing_comment_qc.yaml)
# が、同じ壊れた抽出(コメントを切らずに比較する)の写しが stall_watchdog.sh・
# inbox_watcher.sh・console_stall_watchdog.sh・start_task.sh にも残っている
# ことを見つけた。★stall_watchdog.sh では向きが逆で deadman_switch.sh より重い:
# 「status: assigned  # 家老が割当」を 'assigned' と読めず、本当に詰まった
# 足軽を検知しない(無音の見逃し)方向に効く。写しが5か所ある以上、各所で
# 直すのでなく本ライブラリへ一本化し、全箇所から source して呼ぶ。
#
# ★抽出ロジック(3段の順序)は PR#199 の実装をそのまま移植したものであり、
# 変更してはならない(各段の理由は下記の註)。
#
# tmux・PyYAML 非依存。単体テスト可能(tests/unit/test_yaml_scalar.bats)。

# cmd_942派生(2026-10-07): task:直下(字下げ2つ)の scalar を1つ読む。
# $1=鍵(status / task_id) $2=task YAMLパス
# 家老は `status: done  # 16:58 CI全green・main be2647aへmerge済み(家老)` の
# ようにinline commentで根拠を添える慣例がある。従来の抽出はコメントを
# 切り捨てずに空白だけ潰していたため $status が「done#16:58CI全green…」と
# なり done/blocked に一致せず、手が空いただけの足軽へ20分おきに🚨を出し
# 続けた。
# 段の順序が要(code-review指摘で実証):
#   1) まず「空白+#」以降をコメントとして切る(YAMLの規則どおり。空白を伴わぬ
#      # はコメントでないため切らず、クォート内に#を含む値を壊さない)
#   2) 次に鍵を★行頭に錨を打って(`^  key:`)抜く。欲張りな `.*key:` を先に
#      走らせると、コメント内に同じ鍵の語(「旧status: assigned」等)があれば
#      そこまで飛んでしまい、1)を後に置いても残骸が残る
#   3) クォートと空白(TAB/CR含む・`tr -d ' '`ではTABが残る)を落とす
# ★deadman_switch.sh はPyYAMLをwrite_back_status/reconcileで既に要するが、判定の
# 入口はpython無しでも動くよう従来どおりテキスト抽出のまま(置換は別件)。
#
# ★契約の正確な範囲(共通化時のself code-review指摘・正直に明記):
#   - 読むのは「字下げ2つの `  key:` 行の最初の1つ」であり、task: ブロックに
#     限定はしていない(task: 以前に同じ字下げの key: があればそちらを返す。
#     当家のtask YAMLはtask:が唯一のトップレベルであり実害は無い)。
#   - 1)は「空白+#」で切るため、クォート内に「空白+#」を含む値
#     (例 "wip # keep")は切れる。壊さないのは空白を伴わぬ#(例 "issue#12")のみ。
#   - 字下げ2つの key: 行が無い場合は空文字を返す。★戻り値は常に0: grepの
#     不一致(rc=1)を伝播させると、`set -e` 下の呼び出し元(stall_watchdog.sh
#     メインループの `status=$(task_status ...)`)が最初の該当agentで中断し、
#     以後の全agentが無音で見張られなくなる(self code-reviewで再現済み)。
#     呼び出し元は空文字を「監視対象外/不明」として扱う。抽出の3段と順序は
#     不変であり、変えたのは終了コードのみ。
task_scalar() {
  local key="$1" file="$2"
  grep -E "^  ${key}:" "$file" | head -1 \
    | sed -E "s/[[:space:]]#.*$//; s/^  ${key}:[[:space:]]*//" \
    | tr -d "\"'" | tr -d '[:space:]' || true
}
