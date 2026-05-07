#!/usr/bin/env bash
# Layer 1: warn when non-policy remote branches age past the configured limit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/branch_policy.sh
source "$SCRIPT_DIR/lib/branch_policy.sh"

DRY_RUN=0
NO_FETCH=0

usage() {
    cat <<'EOF'
Usage: branch_drift_check.sh [--dry-run] [--no-fetch] [--settings PATH]

Checks branch_policy.monitored_repos for remote branches that are not listed in
branch_policy.allowed_long_lived and are older than branch_policy.max_age_seconds.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --no-fetch) NO_FETCH=1; shift ;;
        --settings) BRANCH_POLICY_SETTINGS="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

export BRANCH_POLICY_DRY_RUN="$DRY_RUN"

MAX_AGE_SECONDS="$(branch_policy_query max_age_seconds)"
NOW_SECONDS="$(date +%s)"
mapfile -t REPO_PATHS < <(branch_policy_query repos)

for repo_path in "${REPO_PATHS[@]}"; do
    if ! branch_policy_is_git_repo "$repo_path"; then
        echo "[SKIP] not a git repo: $repo_path" >&2
        continue
    fi

    if [[ "$DRY_RUN" == "1" || "$NO_FETCH" == "1" ]]; then
        echo "[INFO] fetch skipped: $repo_path"
    else
        if ! git -C "$repo_path" fetch --all --prune; then
            branch_policy_notify "branch drift check: fetch failed in $repo_path"
            continue
        fi
    fi

    while IFS=$'\t' read -r full_ref short_ref commit_seconds; do
        [[ -z "${short_ref:-}" ]] && continue
        [[ "$full_ref" == refs/remotes/*/HEAD ]] && continue
        [[ "$short_ref" == */HEAD ]] && continue

        branch_name="${short_ref#*/}"
        if branch_policy_is_allowed_long_lived "$branch_name"; then
            continue
        fi

        if [[ -z "${commit_seconds:-}" || "$commit_seconds" == "0" ]]; then
            echo "[SKIP] no commit timestamp: $repo_path $short_ref" >&2
            continue
        fi

        age_seconds=$((NOW_SECONDS - commit_seconds))
        if (( age_seconds > MAX_AGE_SECONDS )); then
            age_hours=$((age_seconds / 3600))
            message="branch drift: $short_ref in $repo_path (${age_hours}h old, limit=${MAX_AGE_SECONDS}s)"
            echo "[DRIFT] $message"
            branch_policy_notify "$message"
        else
            echo "[OK] $repo_path $short_ref age=${age_seconds}s"
        fi
    done < <(branch_policy_remote_refs "$repo_path")
done
