#!/usr/bin/env bash
# scripts/yaml_slim_weekly.sh — 週次 YAML slim ジョブ (cmd_766 第二層)
#
# scripts/slim_yaml.sh karo を週次で実行し、台帳/task/report/inbox を退避する。
# 退避であって削除でない(slim_yaml.py は rename のみ・rm を呼ばない)。
#
# launchd から週次 (com.swarm.yaml-slim.plist) で起動される。
# HC dead-man's-switch: HC_PING_URL_YAMLSLIM は yaml-slim-launcher.sh が
# Keychain (hc-ping-url-yaml-slim) から注入する。sweep.sh 直叩き誤り
# (cmd_767 教訓)を繰り返さぬこと — このスクリプト単体で叩いても
# HC_PING_URL_YAMLSLIM は空のまま no-op になるのは仕様通り。
#
# フラグ:
#   --dry-run : slim_yaml.sh 側にも --dry-run を渡す。curl は呼ばない。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_FILE="${PROJECT_ROOT}/logs/yaml_slim_weekly.log"

mkdir -p "${PROJECT_ROOT}/logs"

DRY_RUN=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

log() {
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# ── 単一起動ガード (slim_yaml.sh 自身の queue lock とは別に、ジョブ自体の多重起動防止) ──
# flock が無い環境(macOSはutil-linuxのflockを標準搭載しない)では
# mkdir ベースのロックにフォールバックする。「flock: command not found」を
# 「ロック取得済み」と誤認して黙って no-op する事故があった(macOS CI実測)。
LOCK_FILE="/tmp/yaml_slim_weekly.lock"
if command -v flock &>/dev/null; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "[yaml_slim_weekly] already running (lock held). exiting." >&2
        exit 0
    fi
else
    LOCK_DIR="${LOCK_FILE}.d"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "[yaml_slim_weekly] already running (lock held). exiting." >&2
        exit 0
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
fi

log "[START] yaml_slim_weekly dry_run=$DRY_RUN"

slim_args=(karo)
$DRY_RUN && slim_args+=(--dry-run)

slim_output=$(bash "${SCRIPT_DIR}/slim_yaml.sh" "${slim_args[@]}" 2>&1)
slim_exit=$?
log "$slim_output"

if [[ $slim_exit -ne 0 ]]; then
    log "[ERROR] slim_yaml.sh karo failed (exit=$slim_exit)"
    exit 1
fi

log "[DONE] yaml_slim_weekly scan complete"

# Healthchecks.io ping — 週次回収完了 (HC_PING_URL_YAMLSLIM 未設定時は no-op)
if [[ -n "${HC_PING_URL_YAMLSLIM:-}" ]] && ! $DRY_RUN; then
    curl -fsS -m 5 --retry 2 "${HC_PING_URL_YAMLSLIM}" >/dev/null 2>&1 || true
fi

exit 0
