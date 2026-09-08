#!/usr/bin/env bash
# scripts/deadman_switch.sh — cmd_779 死者確認スイッチ(独立・粗い網)
#
# ★★★独立性が本スクリプトの唯一の価値である★★★
# inbox_watcher.sh / stall_watchdog.sh / heartbeat_detect.sh 等の既存検知機構は
# 一切 source/呼び出し/import しない(2026-09-06のashigaru4 24h凍結事故で、
# 既存機構が"見逃した"真因が未判明のまま——同じ壊れ方をする依存を作れば
# 安全網ごと道連れに死ぬ)。判定に使う信号は queue/tasks/*.yaml の mtime のみ。
#
# 閾値根拠 (2026-09-07 実測・ashigaru7):
#   queue/inbox/*.yaml 全メッセージの timestamp を集計したところ、2026-09-06の
#   確認済み正常稼働時間帯(11:27〜22:30, 昼間)でも家中全体で最大126.4分の
#   無通信ギャップが実在した(60.0/72.7/98.1/126.4分の4件)。queue/tasksは
#   inboxより粗い信号(タスク再割当時のみ更新)ゆえ、正常時のギャップは
#   これと同等かそれ以上になり得る。一方、2026-09-06 23:46→09-07 23:10の
#   1403分(約23.4h)ギャップは実際のashigaru4凍結事故の期間と一致した。
#   よって「目安40分」ではなく実測正常上限(126分)に十分な余裕を持たせた
#   150分(2.5h)を採用する——事故発覚は24hから2.5hへ大幅短縮される。
#
# 設計変更(2026-09-07 23:32将軍実測・addendum反映): 当初「最新1本のmtime」
# だけを見る設計では、7名中1名だけ死んでも他の稼働者がtask YAMLを動かし
# 続ける限り網が鳴らなかった(ashigaru3が35時間気づかれなかった実例)。
# ★各エージェントのtask YAMLを個別に見る★よう改める。ただし
# status: blocked(殿/外部の手番待ち)は正しく待っているだけなので対象外。
THRESHOLD_MIN=150
#
# 夜間ルーティング追加(cmd_781・殿ご裁可 2026-09-08): 9/7 23:30〜9/8 07:51に
# 家中8名全員が停止した実例を受け、「殿は夜間打たれぬ(現状維持)」と
# 「家中が夜間に止まる(理由なし)」は別問題と切り分けた。停止検知時は
# 昼夜問わず★家老inbox★へ通知する(既存inbox_write.shをそのまま使う・
# 新規機構は作らない)。殿へのntfyは従来どおり夜間は発火させない。
#
# 「殿は最後の砦」是正(cmd_783・殿ご裁可 2026-09-08): 昼間、家老通知の
# 直後に殿宛cooldownが並行して進み、家老の対応を待たずに殿へ飛ぶ設計を
# 改める。殿宛ntfyは「家老通知から15分(LORD_ESCALATION_WAIT_SEC)経っても
# 該当agentの停止が解消されていない場合」に限り発火する。家老が対応し
# 解消済みなら次回実行時に該当agentが停止リストから消え、自然に殿宛は
# 発火しない(新規の「家老が動いたか」判定は作らず、agent一覧の突き合わせ
# だけで実現する・将軍の明記事項)。夜間はこのエスカレーション自体を
# 発火しない(★夜間は家老のみ・殿は絶対に起こさない、を維持)。
#
# ★手動実行時の注意(cmd_784): デバッグ等で手動実行する場合は
# DEADMAN_LOG_FILE を明示的に指定し、本番 logs/deadman_switch.log を
# 汚染しないこと(例: DEADMAN_LOG_FILE=/tmp/deadman_test.log bash scripts/deadman_switch.sh)。
# 未指定の手動実行が本番ログへ旧形式・偽装時刻の行を混入させた実例あり(2026-09-08)。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR" || exit 1

# DEADMAN_*: bats単体テストがproduction queue/tasks・dashboard.mdを汚さぬための
# 差し替え口(未設定時は本番と同じ実パス。本番運用では一切指定不要)
TASKS_DIR="${DEADMAN_TASKS_DIR:-$SCRIPT_DIR/queue/tasks}"
DASHBOARD="${DEADMAN_DASHBOARD:-$SCRIPT_DIR/dashboard.md}"
STATE_DIR="${DEADMAN_STATE_DIR:-$SCRIPT_DIR/queue/deadman_switch}"
LOG_FILE="${DEADMAN_LOG_FILE:-$SCRIPT_DIR/logs/deadman_switch.log}"
LIVENESS_FILE="${DEADMAN_LIVENESS_FILE:-/tmp/deadman-last-run}"
NTFY_SCRIPT="${DEADMAN_NTFY_SCRIPT:-$SCRIPT_DIR/scripts/ntfy.sh}"
INBOX_WRITE_SCRIPT="${DEADMAN_INBOX_WRITE_SCRIPT:-$SCRIPT_DIR/scripts/inbox_write.sh}"
LAST_FIRE_FILE="$STATE_DIR/last_fire_epoch.txt"
KARO_LAST_FIRE_FILE="$STATE_DIR/karo_last_fire_epoch.txt"   # 殿宛cooldownとは別名(混線防止)
KARO_NOTIFIED_AGENTS_FILE="$STATE_DIR/karo_notified_agents.txt"  # cmd_783: 家老通知時刻+停止agent一覧のスナップショット
COOLDOWN_SEC=$((2 * 60 * 60))   # 殿宛: 1回/2時間
KARO_COOLDOWN_SEC=$((30 * 60))  # 家老宛: 1回/30分(家老は起きたらすぐ気づくべき・殿宛より短く)
LORD_ESCALATION_WAIT_SEC=$((15 * 60))  # cmd_783: 家老通知から殿宛エスカレーションまでの猶予
NIGHT_START_HOUR=22             # config/settings.yaml console_stall_watchdog に倣う
NIGHT_END_HOUR=8
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

# DEADMAN_NOW_EPOCH: 誤報/夜間の再現テスト用の時刻偽装(未設定時は実時計)
now_epoch="${DEADMAN_NOW_EPOCH:-$(date +%s)}"
now_iso=$(date -r "$now_epoch" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$now_epoch" '+%Y-%m-%dT%H:%M:%S%z')
hour=$((10#$(date -r "$now_epoch" '+%H' 2>/dev/null || date -d "@$now_epoch" '+%H')))

# ⑦ 網自身の生存証跡(この網自身を監視する「網の網」は作らない)
touch "$LIVENESS_FILE"

file_count=0
stalled=()
stalled_agents=()  # cmd_783: 殿宛エスカレーション比較用の素のagent名一覧(detail文言を含まぬ)
for f in "$TASKS_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  agent="$(basename "$f" .yaml)"
  # 実測で発見(2026-09-07): queue/tasks/にはgunshi_cmd624_design.yaml等
  # エージェント名でないファイルも混在し、真の実働エージェントに絞らねば
  # 何ヶ月も前のファイルが毎回誤検知される。既知の実働名のみ対象とする。
  # ★gunshi2は実在しないpane(2026-09-05将軍確認済み・cmd_754で誤検知の
  # 元凶となった)ゆえ対象から除外する。旧gunshi2.yaml(完結済み実績)は
  # 削除でなくqueue/archive/へ退避済み(cmd_783)。
  case "$agent" in
    ashigaru[0-9]|gunshi|karo|shogun) ;;
    *) continue ;;
  esac
  file_count=$((file_count + 1))
  # ★GNUのstat -fはBSDと意味が違う(ファイルシステム情報表示・%mはmount pointとして
  # 解釈され、%mを渡しても exit 0 で複数行の無関係な出力を返す=フォールバックが
  # 発火しない罠)。GNU形式(-c %Y)を先に試し、macOSではillegal optionで正しく
  # 失敗してBSD形式(-f %m)へフォールバックする順序にする(CI ubuntu-latestで実測)。
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || continue
  [ -z "$m" ] && continue
  status=$(grep -E '^\s*status:\s*' "$f" | head -1 | sed 's/.*status:[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d ' ')
  [ "$status" = "blocked" ] && continue   # 殿/外部の手番待ちは正しい停止・対象外
  idle=$(( (now_epoch - m) / 60 ))
  if [ "$idle" -ge "$THRESHOLD_MIN" ]; then
    stalled+=("${agent}(status=${status:-不明}・idle=${idle}分)")
    stalled_agents+=("$agent")
  fi
done

if [ "$file_count" -eq 0 ]; then
  echo "[deadman_switch] $now_iso queue/tasks/*.yaml が見つからぬ。判定不能。" >> "$LOG_FILE"
  exit 1
fi

in_night=false
if [ "$hour" -ge "$NIGHT_START_HOUR" ] || [ "$hour" -lt "$NIGHT_END_HOUR" ]; then
  in_night=true
fi

echo "[deadman_switch] $now_iso files=$file_count stalled=${#stalled[@]} in_night=$in_night" >> "$LOG_FILE"

# ⑦ 最終実行時刻をdashboard.mdへ1行出力(heartbeat行を毎回上書き・追記しない)
heartbeat_line="<!-- deadman_switch:heartbeat --> 🕐 [deadman_switch] 最終実行 $now_iso (files=${file_count}・stalled=${#stalled[@]}・夜間=${in_night})"
if [ -f "$DASHBOARD" ] && grep -q '<!-- deadman_switch:heartbeat -->' "$DASHBOARD"; then
  _hb_tmp=$(mktemp)
  awk -v line="$heartbeat_line" '{ if ($0 ~ /<!-- deadman_switch:heartbeat -->/) print line; else print }' "$DASHBOARD" > "$_hb_tmp" && mv "$_hb_tmp" "$DASHBOARD"
else
  printf '\n%s\n' "$heartbeat_line" >> "$DASHBOARD"
fi

# ここから先は「停止」判定時のみ
[ "${#stalled[@]}" -eq 0 ] && exit 0

detail=$(IFS=', '; echo "${stalled[*]}")

# 家老inboxへの通知(昼夜問わず・独立cooldown。夜間は「軽い作業のみ回せ」を明記)
karo_last_fire=0
[ -f "$KARO_LAST_FIRE_FILE" ] && karo_last_fire=$(cat "$KARO_LAST_FIRE_FILE" 2>/dev/null || echo 0)
if [ $(( now_epoch - karo_last_fire )) -ge "$KARO_COOLDOWN_SEC" ]; then
  if $in_night; then
    karo_msg="🚨【死者確認スイッチ・夜間】status:blocked以外で放置中: ${detail} @ $now_iso ★夜間である。軽い作業のみ回せ★"
  else
    karo_msg="🚨【死者確認スイッチ】status:blocked以外で放置中: ${detail} @ $now_iso"
  fi
  bash "$INBOX_WRITE_SCRIPT" karo "$karo_msg" task_assigned deadman_switch
  echo "$now_epoch" > "$KARO_LAST_FIRE_FILE"
  # cmd_783: 殿宛エスカレーション判定用に、この通知時点の停止agent一覧を記録
  printf '%s,%s\n' "$now_epoch" "$(IFS=,; echo "${stalled_agents[*]}")" > "$KARO_NOTIFIED_AGENTS_FILE"
  echo "[deadman_switch] $now_iso KARO_NOTIFIED stalled=${stalled[*]} in_night=$in_night" >> "$LOG_FILE"
fi

# 殿へのntfyは夜間は引き続き発火しない(殿のお休みを妨げぬため・現状維持)
$in_night && exit 0

# cmd_783【殿は最後の砦】: 家老通知から15分経ってもなお同一agentが停止中の
# 場合に限り殿宛エスカレーションへ進む。記録が無い(まだ家老通知1回目)か
# 15分未満、あるいは記録済みagentが全員解消済みなら、殿は起こさない。
lord_escalate=false
if [ -f "$KARO_NOTIFIED_AGENTS_FILE" ]; then
  IFS=',' read -r karo_notify_epoch karo_notify_agents_csv < "$KARO_NOTIFIED_AGENTS_FILE"
  if [ -n "${karo_notify_epoch:-}" ] && [ $(( now_epoch - karo_notify_epoch )) -ge "$LORD_ESCALATION_WAIT_SEC" ]; then
    IFS=',' read -ra karo_notify_agents <<< "$karo_notify_agents_csv"
    for na in "${karo_notify_agents[@]}"; do
      for sa in "${stalled_agents[@]}"; do
        if [ "$na" = "$sa" ]; then
          lord_escalate=true
          break 2
        fi
      done
    done
  fi
fi
$lord_escalate || exit 0

# cooldownは全体で1本(agent毎に持たず60行の縛りを優先・addendum⑤準拠)
last_fire=0
[ -f "$LAST_FIRE_FILE" ] && last_fire=$(cat "$LAST_FIRE_FILE" 2>/dev/null || echo 0)
[ $(( now_epoch - last_fire )) -lt "$COOLDOWN_SEC" ] && exit 0

msg="🚨【死者確認スイッチ】status:blocked以外で放置中: ${detail} @ $now_iso"
bash "$NTFY_SCRIPT" "$msg"
echo "$now_epoch" > "$LAST_FIRE_FILE"
printf '\n- 🚨 [deadman_switch] status:blocked以外で放置中: %s→ntfy送信 @ %s\n' "$detail" "$now_iso" >> "$DASHBOARD"
echo "[deadman_switch] $now_iso FIRED stalled=${stalled[*]}" >> "$LOG_FILE"
