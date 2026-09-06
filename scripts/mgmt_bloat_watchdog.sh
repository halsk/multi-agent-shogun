#!/usr/bin/env bash
# scripts/mgmt_bloat_watchdog.sh — cmd_766 第三層(掃除機自身の監視)+第四層(閾値通知)
#
# 対象: 台帳(queue/shogun_to_karo.yaml)・dashboard.md・queue/inbox/*.yaml・
#       queue/tasks/*.yaml・queue/reports/*.yaml
#
# 第四層(check_layer4): 各ファイルの実サイズ(・件数)を lib/mgmt_bloat_thresholds.sh
#   の閾値と突き合わせ、超過→dashboard記録(cooldown付き)、大幅超過(閾値の2倍)
#   →ntfy(cooldown付き)。新しい通知経路は作らず scripts/ntfy.sh を呼ぶだけ。
#
# 第三層(check_layer3): scripts/slim_yaml.py が書く
#   queue/metrics/slim_yaml_last_run.json を見て、「いずれかの管理ファイルが
#   閾値超なのにarchived_count==0」という状態が K回連続の"別run"に渡って続いたら
#   掃除機自身の沈黙(meeting-link-sweep 13日死の再発)として通知する。
#   ★単純な「archived=0で即警報」にはしない。肥大が無い週の0件は正常であり、
#     『肥大あり且つ回収0』のAND条件+K回連続のヒステリシスで誤警報を防ぐ。
#     同一run(timestampが同じ)への複数tickではstreakを進めない
#     (このwatchdog自体は高頻度で叩かれる想定・slim_yamlは週次のため)。
#
# Usage: bash scripts/mgmt_bloat_watchdog.sh [--dry-run]
#
# Env overrides (テスト用の隔離):
#   SHOGUN_PROJECT_ROOT  — プロジェクトルート(既定: このスクリプトの親の親)
#   SHOGUN_QUEUE_DIR     — queueディレクトリ(既定: PROJECT_ROOT/queue)
#   SHOGUN_DASHBOARD_FILE — dashboard.mdのパス(既定: PROJECT_ROOT/dashboard.md)
#   MGMT_BLOAT_K         — 第三層のヒステリシスしきい値(既定: 3)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="${SHOGUN_PROJECT_ROOT:-$SCRIPT_DIR}"
QUEUE_DIR="${SHOGUN_QUEUE_DIR:-$PROJECT_ROOT/queue}"
DASHBOARD_FILE="${SHOGUN_DASHBOARD_FILE:-$PROJECT_ROOT/dashboard.md}"
STATE_DIR="$QUEUE_DIR/mgmt_bloat_watchdog"
LAST_RUN_FILE="$QUEUE_DIR/metrics/slim_yaml_last_run.json"
K="${MGMT_BLOAT_K:-3}"

# shellcheck source=../lib/mgmt_bloat_thresholds.sh
source "$PROJECT_ROOT/lib/mgmt_bloat_thresholds.sh"

DRY_RUN=false
for arg in "$@"; do
    [ "$arg" = "--dry-run" ] && DRY_RUN=true
done

DASHBOARD_COOLDOWN=$((12 * 3600))
NTFY_COOLDOWN=$((24 * 3600))

log() { echo "[mgmt_bloat_watchdog] $*" >&2; }

now_epoch() { date '+%s'; }
now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# ── state (cooldown / streak) ────────────────────────────────────────────
STATE_FILE="$STATE_DIR/state.yaml"

state_get() {
    local key="$1" default="${2:-}"
    [ -f "$STATE_FILE" ] || { echo "$default"; return; }
    local v
    v=$(grep -E "^${key}:" "$STATE_FILE" | head -1 | sed "s/^${key}:[[:space:]]*//" | tr -d '"')
    [ -z "$v" ] && v="$default"
    echo "$v"
}

state_set() {
    # dry-run中はcooldown/streak状態を一切書き換えない(観測専用の実行が
    # 以後の本番通知を握り潰す事故を防ぐ)。
    $DRY_RUN && return
    local key="$1" value="$2"
    mkdir -p "$STATE_DIR"
    [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
    if grep -qE "^${key}:" "$STATE_FILE" 2>/dev/null; then
        sed -i '' "s|^${key}:.*|${key}: ${value}|" "$STATE_FILE"
    else
        printf '%s: %s\n' "$key" "$value" >> "$STATE_FILE"
    fi
}

cooldown_ok() {
    local key="$1" seconds="$2"
    local last
    last=$(state_get "${key}_ts" "0")
    [ "$last" = "0" ] && return 0
    local now
    now=$(now_epoch)
    [ $(( now - last )) -ge "$seconds" ]
}

mark_notified() {
    state_set "${1}_ts" "$(now_epoch)"
}

# ── 通知先(既存の作法に相乗り) ─────────────────────────────────────────────

notify_dashboard() {
    local entry="$1"
    if $DRY_RUN; then
        log "[DRY-RUN] dashboard記録: $entry"
        return
    fi
    if [ -f "$DASHBOARD_FILE" ]; then
        local marker_line
        marker_line=$(grep -nE '要対応.*殿のご判断|🚨.*要対応' "$DASHBOARD_FILE" | head -1 | cut -d: -f1)
        if [ -n "$marker_line" ]; then
            local tmpfile
            tmpfile=$(mktemp)
            printf '%s\n' "$entry" > "$tmpfile"
            sed -i '' "${marker_line}r ${tmpfile}" "$DASHBOARD_FILE"
            rm -f "$tmpfile"
            return
        fi
    fi
    printf '\n%s\n' "$entry" >> "$DASHBOARD_FILE"
}

send_ntfy() {
    local msg="$1"
    if $DRY_RUN; then
        log "[DRY-RUN] ntfy送信: $msg"
        return
    fi
    bash "$PROJECT_ROOT/scripts/ntfy.sh" "$msg"
}

# ── 第四層: 閾値判定 ────────────────────────────────────────────────────────

# 閾値超過なら0(true)、そうでなければ1(false)を返す。副作用なし(通知しない)。
file_is_over() {
    local path="$1"
    [ -f "$path" ] || return 1
    local category
    category=$(mgmt_bloat_category_for_path "$path")
    [ -z "$category" ] && return 1

    local size threshold count count_threshold
    size=$(wc -c < "$path" | tr -d ' ')
    threshold=$(mgmt_bloat_threshold_bytes "$category")
    count=$(mgmt_bloat_count_for_file "$path" "$category")
    count_threshold=$(mgmt_bloat_threshold_count "$category")

    if [ "$threshold" -gt 0 ] && [ "$size" -ge "$threshold" ]; then
        return 0
    fi
    if [ "$count_threshold" -gt 0 ] && [ "$count" -ge "$count_threshold" ]; then
        return 0
    fi
    return 1
}

all_managed_files() {
    local f
    [ -f "$QUEUE_DIR/shogun_to_karo.yaml" ] && echo "$QUEUE_DIR/shogun_to_karo.yaml"
    [ -f "$DASHBOARD_FILE" ] && echo "$DASHBOARD_FILE"
    for f in "$QUEUE_DIR"/inbox/*.yaml; do [ -f "$f" ] && echo "$f"; done
    for f in "$QUEUE_DIR"/tasks/*.yaml; do [ -f "$f" ] && echo "$f"; done
    for f in "$QUEUE_DIR"/reports/*.yaml; do [ -f "$f" ] && echo "$f"; done
}

any_managed_file_over() {
    local f
    while IFS= read -r f; do
        file_is_over "$f" && return 0
    done < <(all_managed_files)
    return 1
}

check_one_file() {
    local path="$1"
    file_is_over "$path" || return 0

    local category size threshold far_threshold rel state_key
    category=$(mgmt_bloat_category_for_path "$path")
    size=$(wc -c < "$path" | tr -d ' ')
    threshold=$(mgmt_bloat_threshold_bytes "$category")
    far_threshold=$(( threshold * $(mgmt_bloat_far_exceed_factor) ))
    rel="${path#"$PROJECT_ROOT"/}"
    state_key="size_$(printf '%s' "$rel" | tr '/.' '__')"

    if cooldown_ok "$state_key" "$DASHBOARD_COOLDOWN"; then
        notify_dashboard "- 🚨 [mgmt_bloat_watchdog] ${rel} がサイズ上限超過(${size}B ≥ ${threshold}B, category=${category}) @ $(now_iso)"
        mark_notified "$state_key"
    fi

    if [ "$threshold" -gt 0 ] && [ "$size" -ge "$far_threshold" ]; then
        local ntfy_key="ntfy_${state_key}"
        if cooldown_ok "$ntfy_key" "$NTFY_COOLDOWN"; then
            send_ntfy "mgmt_bloat_watchdog: ${rel} が大幅超過(${size}B ≥ ${far_threshold}B)。回収を確認せよ"
            mark_notified "$ntfy_key"
        fi
    fi
}

check_layer4() {
    local f
    while IFS= read -r f; do
        check_one_file "$f"
    done < <(all_managed_files)
}

# ── 第三層: 掃除機自身の監視(ヒステリシス) ──────────────────────────────────

check_layer3() {
    if [ ! -f "$LAST_RUN_FILE" ]; then
        log "layer3: last-run.json不在(slim_yaml未実行)・skip"
        return 0
    fi

    local run_ts archived_count
    run_ts=$(python3 -c "import json; d=json.load(open('$LAST_RUN_FILE')); print(d.get('timestamp',''))" 2>/dev/null)
    archived_count=$(python3 -c "import json; d=json.load(open('$LAST_RUN_FILE')); print(d.get('archived_count',0))" 2>/dev/null)

    if [ -z "$run_ts" ]; then
        log "layer3: last-run.json不正・skip"
        return 0
    fi

    local last_seen
    last_seen=$(state_get "layer3_last_seen_run_ts" "")

    if [ "$run_ts" = "$last_seen" ]; then
        log "layer3: 新しいrunなし(ts=$run_ts)・streak判定skip"
        return 0
    fi

    local streak
    streak=$(state_get "layer3_streak" "0")

    if any_managed_file_over && [ "$archived_count" = "0" ]; then
        streak=$((streak + 1))
        log "layer3: 肥大あり且つarchived=0 (run=$run_ts) → streak=$streak"
    else
        if [ "$streak" != "0" ]; then
            log "layer3: 正常run検知(archived=$archived_count) → streakリセット"
        fi
        streak=0
    fi

    state_set "layer3_streak" "$streak"
    state_set "layer3_last_seen_run_ts" "$run_ts"

    if [ "$streak" -ge "$K" ]; then
        if cooldown_ok "layer3_notify" "$NTFY_COOLDOWN"; then
            notify_dashboard "- 🚨 [mgmt_bloat_watchdog] slim_yamlが${streak}回連続で『肥大あり且つ回収0』。掃除機停止の疑い @ $(now_iso)"
            send_ntfy "mgmt_bloat_watchdog: slim_yamlが${streak}回連続で回収0。掃除機(週次slim_yaml)が死んでいないか確認せよ"
            mark_notified "layer3_notify"
        fi
    fi
}

# ── テスト用source ガード ────────────────────────────────────────────────────
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

# ── flock 単一起動(stall_watchdog.shと同じ作法) ─────────────────────────────
# 実行が長引いて次のtickと重なった場合、state.yaml への並行read-modify-write
# (cooldown/streak破損・二重通知)を防ぐ。dry-runでも state_dir 自体は
# 副作用として作られるが、state.yaml(cooldown本体)はstate_setのdry-run
# ガードで別途守られている。
mkdir -p "$STATE_DIR"
LOCK_FILE="$STATE_DIR/.lock"
if command -v flock &>/dev/null; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "already running (lock held) — exiting"
        exit 0
    fi
else
    _ld="${LOCK_FILE}.d"; _i=0
    while ! mkdir "$_ld" 2>/dev/null; do sleep 0.1; _i=$((_i+1)); [ $_i -ge 300 ] && { log "already running (lock held) — exiting"; exit 0; }; done
    trap "rmdir '$_ld' 2>/dev/null" EXIT
fi

# ── メイン実行 ──────────────────────────────────────────────────────────────
check_layer4
check_layer3
