#!/usr/bin/env bash
# Layer 2/3 deploy gate: abort deploy unless the target repo is on the configured primary branch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/branch_policy.sh
source "$SCRIPT_DIR/lib/branch_policy.sh"

DRY_RUN=0
REPO_PATH="${DEPLOY_REPO_PATH:-$(pwd)}"

usage() {
    cat <<'EOF'
Usage: pre_deploy_verify.sh [--repo PATH] [--dry-run] [--settings PATH]

Verifies that the deploy target repo is checked out on the first branch listed in
branch_policy.allowed_long_lived. Exits non-zero and sends ntfy on mismatch.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO_PATH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --settings) BRANCH_POLICY_SETTINGS="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

export BRANCH_POLICY_DRY_RUN="$DRY_RUN"

if ! branch_policy_is_git_repo "$REPO_PATH"; then
    echo "[ABORT] deploy abort: not a git repo: $REPO_PATH" >&2
    exit 1
fi

EXPECTED_BRANCH="$(branch_policy_query primary)"
CURRENT_BRANCH="$(git -C "$REPO_PATH" branch --show-current)"

if [[ "$CURRENT_BRANCH" != "$EXPECTED_BRANCH" ]]; then
    message="deploy abort: branch=$CURRENT_BRANCH in $REPO_PATH (expected: $EXPECTED_BRANCH)"
    echo "[ABORT] $message" >&2
    branch_policy_notify "$message"
    exit 1
fi

echo "[OK] deploy branch confirmed: $CURRENT_BRANCH"
