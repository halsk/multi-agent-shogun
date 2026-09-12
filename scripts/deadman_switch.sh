#!/usr/bin/env bash
# scripts/deadman_switch.sh — cmd_779 死者確認スイッチ(独立・粗い網)
#
# ★★★独立性が本スクリプトの唯一の価値である★★★
# inbox_watcher.sh / stall_watchdog.sh / heartbeat_detect.sh 等の既存検知機構は
# 一切 source/呼び出し/import しない(2026-09-06のashigaru4 24h凍結事故で、
# 既存機構が"見逃した"真因が未判明のまま——同じ壊れ方をする依存を作れば
# 安全網ごと道連れに死ぬ)。判定に使う信号は queue/tasks/*.yaml の mtime のみ。
#
# 閾値根拠 (2026-09-07 実測・ashigaru7、2026-09-09 ashigaru4が根拠を是正):
#   当初、queue/inbox/*.yaml全メッセージのtimestampから求めた「家中全体の
#   正常時最大無通信ギャップ126.4分」に24分のマージンを足しただけの150分を
#   採用していたが、これは信号の種類を取り違えた転用だった——inboxのギャップは
#   「メッセージのやり取り(雑談・報告・割当連絡)がどれだけ空くか」という
#   ★会話頻度★の指標であり、queue/tasksのmtimeは「taskの割当・完了という
#   境界イベントの間隔」という★作業所要時間★の指標である。queue/tasksが
#   inboxより粗いのは事実だが、その粗さの正体は会話頻度の違いではなく、
#   worktree+TDD+PR一式のL4級タスクは1件で1〜数時間かかりうるという設計上の
#   性質そのものであり、inbox実測値をそのまま流用しても正しい安全マージンには
#   ならない(2026-09-09 ashigaru4実測)。
#   ★実際に何を検知したいかで閾値の妥当性を評価し直した:
#   (a) status:done(作業完了・次割当待ち)のidleは「家老の割当対応がどれだけ
#       遅れているか」を表し、これはinboxの会話頻度に近い性質を持つ——実際
#       2026-09-09昼(健全稼働中)にstatus:doneのidleが133〜164分に達する事例が
#       観測されており、150分は「次割当が遅い」を過不足なく拾えている
#       (通知後、家老が数分で次taskを割り当て解消する挙動も同日ログで確認済み)。
#   (b) status:assigned(作業中)のidleは上記のとおり作業所要時間そのものに
#       依存し、150分超は正常な長時間タスクとも実際の凍結事故とも見分けが
#       付かない。過去ログで150分超のassigned idleが観測された事例は、いずれも
#       既知の凍結事故(ashigaru3の35h放置・ashigaru4の24h凍結等)の期間内に
#       収まっており、「凍結でない正常な長時間タスクがこの閾値で誤検知された」
#       という実例は見つからなかった。
#   結論: 150分という★値★を裏付ける実測は(a)(b)いずれからも得られており、
#   変更の必要は無いと判断した(誤検知を増やす方向の短縮は特に避けるべき、との
#   task指示に沿う)。ただし根拠の★説明★は誤りだったため本コメントで是正する。
#   将来、status:assignedの長時間タスクで誤検知の実例が出た場合はstatus別に
#   閾値を分離する設計変更を検討せよ(現時点ではその実例が無く、複雑化を
#   避けるため見送る)。
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
#
# 家老/将軍自身の生存監視(cmd_784・殿ご裁可 2026-09-08): 家老・将軍は
# dispatcherでありtask YAMLを持たぬため、mtimeベースの本網からは不可視
# だった(本日の24h停止=家老が詰まった/8h停止=将軍が眠った、の当事者
# 自身が全検知網から見えていなかった)。代わりに「自分のinbox(queue/inbox/
# {karo,shogun}.yaml)に未読(read:false)が閾値以上滞留しているか」を生存信号
# とする——生きたdispatcherは即座にinboxを処理しread:trueにする。未読ゼロ
# (手番なし)なら正常なidleゆえ対象外(「詰まった」と「手番待ち」の機械的
# 区別)。検知後は既存の stalled 網へそのまま積み、家老通知→15分→殿ntfyの
# 最後の砦を再利用する(新規経路は作らない)。★独立性の掟との整合: これは
# 既存の検知スクリプト(inbox_watcher等)への依存ではなく、mailboxデータを
# task YAMLと同様に直接読むだけであり、判定を他機構へ委ねてはいない。

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
KARO_INBOX="${DEADMAN_KARO_INBOX:-$SCRIPT_DIR/queue/inbox/karo.yaml}"      # cmd_784: 家老の生存信号
SHOGUN_INBOX="${DEADMAN_SHOGUN_INBOX:-$SCRIPT_DIR/queue/inbox/shogun.yaml}" # cmd_784: 将軍の生存信号
LAST_FIRE_FILE="$STATE_DIR/last_fire_epoch.txt"
KARO_LAST_FIRE_FILE="$STATE_DIR/karo_last_fire_epoch.txt"   # 殿宛cooldownとは別名(混線防止)
KARO_NIGHT_DONE_LAST_FIRE_FILE="$STATE_DIR/karo_night_done_last_fire_epoch.txt"  # cmd_785⑨: 夜間・全員done停止専用cooldown
KARO_NOTIFIED_AGENTS_FILE="$STATE_DIR/karo_notified_agents.txt"  # cmd_783: 家老通知時刻+停止agent一覧のスナップショット
COOLDOWN_SEC=$((2 * 60 * 60))   # 殿宛: 1回/2時間
KARO_COOLDOWN_SEC=$((20 * 60))  # 家老宛: 1回/20分(cmd_783受入条件。cmd_784バグ②修正: 従前の30分はcmd_783受入条件との食い違いだった)
# cmd_785⑨: 夜間、停止中の全員がstatus:done(実働中フリーズが1件も混在しない)場合に限る
# 間引き用cooldown。3時間という値は本リポでの直近の同種是正(cmd_741・CI心拍ntfyの
# 狼少年化対策で30分→3時間)に倣う。status:assigned等が1件でも混在する場合はこの間引きを
# 適用せず、従来どおりKARO_COOLDOWN_SEC(20分)を維持する(実働中フリーズの検知速度を
# 落とさないため——2026-09-06のashigaru4 24h凍結のような事故は夜間にも起こりうる)。
NIGHT_DONE_COOLDOWN_SEC=$((3 * 60 * 60))
LORD_ESCALATION_WAIT_SEC=$((15 * 60))  # cmd_783: 家老通知から殿宛エスカレーションまでの猶予
NIGHT_START_HOUR=22             # config/settings.yaml console_stall_watchdog に倣う
NIGHT_END_HOUR=8
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

# cmd_784: inbox(mailbox)の最古の未読(read:false)エントリのtimestampをepochで返す
# (未読が無ければ何も出力しない=手番待ちでなく正常idle)。家老/将軍の生存信号に用いる。
# ★read行はtimestamp行より前(entry内はcontent,from,id,read,timestamp,typeの
# アルファベット順)ゆえ、timestamp行に達した時点でread値は確定している。
oldest_unread_epoch() {
  local inbox="$1"
  [ -f "$inbox" ] || return 0
  local tss
  tss=$(awk '
    /^- content:/ { r=""; }
    /^  read:/ { v=$0; sub(/^  read:[[:space:]]*/,"",v); gsub(/[[:space:]]/,"",v); r=v }
    /^  timestamp:/ {
      v=$0; sub(/^  timestamp:[[:space:]]*/,"",v); gsub(/[\047"[:space:]]/,"",v);
      if (r=="false" && v!="") print v
    }
  ' "$inbox")
  [ -z "$tss" ] && return 0
  local ts e min=""
  while IFS= read -r ts; do
    [ -z "$ts" ] && continue
    e=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${ts%%+*}" +%s 2>/dev/null || date -d "$ts" +%s 2>/dev/null)
    [ -z "$e" ] && continue
    if [ -z "$min" ] || [ "$e" -lt "$min" ]; then min="$e"; fi
  done <<< "$tss"
  [ -n "$min" ] && echo "$min"
  return 0
}

# DEADMAN_NOW_EPOCH: 誤報/夜間の再現テスト用の時刻偽装(未設定時は実時計)
now_epoch="${DEADMAN_NOW_EPOCH:-$(date +%s)}"
now_iso=$(date -r "$now_epoch" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$now_epoch" '+%Y-%m-%dT%H:%M:%S%z')
hour=$((10#$(date -r "$now_epoch" '+%H' 2>/dev/null || date -d "@$now_epoch" '+%H')))

# ⑦ 網自身の生存証跡(この網自身を監視する「網の網」は作らない)
touch "$LIVENESS_FILE"

file_count=0
stalled=()
stalled_agents=()  # cmd_783: 殿宛エスカレーション比較用の素のagent名一覧(detail文言を含まぬ)
stalled_statuses=()  # cmd_785⑨: 夜間done間引き判定用(dispatcher停止は"dispatcher"を積む)
for f in "$TASKS_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  agent="$(basename "$f" .yaml)"
  # 実測で発見(2026-09-07): queue/tasks/にはgunshi_cmd624_design.yaml等
  # エージェント名でないファイルも混在し、真の実働エージェントに絞らねば
  # 何ヶ月も前のファイルが毎回誤検知される。既知の実働名のみ対象とする。
  # gunshi2は cmd_803(2026-09-12)・軍師2人体制の復帰によりpaneが常設された
  # (shutsujin_departure.sh改修と対)。2026-09-05〜cmd_754当時の「pane不在ゆえ除外」
  # という前提はもう成り立たないため、監視対象へ戻す。
  case "$agent" in
    ashigaru[0-9]|gunshi|gunshi2|karo|shogun) ;;
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
    stalled_statuses+=("${status:-不明}")
  fi
done

# ── cmd_784: 家老/将軍(dispatcher)の生存判定を stalled 網へ相乗りさせる ──
# task YAMLループと同じ stalled/stalled_agents 配列へ積むだけで、以降の家老通知・
# 殿へのエスカレーション・cooldown・夜間抑止の全機構を再利用する(新規経路は
# 作らない)。閾値は task YAML mtime 判定と同じ THRESHOLD_MIN を共用する。
# 家老が詰まっている場合、家老宛通知は本人に届かぬが害はなく(未読が積まれる
# のみ)、15分後の殿宛エスカレーションが最後の砦として機能する。将軍が詰まって
# いる場合も、まず家老へ通知され(家老が生きていれば殿へ人手で促せる)、最終的に
# 殿宛ntfyが最後の砦となる。夜間は既存方針どおり殿を起こさない。
for dispatcher in karo shogun; do
  case "$dispatcher" in
    karo)   d_inbox="$KARO_INBOX" ;;
    shogun) d_inbox="$SHOGUN_INBOX" ;;
    *)      continue ;;
  esac
  d_oldest=$(oldest_unread_epoch "$d_inbox")
  [ -z "$d_oldest" ] && continue   # 未読なし=手番待ちでなく正常idle=対象外
  d_idle=$(( (now_epoch - d_oldest) / 60 ))
  if [ "$d_idle" -ge "$THRESHOLD_MIN" ]; then
    stalled+=("${dispatcher}(inbox未読滞留=${d_idle}分)")
    stalled_agents+=("$dispatcher")
    stalled_statuses+=("dispatcher")  # cmd_785⑨: done扱いしない(実働中フリーズ相当として速い cadence を維持)
  fi
done

# 判定不能ガード: task YAMLが1件も無く、かつdispatcher未読滞留も無い場合のみ
# 「判定材料なし」で終了する(dispatcher停止だけは検知できる場合を取りこぼさない)。
if [ "$file_count" -eq 0 ] && [ "${#stalled[@]}" -eq 0 ]; then
  echo "[deadman_switch] $now_iso queue/tasks/*.yaml が見つからず、dispatcher未読滞留も無し。判定不能。" >> "$LOG_FILE"
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

# cmd_785⑨: 停止中の全員がstatus:done(dispatcher停止・status:assigned等の実働中
# フリーズが1件も混在しない)かどうかを判定する。夜間はこの場合のみcooldownを
# 20分→3時間へ間引く——「doneのまま放置」の検知価値(cmd_771)は保ったまま、深夜に
# 同じ顔ぶれを20分毎に連打するノイズだけを削る(2026-09-09未明の実測: 8エージェント
# 全員status=doneのまま20分毎に6時間以上連打が続いていた)。1件でもstatus:assigned等が
# 混じれば「done除外」にはならず、従来どおり20分cooldownのまま速く家老へ知らせる
# (実働中フリーズは夜間にも起こりうるため——2026-09-06 ashigaru4 24h凍結の教訓)。
all_done_stall=true
for st in "${stalled_statuses[@]}"; do
  if [ "$st" != "done" ]; then
    all_done_stall=false
    break
  fi
done

karo_cooldown_sec="$KARO_COOLDOWN_SEC"
karo_last_fire_file="$KARO_LAST_FIRE_FILE"
if $in_night && $all_done_stall; then
  karo_cooldown_sec="$NIGHT_DONE_COOLDOWN_SEC"
  karo_last_fire_file="$KARO_NIGHT_DONE_LAST_FIRE_FILE"
fi

# 家老inboxへの通知(昼夜問わず・独立cooldown。夜間は「軽い作業のみ回せ」を明記)
karo_last_fire=0
[ -f "$karo_last_fire_file" ] && karo_last_fire=$(cat "$karo_last_fire_file" 2>/dev/null || echo 0)
if [ $(( now_epoch - karo_last_fire )) -ge "$karo_cooldown_sec" ]; then
  if $in_night; then
    karo_msg="🚨【死者確認スイッチ・夜間】status:blocked以外で放置中: ${detail} @ $now_iso ★夜間である。軽い作業のみ回せ★"
    $all_done_stall && karo_msg="${karo_msg}(全員done・3時間間隔に間引き中)"
  else
    karo_msg="🚨【死者確認スイッチ】status:blocked以外で放置中: ${detail} @ $now_iso"
  fi
  bash "$INBOX_WRITE_SCRIPT" karo "$karo_msg" task_assigned deadman_switch
  echo "$now_epoch" > "$karo_last_fire_file"
  # cmd_783: 殿宛エスカレーション判定用に、この通知時点の停止agent一覧を記録
  printf '%s,%s\n' "$now_epoch" "$(IFS=,; echo "${stalled_agents[*]}")" > "$KARO_NOTIFIED_AGENTS_FILE"
  echo "[deadman_switch] $now_iso KARO_NOTIFIED stalled=${stalled[*]} in_night=$in_night" >> "$LOG_FILE"
fi

# ★cmd_795【殿ご裁定=丙・2026-09-11】殿宛エスカレーションを無効化する。
# 殿のお尋ね「死者確認スイッチが届くが私は何をすればよい?」→答え「何もない」。
# 家中の停止は我らで片付けるべきもので、殿にしかできぬこと(裁可・認証・外部への一声)ではない。
# よって以下の殿宛ntfyエスカレーション一式は発火させない。
# ★家老宛通知(256-271行)は一切変更せず正しく機能し続ける(dashboardにも従来どおり出る)。
# ★実装は消さず(cmd_783/784の履歴保全)、この exit で無効化する。復活は殿の明示裁定を要す。
exit 0

# 殿へのntfyは夜間は引き続き発火しない(殿のお休みを妨げぬため・現状維持)
$in_night && exit 0

# cmd_783【殿は最後の砦】: 家老通知から15分経ってもなお同一agentが停止中の
# 場合に限り殿宛エスカレーションへ進む。記録が無い(まだ家老通知1回目)か
# 15分未満、あるいは記録済みagentが全員解消済みなら、殿は起こさない。
# cmd_784 バグ①修正: 殿へ上げるのは「家老へ既に個別通知され(karo_notify_agents
# に登場)、かつ15分経過し、かつ現在も停止中」の★交差集合(escalate_agents)★のみ。
# 従前は karo_notify_agents に1人でも生存停止者がいれば lord_escalate=true とし、
# 殿へ送る文面に ${detail}(現在の停止agent全員)を使っていたため、家老へ一度も
# 個別通知されていない新規停止agentまで巻き込んで殿へ飛ばしていた(実測: 20:56に
# ashigaru1が、15分経過済みのashigaru5に相乗りする形で家老通知を経ずに殿へ飛んだ)。
# 新規停止agentは次の家老通知サイクル(snapshot更新)を経てから初めて対象になる。
lord_escalate=false
escalate_agents=()
if [ -f "$KARO_NOTIFIED_AGENTS_FILE" ]; then
  IFS=',' read -r karo_notify_epoch karo_notify_agents_csv < "$KARO_NOTIFIED_AGENTS_FILE"
  if [ -n "${karo_notify_epoch:-}" ] && [ $(( now_epoch - karo_notify_epoch )) -ge "$LORD_ESCALATION_WAIT_SEC" ]; then
    IFS=',' read -ra karo_notify_agents <<< "$karo_notify_agents_csv"
    for na in "${karo_notify_agents[@]}"; do
      [ -z "$na" ] && continue
      for sa in "${stalled_agents[@]}"; do
        if [ "$na" = "$sa" ]; then
          escalate_agents+=("$na")
          lord_escalate=true
          break
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

# ★殿へ送る文面は escalate_agents(交差集合)のみを列挙する(${detail}=現在の停止
# agent全員 を使ってはならない・バグ①の再発防止)
escalate_detail=$(IFS=', '; echo "${escalate_agents[*]}")
msg="🚨【死者確認スイッチ】status:blocked以外で放置中(家老通知後15分以上未解消): ${escalate_detail} @ $now_iso"
bash "$NTFY_SCRIPT" "$msg"
echo "$now_epoch" > "$LAST_FIRE_FILE"
printf '\n- 🚨 [deadman_switch] status:blocked以外で放置中(15分未解消): %s→ntfy送信 @ %s\n' "$escalate_detail" "$now_iso" >> "$DASHBOARD"
echo "[deadman_switch] $now_iso FIRED escalated=${escalate_agents[*]}" >> "$LOG_FILE"
