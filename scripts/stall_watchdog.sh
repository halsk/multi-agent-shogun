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
    echo "$1" | md5 2>/dev/null | cut -c1-8 \
        || echo "$1" | md5sum | cut -c1-8
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
    # session_many_clients が 1 以上かつ pane_active ならば抑制
    local clients
    clients=$(tmux display-message -t "$pane" -p '#{session_many_clients}' 2>/dev/null || echo "0")
    local active
    active=$(tmux display-message -t "$pane" -p '#{pane_active}' 2>/dev/null || echo "0")
    [[ "$clients" -ge 1 && "$active" == "1" ]]
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
    if [[ "$status" != "in_progress" && "$status" != "work" ]]; then
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
        continue
    fi

    # pane テキスト取得
    pane_text=$(tmux capture-pane -t "$pane" -p 2>/dev/null | tail -40)
    sig=$(classify_pane "$pane_text")

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

log "[DONE] stall_watchdog scan complete"
