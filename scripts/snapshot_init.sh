#!/usr/bin/env bash
# snapshot_init.sh — 台帳控え置き場(独立ローカルgit)の初期化。冪等。
# ★multi-agent-shogunリポはPUBLIC。台帳には家計・顧客名・非公開repo情報が入る。
#   控えは本リポのgit管理に入れず、remote無しの別repoへ置く。pre-pushは必ず失敗させる。
# Usage: bash scripts/snapshot_init.sh [dest_dir]   (既定 ~/workspace/shogun-state-backup)
set -euo pipefail
DEST="${1:-${SNAPSHOT_DEST:-$HOME/workspace/shogun-state-backup}}"
bk() { git -C "$DEST" "$@"; }
mkdir -p "$DEST"
[[ -d "$DEST/.git" ]] || bk init -q
mkdir -p "$DEST/.git/hooks"
cat > "$DEST/.git/hooks/pre-push" <<'H'
#!/usr/bin/env bash
echo "❌ shogun-state-backup は非公開の控え。push厳禁(remote追加も禁止)。" >&2
exit 1
H
chmod +x "$DEST/.git/hooks/pre-push"
cat > "$DEST/README.md" <<'R'
# shogun-state-backup

**非公開。公開・remote追加・push厳禁。**

multi-agent-shogun の台帳(queue/shogun_to_karo.yaml)等の定期控え。
家計・顧客名・非公開repo情報を含むため、remoteは一切付けない。
pre-push hook は常に失敗する(誤pushの二重の止め)。
書き手は scripts/snapshot.sh のみ。復旧手順は instructions/karo.md「台帳復旧手順」。
R
bk config user.name "shogun-snapshot"
bk config user.email "snapshot@localhost.invalid"
bk config commit.gpgsign false
if ! bk rev-parse HEAD >/dev/null 2>&1; then
  bk add -A
  bk commit -q --no-verify -m "init: shogun-state-backup"
fi
echo "initialized: $DEST"
