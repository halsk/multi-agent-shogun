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
# Extract the path argument following <kw> in a command string.
#   kw="cd"            → last `cd <path>`
#   kw="git[[:space:]]+-C" → last `git -C <path>`
# <kw> is an ERE fragment; the target is a quoted string or a non-ws/&/;/| run.
# Portable across GNU (Linux/WSL2) and BSD (macOS) grep — no PCRE -P/\K.
_arg_after() {
  echo "$1" | grep -oE "$2[[:space:]]+(\"[^\"]+\"|[^[:space:]&;|]+)" | sed -E "s/^$2[[:space:]]+//" | tail -1 | tr -d '"'
}

resolve_git_dir() {
  local cmd="$1" target
  # Prefer `git -C <dir>` (git operates there regardless of cwd), else last `cd <dir>`.
  target=$(_arg_after "$cmd" 'git[[:space:]]+-C')
  if [[ -n "$target" && -d "$target" ]]; then echo "$target"; return; fi
  target=$(_arg_after "$cmd" 'cd')
  if [[ -n "$target" && -d "$target" ]]; then echo "$target"; else echo "."; fi
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
  # git -C <dir> subcmd (the -C global option breaks the direct "git <subcmd>" adjacency)
  echo "$cmd" | grep -qE "git\s+-C\s+(\"[^\"]+\"|[^[:space:]&;|]+)\s+$subcmd\b" && return 0
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
# Skip: Marker file `.guard-skip` present
# ----------------------------------------------------------------
# リポルートに .guard-skip ファイルがあれば全 hook をスキップ。
# Obsidian Vault のように auto-sync で main 直接 commit/push が運用前提の
# リポで、各環境 (WSL2 / Mac mini) のパスに依存せず明示マーカーで除外する。
# 殿の指示 (2026-06-06): Vault 削除事故 + push 阻害が起きたため恒久対策。
# Obsidian Vault には別途 .guard-skip を置くこと (リポ毎に明示)。
# ============================================================
SKIP_CWD=$(resolve_git_dir "$COMMAND")
SKIP_GIT_ROOT=$(git -C "$SKIP_CWD" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$SKIP_GIT_ROOT" ] && [ -f "$SKIP_GIT_ROOT/.guard-skip" ]; then
  exit 0
fi

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
# Hook 7: 上流 repo への gh pr create をブロック
# gh pr create --repo yohey-w/* または --repo digital-go-jp/* を検知して拒否。
# cwd の git remote origin が上流を指している場合も同様にブロック。
# read-only 操作 (gh api / gh pr list 等) はブロックしない。
# V002 CRITICAL 恒久対策 (足軽1が yohey-w/multi-agent-shogun に2度誤 PR した事例)。
# ============================================================
if echo "$COMMAND" | grep -qE 'gh\s+(pr|pull-request)\s+create'; then
  # --repo / -R フラグで上流 repo を直接指定している場合
  if echo "$COMMAND" | grep -qE '(-R|--repo)[[:space:]=]+(yohey-w/|digital-go-jp/)'; then
    echo "🚫 BLOCKED: 上流 repo への gh pr create は禁止 (yohey-w/* / digital-go-jp/*)" >&2
    echo "   正しい repo: halsk/* または geolonia/* を --repo に指定せよ" >&2
    exit 2
  fi
  # --repo フラグ未指定: gh はフォーク親 (upstream) に PR を送るため必ず明示が必要。
  # halsk/multi-agent-shogun は yohey-w のフォーク → --repo 省略で yohey-w に誤 PR が届く事例あり。
  if ! echo "$COMMAND" | grep -qE '(-R|--repo)\b'; then
    echo "🚫 BLOCKED: gh pr create には --repo <org/repo> を明示せよ" >&2
    echo "   フォーク repo で --repo を省略すると上流 (yohey-w/* 等) に誤 PR が発生する" >&2
    exit 2
  fi
  # cwd の git remote origin が上流を指している場合
  UPSTREAM_REMOTE=$(git -C "$GIT_TARGET_DIR" remote get-url origin 2>/dev/null || echo "")
  if echo "$UPSTREAM_REMOTE" | grep -qE '(yohey-w/|digital-go-jp/)'; then
    echo "🚫 BLOCKED: cwd の git remote origin が上流 repo を指しています (yohey-w/* / digital-go-jp/*)" >&2
    echo "   正しい repo: halsk/* または geolonia/* の worktree で作業せよ" >&2
    exit 2
  fi
fi

# ============================================================
# Hook 6 helpers: docs-only skip
# ============================================================
is_docs_only_file() {
  local f="$1"
  case "$f" in
    *.md|docs/*|.gitignore|.code-review-done|README*|LICENSE*) return 0 ;;
    *) return 1 ;;
  esac
}

determine_baseline() {
  local marker_hash="$1"
  if [[ -n "$marker_hash" ]] && git -C "$GIT_TARGET_DIR" rev-parse "$marker_hash" >/dev/null 2>&1; then
    echo "$marker_hash"
  else
    local base
    base=$(git -C "$GIT_TARGET_DIR" merge-base HEAD origin/main 2>/dev/null) || \
    base=$(git -C "$GIT_TARGET_DIR" rev-parse HEAD~1 2>/dev/null) || base=""
    echo "$base"
  fi
}

# ============================================================
# Hook 6: code-review-expert 実行強制（マーカーファイル方式）
# Uses GIT_TARGET_DIR for HEAD hash and .code-review-done lookup
# docs-only changes (docs/*, *.md, etc.) are auto-skipped
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
      BASELINE=$(determine_baseline "$REVIEW_HASH")
      DOCS_ONLY_SKIP=0
      if [[ -n "$BASELINE" ]]; then
        CHANGED_FILES=$(git -C "$GIT_TARGET_DIR" diff --name-only "$BASELINE" HEAD 2>/dev/null || echo "")
        if [[ -n "$CHANGED_FILES" ]]; then
          ALL_DOCS=1
          while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            if ! is_docs_only_file "$file"; then
              ALL_DOCS=0
              break
            fi
          done <<< "$CHANGED_FILES"
          if [[ $ALL_DOCS -eq 1 ]]; then
            DOCS_ONLY_SKIP=1
          fi
        fi
      fi
      if [[ $DOCS_ONLY_SKIP -eq 1 ]]; then
        echo "$HEAD_HASH" > "$REVIEW_DONE_FILE"
        echo "ℹ️  guard.sh: docs-only change detected, code-review skipped + marker auto-updated" >&2
      else
        echo "❌ code-review-expert を実行してください。push 前にレビューが必要です。（コミット後に再レビューが必要です）" >&2
        exit 2
      fi
    fi
  fi
fi

exit 0
