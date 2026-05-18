#!/usr/bin/env bash
# Shared helpers for branch policy scripts.

BRANCH_POLICY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH_POLICY_SETTINGS="${BRANCH_POLICY_SETTINGS:-$BRANCH_POLICY_ROOT/config/settings.yaml}"

branch_policy_python() {
    if [[ -x "$BRANCH_POLICY_ROOT/.venv/bin/python3" ]]; then
        printf '%s\n' "$BRANCH_POLICY_ROOT/.venv/bin/python3"
    else
        command -v python3
    fi
}

branch_policy_query() {
    local query="$1"
    local python_bin
    python_bin="$(branch_policy_python)"

    "$python_bin" - "$BRANCH_POLICY_SETTINGS" "$query" <<'PY'
import sys

try:
    import yaml
except Exception as exc:
    raise SystemExit(f"PyYAML is required to read branch_policy: {exc}")

settings_path, query = sys.argv[1], sys.argv[2]

with open(settings_path, "r", encoding="utf-8") as fh:
    settings = yaml.safe_load(fh) or {}

policy = settings.get("branch_policy")
if not isinstance(policy, dict):
    raise SystemExit("branch_policy is not configured in settings.yaml")

allowed = policy.get("allowed_long_lived") or []
if not isinstance(allowed, list) or not allowed:
    raise SystemExit("branch_policy.allowed_long_lived must be a non-empty list")
allowed = [str(item) for item in allowed]

def max_age_seconds() -> int:
    value = policy.get("max_age_seconds", policy.get("max_short_lived_age_seconds"))
    if value is None:
        raise SystemExit("branch_policy.max_age_seconds is required")
    return int(value)

if query == "allowed":
    print("\n".join(allowed))
elif query == "primary":
    print(allowed[0])
elif query == "short_lived_pattern":
    pattern = policy.get("short_lived_pattern")
    if not pattern:
        raise SystemExit("branch_policy.short_lived_pattern is required")
    print(str(pattern))
elif query == "max_age_seconds":
    print(max_age_seconds())
elif query == "repos":
    repos = policy.get("monitored_repos") or []
    if not isinstance(repos, list) or not repos:
        raise SystemExit("branch_policy.monitored_repos must be a non-empty list")
    paths = []
    for item in repos:
        if isinstance(item, dict):
            path = item.get("path")
        else:
            path = item
        if path:
            paths.append(str(path))
    if not paths:
        raise SystemExit("branch_policy.monitored_repos has no valid path entries")
    print("\n".join(paths))
elif query == "ntfy_topic":
    topic = settings.get("ntfy_topic")
    if topic:
        print(str(topic))
else:
    raise SystemExit(f"unknown branch_policy query: {query}")
PY
}

branch_policy_is_allowed_long_lived() {
    local branch="$1"
    local allowed
    while IFS= read -r allowed; do
        [[ "$branch" == "$allowed" ]] && return 0
    done < <(branch_policy_query allowed)
    return 1
}

branch_policy_is_git_repo() {
    local repo_path="$1"
    git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1
}

branch_policy_is_clean_repo() {
    local repo_path="$1"
    [[ -z "$(git -C "$repo_path" status --porcelain)" ]]
}

branch_policy_notify() {
    local message="$1"

    if [[ "${BRANCH_POLICY_DRY_RUN:-0}" == "1" ]]; then
        printf '[DRY-RUN] notify: %s\n' "$message"
        return 0
    fi

    if [[ -x "$BRANCH_POLICY_ROOT/scripts/ntfy_send.sh" ]]; then
        bash "$BRANCH_POLICY_ROOT/scripts/ntfy_send.sh" "$message"
        return $?
    fi

    if [[ -x "$BRANCH_POLICY_ROOT/scripts/ntfy.sh" ]]; then
        bash "$BRANCH_POLICY_ROOT/scripts/ntfy.sh" "$message"
        return $?
    fi

    local topic
    topic="$(branch_policy_query ntfy_topic)"
    if [[ -z "$topic" ]]; then
        printf 'ntfy_topic not configured; notification skipped: %s\n' "$message" >&2
        return 1
    fi

    curl -fsS -d "$message" "https://ntfy.sh/$topic" >/dev/null
}

branch_policy_remote_refs() {
    local repo_path="$1"
    git -C "$repo_path" for-each-ref \
        --format='%(refname)%09%(refname:short)%09%(committerdate:unix)' \
        refs/remotes
}
