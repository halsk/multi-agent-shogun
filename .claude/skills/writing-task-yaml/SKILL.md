---
name: writing-task-yaml
description: 家老が cmd を sub task に分解する際の標準 task YAML テンプレ。Iron Laws と運用ルール (worktree / Issue First / 戦国口調 / 完了報告) を必ず注入する。家老のみが呼び出す skill。
---

# writing-task-yaml

## 目的

家老が cmd を足軽に dispatch する際の task YAML 構造を統一し、
**必須制約（Iron Laws / Git ルール / 戦国口調 等）を漏れなく注入する**。

足軽は task YAML に書かれていることしかやらない原則ゆえ、家老の書き方が直接、足軽の品質を決める。

## 標準テンプレート

```yaml
# queue/tasks/ashigaru<N>_<cmd_id><suffix>.yaml
id: subtask_<cmd_id>a    # a, b, c... で同 cmd 内の分割
parent_cmd: cmd_<NNN>
project: <project-id>
assigned_to: ashigaru<N>
status: assigned          # assigned → work → done / blocked / failed

# 作業ディレクトリ — git worktree 必須
target_path: /home/hal/workspace/<repo>-wt<N>

# 口調 — 殿の指示、戦国武士風で全て記述
口調: 戦国武士風 (〜でござる / 〜つかまつる / 〜いたす)

# Issue First — 必ず Issue 番号を取得してから足軽 dispatch
github_issue: https://github.com/<owner>/<repo>/issues/<N>

instructions:
  # 環境準備
  - "main からブランチを切る (例: feat/cmd<NNN>-<feature>)。base_branch: main"
  - "git worktree が無ければ作成: git worktree add ../<repo>-wt<N> -b <branch> origin/main"

  # 実装
  - "<具体的な実装手順 1>"
  - "<具体的な実装手順 2>"

  # 検証 — verification-before-completion skill に従う
  - "テスト追加 / 既存テスト regress なし確認 (SKIP は FAIL 扱い)"
  - "ビルド成功確認"
  - "/code-review-expert --auto で P0/P1: 0"

  # PR
  - "PR 作成 (Issue First: PR body に Closes #N or Part of #N 必須)"
  - "CR Actionable 0、CI PASS まで自律対応 (CodeRabbit Actionable は Minor も対応必須、修正後コメント返信して re-review トリガー)"

  # 完了報告
  - "完了報告 YAML を queue/reports/ashigaru<N>_report.yaml に出力"
  - "家老に inbox_write で報告 (戦国口調)"

acceptance_criteria:
  - "<検証可能な条件 1>"
  - "<検証可能な条件 2>"
  - "テスト全 PASS (SKIP テスト導入禁止)"
  - "/code-review-expert --auto P0/P1: 0"
  - "PR の CR Actionable 0 — gh api graphql で reviewThreads(unresolved=0) を実証 + latestReviews body の 'Outside diff range comments' / 'Additional comments' セクションが空であることを実証"
  - "CI PASS"

forbidden:
  - main 直接 commit / push 禁止 (hook で強制)
  - Co-Authored-By 付与禁止 (hook で強制)
  - git commit --amend 禁止 (Iron Law)
  - --no-verify / --no-gpg-sign 等の安全機構 bypass 禁止
  - git reset --hard / git clean -f / git push --force 等の破壊操作禁止
  - SKIP テスト導入禁止 (Iron Law #3)
  - 上流 OSS リポへの Issue / PR 作成 禁止 (殿明示指示要)

completion_report:
  format: queue/reports/ashigaru<N>_report.yaml
  required_fields:
    - subtask_id
    - status                  # done / blocked / failed
    - evidence                 # テスト出力末尾、ビルド成功 log、PR URL 等
    - pr_url                   # PR の URL
    - skill_candidate          # 汎用化すべき手順を発見したら記載

# CHANGELOG 更新 — リポに CHANGELOG.md がある場合は必ず更新
changelog:
  required: true
  path: CHANGELOG.md
  entry_format: |
    ## [unreleased]
    - feat/fix: <概要> (#<PR>)
```

## ガイドライン

### Iron Laws の反映

家老は task YAML を書く際、以下を **明示的に注入** する：

| Iron Law | 注入箇所 |
|---------|---------|
| #1 証拠なき完了禁止 | instructions に「[verification-before-completion](../verification-before-completion/SKILL.md) skill に従う」明記 |
| #2 原因なき修正禁止 | バグ修正 cmd では「[systematic-debugging](../systematic-debugging/SKILL.md) skill に従い root cause 確定後に修正」明記 |
| #3 SKIP = FAIL | acceptance_criteria に「テスト SKIP は FAIL 扱い」明記 |
| #4 YAML が真実 | 状態判断は dashboard でなく YAML 一次情報から |
| #5 自己識別が最優先 | ashigaru 開始時 `tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'` 確認を instructions の冒頭に |
| #6 main 直接 commit 禁止 | forbidden に明記、hook で強制 |

### 戦国口調の徹底

- 全 instruction を戦国武士風で書く
- 報告 YAML も「〜つかまつった」「任務完了でござる」等
- これを忘れると殿に叱られた事例あり（家老の責任）

### worktree 使用ルール

- 複数足軽が同リポで作業 → worktree 必須
- target_path は `~/workspace/<repo>-wt<N>` に統一
- メインワークツリーは将軍 / 殿用、足軽は触らない
- 作業完了後 `git worktree remove` で片付け

### Issue First ルール（殿確定 2026-02-24）

- cmd 着手前に GitHub Issue 作成
- PR の body に必ず `Closes #N` または `Part of #N`
- task YAML に Issue URL を含める
- PR body の `Closes #N` は **Issue 番号** を指す（cmd 番号と混同禁止）

### マージ前チェック義務（家老の責務）

- 足軽報告の「P0/P1: 0」のみを信用せず、CodeRabbit Actionable/Minor も必ず確認
- 確認は `gh api graphql` で `reviewThreads(unresolved)` 件数を実証
- 加えて latestReviews body の "Outside diff range comments" セクションも確認すること（reviewThreads=0 でも残置される場合あり — cmd_499 subtask_499a で Critical 見落とし発覚）
  ```bash
  gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){pullRequest(number:N){latestReviews(first:10){nodes{author{login},state,body}}}}}' | python3 -c "
  import json,sys
  d=json.load(sys.stdin)
  reviews=d['data']['repository']['pullRequest']['latestReviews']['nodes']
  for r in reviews:
    if r['author']['login'] == 'coderabbitai':
      body=r.get('body','')
      if 'Outside diff range' in body or 'outside diff' in body.lower():
        print('⚠️ Outside diff range comments あり → 要対応'); sys.exit(1)
  print('OK: latestReviews body に Outside diff range なし')
  "
  ```
- dashboard 表記は「CR Actionable 0」と書く前に GraphQL で確認

## アンチパターン（家老が避けるべき）

| アンチパターン | なぜ駄目か |
|--------------|----------|
| acceptance_criteria を曖昧に書く（"動くこと"） | 検証できず、足軽が「動いた気」で報告 |
| forbidden を省略する | hook 経由のルール突破試行が発生 |
| 戦国口調を忘れる | 殿に叱られる |
| Issue 番号を cmd 番号と混同 | PR の `Closes #N` が誤動作 |
| 1 cmd を 1 巨大 subtask にする | テスト・レビューしづらい、殿は「小さい PR」を好む |
| target_path を main ワークツリーにする | 他作業とコンフリクト、worktree ルール違反 |
| 殿への報告で dashboard を二次情報として信用する | YAML が真実 (Iron Law #4)、dashboard は家老の要約 |
| `reviewThreads(unresolved=0)` のみ確認して完了と報告 | latestReviews body の Outside diff range comments も確認必須 (cmd_499 subtask_499a で Critical 見落とし事例) |

## 関連

- Iron Laws (CLAUDE.md)
- [verification-before-completion](../verification-before-completion/SKILL.md): 完了報告前の検証
- [systematic-debugging](../systematic-debugging/SKILL.md): バグ修正の root cause 特定
- Git Worktree ルール (CLAUDE.md / MEMORY)
- Issue First ルール (CLAUDE.md / MEMORY)
- Communication Protocol (CLAUDE.md): inbox_write の使い方
