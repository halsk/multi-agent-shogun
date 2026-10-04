---
name: inbox
description: 足軽のinbox処理〜タスク実行〜報告までの標準パイプライン(cmd_742)。`inboxN` nudge(Nは可変)を受信したら、Nの値を見ずに本skillを呼び出す。worktree/TDD/静的検証/PR/CI+CodeRabbit/ブラウザ検証/全文報告/inbox既読化/worktree撤収を順に実行する。認証待ちの段は最後尾。
---

# inbox

## 起動条件

`inboxN`(例: `inbox1` `inbox3`)という nudge を受け取ったら、**N の値を見ずに**本skillを呼び出す。

理由(cmd_742・`/insights` 指摘③): nudge の未読数 N は可変であり、`/inbox1` のような固定スラッシュコマンドでは全ての N に対応できない。skill 名を固定の `inbox` とし、実際の未読件数は本 skill の Step 1 で Read してその都度数える設計にすることで、N の値に依存しない起動を実現する。

**適用範囲**: 本 skill は Claude Code の Skill 機構が使える足軽セッション向け。Codex/Copilot/Kimi 等 Skill 機構を持たない CLI では `instructions/ashigaru.md` の `workflow`(YAML frontmatter)が引き続き正典として機能する——本 skill はそれを置き換えない。役割分担: `instructions/ashigaru.md` は cross-CLI 共通の骨格契約、本 skill は Claude Code 向けの詳細手順書(正典はこちら)。二重に書き写して食い違いが生じるのを避けるため、`instructions/ashigaru.md` 側は詳細手順をここへの参照に留める。

## 手順

### Step 0: 自己識別

```bash
tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'
```

以後の全手順は自分の ID(`ashigaru{N}`)のファイルのみを対象とする。他の足軽の YAML は絶対に読み書きしない(過去実例: ashigaru5 が ashigaru2 のタスクを実行した事故)。

### Step 1: inbox 読込・未読数の実測

```bash
cat queue/inbox/{自分のid}.yaml
```

`read: false` のエントリを全て洗い出す。**nudge の数字(inboxN)は無視し、実測した件数を正とする**(可変 N 問題への対処そのもの)。

### Step 2: タスク YAML 読込・前提の検証

```bash
cat queue/tasks/{自分のid}.yaml
```

- タスクが参照する上流 YAML(例: `parent_cmd` の出所である `queue/shogun_to_karo.yaml`)がリスト構造を持つ場合、`- id:` 境界マーカーの出現数を実測し記録する:
  ```bash
  grep -c '^- id:' queue/shogun_to_karo.yaml
  ```
  直前の編集で件数が不自然に減っている(=リスト項目が誤って統合された疑いがある)場合は、その場で作業を止め家老へエスカレーションする。
- ★前提の検証: タスクの前提(project / target_path / context 等)が YAML の実際の記述や現在のリポジトリ状態と矛盾していないか確認する。矛盾があれば実行せず停止し、エスカレーションする(推測で埋め合わせない)。

### Step 3: task YAML の status を in_progress へ(cmd_914)

```bash
bash scripts/start_task.sh
```

自分の task YAML(`queue/tasks/{自分のid}.yaml`)の status が `assigned` の時だけ
`in_progress` へ書き換える(flock・mtime 確認込み・既に in_progress 等なら無害に
no-op)。★これを飛ばすな——真因調査(cmd_914)で足軽7人全員が今日この書換を
一度も行っていなかったことが判明している(旧手順にはこの段自体が無かった)。

### Step 3.5: worktree 作成

対象 repo が git 管理下なら、必ず専用 worktree を切ってから作業する。

```bash
git worktree add ../<repo>-wt{N} -b <branch-name>
```

main 直接 commit 禁止(Iron Law 6)。複数エージェントが同一 repo に触れる可能性がある場合は特に必須。

### Step 4: TDD(RED → GREEN)

1. 先に失敗するテストを書く(RED)。既存テストがあれば現状(何が落ちているか)を確認する。
2. 実装する。
3. テストを通す(GREEN)。

### Step 5: 静的検証・テスト一式

```bash
npm run typecheck   # あれば
npm run lint        # あれば
npm test            # unit
npm run test:e2e    # e2e(あれば)
```

SKIP = FAIL(Iron Law 3)。1 件でも SKIP があれば未完了として扱う。

### Step 6: 自己コードレビュー

`geolonia-skills:code-review-expert` skill(`--auto`)を実行し、P0・P1 の指摘がゼロになったら
次工程へ進む。★組織版(同期 plugin の `code-review-expert`)は
`.code-review-done` を書く手順を持たぬ(当家独自版にのみあった手順)。
guard.sh Hook 6 は push の前にこの file が HEAD と一致することを求めるため、
**自ら `git rev-parse HEAD > .code-review-done` を書いて印とせよ**
(`--auto` で P0・P1 が0になり、かつ★全ての変更を commit した後の HEAD で。
レビューの直しを commit する前に印を書くと、HEAD がずれて Hook 6 が push を
止める)。

### Step 7: PR 作成(draft first・cmd_871)

```bash
gh pr create --draft --repo <owner>/<repo> --title "..." --body "..."
```

- halsk/multi-agent-shogun は Issue First 免除・CodeRabbit 不要(それ以外の repo は project 方針に従う)
- `--repo` を必ず明示する(フォーク元への誤 PR 防止。省略すると upstream に誤って PR が飛ぶ実例あり)
- ★CodeRabbit 導入 repo(halsk/* 以外)は **必ず `--draft` で開く**。中央設定
  (`geolonia/coderabbit`)は `auto_review.drafts: false` であり、draft 中は
  CodeRabbit がレビューしない。Adaptive Fair Usage は直近7日のレビュー数で
  毎時枠自体を引き下げる仕組みのため、未完成な差分への重ねレビューで枠を
  浪費してはならない。
- ★足軽は **自ら ready にせぬ**(`gh pr ready` を打たぬ)。是正の push は
  draft のまま済ませ、**draft のまま報告せよ**。ready は**軍師の QC の PASS
  の後に、家老が一度だけ**行う(cmd_934【四】)。ready 化した時点で
  初めてレビューが走る(レビューを避けるのではなく、未完成物への重複
  レビューを避けるための運用)。
- ★`@coderabbitai review`・`@coderabbitai rate limit` も足軽は自ら投じぬ。
  投じる引き金は `cr_retrigger`(review-next の判断に従う自動化)だけが
  持つ(cmd_934【一】)。

### Step 8: CI 確認(CodeRabbit の確かめは ready 後)

```bash
gh pr checks <N>
```

CI green を確認する。★PR は draft のまま報告する決まり(Step 7・cmd_934)の下では、
この時点で CodeRabbit はまだ走っていない(`auto_review.drafts: false`)。
CodeRabbit の reviewThreads・commit status の確認は、ready にした後の家老
(または家老が出す直しの task)が担う(`instructions/karo.md`「コード変更 PR
のマージ必須条件」節)。足軽は CI の緑を確かめたら、CodeRabbit のレビューを
待たずに次工程(報告)へ進んでよい。

### Step 9: ブラウザ検証(UI 変更を伴う場合)

UI に関わる変更は、実ブラウザで意図した画面が現れるまで完了と述べない(CLAUDE.md「Deploy/UI 完了判定の掟」)。curl 200 や JS grep は中間確認に過ぎない。

- **認証待ちで進めない場合**: 30 秒待って**一度だけ**再試行する。それでも進めなければ `status: blocked` として正直に記録し、認証待ちである旨を報告に明記する。無理な回避や「見た」という申告だけで済ませない。

### Step 10: 報告 YAML 作成(全文書換)

`queue/reports/ashigaru{N}_report.yaml` は **Edit(部分編集)ではなく全文を書き直す**(Write)。

理由: 部分編集はフィールド抜け・前回実行の古い値の残存に気づきにくい。前回の報告構造を流用せず、今回の実行結果で全項目を作り直す。

必須フィールド(`instructions/ashigaru.md`「Report Format」参照): `worker_id, task_id, parent_cmd, status, timestamp, result, skill_candidate`。

### Step 11: task 完了(finish_task.sh)+ 既読化(cmd_914)

```bash
bash scripts/finish_task.sh --status done
# blocked/failed で終える場合は --status blocked / --status failed
# 既定文言でなく戦国口調で明示したい場合は --message "..." を添える
```

`finish_task.sh` が一度に行う(一つでも欠ければ非0で止まり何も書き換えない):
report YAML の検め(単一文書・task_id 一致・重複キー無し・必須欄そろう・
status 一致・report の mtime が task より新しい)→ task YAML の status 書換
(flock・mtime 確認込み)→ report_to(通常 gunshi)へ `inbox_write.sh`
(type=report_received)→ ログ出力。★従来の手書き `inbox_write.sh` 直呼びは
これに置き換わった——真因調査(cmd_914)で明らかになった「done へ戻す段が
無い」問題を、report YAML 作成(Step 10)の直後にこの一つの呼出で解消する。

非0で終了した場合は report YAML の内容(task_id・status・timestamp 等)を
見直し、原因(task_id 不一致・report が古い・必須欄欠落等)を解消してから
再実行する。

続けて、Step 1 で洗い出した `read: false` エントリを全て `read: true` に更新する(Edit ツール)。既読化を飛ばして待機に入らない(CLAUDE.md「MANDATORY Post-Task Inbox Check」)。

### Step 12: worktree 撤収

```bash
git worktree remove ../<repo>-wt{N}
```

`git worktree list` で撤収済みであることを実測してから完了とする。「残存物を実測なしで軽微と報告してはならない」——撤収漏れは du 等で実測して報告する。

### Step 13(最後尾・認証を要する場合のみ): 1Password 等の認証待ち

1Password Touch ID 等、人間の介入を要する認証段は**必ず最後尾**に配置する(過去実績: 認証待ちの timeout が 4 セッションで最終段を潰し、完成済みの作業まで「阻害」扱いになった)。

- 認証プロンプトが出たら 30 秒待って一度だけ再試行する
- それでも進まなければ、他の全工程(Step 1〜12)が完了していることを報告に明記した上で `status: blocked`(認証待ち)として記録する

## 関連

- [verification-before-completion](../verification-before-completion/SKILL.md) — Step 5〜9 の証拠基準
- [systematic-debugging](../systematic-debugging/SKILL.md) — バグ修正を伴うタスクの前段
- `instructions/ashigaru.md` — cross-CLI 共通の workflow 契約(Codex/Copilot/Kimi はこちらが正典)
- CLAUDE.md「Deploy/UI 完了判定の掟」「Inbox Processing Protocol」「MANDATORY Post-Task Inbox Check」
