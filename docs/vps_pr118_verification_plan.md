# VPS PR #118 検証計画書 (cmd_334)

作成日: 2026-05-17  
作成者: 家老 (karo)

---

## 概要

PR #118 (OpenCode 統合 by ZenkakuHiragana) の merge 加速のため、  
Contabo VPS (144.91.125.163) を multi-agent-shogun 検証環境として整備した記録と手順書。

---

## VPS 現状確認 (2026-05-17 調査済み)

| 項目 | 状態 |
|------|------|
| SSH 接続 | ✅ `ssh -i ~/.ssh/contabo root@144.91.125.163` で即時接続可 |
| osato-lms (:3000) | ✅ Up 9 days, HTTP 200 (大里様デモ環境 — 破壊厳禁) |
| multi-agent-shogun リポ | ✅ `/root/multi-agent-shogun` に clone 済み |
| main ブランチ | ✅ `b5beb06` (2026-05-17 git pull 済み) |
| claude CLI | ✅ v2.1.80 |
| codex CLI | ✅ インストール済み |
| tmux | ✅ インストール済み (セッション無し) |
| PR #118 fork remote | ✅ `opencode` として追加済み |
| PR #118 branch | ✅ `pr118-opencode` (opencode/feature/opencode-compatibility 追跡) |

---

## PR #118 コンフリクト状況

```
# 確認コマンド (VPS上で実行)
cd /root/multi-agent-shogun
git fetch opencode
git merge --no-commit --no-ff pr118-opencode
```

**結果**: コンフリクト 2 ファイルのみ

| ファイル | 状態 |
|---------|------|
| `lib/cli_adapter.sh` | UU (両方変更) |
| `scripts/inbox_watcher.sh` | UU (両方変更) |

その他 200+ ファイルは自動 merge 成功。コンフリクトスコープは想定より軽微。

---

## 軍師 QC 指摘事項 (PR #118 に対して、未修正)

PR #118 を merge する前に以下の修正が必要 (軍師判定: Request Changes):

| # | 重要度 | 指摘 |
|---|--------|------|
| 1 | MAJOR | `opencode_tools.md`: ツール名 `mark_as_read.ts` → `mark-as-read.ts` (ハイフン統一) |
| 2 | MAJOR | `lib/agent_status.sh`: busy検知 grep fallback が部分充填を見逃す (python 非存在環境で偽陰性) |
| 3 | MAJOR | `scripts/build_instructions.sh`: Python 終了コード未検証 (不正 YAML 時に権限なし設定で生成リスク) |

---

## 投稿者対応フロー

### フェイルセーフ期限: 2026-05-24 (1週間)

```
2026-05-17  今日: VPS 環境整備完了 → 投稿者待ち状態に入る
2026-05-24  期限: 投稿者から rebase 反応なき場合 → 当方で conflict 解消を引き取る (家老判断)
```

---

## VPS での検証手順 (投稿者 rebase 完了後)

投稿者が `feature/opencode-compatibility` を最新 main へ rebase 後:

```bash
# 1. VPS に SSH 接続
ssh -i ~/.ssh/contabo root@144.91.125.163

# 2. VPS 上の multi-agent-shogun を更新
cd /root/multi-agent-shogun
git pull origin main
git fetch opencode

# 3. PR #118 branch を最新に更新
git checkout pr118-opencode
git pull

# 4. merge test
git checkout main
git merge --no-commit --no-ff pr118-opencode
# CONFLICT なければ continue
# CONFLICT あれば → 解消 → merge --continue

# 5. 動作確認 — shutsujin_departure.sh の起動テスト (dry-run 相当)
bash shutsujin_departure.sh 2>&1 | head -20

# 6. OpenCode 特有の機能確認
# .opencode/agents/ に各エージェント定義が入っている
ls .opencode/agents/
# opencode_tools.md の内容確認
cat .opencode/tools/mark-as-read.ts 2>/dev/null || cat .opencode/tools/mark_as_read.ts 2>/dev/null

# 7. 軍師 QC 3項目の修正確認
# - mark-as-read.ts ファイル名 (ハイフン)
# - agent_status.sh の busy 検知
# - build_instructions.sh の終了コード確認

# 8. osato-lms 稼働確認 (破壊確認)
curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/
# 200 が返れば OK
```

---

## 当方で conflict 引き取る場合の手順 (フェイルセーフ)

```bash
# VPS 上で
cd /root/multi-agent-shogun
git checkout -b fix/pr118-opencode-merge main
git merge pr118-opencode

# CONFLICT files を手動解消:
# 1. lib/cli_adapter.sh
# 2. scripts/inbox_watcher.sh

# 解消後
git add lib/cli_adapter.sh scripts/inbox_watcher.sh
git merge --continue -m "merge: PR #118 OpenCode compatibility (conflict resolved by karo)"

# 軍師 QC 3項目も同時修正:
# 1. mark_as_read.ts → mark-as-read.ts rename
# 2. agent_status.sh grep fallback 修正
# 3. build_instructions.sh 終了コード追加

# 動作確認後 PR を作成
git push origin fix/pr118-opencode-merge
gh pr create --title "merge: PR #118 OpenCode compatibility (rebase + conflict resolved)" \
  --body "PR #118 のコンフリクトを解消し、軍師 QC 指摘3点を修正。"
```

---

## dashboard.md 更新トリガー

以下の状況変化時に家老が dashboard.md を更新する:

- 投稿者から rebase 完了の通知 → "PR #118: rebase待ち → VPS検証開始"
- VPS 検証 PASS → "PR #118: 検証PASS → merge可能"
- フェイルセーフ実行 → "PR #118: 当方 conflict 引き取り → PR作成"

---

*記録: /home/tono/multi-agent-shogun/reports/vps_pr118_verification_plan.md*
