# multi-agent-shogun: WSL2 → macOS (Mac mini) 移行仕様書

> 対象: Claude Code（Mac mini で実行する Claude エージェント）
> 作成: 2026-05-20
> 目的: WSL2 環境で稼働中の multi-agent-shogun + 周辺プロジェクト群を Mac mini に移行する作業を **Claude 単独で実行可能** にする
> 前提: Mac mini 側で Claude Code がインストール済み、Lord がブラウザ等を介して必要な対話操作（SSO 認証等）に応える

---

## ⚠️ Iron Laws（厳守事項）

本仕様書全体に適用する不変ルール。違反不可。

1. **証拠なき完了禁止**: 各 Phase の acceptance check を全て pass した時のみ「Phase 完了」と報告
2. **破壊的操作禁止**: `rm -rf /` 系、`git push --force` (without --force-with-lease)、`git reset --hard` を実行する場合は事前に Lord 確認
3. **main 直接 commit/push 禁止**: 仕様書に基づく修正はブランチ + PR 経由
4. **path 書換は dry-run 先行**: 全体置換前に diff 確認、Lord 承認後に apply
5. **戦国口調**: 報告は「〜つかまつる」「〜にござる」等の sengoku 風で（multi-agent-shogun のキャラクター維持）
6. **Lord 認証必要箇所では停止**: SSO ログイン、GitHub OAuth、ブラウザ認証は Lord 介入待ち

---

## ゴール

Mac mini 上で以下が動作する状態を実現する:

- `tmux list-panes -t multiagent -F '#{pane_index} #{@agent_id}'` で 9 pane に shogun / karo / ashigaru1-7 / gunshi が割当済
- `bash scripts/inbox_write.sh karo "test" cmd_new shogun` がエラーなく実行、karo pane が反応する
- 全 inbox_watcher (10 個) プロセス稼働
- Claude Code が `~/tools/multi-agent-shogun/CLAUDE.md` を auto-load し、memory（`~/.claude/projects/-Users-hal-tools-multi-agent-shogun/memory/`）を読込可能

---

## Phase 0: 前提確認 + 依存ツール install

### 0.1 環境チェック

```bash
sw_vers   # macOS 14+ 推奨
uname -m  # arm64 (Apple Silicon) を想定
echo $SHELL  # zsh デフォルト
```

### 0.2 Homebrew install（未導入時）

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"  # PATH 設定
```

### 0.3 必須ツール

```bash
brew install \
  tmux \
  fswatch \
  coreutils \
  flock \
  gh \
  node \
  python@3.12 \
  jq \
  git \
  docker \
  rsync
```

**注意**:
- `coreutils` は `g` プレフィックス付きで install される（`grealpath`, `gsed`, `gdate` 等）
- スクリプト側で GNU 系前提の箇所は対応要（Phase 3.5 で詳述）

### 0.4 Claude Code

```bash
# 公式 https://claude.com/code から DMG ダウンロード + install
# または:
# curl -fsSL ... # 公式手順に従う
```

`claude` コマンドが PATH に通っていることを確認:
```bash
which claude && claude --version
```

### 0.5 SSH 鍵設定

```bash
# WSL2 側から鍵をコピー（推奨: 同じ鍵を再利用）
# 別 PC 経由で ~/.ssh/id_ed25519 + id_ed25519.pub をコピー
# 権限設定:
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

# 動作確認:
ssh -T git@github.com  # Hi halsk! ... と返れば OK
```

### 0.6 gh CLI 認証

```bash
gh auth login
# Interactive: GitHub.com → SSH → 既存 SSH 鍵
```

**Lord 対話必要箇所**: gh auth login のブラウザ認証

### 0.7 Phase 0 完了確認

```bash
brew list | grep -E "tmux|fswatch|coreutils|flock|gh|node|python|jq|git|docker|rsync" | wc -l  # >= 10
ssh -T git@github.com 2>&1 | grep -q "Hi halsk" && echo "SSH OK"
gh auth status | grep -q "Logged in" && echo "gh OK"
which claude && echo "Claude Code OK"
```

全て pass で **Phase 0 完了**。

---

## Phase 1: multi-agent-shogun リポジトリ clone

### 1.1 ディレクトリ準備

```bash
mkdir -p ~/tools
cd ~/tools
```

### 1.2 clone（halsk fork + upstream remote 追加）

```bash
git clone git@github.com:halsk/multi-agent-shogun.git
cd multi-agent-shogun

git remote add upstream git@github.com:yohey-w/multi-agent-shogun.git
git fetch upstream

git log --oneline -5  # 確認
```

### 1.3 確認

```bash
test -f CLAUDE.md && echo "CLAUDE.md OK"
test -d queue && echo "queue/ OK"
test -d scripts && echo "scripts/ OK"
test -f shutsujin_departure.sh && echo "shutsujin OK"
```

**Phase 1 完了**: 全て pass。

---

## Phase 2: Hardcoded path 一括書換

### 2.1 旧→新 path map

| 種別 | 旧 path (WSL2) | 新 path (macOS) |
|------|---------------|----------------|
| Repo root | `/mnt/c/tools/multi-agent-shogun` | `/Users/hal/tools/multi-agent-shogun` |
| Workspace | `/home/hal/workspace` | `/Users/hal/workspace` |
| Services | `/home/hal/services` | `/Users/hal/services` |
| Home | `/home/hal` | `/Users/hal` |
| Claude memory dir | `~/.claude/projects/-mnt-c-tools-multi-agent-shogun/` | `~/.claude/projects/-Users-hal-tools-multi-agent-shogun/` |

### 2.2 影響ファイル列挙（事前調査）

```bash
cd ~/tools/multi-agent-shogun

# 旧 path 出現箇所を全件列挙
grep -rln "/mnt/c/tools/multi-agent-shogun\|/home/hal/workspace\|/home/hal/services\|/home/hal/\." \
  --exclude-dir=.git --exclude-dir=node_modules --exclude='*.png' --exclude='*.jpg' \
  > /tmp/path_rewrite_targets.txt

wc -l /tmp/path_rewrite_targets.txt
cat /tmp/path_rewrite_targets.txt
```

### 2.3 一括書換（dry-run 先行）

```bash
# Dry-run: 何が変わるかを確認
while IFS= read -r file; do
  echo "=== $file ==="
  grep -nE "/mnt/c/tools/multi-agent-shogun|/home/hal/workspace|/home/hal/services|/home/hal" "$file" | head -5
done < /tmp/path_rewrite_targets.txt | head -100
```

Lord 確認後、apply:

```bash
# 注意: macOS は BSD sed ゆえ `sed -i ''` 構文（gsed で GNU 互換も可）
while IFS= read -r file; do
  gsed -i \
    -e 's|/mnt/c/tools/multi-agent-shogun|/Users/hal/tools/multi-agent-shogun|g' \
    -e 's|/home/hal/workspace|/Users/hal/workspace|g' \
    -e 's|/home/hal/services|/Users/hal/services|g' \
    -e 's|/home/hal/\.|/Users/hal/.|g' \
    "$file"
done < /tmp/path_rewrite_targets.txt
```

### 2.4 書換結果の git diff 確認

```bash
git diff --stat | head -30
git diff CLAUDE.md  # 主要ファイルは個別確認
git diff .claude/settings.json
```

**Lord 対話必要箇所**: diff 確認後、commit 可否を Lord に確認。

### 2.5 commit + branch（main 直接禁止）

```bash
git switch -c feat/macos-port-paths
git add -A
git commit -m "feat(macos): rewrite hardcoded paths from WSL2 to macOS layout

- /mnt/c/tools/multi-agent-shogun → /Users/hal/tools/multi-agent-shogun
- /home/hal/workspace → /Users/hal/workspace
- /home/hal/services → /Users/hal/services
- ~/.claude/projects/-mnt-c-* path mapping in memory references

Closes (本作業の Issue 番号、Phase 1 で起案)"
```

**Phase 2 完了**: diff Lord 確認 + branch commit 済。

---

## Phase 3: inotifywait → fswatch クロスプラットフォーム移植

**最大の難所**。Linux 専用 `inotifywait` を macOS の `fswatch` に置換。両環境動作のため、runtime detection 方式で書換。

### 3.1 影響スクリプト調査

```bash
cd ~/tools/multi-agent-shogun
grep -rln "inotifywait" scripts/ lib/ 2>/dev/null
# 想定: scripts/inbox_watcher.sh (主)、その他にもあるか確認
```

### 3.2 移植方針: 共通 wrapper 関数

`scripts/inbox_watcher.sh` の冒頭に共通 wrapper を追加:

```bash
# === Cross-platform file watch wrapper ===
watch_file_change() {
  local file="$1"
  local timeout_sec="${2:-60}"

  if command -v inotifywait >/dev/null 2>&1; then
    # Linux: inotifywait
    timeout "$timeout_sec" inotifywait -e modify "$file" --quiet 2>/dev/null
    return $?
  elif command -v fswatch >/dev/null 2>&1; then
    # macOS: fswatch (-1 = exit after first event)
    timeout "$timeout_sec" fswatch -1 "$file" >/dev/null 2>&1
    return $?
  else
    # Fallback: polling every 2 sec
    local elapsed=0
    local last_mtime=$(stat -f%m "$file" 2>/dev/null || stat -c%Y "$file" 2>/dev/null)
    while [ $elapsed -lt "$timeout_sec" ]; do
      sleep 2
      elapsed=$((elapsed + 2))
      local new_mtime=$(stat -f%m "$file" 2>/dev/null || stat -c%Y "$file" 2>/dev/null)
      if [ "$new_mtime" != "$last_mtime" ]; then
        return 0
      fi
    done
    return 1
  fi
}
```

`stat` も Linux と macOS で違うため両対応:
- Linux: `stat -c%Y`
- macOS: `stat -f%m`

### 3.3 既存 inotifywait 呼出箇所を置換

```bash
# 例: 旧
# inotifywait -e modify "$INBOX_FILE" --quiet
# 新
# watch_file_change "$INBOX_FILE" 60
```

実装は ashigaru に委ねるが、変更点を全て diff で確認可能にすること。

### 3.4 timeout コマンドの差異

macOS の `timeout` は `coreutils` (`gtimeout`) ゆえ、PATH 通過確認 or alias 設定:

```bash
# ~/.zshrc or scripts 冒頭
if ! command -v timeout >/dev/null 2>&1 && command -v gtimeout >/dev/null 2>&1; then
  alias timeout=gtimeout
fi
```

または `command timeout` を `command gtimeout` に置換。

### 3.5 他のスクリプトの GNU vs BSD 差異

| ツール | Linux | macOS 対応 |
|--------|-------|-----------|
| `sed -i` | GNU sed | BSD sed (`sed -i ''`) or `gsed` |
| `stat -c%Y` | GNU stat | BSD stat (`stat -f%m`) |
| `date -d` | GNU date | BSD date (`-v` フラグ) or `gdate` |
| `realpath` | デフォ | `grealpath` |
| `readlink -f` | デフォ | `greadlink -f` |
| `wc -l` | OK | OK（同じ） |
| `grep -P` | OK | OK |
| `flock` | デフォ | `flock` (brew install) OK |

各スクリプトでこれらが使われていないか個別確認:

```bash
grep -rE "sed -i [^''']|stat -c|date -d|readlink -f" scripts/ lib/ 2>/dev/null
```

### 3.6 単体テスト

`scripts/inbox_watcher.sh` の主要機能をローカルで試験:

```bash
# 1. テスト inbox file
mkdir -p queue/inbox
echo "messages: []" > queue/inbox/test.yaml

# 2. watch 起動（バックグラウンド）
bash scripts/inbox_watcher.sh test test:test claude &
WATCHER_PID=$!
sleep 2

# 3. ファイル変更 → watcher が反応するか
echo "modified" >> queue/inbox/test.yaml
sleep 5

# 4. 結果確認
ps -p $WATCHER_PID && echo "watcher still alive (event handled)"
kill $WATCHER_PID 2>/dev/null
```

**Phase 3 完了**: watcher 動作確認 + diff 全件 Lord 確認 + commit 済。

---

## Phase 4: Memory ディレクトリ rename

### 4.1 Claude Code memory path の構造

Claude Code は cwd に応じて `~/.claude/projects/<encoded-path>/memory/` を auto-load する。
- WSL2 cwd `/mnt/c/tools/multi-agent-shogun/` → `~/.claude/projects/-mnt-c-tools-multi-agent-shogun/`
- macOS cwd `/Users/hal/tools/multi-agent-shogun/` → `~/.claude/projects/-Users-hal-tools-multi-agent-shogun/`

### 4.2 既存 memory を移行

```bash
# WSL2 側から rsync で持ってくる（事前準備、Lord 経由 or 直接コピー）
rsync -av --progress \
  "wsl2:/home/hal/.claude/projects/-mnt-c-tools-multi-agent-shogun/" \
  "$HOME/.claude/projects/-Users-hal-tools-multi-agent-shogun/"
```

### 4.3 memory 内の path 参照書換

```bash
cd ~/.claude/projects/-Users-hal-tools-multi-agent-shogun/memory
gsed -i \
  -e 's|/mnt/c/tools/multi-agent-shogun|/Users/hal/tools/multi-agent-shogun|g' \
  -e 's|/home/hal/workspace|/Users/hal/workspace|g' \
  -e 's|/home/hal/services|/Users/hal/services|g' \
  -e 's|/home/hal/\.|/Users/hal/.|g' \
  *.md
```

### 4.4 確認

```bash
grep -l "/mnt/c\|/home/hal" *.md  # 出力なし = 全件書換済
```

**Phase 4 完了**.

---

## Phase 5: 周辺プロジェクト clone

### 5.1 プロジェクト一覧の取得

```bash
cd ~/tools/multi-agent-shogun
cat config/projects.yaml | grep -E "repo:|path:" | head -40
```

### 5.2 必須プロジェクト clone

```bash
mkdir -p ~/workspace && cd ~/workspace

# 主要プロジェクト（必要に応じて選択）
REPOS=(
  "halsk/automation"          # PA-001 + gitops + scripts
  "halsk/obsidian"            # Vault
  "geolonia/workflow-portal"  # Workflow ハブ
  "geolonia/yuuhitsu"         # AI 文書処理 CLI
  "geolonia/geonicdb-docs"    # GeonicDB ドキュメント
  "geolonia/geonicdb-console" # SaaS Web コンソール
  "geolonia/geonicdb-cli"     # CLI
  "geolonia/civic-intelligence-rag"  # lawsy
  "geolonia/genai-web"        # 源内 fork (codeforjapan/ddcr もあり)
  "codeforjapan/ddcr"         # 災害情報統合
)

for repo in "${REPOS[@]}"; do
  name=$(basename "$repo")
  if [ ! -d "$name" ]; then
    git clone "git@github.com:${repo}.git"
  fi
done
```

### 5.3 Obsidian Vault

`~/workspace/obsidian` は重要（Plaud meeting notes 等の data）。clone 後の構造確認:

```bash
cd ~/workspace/obsidian
ls -d raw/meetings/2026-* 2>/dev/null | head -5  # 月毎フォルダ確認
```

**Phase 5 完了**: 必須リポ clone 済。

---

## Phase 6: 外部サービス再構築 (n8n / Dify)

> **n8n の詳細移行手順は別仕様書**: [`docs/migration-n8n.md`](migration-n8n.md)
> postgres DB dump + restore（方式 A）+ Soft cutover（並行稼働）で credentials 完全保全。
> 本 Phase 6 はサマリのみ、実作業は migration-n8n.md を参照すること。

### 6.1 n8n (ai-worker)

```bash
mkdir -p ~/services && cd ~/services
# automation repo は既に Phase 5 で clone 済
ln -sf ~/workspace/automation ai-worker
cd ai-worker

# .env 復元 (1Password 経由、Lord 操作必要)
op signin
bash scripts/migrate-to-1password.sh  # 既存スクリプト利用 or 手動 .env コピー
```

**Lord 対話必要**: 1Password CLI sign-in、credentials 復元

### 6.2 Docker Desktop / OrbStack

```bash
# Docker Desktop インストール (公式から DMG) or
# OrbStack (推奨、軽量): brew install orbstack
brew install --cask orbstack
open -a OrbStack
```

### 6.3 n8n 起動

```bash
cd ~/services/ai-worker
docker-compose up -d
docker ps | grep n8n  # ai-worker-n8n-1 等が稼働
```

### 6.4 n8n credentials & workflows

- N8N_ENCRYPTION_KEY を **旧環境と一致** させる（さもなくば credentials 復号不可）
- workflow を `scripts/import-workflows.sh` 等で再 import
- credential を 1Password から手動再設定（Gmail OAuth は再認証要）

**Lord 対話必要**: Gmail OAuth, Slack OAuth 等のブラウザ認証

### 6.5 Dify (任意)

殿が Dify 利用中なら同様に `~/services/dify/` で `docker-compose up -d`。
利用しなければ skip。

**Phase 6 完了**: n8n 稼働 + 主要 workflow 動作確認済。

---

## Phase 7: 起動 + 動作確認

### 7.1 multi-agent-shogun 起動

```bash
cd ~/tools/multi-agent-shogun
bash shutsujin_departure.sh
```

**期待**: tmux session `multiagent` 内に 9 pane 作成（karo + ashigaru1-7 + gunshi）、shogun session も別途。

### 7.2 確認

```bash
# tmux pane mapping
tmux list-panes -t multiagent -F '#{pane_index} #{@agent_id}'
# 期待: 9 行、ashigaru1-7 + karo + gunshi 全揃い

# inbox_watcher プロセス
ps aux | grep inbox_watcher | grep -v grep | wc -l
# 期待: 10 個（shogun + karo + ashigaru1-7 + gunshi）

# fswatch プロセス（macOS なら）
ps aux | grep fswatch | grep -v grep | wc -l
# 期待: 10 個前後（各 watcher が fswatch を spawn）
```

### 7.3 inbox エンドツーエンド test

```bash
bash scripts/inbox_write.sh karo "macOS 移行 smoke test" cmd_new shogun
sleep 5
tmux capture-pane -t multiagent:agents.1 -p | tail -10
# 期待: karo pane に inbox1 nudge or 反応
```

### 7.4 SessionStart hook 確認

```bash
# Claude Code session を新規起動 → CLAUDE.md auto-load + memory 認識
cd ~/tools/multi-agent-shogun
claude  # 新 session
# 内部で: tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' が正しく返る
# memory MCP read_graph が機能する
```

**Phase 7 完了**: 全 acceptance check pass、システム稼働。

---

## Phase 8: 最終 PR + Cleanup

### 8.1 PR 起案

```bash
cd ~/tools/multi-agent-shogun
git push -u origin feat/macos-port-paths

unset GH_TOKEN
gh pr create --repo halsk/multi-agent-shogun \
  --title "feat: macOS (Mac mini) 移行 — path 書換 + inotifywait→fswatch 移植" \
  --body "$(cat <<'EOF'
## Summary
- WSL2 環境から macOS (Mac mini) への移行作業
- Phase 0-7 の全 acceptance check pass 済

## Changes
- 全 hardcoded path 書換: /mnt/c/... → /Users/hal/...
- scripts/inbox_watcher.sh: inotifywait → cross-platform (inotifywait/fswatch/polling)
- BSD vs GNU 系コマンド差異対応 (sed, stat, date, realpath)
- memory ディレクトリ rename: -mnt-c-* → -Users-hal-tools-*

## Verification
- [ ] tmux 9 pane 全揃い
- [ ] inbox_watcher プロセス 10 個稼働
- [ ] inbox e2e test pass
- [ ] Claude Code memory 認識
- [ ] n8n PA-001 動作確認

## Notes
- 詳細は docs/migration-to-macos.md 参照
- Lord 確認ポイントは全て対応済
EOF
)"
```

### 8.2 Lord マージ確認

PR diff を Lord にご確認いただき、マージ依頼。

### 8.3 WSL2 環境の retirement

殿の判断:
- WSL2 環境を **archive**（読取専用化、ある程度の期間保持）
- WSL2 → Mac mini への重要ファイル同期完了確認
- 旧 ~/.claude/projects/-mnt-c-* memory を退避

---

## Lord 対話チェックポイント一覧

本作業を Claude が単独実行する際、**以下の箇所で必ず Lord に確認を求める**:

| Phase | チェックポイント | 内容 |
|-------|----------------|------|
| 0.6 | gh auth login | ブラウザ認証 |
| 0.5 | SSH 鍵設定 | 鍵をどこから持ってくるか |
| 2.4 | Path 書換 diff | 全 file の diff Lord 確認 |
| 3.6 | inbox_watcher テスト | fswatch 動作確認 Lord 報告 |
| 4.2 | memory rsync | WSL2 からどう持ってくるか |
| 6.1 | 1Password sign-in | CLI 認証 |
| 6.4 | n8n credentials | Gmail/Slack OAuth 再認証 |
| 8.2 | 最終 PR マージ | Lord マージ承認 |

---

## トラブルシューティング

### Q: shutsujin_departure.sh で tmux pane が 9 個作れない

A: macOS の tmux は session/window/pane の作成順序が Linux と若干違う。
   `tmux -V` で 3.4+ 確認、必要なら `brew upgrade tmux`。
   `shutsujin_departure.sh` のログを `bash -x` で trace。

### Q: inbox_watcher が早期終了する

A: fswatch のオプションを確認:
   - `-1`: 1 event で終了（意図通り）
   - `-l`: latency 設定
   - macOS では `--monitor=poll_monitor` で polling fallback も可

### Q: Claude Code が memory を見つけられない

A: ~/.claude/projects/ 配下の path encoding を確認:
   ```
   ls ~/.claude/projects/ | grep -i "multi-agent-shogun"
   ```
   命名規則: cwd の `/` を `-` に置換、先頭にも `-` 追加。
   `/Users/hal/tools/multi-agent-shogun` → `-Users-hal-tools-multi-agent-shogun`

### Q: n8n が起動しない

A: docker-compose logs n8n でログ確認。よくある原因:
   - PostgreSQL volume permission（macOS Docker Desktop 特有）
   - N8N_ENCRYPTION_KEY が旧環境と不一致
   - port 5678 が他プロセスに占有

### Q: SSH 認証失敗 (git clone 時)

A: `ssh -vT git@github.com` で詳細確認。鍵 permission（600）、known_hosts、GitHub 側の鍵登録を確認。

---

## 参考資料

- 移行関連 memory: `memory/project_pa001_restore_plan.md`、`memory/project_upstream_v461_decisions.md`
- 本作業の発端: 殿の指示「この環境を新しく買った mac mini で動かしたい」(2026-05-16)
- 関連 cmd（過去）: cmd_245 (upstream v4.6.1 取込)、cmd_246 (Phase 1-3)、cmd_472 (lawsy)
- multi-agent-shogun 公式リポ (上流): https://github.com/yohey-w/multi-agent-shogun
- halsk fork: https://github.com/halsk/multi-agent-shogun

---

## 想定工数

| Phase | 工数 (Claude 実行) | Lord 対話時間 |
|-------|---------------------|---------------|
| 0: 依存 install | 15-30 分 | ~5 分 (gh auth, SSH) |
| 1: clone | 5 分 | - |
| 2: path 書換 | 30 分 | ~10 分 (diff 確認) |
| 3: fswatch 移植 | 60-90 分 | ~10 分 (diff 確認) |
| 4: memory rename | 15 分 | ~5 分 |
| 5: 周辺 repo clone | 15-30 分 | - |
| 6: n8n / 外部サービス | 60-90 分 | ~20 分 (1Password, OAuth) |
| 7: 動作確認 | 30 分 | ~10 分 (smoke test) |
| 8: PR | 15 分 | ~5 分 (マージ) |
| **合計** | **4-5 時間** | **~1 時間** |

殿が他作業しながらでも進められる構成。

---

## 改訂履歴

| 日付 | 変更 |
|------|------|
| 2026-05-20 | 初版作成 (shogun が Lord 指示で起案) |
