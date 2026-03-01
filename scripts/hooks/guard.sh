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
# Hook 1: Co-Authored-By 禁止
# ============================================================
if echo "$COMMAND" | grep -qE 'git\s+commit' && echo "$COMMAND" | grep -qi 'Co-Authored-By'; then
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

# D003: git push --force / git push -f (without --force-with-lease)
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force\b' && ! echo "$COMMAND" | grep -q 'force-with-lease'; then
  echo "❌ 破壊的操作が検出されました: git push --force。D003 違反です。--force-with-lease を使用してください。" >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*\s-f\b'; then
  echo "❌ 破壊的操作が検出されました: git push -f。D003 違反です。--force-with-lease を使用してください。" >&2
  exit 2
fi

# D004: git reset --hard / git checkout -- . / git restore . / git clean -f
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
  echo "❌ 破壊的操作が検出されました: git reset --hard。D004 違反です。git stash を使用してください。" >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+--\s+\.'; then
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

# D007: mkfs/dd if=/fdisk/mount/umount
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
# ============================================================
if echo "$COMMAND" | grep -qE 'git\s+(commit|push)\b'; then
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
    echo "❌ main ブランチへの直接 commit/push は禁止です。ブランチを切ってください。" >&2
    exit 2
  fi
fi

# ============================================================
# Hook 4: push 前 lint/typecheck チェック
# ============================================================
if echo "$COMMAND" | grep -qE 'git\s+push\b'; then
  PKG_JSON=$(find . -maxdepth 2 -name "package.json" ! -path "*/node_modules/*" 2>/dev/null | head -1)
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
# ============================================================
if echo "$COMMAND" | grep -qE 'git\s+push\b'; then
  HEAD_HASH=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [[ -n "$HEAD_HASH" ]]; then
    REVIEW_DONE_FILE=".code-review-done"
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
