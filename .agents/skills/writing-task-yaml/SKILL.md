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
  - "【CR 完了確認必須】statusCheckRollup=SUCCESS は CodeRabbit 完了の証拠にならない。完了報告前に必ず以下を実行して reviewThreads(unresolved=0) を実証すること: gh api graphql -f query='{ repository(owner:\"<owner>\",name:\"<repo>\") { pullRequest(number:<PR_NUMBER>) { reviewThreads(first:50) { nodes { isResolved } } } } }' | python3 -c \"import json,sys; d=json.load(sys.stdin); threads=d['data']['repository']['pullRequest']['reviewThreads']['nodes']; unresolved=sum(1 for t in threads if not t['isResolved']); print(f'Unresolved: {unresolved}'); assert unresolved==0,'FAIL'\""

  # 完了報告
  - "完了報告 YAML を queue/reports/ashigaru<N>_report.yaml に出力"
  - "家老に inbox_write で報告 (戦国口調)"

acceptance_criteria:
  - "<検証可能な条件 1>"
  - "<検証可能な条件 2>"
  - "テスト全 PASS (SKIP テスト導入禁止)"
  - "/code-review-expert --auto P0/P1: 0"
  - "PR の CR Actionable 0 — gh api graphql で reviewThreads(unresolved=0) を実証済み (statusCheckRollup のみでは不可)"
  - "CI PASS"
  # ★deploy を伴う task は必ず最終条件として以下を追加せよ(殿確定 2026-08-13・cmd_717。
  #   JS の grep・HTTP ヘッダ・workflow success はいずれも中間確認であり完了条件にしてはならない)
  - "実ブラウザで<意図した要素>が画面に現れることを確認し、スクリーンショットを証跡として残している"

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

### テストファースト要件（コード実装タスク — Bloom L4 以上またはコード変更を含む場合）

コード変更を伴うタスクの acceptance_criteria には以下を必ず含めること:

```yaml
acceptance_criteria:
  - "テストファースト: 実装前にテスト/仕様を書く"
  - "テスト全件 PASS / SKIP=0"
  - "CI (test+lint+build) 緑"
  - "テストが変更をカバーしている (新機能には新テスト)"
```

**理由**: PR#9 でテスト/CIゼロのコード変更が軍師QC・家老マージゲートを素通りした (2026-06-30 根本対策)。
テスト不在は「未完」扱い。acceptance_criteria に明記してはじめてゲートが機能する。

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

### console e2e/検証タスクの規律（テナントアドミン必須・殿確定 2026-07-11）

- **geonicdb-console の e2e/検証系タスクは必ずテナントアドミンでログイン + テナント選択**すること。
  super admin(superuser)は**厳禁**。
- 理由: super admin は単一テナントにスコープされないため `currentTenant` が空になり、
  NGSI-LD entities 等のリクエストが 403 を返す**偽陰性**が発生する(cmd_656・cmd_661 で2度再発)。
  これは real bug でも当該アプリの回帰でもなく、検証手順の誤りによる誤検知。
- task YAML の instructions/context に以下を必須明記すること:
  ```
  ★e2e規律: 必ずテナントアドミンでログイン+テナント選択して検証せよ。super admin(superuser)は
  厳禁(=単一テナント非スコープでcurrentTenant空→403偽陰性の常習原因。cmd_656/cmd_661参照)。
  ```
- 参照: memory `feedback_console_e2e_tenant_admin_required`

### 認証を要する作業と要さぬ作業を同一 subtask に束ねるな（殿確定 2026-08-13・cmd_716）

- 1Password / AWS / Touch ID 等の認証を要する工程と、要さぬ工程を **同一 subtask に束ねてはならない**。
  束ねると、認証側が失効・失敗した瞬間に認証不要な工程まで巻き込まれて全体が止まる
  (本セッションで五度繰り返した失敗の構造的原因。cmd_703/712a/712c/712d/716c)。
- **設計原則**: 認証を要さぬものを先に片付ける subtask に切り出し、認証を要るものだけを
  別 subtask にして殿の認証窓(Touch ID 等)に合わせて dispatch する。
- **1Password 関連の技術知見**(必ず踏まえよ):
  - `op signin` は空振りする(デスクトップアプリ連携ゆえ不要)。**目的の op コマンド
    (`op read` / `op item get` / `op vault list`)自体が認証をトリガーする**。
  - **資格情報先取り方式**: ブラウザ操作等の本作業に入る**前に** `op read` で資格情報を
    取得しメモリに保持してから本作業へ進む。セッション途中失効の影響を受けにくい
    (cmd_712d でこの順序変更のみで四度の失敗を越えた)。
  - `op://` 参照は外部へ出す文書(Issue コメント等)に書くな——値そのものでなくとも
    「どの vault のどの item に資格情報があるか」を外部に残す必要はない。

### deploy 完了確認の階層(殿確定 2026-08-13・cmd_717)

- UI 変更を伴う cmd は acceptance に原則ブラウザ確認を入れよ(2026-07-09 殿確定 standing
  rule)。★deploy の完了確認にも同じ精神を適用し、以下の階層を取り違えるな:
  1. (a) workflow が success ——「処理が終わった」だけ
  2. (b) HTTP ヘッダが変わった ——stack(CloudFront 設定等)の反映を示すのみで、
     **S3 等に置かれる成果物の反映を示さない**
  3. (c) 成果物(assets/\*.js 等)に新しい実装が含まれる ——ここまでで「配られた」
  4. (d) ★**実ブラウザで画面を開き、意図した要素が現れている** ——**ここで初めて
     「反映された」と言える**
- **(a)(b)(c) のいずれで止まっても「deploy 済」と述べるな。(d) を確かめてから述べよ。**
  curl でのヘッダ確認や JS の grep だけで完了宣言することを禁ずる(cmd_717 で将軍が
  CSP ヘッダだけを見て「deploy 済」と誤断し、実際は deploy 失敗で JS が古いままだった
  実例あり)。
- 実ブラウザ確認は Playwright 等で agent でも実行可能。スクリーンショットを証跡に残せ。
  ★このブラウザ確認自体はログイン等の認証を要しない場合が多い(画面に要素が現れることを
  見るだけ)——認証が要るのは多くの場合その先の「ログインしてデータを読む」工程のみであり、
  上記の「認証を要する/要さぬ作業の分離」原則に従い前者は先に片付けよ。

### マージ前チェック義務(家老の責務)

- 足軽報告の「P0/P1: 0」のみを信用せず、CodeRabbit Actionable/Minor も必ず確認
- **commit push だけでは reviewThreads が unresolved のまま残るケースあり。修正 push + CR re-review 後に必ず以下を実行し unresolved=0 を実証すること:**
  ```bash
  GH_TOKEN= gh api graphql -f query='
  {
    repository(owner:"OWNER", name:"REPO") {
      pullRequest(number: PR_NUM) {
        reviewThreads(first:50) {
          nodes { isResolved isOutdated path }
        }
      }
    }
  }' | python3 -c "
  import sys,json; d=json.load(sys.stdin)
  threads=d['data']['repository']['pullRequest']['reviewThreads']['nodes']
  unresolved=[t for t in threads if not t['isResolved']]
  print(f'total={len(threads)} unresolved={len(unresolved)}')
  for t in unresolved: print(' -', t['path'], 'outdated=', t['isOutdated'])
  "
  ```
- unresolved が残る場合は 1 件ずつ対応: (a) CR 期待通り修正 または (b) `「Resolved as Designed: <理由>」` reply + 手動 Resolve conversation
- 証拠を報告に含める: `total=N unresolved=0`
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
| statusCheckRollup=SUCCESS を CR 完了と誤認する | 2度連続違反事例あり (subtask_497a + 497a3)。必ず reviewThreads を gh api graphql で実証せよ |
| console 検証タスクで super admin を使う | 403偽陰性の常習原因(cmd_656/cmd_661で2度再発)。必ずテナントアドミン+テナント選択を明記せよ |

## 関連

- Iron Laws (CLAUDE.md)
- [verification-before-completion](../verification-before-completion/SKILL.md): 完了報告前の検証
- [systematic-debugging](../systematic-debugging/SKILL.md): バグ修正の root cause 特定
- Git Worktree ルール (CLAUDE.md / MEMORY)
- Issue First ルール (CLAUDE.md / MEMORY)
- Communication Protocol (CLAUDE.md): inbox_write の使い方
