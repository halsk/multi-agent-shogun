---
name: ud
description: dashboard.md のPR状態をGitHubと自動照合し、マージ済みPRを移動・未解決指摘を警告するスラッシュコマンド。/ud と入力して実行。
---

# Update Dashboard (/ud)

## 概要

`dashboard.md` の「マージ承認待ち」「進行中」セクションを GitHub の実際の PR 状態と照合し、
自動的に最新状態に更新するスラッシュコマンド。

- マージ済み PR → 「本日マージ済み」テーブルに移動
- クローズ済み PR → 削除して備考に記録
- OPEN PR → CodeRabbit の Actionable 指摘があれば警告を追加
- 「最終更新」日時を現在時刻に自動更新

## 使い方

```
/ud
```

引数なし。実行するとダッシュボードを GitHub と照合し、上書き保存する。

## 処理手順

### Step 1: dashboard.md を読み込む

```bash
Read /mnt/c/tools/multi-agent-shogun/dashboard.md
```

### Step 2: 「マージ承認待ち」セクションから PR 一覧を抽出

dashboard.md の「マージ承認待ち」セクションを探し、全 PR の URL を抽出する。

PR URL のパターン: `https://github.com/<owner>/<repo>/pull/<N>`

各 URL から以下を取得:
- `owner/repo` = リポジトリ名
- `<N>` = PR 番号

### Step 3: 各 PR の GitHub 状態を確認

```bash
unset GH_TOKEN
gh pr view <N> --repo <owner>/<repo> --json state,mergedAt,title,reviews
```

**注意**: gh コマンドの前に必ず `unset GH_TOKEN` を実行すること。

エラーが発生した場合（リポが見つからない、権限なし等）は「確認できなかった PR」としてスキップし、
処理を続行する。

### Step 4: 状態判定と dashboard.md 更新

#### MERGED の場合

1. 「マージ承認待ち」行を削除
2. 「本日マージ済み」テーブルに以下の形式で追記:

```
| PR#N | owner/repo | タイトル（短縮）|
```

#### CLOSED（マージなし）の場合

1. 「マージ承認待ち」行を削除
2. 処理サマリーに「クローズ済み」として記録（テーブルには追加しない）

#### OPEN の場合

1. CodeRabbit の Actionable 指摘を確認:
   - `reviews` フィールドから `CHANGES_REQUESTED` 状態のレビューを確認
   - または `gh pr view <N> --repo <owner>/<repo> --comments` で CodeRabbit コメントを確認
2. Actionable 指摘がある場合、該当 PR 行に `⚠️ CR指摘あり` を追記
3. 指摘がない場合は変更なし

### Step 5: 「最終更新」日時を更新

dashboard.md 冒頭の「最終更新:」行を現在の日時に更新:

```
最終更新: YYYY-MM-DD HH:MM（/ud 自動更新）
```

日時取得:
```bash
date '+%Y-%m-%d %H:%M'
```

### Step 6: dashboard.md を保存

Edit ツールで dashboard.md を上書き保存する。

### Step 7: 更新サマリーを出力

処理結果を以下の形式で出力:

```
=== dashboard.md 更新完了 ===
確認した PR: N 件
- MERGED → テーブル移動: X 件
- CLOSED → 削除: Y 件
- OPEN / 変更なし: Z 件
- 確認不可（スキップ）: W 件
⚠️ CR 指摘あり: [PR#N (repo), ...]
最終更新: YYYY-MM-DD HH:MM
```

## 実装上の注意

### GH_TOKEN

```bash
unset GH_TOKEN
```

gh コマンド実行前に必ず実行すること。設定されていると geolonia org への認証が失敗する場合がある。

### PR URL の正規表現パターン

```
https://github\.com/([^/]+/[^/]+)/pull/(\d+)
```

- グループ1: `owner/repo`
- グループ2: PR 番号

### エラーハンドリング

gh コマンドが失敗した場合（Exit code != 0）:
- 該当 PR を「確認不可（スキップ）」として記録
- 処理を続行（abort しない）
- サマリーに「確認不可: PR#N (owner/repo) — エラー内容」を記録

### CodeRabbit Actionable 確認

`gh pr view --json reviews` の `reviews` 配列から:
- `author.login` が `coderabbitai` または `coderabbit-ai`
- `state` が `CHANGES_REQUESTED`

これが存在すれば Actionable 指摘ありと判定する。

### 「マージ承認待ち」セクションが空の場合

セクション自体は残し、`（なし）` と表示する。サマリーに「確認する PR がありませんでした」と出力。

### 「進行中」セクションの扱い

現バージョンでは「進行中」セクションは読み取り専用（変更しない）。
YAML ファイル（queue/tasks/）と照合する機能は将来の拡張とする。

## 出力例

```
=== dashboard.md 更新完了 ===
確認した PR: 3 件
- MERGED → テーブル移動: 2 件
  - PR#121 (geolonia/workflow-estimates)
  - PR#126 (geolonia/workflow-estimates)
- CLOSED → 削除: 0 件
- OPEN / 変更なし: 1 件
- 確認不可（スキップ）: 0 件
⚠️ CR 指摘あり: PR#123 (geolonia/workflow-estimates)
最終更新: 2026-03-10 21:30
```
