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

# RACE-001機械検知の必須フィールド(cmd_778)— worktree外の共有/gitignoreファイル
# (queue/・config/・projects/配下等)へ書き込む場合はそのパスを列挙。無ければ []
touches_files: []

# staging検証テナント必須フィールド(cmd_826)— ステージングで実ブラウザ確認を伴う
# taskは必ずどのテナントで確認するかを明記せよ。「テナントアドミンで確認せよ」
# だけでは不十分(cmd_821/cmd_826で殿確認と足軽実測が食い違って見えた事故の因)。
# 該当しないtaskはnullのまま可。
staging_tenant: null   # 例: console_qa (geonicdb-console)

# 作業ディレクトリ必須フィールド(cmd_820・cmd_830・cmd_836)— git管理下のファイルを
# 変更するtaskは必ずtarget_path(worktreeパス)を指定せよ。null/未指定のまま
# dispatchすると足軽がmain作業木を直接編集する事故に直結する(cmd_820・cmd_830・
# cmd_836で3度実際に発生。いずれも足軽でなくtask YAML側の書き忘れが原因)。
# ファイル編集を伴わぬ純粋な分析・調査taskに限りnullも可(touches_filesが[]で
# よい場合と同じ扱い)。
target_path: /home/hal/workspace/<repo>-wt<N>   # 必須。null可は純粋分析task限定

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

### テスト品質11条(空虚なテスト防止・殿確定+将軍加筆 2026-09-15・cmd_830)

殿ご下命(2026-09-15)「実装をなぞっただけの空虚なテストにしないように」——これを以後の
全実装 task へ **必須項目として注入する**。人の記憶に頼った結果、cmd_817 には書けたが
cmd_823/825/829 には書き落とし、守られる task と落ちる task が生じた(同日 postmortem)。
★既存テストの一斉書き直しは求めない。以後の実装から適用する。★カバレッジ数値を
目標に掲げてはならない(条件5参照)。

instructions / acceptance_criteria には、以下11条のうち **該当するものを具体的な文言で**
盛り込め(「テスト品質11条を満たす」という抽象的な一行のみで済ませるな)。各条には軍師が
QC で検分する観点を併記した。

**殿の条件(1〜6)**

1. **正常系だけでなく異常系・境界値・冪等性・並行実行を明示的に要求する**
   検分観点: acceptance_criteria に「異常系」「境界値」「冪等性」「並行実行」のいずれかが
   具体的なケース名で列挙されているか(該当しない観点は理由が明記されているか)。
2. **公開インターフェースの入出力・振る舞いをテストする**
   検分観点: テストが実装の内部関数/内部状態でなく、呼び出し側から見える入出力・戻り値・
   例外を検証しているか。
3. **E2E ではブラウザでのスクリーンショットを確認する**
   検分観点: report にスクリーンショットの証跡があるか(「deploy 完了確認の階層」§(d)と
   同一要件)。
4. **モックは多用しない**
   検分観点: モック導入数が最小限か、外部I/O境界(ネットワーク/DB/時刻等)に限定されているか。
5. **カバレッジ100%を目指すのではなく、壊れたら困る挙動を優先してテストする**
   検分観点: acceptance_criteria や report にカバレッジ%目標が掲げられていないか(掲げて
   いれば差し戻す)。テスト対象の選定理由が「壊れたら困るから」で説明されているか。
6. **再利用できるものはする**
   検分観点: 既存のテストヘルパー/フィクスチャ/モックを流用せず重複実装していないか。

**将軍が加える条件(7〜11・cmd_830当日の実例から導出)**

7. **★★是正前に必ず落ちることを実証せよ(RED の対照)——習慣でなく成果物として残せ**
   実装(是正)を一時的に外す/コメントアウトし当該テストが実際に FAIL することを確認し、
   戻すと PASS することを確認する。★commit を分ける必要はない(実装とテストを分けると
   CI が赤の commit を含む別の不都合が出る)——その代わり、**report または PR 本文に必ず
   次の一節を含めよ**:「この実装/この規則を一時的に無効化すると、次のテストが落ちる:
   <テスト名> — <実行出力の抜粋>」。
   検分観点: report/PR 本文に上記一節(無効化対象・落ちるテスト名・実行出力抜粋)が
   **具体的に**書かれているか。
   ★根拠(軍師の cmd_830 監査で判明): PR#177・#178・#175 の3件はいずれも「是正前に落ちる
   ことを確認した」と自己申告していたが、実装とテストが同一 commit に載る作法のため RED
   状態そのものは成果物として残っておらず、QC は自己申告を追認するしかなかった(検証で
   なく確認)。上記一節を必須にすることで、自己申告でなく再現可能な記述を報告に残させる。
8. **★★「失敗が失敗として現れること」をテストせよ**
   「データが無い」と「取得に失敗した」が区別されることを明示的にテストする。破壊的操作の
   直前確認は、確認自体が失敗した場合に安全側(=操作中止)へ倒れることを必ずテストする。
   検分観点: report/テストコードに「取得失敗時に中止する」ケースのテストが明示されているか。
9. **テストが実際に走っていることを確かめよ**
   検分観点: report に「CIのどのjob名/step名から実行されるか」の記載があるか。「0 SKIP」の
   申告だけでなく、実行総件数(collected/passed件数)が記載されているか(cmd_754で隠れSKIP
   を「0 SKIP」と誤認した実例あり)。
10. **モックを使うなら、モックが本物と食い違ったときに気づける形にせよ**
    検分観点: モックを使うテストに、実物との突き合わせ(contract test/実APIへの最低1件の
    スモークテスト等)が一件以上あるか。
11. **テストの名前が「何が壊れたら困るか」を語ること**
    検分観点: テスト名が `test_function_a` のような実装追従名でなく、「削除前の確認に
    失敗したら削除を止める」のように失敗シナリオを語っているか。

**acceptance_criteria への反映例**(コピペしてそのまま使える形。該当する条件のみ選べ):

```yaml
acceptance_criteria:
  - "異常系(<具体的ケース>)・境界値(<具体的ケース>)・冪等性・並行実行のテストがある(該当しない観点は理由を明記)"
  - "公開インターフェース(<関数/APIエンドポイント名>)の入出力・振る舞いをテストしている(内部実装詳細でなく)"
  - "モックは外部I/O境界(<例: 外部API/DB>)に限定し多用していない。モックを使う箇所は本物との突き合わせ(<contract test名>)を1件以上持つ"
  - "カバレッジ%を目標に掲げていない。「壊れたら困る挙動」を優先している理由をreportに記載"
  - "既存のテストヘルパー/フィクスチャ(<名前>)を再利用している"
  - "★是正前にREDを実証: 実装を一時的に外すとFAILし戻すとPASSすることを確認し、report/PR本文に「この実装/この規則を一時的に無効化すると、次のテストが落ちる: <テスト名> — <実行出力の抜粋>」を具体的に記載している"
  - "★「データが無い」と「取得に失敗した」が区別されるテストがある。破壊的操作(<具体的操作>)の直前確認が失敗した場合、安全側(操作中止)へ倒れることをテストしている"
  - "reportにCIのjob名/step名を明記し、「0 SKIP」に加え実行総件数(collected/passed件数)を記載している"
  - "テスト名が失敗シナリオを語っている(例: test_abort_deletion_when_precheck_fails)"
```

### 戦国口調の徹底

- 全 instruction を戦国武士風で書く
- 報告 YAML も「〜つかまつった」「任務完了でござる」等
- これを忘れると殿に叱られた事例あり（家老の責任）

### worktree 使用ルール

- 複数足軽が同リポで作業 → worktree 必須
- target_path は `~/workspace/<repo>-wt<N>` に統一
- メインワークツリーは将軍 / 殿用、足軽は触らない
- 作業完了後 `git worktree remove` で片付け

### target_path は必須欄とせよ(cmd_836・軍師具申 2026-09-16)

- 本日、家老が書いた task YAML に `target_path`(worktree 指定)が欠けていたため、
  足軽の成果物(git 管理下のファイル編集)が main 作業木に未 commit のまま残る事故が
  **3 度発生した**(cmd_820・cmd_830/ashigaru4・cmd_836/ashigaru2)。いずれも足軽の
  落ち度ではなく、task YAML の書き方側の抜けが原因である。
- **★touches_files(RACE-001・cmd_778)と staging_tenant(cmd_826)は、同種の「書き忘れを
  人の記憶に頼らず機械で防ぐ」ために既に必須欄化されている。target_path も同じ理屈で
  必須欄とする。**
- git 管理下のファイルを変更する task で `target_path` が未指定・null のまま dispatch
  してはならない。指定漏れは足軽が main 作業木を直接編集する事故に直結する。
- **例外**: ファイル編集を伴わない純粋な分析・調査 task は `target_path: null` のままで
  よい(touches_files が `[]` でよい場合と同じ扱い)。

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

### staging 検証手順には「どのテナントで」を必須明記せよ（cmd_826 postmortem・殿確定 2026-09-15）

- cmd_821/cmd_826 で、殿が確認した「20件超のエンティティ」と足軽が実測した「console_qa
  テナントで0件」が食い違って見える騒ぎがあった。★原因は両者とも正しく、確認していた
  **テナントが違っていただけ**だった(console_qa は検証専用の空テナント、殿がご覧に
  なったのは実データを持つ別テナント)。手順に「どのテナントで確認するか」が書かれて
  いなかったことが、食い違いに気づくまでの時間を長引かせた根本原因である。
- **★ staging 検証・e2e タスクの instructions / acceptance_criteria には、必ず具体的な
  テナント名を明記すること**(例: 「console_qa テナントで確認せよ」)。「テナントアドミン
  で」だけでは不十分――*どの*テナントアドミンかまで書け(§「console e2e/検証タスクの規律」
  と両輪)。
- **人の記憶に頼るな**: 上記テンプレートの `staging_tenant:` フィールド(cmd_826 で追加)を
  必須で埋めよ。staging でのブラウザ確認を伴う task にこのフィールドが `null` のまま
  dispatch してはならない。touches_files(RACE-001)と同じく、テンプレートに固定欄として
  組み込むことで「書き忘れ」を構造的に防ぐ。
- テナント名と認証情報の対応表は `context/geonicdb-console-issue-order.md` の
  「staging検証の認証情報」節を正典とする(project 固有の対応表がある場合はそちらも参照)。

### 認証を要する作業と要さぬ作業を同一 subtask に束ねるな（殿確定 2026-08-13・cmd_716）

- 1Password / AWS / Touch ID 等の認証を要する工程と、要さぬ工程を **同一 subtask に束ねてはならない**。
  束ねると、認証側が失効・失敗した瞬間に認証不要な工程まで巻き込まれて全体が止まる
  (本セッションで五度繰り返した失敗の構造的原因。cmd_703/712a/712c/712d/716c)。
- **設計原則**: 認証を要さぬものを先に片付ける subtask に切り出し、認証を要るものだけを
  別 subtask にして殿の認証窓(Touch ID 等)に合わせて dispatch する。
- **1Password 関連の技術知見**(必ず踏まえよ):
  - `op signin` は空振りする(デスクトップアプリ連携ゆえ不要)。**目的の op コマンド
    (`op read` / `op item get` / `op vault list`)自体が認証をトリガーする**。
  - **資格情報先取り方式**: ブラウザ操作等の本作業に入る**前に**
    `v=$(timeout 30 op read '...')` のように**代入形で**取得しメモリに保持してから
    本作業へ進む(端末へ出力する形は使うな)。セッション途中失効の影響を受けにくい
    (cmd_712d でこの順序変更のみで四度の失敗を越えた)。疎通確認のみが目的なら
    `op item list` の件数で行い、値そのものを取得する呼出は本作業の直前まで待て
    (cmd_836・2026-09-16、家老が `--reveal` 付き `op item get` の出力形で実行し
    資格情報を端末へ露出させた事故を受けての是正)。
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

### 登壇物の完了確認の階層（cmd_754 postmortem・2026-09-03）

講演・プレゼン資料・スピーチ原稿を伴う cmd は、上記「deploy 完了確認の階層」と
**同型の構造**を持つ。★deploy が「実ブラウザで見るまで反映と言えぬ」のと同様、
登壇物は**「声に出して通しで読むまで完成と言えぬ」**。以下の階層を取り違えるな:

1. (a) 語数が減った／所要時間見積りが縮んだ ——文字の上の代理指標にすぎぬ
2. (b) 発音しにくい語を置換した ——読みやすさの改善であり、喋りやすさの証明ではない
3. (c) 1文1論点・15語以内等の register を満たした ——**紙の上で読みやすい**まで
4. (d) ★**登壇者本人(または代役)が声に出して通しで読み、詰まりが無い** ——
   **ここで初めて「喋れる」と言える**

- **(a)(b)(c) のいずれで止まっても「完成」と述べるな。(d) を確かめてから述べよ。**
  語数・timing・平易化パスだけで完了宣言することを禁ずる(cmd_754 で台本を
  「読む文章」として最適化し「喋る文章」として検めず、殿が壇上で詰まった実例あり)。
- 登壇物 cmd の acceptance_criteria には必ず次の1行を含めよ:
  「登壇者本人(または代役)が声に出して通しで読み、詰まった箇所ゼロを確認している
  (録音または稽古実施の証跡を残す)」
- **★所見応答プロトコル(必須)**: 殿(または登壇者)から「詰まった」「喋りにくかった」等の
  所見が出た場合、**テキスト修正(平易化・語数削減・語の置換)だけで応じることを禁ずる**。
  必ず**再度の音読(声に出す)往復**を経て、当該箇所の詰まりが消えたことを確認してから
  完了とせよ。症状(詰まる)に代理指標(文字の読みやすさ)で応じるな。
  ——2026-09-02、殿の音読所見に対し我らはテキスト平易化パス一度で応じ、再音読を
  経ぬまま登壇に至った。この型を繰り返すな。
- **★文体の要注意パターン(文字で高評価・音声で難所)**: 以下は紙で読むと洗練されて
  見え高評価になりがちだが、声に出すと難しい。task instructions で登壇物を書かせる際、
  避けるか音読で必ず検めよ:
  - **em-dash による挿入句**(主語を長い割り込みの向こうへ保持させる)
  - **同格の言い換え**(A、すなわち B、すなわち C…と重ねる)
  - **対句・反復構造**(not X but Y / less A, more B)
  実例(cmd_754 台本 ACT I): `That gap — between clever AI and understood data — is what
  this talk is about.` ——紙では美しいが、話者は主語「That gap … is what this talk is
  about」を6語の割り込みを跨いで保持せねばならず、非ネイティブには難所となる。

### 設定を一時的に緩める task の必須欄(cmd_760 postmortem・殿確定 2026-09-05)

登壇・検証・デバッグ等のため**既存の設定を一時的に緩める**(認証を弱める・タイムアウトを延ばす・
自動ロックを止める等)task には、以下を必須で含めよ。今週だけで3件の一時緩和(dpopRequired・
ControlPlaneReservedConcurrency・1Password自動ロック)があり、元値を記録していた2件は
判断できたが、1Passwordだけ記録が無く2日blockedした——GUIでしか読めぬ設定はとくに危うい。

- **★★★「緩める前の値」を書く欄を必須とする**。task YAMLに`original_value:`のような
  明示フィールドを持たせ、緩めた本人がその場で控えよ。「後で調べれば分かる」と思うな——
  1PasswordのようにGUIでしか読めずCLIで取得できぬ設定は、後から復元不能になりうる。
- **★acceptance_criteriaに「何へ戻すか」を具体的に明記させる**。「登壇後に戻す」だけでは
  足りぬ——戻す先の値・戻す条件の両方を書け。
- **★★復元条件は「観測できる事実」で書け**。ControlPlaneReservedConcurrencyの一件では
  「認証往復が消えたことの実証」を復元条件にしたが、SDKの設計上その事象自体が起こり得ない
  ことが後で判明した——検証不能な条件を復元ゲートに置くな。

### マージ前チェック義務（家老の責務）

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
| target_path を書き忘れる(null/未指定のまま dispatch) | 足軽が main 作業木を直接編集する事故に直結(cmd_820・cmd_830・cmd_836で3度発生)。純粋分析task以外は必須欄 |
| 殿への報告で dashboard を二次情報として信用する | YAML が真実 (Iron Law #4)、dashboard は家老の要約 |
| `reviewThreads(unresolved=0)` のみ確認して完了と報告 | latestReviews body の Outside diff range comments も確認必須 (cmd_499 subtask_499a で Critical 見落とし事例) |
| console 検証タスクで super admin を使う | 403偽陰性の常習原因(cmd_656/cmd_661で2度再発)。必ずテナントアドミン+テナント選択を明記せよ |
| staging 検証 task に `staging_tenant:` を埋めず dispatch | どのテナントを見ているか取り違え、殿確認と足軽実測が食い違って見える(cmd_826) |

## 関連

- Iron Laws (CLAUDE.md)
- [verification-before-completion](../verification-before-completion/SKILL.md): 完了報告前の検証
- [systematic-debugging](../systematic-debugging/SKILL.md): バグ修正の root cause 特定
- Git Worktree ルール (CLAUDE.md / MEMORY)
- Issue First ルール (CLAUDE.md / MEMORY)
- Communication Protocol (CLAUDE.md): inbox_write の使い方
