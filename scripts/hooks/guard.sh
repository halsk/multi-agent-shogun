#!/usr/bin/env bash
# guard.sh — Claude Code PreToolUse hook for Bash tool
# Reads JSON from stdin: {"tool_name": "Bash", "tool_input": {"command": "..."}}
# exit 0 = allow, exit 2 = block (stderr shown as error message)

set -euo pipefail

# Read JSON from stdin
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# ============================================================
# Helper: resolve effective working directory from cd in command
# Handles: "cd /path && git push", "cd /path; git commit"
# Falls back to current directory if no cd found
# ============================================================
resolve_git_dir() {
  local cmd="$1"
  # Extract last cd target (handles: cd /path, cd "/path with spaces")
  local cd_target
  cd_target=$(echo "$cmd" | grep -oP 'cd\s+\K("[^"]+"|[^\s&;|]+)' | tail -1 | tr -d '"')
  if [[ -n "$cd_target" && -d "$cd_target" ]]; then
    echo "$cd_target"
  else
    echo "."
  fi
}

GIT_TARGET_DIR=$(resolve_git_dir "$COMMAND")

# ============================================================
# Helper: detect git subcommand invocation
# Catches: direct (git push), full path (/usr/bin/git push),
#   command/env wrapper, function alias (f(){ git "$@"; }; f push),
#   variable alias (v=git; $v push)
# ============================================================
has_git_subcmd() {
  local cmd="$1"
  local subcmd="$2"
  # Direct: git push, git commit
  echo "$cmd" | grep -qE "git\s+$subcmd\b" && return 0
  # Full path: /usr/bin/git push
  echo "$cmd" | grep -qE "/git\s+$subcmd\b" && return 0
  # command/env wrapper: command git push, env git push
  echo "$cmd" | grep -qE "(command|env)\s+git\s+$subcmd\b" && return 0
  # Function alias: f() { git "$@"; } ... f push
  echo "$cmd" | grep -qE '\(\)\s*\{[^}]*git\b' && echo "$cmd" | grep -qE "\b$subcmd\b" && return 0
  # Variable alias: v=git; $v push
  echo "$cmd" | grep -qE '\w+=git(\s|;|&|$)' && echo "$cmd" | grep -qE "\b$subcmd\b" && return 0
  # Variable subcommand: SUBCMD=push; git $SUBCMD
  echo "$cmd" | grep -qiE "\w+=$subcmd(\s|;|&|\"|$)" && echo "$cmd" | grep -qE 'git\s+\$' && return 0
  return 1
}

# ============================================================
# Hook 1: Co-Authored-By 禁止
# ============================================================
if has_git_subcmd "$COMMAND" "commit" && echo "$COMMAND" | grep -qi 'Co-Authored-By'; then
  echo "❌ Co-Authored-By は禁止です。CLAUDE.md の Git Commit Rules を確認してください。" >&2
  exit 2
fi

# ============================================================
# Hook 2: 破壊的操作ガード (D001-D008)
# ============================================================

# D001: rm -rf on critical paths
if echo "$COMMAND" | grep -qE 'rm\s+-rf\s+(/\*?$|/mnt/\*|/home/\*|~(/|$| ))' || \
   echo "$COMMAND" | grep -qE 'rm\s+-rf\s+~$'; then
  echo "❌ 破壊的操作が検出されました: rm -rf 重要パス。D001 違反です。" >&2
  exit 2
fi

# D003: git push --force / -f (without --force-with-lease)
if has_git_subcmd "$COMMAND" "push" && echo "$COMMAND" | grep -qE '\-\-force\b' && ! echo "$COMMAND" | grep -q 'force-with-lease'; then
  echo "❌ 破壊的操作が検出されました: git push --force。D003 違反です。--force-with-lease を使用してください。" >&2
  exit 2
fi
if has_git_subcmd "$COMMAND" "push" && echo "$COMMAND" | grep -qE '(^|\s)-f\b'; then
  echo "❌ 破壊的操作が検出されました: git push -f。D003 違反です。--force-with-lease を使用してください。" >&2
  exit 2
fi

# D004: git reset --hard / git checkout -- . / git restore . / git clean -f
if has_git_subcmd "$COMMAND" "reset" && echo "$COMMAND" | grep -q '\-\-hard'; then
  echo "❌ 破壊的操作が検出されました: git reset --hard。D004 違反です。git stash を使用してください。" >&2
  exit 2
fi
if has_git_subcmd "$COMMAND" "checkout" && echo "$COMMAND" | grep -qE '\-\-\s+\.'; then
  echo "❌ 破壊的操作が検出されました: git checkout -- .。D004 違反です。" >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE 'git\s+restore\s+\.'; then
  echo "❌ 破壊的操作が検出されました: git restore .。D004 違反です。" >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE 'git\s+clean\s+-f'; then
  echo "❌ 破壊的操作が検出されました: git clean -f。D004 違反です。git clean -n でドライランを先に実行してください。" >&2
  exit 2
fi

# D005: chmod -R / chown -R on system paths
if echo "$COMMAND" | grep -qE '(chmod|chown)\s+-R\b' && \
   echo "$COMMAND" | grep -qE '\s/(etc|usr|bin|sbin|lib|lib64|var|opt|root|sys|proc|boot|dev|srv|mnt|snap)(/| |$)'; then
  echo "❌ 破壊的操作が検出されました: chmod/chown -R on system path。D005 違反です。" >&2
  exit 2
fi

# D006: kill/killall/pkill/tmux kill-server/tmux kill-session
if echo "$COMMAND" | grep -qE '\b(killall|pkill)\b'; then
  echo "❌ 破壊的操作が検出されました: killall/pkill。D006 違反です。" >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE 'tmux\s+kill-(server|session)'; then
  echo "❌ 破壊的操作が検出されました: tmux kill-server/kill-session。D006 違反です。" >&2
  exit 2
fi

# D007: mkfs/dd if=/fdisk
if echo "$COMMAND" | grep -qE '\b(mkfs|fdisk)\b'; then
  echo "❌ 破壊的操作が検出されました: mkfs/fdisk。D007 違反です。" >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE 'dd\s+if='; then
  echo "❌ 破壊的操作が検出されました: dd if=。D007 違反です。" >&2
  exit 2
fi

# D008: pipe-to-shell patterns
if echo "$COMMAND" | grep -qE '(curl|wget)\s+.*\|\s*(bash|sh)'; then
  echo "❌ 破壊的操作が検出されました: curl/wget|bash|sh パターン。D008 違反です。" >&2
  exit 2
fi

# ============================================================
# Hook 3: main ブランチ保護
# Uses GIT_TARGET_DIR to check the correct repo's branch
# (prevents false block when CWD is multi-agent-shogun/main
#  but command targets an external repo on a feature branch)
# ============================================================
if has_git_subcmd "$COMMAND" "commit" || has_git_subcmd "$COMMAND" "push"; then
  CURRENT_BRANCH=$(git -C "$GIT_TARGET_DIR" branch --show-current 2>/dev/null || echo "")
  if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
    echo "❌ main ブランチへの直接 commit/push は禁止です。ブランチを切ってください。" >&2
    exit 2
  fi
fi

# ============================================================
# Hook 4: push 前 lint/typecheck チェック
# Uses GIT_TARGET_DIR to find package.json in the correct repo
# ============================================================
if has_git_subcmd "$COMMAND" "push"; then
  PKG_JSON=$(find "$GIT_TARGET_DIR" -maxdepth 2 -name "package.json" ! -path "*/node_modules/*" 2>/dev/null | head -1)
  if [[ -n "$PKG_JSON" ]]; then
    PKG_DIR=$(dirname "$PKG_JSON")
    HAS_TYPECHECK=$(jq -r '.scripts.typecheck // ""' "$PKG_JSON")
    HAS_LINT=$(jq -r '.scripts.lint // ""' "$PKG_JSON")

    if [[ -n "$HAS_TYPECHECK" || -n "$HAS_LINT" ]]; then
      cd "$PKG_DIR"
      FAILED=0
      if [[ -n "$HAS_TYPECHECK" ]]; then
        if ! npm run typecheck --silent 2>/dev/null; then
          FAILED=1
        fi
      fi
      if [[ -n "$HAS_LINT" ]]; then
        if ! npm run lint --silent 2>/dev/null; then
          FAILED=1
        fi
      fi
      if [[ $FAILED -eq 1 ]]; then
        echo "❌ typecheck/lint エラーがあります。修正してから push してください。" >&2
        exit 2
      fi
    fi
  fi
fi

# ============================================================
# Hook 5: GH_TOKEN 自動 unset 警告
# ============================================================
if echo "$COMMAND" | grep -qE '\bgh\b'; then
  if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "❌ GH_TOKEN が設定されています。\`unset GH_TOKEN && gh ...\` としてください。" >&2
    exit 2
  fi
fi

# ============================================================
# Hook 6: code-review-expert 実行強制（マーカーファイル方式）
# Uses GIT_TARGET_DIR for HEAD hash and .code-review-done lookup
# ============================================================
if has_git_subcmd "$COMMAND" "push"; then
  HEAD_HASH=$(git -C "$GIT_TARGET_DIR" rev-parse HEAD 2>/dev/null || echo "")
  if [[ -n "$HEAD_HASH" ]]; then
    REVIEW_DONE_FILE="$GIT_TARGET_DIR/.code-review-done"
    if [[ ! -f "$REVIEW_DONE_FILE" ]]; then
      echo "❌ code-review-expert を実行してください。push 前にレビューが必要です。" >&2
      exit 2
    fi
    REVIEW_HASH=$(tr -d '[:space:]' < "$REVIEW_DONE_FILE" 2>/dev/null || echo "")
    if [[ "$REVIEW_HASH" != "$HEAD_HASH" ]]; then
      echo "❌ code-review-expert を実行してください。push 前にレビューが必要です。（コミット後に再レビューが必要です）" >&2
      exit 2
    fi
  fi
fi

exit 0
