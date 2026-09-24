# CodeRabbit Adaptive Fair Usage と未レビュー検知 (cmd_871)

## 背景

CodeRabbitのAdaptive Fair Usageは、直近7日のレビュー数に応じて毎時のレビュー枠自体を
段階的に引き下げる(0-29件/7日→5件/時、30-39→4件/時、40-49→3件/時、50-59→2件/時、
60件以上→1件/時)。従量課金はこの引き下げを覆さない。

30日分の実測で、書き換えられたcommitへのレビュー比率がhalsk名義11.5%対
dkastl殿1.4%(約8倍)であった。「merge→rebase→再レビュー」の型が浪費の主因と見られる。

## CodeRabbitのcommit statusは、レビューせぬ場合も state=success を返す

30日実測(github commit status API):
- Review completed: 3,021件(正常)
- Review rate limited: 42件
- Review skipped: ...: 359件(rate limitedの約8倍)
- Reviews paused: 4件

上記いずれも `state=success` として記録されていた。**検査の不在が、検査の合格として
現れる構造**である。merge前チェックが state だけを見ると、この3種を「レビュー合格」と
誤判定してしまう。

対策として、description まで見て未レビューを検知する判定ロジックを実装した:
- `scripts/lib/coderabbit_gate.sh`(`coderabbit_gate_check` 関数)
- CLIラッパー: `scripts/coderabbit_review_gate.sh <owner/repo> <PR番号>`
- テスト: `tests/unit/test_coderabbit_gate.bats`(是正前=state のみ判定のRED対照つき)
- 呼び出し手順: `instructions/karo.md`「コード変更 PR のマージ必須条件」節

## draft PR方式でレビュー回数そのものを減らす

中央設定(`geolonia/coderabbit` の `.coderabbit.yaml`)は `auto_review.drafts: false`
であるため、PRがdraft中はCodeRabbitがレビューしない。足軽はdraftでPRを開き、是正の
pushをdraftのまま済ませ、仕上がってから一度だけreadyにする(readyにした時点で初めて
レビューが走る)。

★この方式とmergeゲート是正は表裏の関係にある: draft中の"Review skipped"は
state=successで返るため、ゲートを直さずdraft方式だけ導入すると、節約策がそのまま
新しい穴になる。

★2026-09-24時点: cmd_872(家老による前提検証)で「ready化はdraft中の全commit
変更をレビュー対象にする」ことが実在PR3件で実証され、保留を解除した。この作法は
instructions/ashigaru.mdおよび`.claude/skills/inbox/SKILL.md`(Step 7)の両方へ
反映済み(片方のみでは、skill機構を持たないCLI向けのcross-CLI contractである
instructions/ashigaru.mdが古いままになる)。

## rate limit残量の確認手順

PRへ `@coderabbitai rate limit` とコメント投稿すると、レビュー枠の残量が返信で分かる。
この照会自体はレビューを消費しない(Daniel殿(dkastl)の調べ)。

★ただしPRへのコメント投稿は殿の代理での外部書き込みである(Iron Law 7)。投稿する
場合は必ず①事前に殿/家老の確認を取り、②冒頭に `[AI]` を付すこと。

## 記録: geonicdb-consoleの.coderabbit.yamlはinheritance指定を欠く

2026-09-24、`gh api repos/geolonia/geonicdb-console/contents/.coderabbit.yaml` で
実際のファイル内容(60行)を取得し確認した。`inheritance`・`base_branches`・
`path_filters`・`drafts` のいずれのキーも存在しない。

一方で中央設定(`geolonia/coderabbit` の `.coderabbit.yaml`)冒頭には次の記載がある:
「Org-wide CodeRabbit defaults, for every repository with no .coderabbit.yaml of its
own. A repository that has one must set `inheritance: true` to keep these.」

つまりgeonicdb-consoleは独自の `.coderabbit.yaml` を持つため、`inheritance: true` を
明示しない限り中央設定(`base_branches: [".*"]`・`path_filters`・`drafts: false`等)を
一切引き継がない。特に `base_branches: [".*"]` を引き継いでいない場合、既定は
defaultブランチ向けPRのみのレビューとなり、feature branchを土台にしたPRのレビューが
静かにスキップされ、かつそれが passing check として現れうる(中央設定のコメントが
警告している事象そのもの)。

★本件はorg全体の設定方針であり、`geolonia/coderabbit#12` でDaniel殿(dkastl)が
議論中。本cmd_871では**記録のみ**とし、geonicdb-consoleの `.coderabbit.yaml` は
直していない。
