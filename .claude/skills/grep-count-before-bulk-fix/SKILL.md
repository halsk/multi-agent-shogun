---
name: grep-count-before-bulk-fix
description: 複数行への一括是正に入る前に対象行数をgrepで数え、是正後に件数一致を機械で確かめる手順。「数えられるものは数えよ」——目視の列挙は1行漏れる。geolonia/geonicdb-console PR#179で実際に1行漏れCodeRabbit2回目のレビューで露見した事故が出所。複数ファイル/複数行に同一パターンを適用する一括修正の直前に呼び出すこと。
---

# grep-count-before-bulk-fix

## 出所となった事故(実物)

**geolonia/geonicdb-console PR#179**「fix(coverage): Issue#168 ⑭を8行へ分解しrule 5(unconfirmed非増加)を解消」
(https://github.com/geolonia/geonicdb-console/pull/179)。

`coverage/coverage.yaml` の absence 判定(`kind: absence`)8行について、
「`find src/pages -iname` によるファイル名検索だけでは根拠不十分」という
CodeRabbit指摘を受け、8行すべてを `grep -r -l -i <term> src/App.tsx
src/components/layout/AppLayout.tsx`(ルート+メニュー) / `src/lib/data-provider.ts
src/lib/sdk-client.ts`(データソース)へ同一パターンで書き換える一括是正を行った。

★対象8行を**目視で列挙**して1行ずつ直したところ、`change-history` 行(⑭の8行のうち
最後の1行)だけ直し忘れた。CodeRabbitの2回目のレビュー(1回目 CHANGES_REQUESTED →
**2回目 CHANGES_REQUESTED でこの1行漏れを指摘** → 3回目 APPROVED)でようやく露見し、
指摘を受けてから是正・再pushする一往復を要した。

この型は殿が戒められた「0 SKIPの申告だけでなく実行総件数を見よ」(cmd_754)と
同じ思想である——**数えられるものは数えよ**。目視の列挙は自己申告と同じで、
機械的に数えない限り漏れを検出できない。

## 適用場面

- 同一パターンの書き換えを**複数行・複数ファイル**にわたって適用する一括是正
- CodeRabbit等のレビュー指摘で「この型の行を全部直せ」と言われた場面
- 1件だけの修正、あるいは対象がgrepで数えられない性質の修正(設計変更・ロジック変更)には引かない

## 手順(3手順・これ以上増やさない)

### 1. 是正前に対象行数をgrepで数える

```bash
grep -n "<是正対象を一意に特定できるパターン>" <対象ファイル> | wc -l
```

出力された件数を**その場でメモする**(例: 8件)。目視で「たぶん8個」と思うのではなく、
このコマンドの出力を根拠にする。

### 2. 是正を行う

一括置換・スクリプト・エディタのいずれで行ってもよいが、**Step 1でメモした件数**を
常に意識する。

### 3. 是正後に同じgrepで件数一致を機械的に確認する

```bash
grep -n "<是正後のパターン>" <対象ファイル> | wc -l
```

Step 1の件数と一致することを確認する。一致しなければ、旧パターンで再度grepし
残存箇所を特定する:

```bash
grep -n "<是正前の(直し忘れなら残っているはずの)パターン>" <対象ファイル>
```

一致するまで `status: done` にしない([[verification-before-completion]]と同じ思想)。

## 無効な言い訳

| 言い訳 | なぜ無効か |
|--------|----------|
| 「目視で全部確認した」 | PR#179はまさにそれで1行漏れた。目視の列挙は数えたことにならない |
| 「件数が少ないから数えるまでもない」 | PR#179は8行——「少ない」の感覚こそ油断の入口 |
| 「diffを見れば分かる」 | diffは直した行しか見せない。直し忘れた行はdiffに現れない |

## 関連

- CLAUDE.md Iron Law 3「SKIP = FAIL」(cmd_754・「0 SKIPの申告だけでなく実行総件数を見よ」と同型の思想)
- [verification-before-completion](../verification-before-completion/SKILL.md)
