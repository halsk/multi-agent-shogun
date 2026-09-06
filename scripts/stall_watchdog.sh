#!/usr/bin/env bash
# scripts/stall_watchdog.sh — Stall Watchdog
#
# タスク実行中に無音固着したエージェントを検知し段階的にエスカレーションする。
# launchd から5分毎に起動される。
#
# フラグ:
#   --dry-run          : 検知結果と予定アクションを stdout に出すのみ。inbox_write/ntfy は呼ばない。
#   --observation-only : P2 /clear を送らない (デフォルト有効)。P3 通知のみ。
#
# 段階起動ポリシー: 初期は --observation-only で誤検知実証してから P2 を有効化する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# ── ライブラリ読み込み ──────────────────────────────────────────────────────
# shellcheck source=../lib/agent_status.sh
source "$SCRIPT_DIR/lib/agent_status.sh"
# shellcheck source=../lib/stall_detect.sh
source "$SCRIPT_DIR/lib/stall_detect.sh"
# shellcheck source=../lib/ledger_mismatch_detect.sh
# cmd_766 第一層: report done なのに台帳 cmd が pending/in_progress のまま
# 残っている「done未遷移」を検知する(cmd_741 第二層watchdogへ相乗り・新機構は作らない)
source "$SCRIPT_DIR/lib/ledger_mismatch_detect.sh"

# ── フラグ解析 ────────────────────────────────────────────────────────────────
DRY_RUN=false
OBSERVATION_ONLY=true   # デフォルト有効

for arg in "$@"; do
    case "$arg" in
        --dry-run)          DRY_RUN=true ;;
        --observation-only) OBSERVATION_ONLY=true ;;
        --no-observation-only) OBSERVATION_ONLY=false ;;
    esac
done

# ── 定数 ──────────────────────────────────────────────────────────────────────
ALL_AGENTS=(shogun karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7 gunshi gunshi2)
STATE_DIR="$SCRIPT_DIR/queue/stall_watchdog"
LOG_FILE="$SCRIPT_DIR/logs/stall_watchdog.log"

# エスカレーション grace (秒)
GRACE_P1=$((20 * 60))   # 20分
GRACE_P2=$((10 * 60))   # P1後+10分
GRACE_P3=$((10 * 60))   # P2後+10分

# cooldown (同一 phase 再送防止)
COOLDOWN_P1=$((10 * 60))
COOLDOWN_P23=$((15 * 60))

# cmd_766 第一層: report done vs 台帳 pending/in_progress の許容経過時間(目安6h・gunshi設計)
LEDGER_MISMATCH_THRESHOLD=$((6 * 60 * 60))

# cmd_771 fix_e: human attach中(E4)の抑止上限。これを超えたら
# 「attachしたまま放置」とみなし通知する(gunshi設計目安=1時間)
E4_SUPPRESS_LIMIT=$((60 * 60))

mkdir -p "$STATE_DIR" logs

# ── ユーティリティ関数 ──────────────────────────────────────────────────────

log() {
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    local msg="[$ts] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

now_epoch() {
    date '+%s'
}

iso_to_epoch() {
    local iso="$1"
    # macOS: date -j -f
    date -j -f '%Y-%m-%dT%H:%M:%S' "${iso%%+*}" '+%s' 2>/dev/null \
        || date -d "$iso" '+%s' 2>/dev/null \
        || echo "0"
}

now_iso() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

md5_short() {
    # macOS: md5 is /sbin/md5 (not in launchd PATH); md5sum is GNU-only.
    # shasum is /usr/bin/shasum on macOS and is in launchd PATH (/usr/bin).
    if command -v md5sum >/dev/null 2>&1; then
        echo "$1" | md5sum | cut -c1-8
    else
        echo "$1" | shasum | cut -c1-8
    fi
}

# タスク YAML の status を取得
task_status() {
    local agent="$1"
    local yaml
    yaml=$(find "$SCRIPT_DIR/queue/tasks" -name "${agent}.yaml" 2>/dev/null | head -1)
    if [[ -z "$yaml" ]]; then
        echo "none"
        return
    fi
    grep -E '^\s*status:\s*' "$yaml" | head -1 | sed 's/.*status:[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d ' '
}

# state ファイル読み取り (フィールドがなければデフォルト)
state_get() {
    local agent="$1"
    local field="$2"
    local default="${3:-}"
    local state_file="$STATE_DIR/${agent}.yaml"
    if [[ ! -f "$state_file" ]]; then
        echo "$default"
        return
    fi
    grep -E "^${field}:" "$state_file" | head -1 | sed "s/^${field}:[[:space:]]*//" | tr -d '"' | tr -d "'" \
        || echo "$default"
}

# state ファイル書き込み (フィールド単体の upsert)
state_set() {
    local agent="$1"
    local field="$2"
    local value="$3"
    local state_file="$STATE_DIR/${agent}.yaml"

    # 初期化
    if [[ ! -f "$state_file" ]]; then
        printf 'agent_id: %s\n' "$agent" > "$state_file"
    fi

    if grep -qE "^${field}:" "$state_file" 2>/dev/null; then
        # sed で該当行を置換 (macOS/BSD 対応)
        sed -i '' "s|^${field}:.*|${field}: ${value}|" "$state_file"
    else
        printf '%s: %s\n' "$field" "$value" >> "$state_file"
    fi
}

# state をリセット (escalation_phase=0)
reset_state() {
    local agent="$1"
    local current_phase
    current_phase=$(state_get "$agent" "escalation_phase" "0")
    if [[ "$current_phase" != "0" ]]; then
        log "[RESET] $agent: escalation_phase → 0"
        state_set "$agent" "escalation_phase" "0"
        state_set "$agent" "last_action" "none"
        state_set "$agent" "pane_hash" ""
        state_set "$agent" "pane_hash_since" ""
        state_set "$agent" "stall_signature" "none"
    fi
}

# pane に人間が attach 中かつアクティブか (E4)
pane_has_human_client() {
    local pane="$1"
    # session_attached が 1 以上かつ pane_active ならば抑制
    local clients
    clients=$(tmux display-message -t "$pane" -p '#{session_attached}' 2>/dev/null || echo "0")
    local active
    active=$(tmux display-message -t "$pane" -p '#{pane_active}' 2>/dev/null || echo "0")
    [[ "$clients" -ge 1 && "$active" == "1" ]]
}

# ── cmd_771 fix_e: E4(human attach中)抑止に上限を設ける ─────────────────────
# attachしたまま離席されると実stallが隠れる(実測1830件抑止)ため、抑止が
# 連続 E4_SUPPRESS_LIMIT 秒を超えたら1回だけ通知する(以後は連続通知しない・
# stateがresetされるまで再送しない)。

notify_dashboard_e4_limit() {
    local agent="$1"
    local elapsed="$2"
    local ts
    ts=$(now_iso)
    local minutes=$(( elapsed / 60 ))
    local entry="- 🚨 [e4_suppress_limit] ${agent}: human attach抑止(E4)が約${minutes}分継続中。attachしたまま放置されていないか確認せよ @ $ts"
    local dashboard="$SCRIPT_DIR/dashboard.md"
    if [[ -f "$dashboard" ]] && grep -q '🚨要対応' "$dashboard"; then
        sed -i '' "/🚨要対応/a\\
$entry
" "$dashboard"
    else
        printf '\n%s\n' "$entry" >> "$dashboard"
    fi
}

send_ntfy_e4_limit() {
    local agent="$1"
    local elapsed="$2"
    local minutes=$(( elapsed / 60 ))
    bash "$SCRIPT_DIR/scripts/ntfy.sh" "e4_suppress_limit: ${agent} のhuman attach抑止が約${minutes}分継続中。attachしたまま放置されていないか確認せよ。"
}

# attach抑止が続いている間、経過時間を state に記録し上限超過時に1回通知する
check_e4_suppress_limit() {
    local agent="$1"

    local since
    since=$(state_get "$agent" "e4_skip_since" "")
    if [[ -z "$since" ]]; then
        state_set "$agent" "e4_skip_since" "$(now_iso)"
        return
    fi

    local since_epoch elapsed now
    since_epoch=$(iso_to_epoch "$since")
    now=$(now_epoch)
    elapsed=$(( now - since_epoch ))

    if [[ "$elapsed" -ge "$E4_SUPPRESS_LIMIT" ]]; then
        local already
        already=$(state_get "$agent" "e4_limit_notified" "false")
        if [[ "$already" != "true" ]]; then
            log "[E4-LIMIT] $agent: human attach抑止が${elapsed}s(上限${E4_SUPPRESS_LIMIT}s)超過 → 通知"
            if $DRY_RUN; then
                log "[DRY-RUN] would notify E4 limit exceeded for $agent"
            else
                notify_dashboard_e4_limit "$agent" "$elapsed"
                send_ntfy_e4_limit "$agent" "$elapsed"
            fi
            state_set "$agent" "e4_limit_notified" "true"
        fi
    fi
}

# attach が外れた/pane が非アクティブになった時に抑止 state をリセットする
reset_e4_suppress_state() {
    local agent="$1"
    state_set "$agent" "e4_skip_since" ""
    state_set "$agent" "e4_limit_notified" "false"
}

# ── エスカレーション ──────────────────────────────────────────────────────────

send_inbox() {
    local agent="$1"
    local msg="$2"
    local type="$3"
    if $DRY_RUN; then
        log "[DRY-RUN] inbox_write → $agent type=$type msg='$msg'"
        return
    fi
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" "$agent" "$msg" "$type" "stall_watchdog"
}

# dashboard 🚨 追記
notify_dashboard() {
    local agent="$1"
    local sig="$2"
    local ts
    ts=$(now_iso)
    local entry="- 🚨 [stall_watchdog] $agent が $sig で固着 (P3 到達) @ $ts"
    if $DRY_RUN; then
        log "[DRY-RUN] dashboard 🚨 追記: $entry"
        return
    fi
    # dashboard.md の 🚨要対応 セクションに追記
    local dashboard="$SCRIPT_DIR/dashboard.md"
    if [[ -f "$dashboard" ]] && grep -q '🚨要対応' "$dashboard"; then
        # 🚨要対応 直後の行に挿入
        sed -i '' "/🚨要対応/a\\
$entry
" "$dashboard"
    else
        printf '\n%s\n' "$entry" >> "$dashboard"
    fi
}

send_ntfy() {
    local agent="$1"
    local sig="$2"
    if $DRY_RUN; then
        log "[DRY-RUN] ntfy.sh push: $agent stall=$sig"
        return
    fi
    bash "$SCRIPT_DIR/scripts/ntfy.sh" "stall_watchdog: $agent が $sig で固着。手動確認せよ。"
}

escalate() {
    local agent="$1"
    local elapsed="$2"
    local sig="$3"

    local phase
    phase=$(state_get "$agent" "escalation_phase" "0")
    local last_action_ts
    last_action_ts=$(state_get "$agent" "last_action_ts" "0")
    local now
    now=$(now_epoch)
    local ts_epoch
    ts_epoch=$(iso_to_epoch "$last_action_ts")
    local since_last=$(( now - ts_epoch ))

    # P1: 20分経過かつ phase=0
    if [[ "$elapsed" -ge "$GRACE_P1" && "$phase" == "0" ]]; then
        if [[ "$since_last" -ge "$COOLDOWN_P1" ]] || [[ "$last_action_ts" == "0" ]]; then
            # E5: shogun へは P1 nudge も /clear も送らない (P3 のみ)
            if [[ "$agent" == "shogun" ]]; then
                log "[P1-SKIP-E5] $agent: shogun への inbox nudge は絶対送らない (P3のみ)"
                state_set "$agent" "last_action" "p1_skipped_shogun"
            else
                log "[P1] $agent: stall=$sig elapsed=${elapsed}s → sending nudge"
                send_inbox "$agent" "watchdog: タスク実行中に見えるが無音。status を確認し再開/報告せよ" "report_received"
                state_set "$agent" "last_action" "nudge_sent"
            fi
            state_set "$agent" "escalation_phase" "1"
            state_set "$agent" "last_action_ts" "$(now_iso)"
        fi
        return
    fi

    # P2: P1後+10分経過かつ phase=1
    local grace_p2=$(( GRACE_P1 + GRACE_P2 ))
    if [[ "$elapsed" -ge "$grace_p2" && "$phase" == "1" ]]; then
        if [[ "$since_last" -ge "$COOLDOWN_P23" ]] || [[ "$last_action_ts" == "0" ]]; then
            # E5: shogun は /clear 絶対しない
            if [[ "$agent" == "shogun" ]]; then
                log "[P2-SKIP-E5] $agent: shogun への /clear は絶対送らない"
            elif $OBSERVATION_ONLY; then
                log "[P2-OBS] $agent: observation-only mode — /clear 抑止 (sig=$sig)"
            else
                log "[P2] $agent: stall=$sig elapsed=${elapsed}s → sending /clear"
                send_inbox "$agent" "" "clear_command"
                state_set "$agent" "escalation_phase" "2"
                state_set "$agent" "last_action" "clear_sent"
                state_set "$agent" "last_action_ts" "$(now_iso)"
                return
            fi
            # observation-only / shogun でもフェーズは進める (P3 に繋げるため)
            state_set "$agent" "escalation_phase" "2"
            state_set "$agent" "last_action" "clear_skipped_obs"
            state_set "$agent" "last_action_ts" "$(now_iso)"
        fi
        return
    fi

    # P3: P2後+10分経過かつ phase=2
    local grace_p3=$(( GRACE_P1 + GRACE_P2 + GRACE_P3 ))
    if [[ "$elapsed" -ge "$grace_p3" && "$phase" == "2" ]]; then
        if [[ "$since_last" -ge "$COOLDOWN_P23" ]] || [[ "$last_action_ts" == "0" ]]; then
            log "[P3] $agent: stall=$sig elapsed=${elapsed}s → dashboard + ntfy"
            notify_dashboard "$agent" "$sig"
            send_ntfy "$agent" "$sig"
            state_set "$agent" "escalation_phase" "3"
            state_set "$agent" "last_action" "notified"
            state_set "$agent" "last_action_ts" "$(now_iso)"
        fi
        return
    fi

    log "[WATCH] $agent: stall=$sig elapsed=${elapsed}s phase=$phase (no action yet)"
}

# ── cmd_766 第一層: report-done-but-ledger-pending 検知 ──────────────────────

notify_dashboard_ledger_mismatch() {
    local cmd_id="$1"
    local report_file="$2"
    local ledger_status="$3"
    local age="$4"
    local ts
    ts=$(now_iso)
    local hours=$(( age / 3600 ))
    local entry="- 🚨 [ledger_mismatch] ${cmd_id}: ${report_file##*/} はdone報告済だが台帳status=${ledger_status}のまま約${hours}時間経過 @ $ts"
    local dashboard="$SCRIPT_DIR/dashboard.md"
    if [[ -f "$dashboard" ]] && grep -q '🚨要対応' "$dashboard"; then
        sed -i '' "/🚨要対応/a\\
$entry
" "$dashboard"
    else
        printf '\n%s\n' "$entry" >> "$dashboard"
    fi
}

send_ntfy_ledger_mismatch() {
    local cmd_id="$1"
    local ledger_status="$2"
    bash "$SCRIPT_DIR/scripts/ntfy.sh" "ledger_mismatch: ${cmd_id} がdone報告済なのに台帳${ledger_status}のまま。是正せよ。"
}

check_ledger_mismatches() {
    local reports_dir="$SCRIPT_DIR/queue/reports"
    local ledger_file="$SCRIPT_DIR/queue/shogun_to_karo.yaml"

    local cmd_id report_file ledger_status age
    while IFS='|' read -r cmd_id report_file ledger_status age; do
        [[ -z "$cmd_id" ]] && continue

        local state_key="ledger_mismatch__${cmd_id}"
        local already_notified
        already_notified=$(state_get "$state_key" "notified_status" "")
        if [[ "$already_notified" == "$ledger_status" ]]; then
            # 同一状態を既に通知済み → 再送しない(スパム防止)
            continue
        fi

        log "[LEDGER-MISMATCH] $cmd_id: report=done ledger=$ledger_status age=${age}s"
        if $DRY_RUN; then
            log "[DRY-RUN] would notify dashboard+ntfy for $cmd_id"
            continue
        fi
        notify_dashboard_ledger_mismatch "$cmd_id" "$report_file" "$ledger_status" "$age"
        send_ntfy_ledger_mismatch "$cmd_id" "$ledger_status"
        state_set "$state_key" "notified_status" "$ledger_status"
    done < <(detect_ledger_mismatches "$reports_dir" "$ledger_file" "$LEDGER_MISMATCH_THRESHOLD")
}

# ── cmd_766 第一層 相乗り: blocked/blocked_needs_decisionでblocked_on/
# blocked_reason空の検知(2026-09-06 ashigaru4→ashigaru5で2度実測された欠陥) ──

notify_dashboard_blocked_reason_gap() {
    local file_name="$1"
    local status="$2"
    local ts
    ts=$(now_iso)
    local entry="- 🚨 [blocked_reason_gap] ${file_name}: status=${status}なのにblocked_on/blocked_reasonが空 @ $ts"
    local dashboard="$SCRIPT_DIR/dashboard.md"
    if [[ -f "$dashboard" ]] && grep -q '🚨要対応' "$dashboard"; then
        sed -i '' "/🚨要対応/a\\
$entry
" "$dashboard"
    else
        printf '\n%s\n' "$entry" >> "$dashboard"
    fi
}

send_ntfy_blocked_reason_gap() {
    local file_name="$1"
    local status="$2"
    bash "$SCRIPT_DIR/scripts/ntfy.sh" "blocked_reason_gap: ${file_name} がstatus=${status}なのにblocked_on/blocked_reasonが空。実態を書け。"
}

check_blocked_reason_gaps() {
    local tasks_dir="$SCRIPT_DIR/queue/tasks"

    local file_name status
    while IFS='|' read -r file_name status; do
        [[ -z "$file_name" ]] && continue

        local state_key="blocked_reason_gap__${file_name}"
        local already_notified
        already_notified=$(state_get "$state_key" "notified_status" "")
        if [[ "$already_notified" == "$status" ]]; then
            # 同一状態を既に通知済み → 再送しない(スパム防止)
            continue
        fi

        log "[BLOCKED-REASON-GAP] $file_name: status=$status blocked_on/blocked_reason空"
        if $DRY_RUN; then
            log "[DRY-RUN] would notify dashboard+ntfy for $file_name"
            continue
        fi
        notify_dashboard_blocked_reason_gap "$file_name" "$status"
        send_ntfy_blocked_reason_gap "$file_name" "$status"
        state_set "$state_key" "notified_status" "$status"
    done < <(detect_blocked_reason_gaps "$tasks_dir")
}

# ── cmd_771 fix_c 相乗り: 孤児cmd(idle足軽+台帳の未完了cmdが誰にも
# 割り当てられていない状態)の検知 ────────────────────────────────────────────

# 全ashigaruのpaneが idle かどうかを判定する(孤児cmdの(b)条件用)。
# pane不在(busy_rc=2)は個別には判定対象外とし誤検知を避けるが、
# ★1体も観測できなかった場合(tmux/セッション全断等)は「全員idle」と
# 断定せずfalseを返す——さもないとinfra障害を「全員idleだから孤児」と
# 誤認し、割当ありcmdまで誤って孤児扱いしてしまう(fail-safe側に倒す)。
all_ashigaru_idle() {
    local agent pane busy_rc observed=0
    for agent in ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7; do
        pane=$(resolve_pane_by_agent_id "$agent")
        [[ -z "$pane" ]] && continue
        observed=1
        busy_rc=0
        agent_is_busy_check "$pane" || busy_rc=$?
        if [[ "$busy_rc" -eq 0 ]]; then
            echo "false"
            return
        fi
    done
    if [[ "$observed" -eq 0 ]]; then
        echo "false"
        return
    fi
    echo "true"
}

notify_dashboard_orphan_cmd() {
    local cmd_id="$1"
    local status="$2"
    local ts
    ts=$(now_iso)
    local entry="- 🚨 [orphan_cmd] ${cmd_id}: 台帳status=${status}だが誰にも割り当てられていない(孤児cmd) @ $ts"
    local dashboard="$SCRIPT_DIR/dashboard.md"
    if [[ -f "$dashboard" ]] && grep -q '🚨要対応' "$dashboard"; then
        sed -i '' "/🚨要対応/a\\
$entry
" "$dashboard"
    else
        printf '\n%s\n' "$entry" >> "$dashboard"
    fi
}

send_ntfy_orphan_cmd() {
    local cmd_id="$1"
    local status="$2"
    bash "$SCRIPT_DIR/scripts/ntfy.sh" "orphan_cmd: ${cmd_id}(台帳status=${status})が誰にも割り当てられていない。task起票せよ。"
}

check_orphan_cmds() {
    local ledger_file="$SCRIPT_DIR/queue/shogun_to_karo.yaml"
    local tasks_dir="$SCRIPT_DIR/queue/tasks"

    local idle_flag
    idle_flag=$(all_ashigaru_idle)

    local cmd_id status
    while IFS='|' read -r cmd_id status; do
        [[ -z "$cmd_id" ]] && continue

        local state_key="orphan_cmd__${cmd_id}"
        local already_notified
        already_notified=$(state_get "$state_key" "notified_status" "")
        if [[ "$already_notified" == "$status" ]]; then
            # 同一状態を既に通知済み → 再送しない(スパム防止)
            continue
        fi

        log "[ORPHAN-CMD] $cmd_id: status=$status 誰にも割り当てられていない(all_ashigaru_idle=$idle_flag)"
        if $DRY_RUN; then
            log "[DRY-RUN] would notify dashboard+ntfy for $cmd_id (orphan)"
            continue
        fi
        notify_dashboard_orphan_cmd "$cmd_id" "$status"
        send_ntfy_orphan_cmd "$cmd_id" "$status"
        state_set "$state_key" "notified_status" "$status"
    done < <(detect_orphan_cmds "$ledger_file" "$tasks_dir" "$idle_flag")
}

# ── テスト用 source ガード ────────────────────────────────────────────────────
# source して関数だけ使う場合はここでリターン (flock・メインループをスキップ)
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

# ── flock 単一起動 ────────────────────────────────────────────────────────────
LOCK_FILE="/tmp/stall_watchdog.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[stall_watchdog] already running (lock held). exiting." >&2
    exit 0
fi

# ── メインループ ──────────────────────────────────────────────────────────────

log "[START] stall_watchdog dry_run=$DRY_RUN observation_only=$OBSERVATION_ONLY"

for agent in "${ALL_AGENTS[@]}"; do
    status=$(task_status "$agent")

    # 対象外 status → state リセットして次へ
    # cmd_771 fix_e: assigned状態の滞留はstatusフィルタ外だった穴を埋める
    if [[ "$status" != "in_progress" && "$status" != "work" && "$status" != "assigned" ]]; then
        reset_state "$agent"
        continue
    fi

    # pane を解決
    pane=$(resolve_pane_by_agent_id "$agent")
    if [[ -z "$pane" ]]; then
        log "[SKIP] $agent: pane not found"
        continue
    fi

    # E1/E2: agent_is_busy_check → 0=稼働中/1=idle/2=不在
    # set -e 下では rc≠0 で即 exit するため || busy_rc=$? で抑止する
    busy_rc=0
    agent_is_busy_check "$pane" || busy_rc=$?
    if [[ "$busy_rc" -eq 0 ]]; then
        reset_state "$agent"
        continue
    fi
    if [[ "$busy_rc" -eq 2 ]]; then
        log "[SKIP] $agent: pane absent (busy_check=2)"
        continue
    fi

    # E4: 人間 attach 中
    if pane_has_human_client "$pane"; then
        log "[SKIP-E4] $agent: human client attached and pane active"
        check_e4_suppress_limit "$agent"
        continue
    fi
    reset_e4_suppress_state "$agent"

    # pane テキスト取得
    pane_text=$(tmux capture-pane -t "$pane" -p 2>/dev/null | tail -40)
    sig=$(classify_pane "$pane_text")

    # permission_prompt シグネチャ → P1/P2 (nudge/clear) を経由させず、
    # cmd_767 既存機構(dashboard🚨+ntfy)へ直接相乗りして通知のみ行う。
    # ★★★理由: P1のnudgeもP2の/clearも tmux 経由でキー入力(Enter含む)を
    # 送る。許可プロンプト表示中に Enter が届けば、カーソル選択中の項目
    # (既定で先頭の "Yes")を誤って確定させ、自動応答(絶対禁止)と同じ
    # 結果になる恐れがある。よって通常のエスカレーション段階を踏ませず、
    # 検知したその場で通知のみ行い、以後は自動操作を一切行わない。
    if [[ "$sig" == "permission_prompt" ]]; then
        current_hash_pp=$(md5_short "$pane_text")
        already_notified_pp=$(state_get "$agent" "permission_prompt_notified_hash" "")
        if [[ "$already_notified_pp" != "$current_hash_pp" ]]; then
            log "[PERMISSION-PROMPT] $agent: 許可プロンプト検知 → dashboard+ntfy通知のみ(自動応答なし)"
            notify_dashboard "$agent" "permission_prompt"
            send_ntfy "$agent" "permission_prompt"
            state_set "$agent" "permission_prompt_notified_hash" "$current_hash_pp"
        else
            log "[PERMISSION-PROMPT] $agent: 同一状態を既に通知済み(再送抑止)"
        fi
        continue
    fi

    # busy シグネチャ → リセット
    if [[ "$sig" == "busy" ]]; then
        reset_state "$agent"
        continue
    fi

    # pane hash でテキスト変化を追跡
    current_hash=$(md5_short "$pane_text")
    saved_hash=$(state_get "$agent" "pane_hash" "")
    now=$(now_epoch)

    if [[ "$current_hash" != "$saved_hash" ]]; then
        # テキストが変化 → ハッシュ更新・エスカレーション中断
        log "[CHANGE] $agent: pane changed (sig=$sig) → reset escalation"
        state_set "$agent" "pane_hash" "$current_hash"
        state_set "$agent" "pane_hash_since" "$(now_iso)"
        state_set "$agent" "stall_signature" "$sig"
        state_set "$agent" "escalation_phase" "0"
        state_set "$agent" "last_action" "none"
        state_set "$agent" "last_action_ts" "$(now_iso)"
        continue
    fi

    # ハッシュ同一 → 経過時間を計算
    pane_hash_since=$(state_get "$agent" "pane_hash_since" "")
    if [[ -z "$pane_hash_since" ]]; then
        # 初回記録
        state_set "$agent" "pane_hash" "$current_hash"
        state_set "$agent" "pane_hash_since" "$(now_iso)"
        state_set "$agent" "stall_signature" "$sig"
        continue
    fi

    since_epoch=$(iso_to_epoch "$pane_hash_since")
    elapsed=$(( now - since_epoch ))

    log "[STALL] $agent: sig=$sig elapsed=${elapsed}s hash=$current_hash"
    escalate "$agent" "$elapsed" "$sig"
done

# cmd_766 第一層: report done vs 台帳 pending/in_progress の突き合わせ(全agent scan後・1回のみ)
check_ledger_mismatches

# cmd_766 第一層 相乗り: blocked/blocked_needs_decisionでblocked_on/blocked_reason空の検知
check_blocked_reason_gaps

# cmd_771 fix_c 相乗り: 孤児cmd(誰にも割り当てられていない未完了cmd)の検知
check_orphan_cmds

log "[DONE] stall_watchdog scan complete"

# cmd_771 ④ 24時間計数報告(自己ゲート・既存5分周期に相乗り・新規launchd不要)
bash "$SCRIPT_DIR/scripts/stall_watchdog_report.sh" || true

# Healthchecks.io ping — scan tick 完了 (HC_PING_URL_STALL_WATCHDOG 未設定時は no-op)
if [[ -n "${HC_PING_URL_STALL_WATCHDOG:-}" ]] && ! $DRY_RUN; then
    curl -fsS -m 5 --retry 2 "${HC_PING_URL_STALL_WATCHDOG}" >/dev/null 2>&1 || true
fi
