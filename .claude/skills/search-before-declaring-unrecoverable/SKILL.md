---
name: search-before-declaring-unrecoverable
description: 失われた設定値・設計文書・分解案を「復元不可能」と断ずる前に当たるべき場所を順に並べた判定木。git管理下判定→queue/archive在庫→logs(検索語源)→手元セッション記録(jsonl)の順。2026-09-13 ntfy_topic紛失事故・Issue#102 S1設計分解の掘り起こしが出所。「復元不可能」「消えた」「見つからない」「探したが無い」と結論する前に必ず呼び出すこと。
---

# search-before-declaring-unrecoverable

## 目的

失われた・見えなくなった成果物(設定値・設計文書・分解案・報告書本文等)を
「復元不可能」「無い」と断ずるのは、実際に探した後でなければならない。
本skillは**探す場所の一覧と順序**を手順として持つ——「ログを探せ」という
一般論だけでは、具体の在り処が無いため実際には探されずに終わる。

## 出所となった事故(実物2件)

### 事故1: 2026-09-13 ntfy_topic紛失

`config/settings.yaml` が消失(gitignore対象・控え無し)。家老は `ntfy_topic` を
「ログ・報告書のどこにも平文で残されていない設計・復元不可能」と結論した。
しかし将軍が実測すると **`logs/ntfy_listener.log` の冒頭行に平文で3回**
記録されていた(listenerが起動時にtopic名を出力する造り)。値そのものを
秘匿する設計でも、その値を使う側が起動ログへ書き出していた。

### 事故2: 2026-09-17 Issue#102 S1設計分解の掘り起こし

`gunshi_decompose_cmd825_issue102` の元の分解(cmd_825・2026-09-15作成)が
失われたと思われた——`gunshi_report.yaml` はtaskごとに丸ごと上書きされる
単一ファイルであり、次のtaskを受けた時点で前の分解本文は消える仕組みで
あった。しかし軍師が `~/.claude/projects/**/*.jsonl`(手元のセッション記録)
から本文を掘り起こせた。★決め手の記録は**発話ではなく、報告書を書いた際の
ツール呼出の入力文字列(pythonのheredocの中身)**であった。

両事故に共通する型: 「設計上どこにも残らないはず」は設計者の意図であって
実測ではない。副次的な出力先(ログ・ツール呼出の入力・セッション記録)に
漏れていることがある。

## 判定木(この順で当たる・jsonlを先頭に置くな)

**★2026-09-17軍師是正: 「jsonl→logs→archive→git履歴」という単純な順は誤り。
以下の判定木に従うこと。**

### 一. まず一つの判定: 成果物がgit管理下か

```bash
git check-ignore -v <path>   # 無出力(exit 1)なら管理下・出力あれば管理外
# または
git ls-files --error-unmatch <path>
```

- **管理下**なら `git log -S<検索語> -- <path>` と `git show <commit>:<path>` が
  最も安く確実な復元路である。jsonlを漁る必要は無い。ここで終わる。
- **管理外**と判った時だけ以下(二〜四)へ進む。
  (例: `queue/reports/` と `context/` は `.gitignore` の `*` 行で全て管理外——
  git履歴を試しても構造的に空振りになる)

### 二. queue/archive の在庫確認(1コマンドで済ませる・探索ではない)

```bash
ls queue/archive/
```

在庫が**在れば最短**(そのまま読める)。**無ければ即三へ進む**。
本件(事故2)ではinboxとtaskの控えはあったがreportの控えは無かった。

### 三. logs/dashboard_archive と logs/daily — 復元源ではなく検索語源

★ここは本文の復元源ではない。**検索語を作るための場所**である。
本件でも本文は残っていなかったが、日付・cmd番号・登場語(例: "S3a")は
ここで得られた。この特徴語が無いと四(jsonl)は絞り込めない
(素の1語では958件が当たった=実測)。

```bash
grep -rn "<cmd番号 or 日付>" logs/dashboard_archive/ logs/daily/
```

### 四. 手元セッション記録(jsonl)— 最後の手段・特徴語で絞る

#### 在り処

```
~/.claude/projects/<cwdのスラッシュをハイフンに潰した名>/*.jsonl
```

例: cwdが `/Users/hal/tools/multi-agent-shogun` なら
`~/.claude/projects/-Users-hal-tools-multi-agent-shogun/*.jsonl`。
cwdが worktree (`/Users/hal/workspace/multi-agent-shogun-wt5-...`) なら
`~/.claude/projects/-Users-hal-workspace-multi-agent-shogun-wt5-.../*.jsonl` と
**別ディレクトリ**になる。★誰がどこで走らせたか分からない時は、
`~/.claude/projects/` 配下の**全projectディレクトリを横断して探せ**
(1つのcwdだけを見て「無い」と断ずるな)。

#### 絞り込み手順(素のgrepでは足りない・実測で958件当たった)

素の1語のgrepでは当たりすぎて使えない。以下の条件全てを満たすものだけに
絞る:

1. 特徴語を**2つ以上同時に含む**(AND)
2. かつ**本文らしい語**を含む(例: 「受入」「分解案」等、対象に応じて選ぶ)
3. jsonlを**1行ずつ**pythonで読み、**全ての文字列フィールドを再帰的に**
   歩く(トップレベルのcontentだけでなく、ネストしたオブジェクト内の
   文字列も含める——次項参照)
4. 一致した行を**timestampで整列**し、**最長のもの**を採用する
   (同じ話題の断片的な言及より、本文そのものを含む行の方が長い)

```python
import json, glob, sys

keywords = ["cmd825", "分解案"]  # 2語以上AND
body_hint = "受入"               # 本文らしさの目印

def walk_strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from walk_strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from walk_strings(v)

candidates = []
for path in glob.glob("/Users/hal/.claude/projects/*/*.jsonl"):
    with open(path, encoding="utf-8", errors="ignore") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            text = "\n".join(walk_strings(rec))
            if all(k in text for k in keywords) and body_hint in text:
                candidates.append((rec.get("timestamp", ""), len(text), path, text))

candidates.sort(key=lambda c: c[0])
for ts, length, path, text in sorted(candidates, key=lambda c: -c[1])[:3]:
    print(ts, length, path)
```

#### ★★最も見落としやすい点: 発話だけでなくツール呼出の入力も走査対象

事故2で掘り当てた本文は、assistantの発話ではなく**報告書を書いた際の
ツール呼出の入力文字列(pythonのheredocの中身)**であった。
`walk_strings` がdict/listを再帰的に歩く実装になっているのはこのため
——tool_useのinputフィールド(コード・heredoc・JSON文字列等)まで
辿らないと同じ探索をしても見つからない。

## 各在り処で見つかる可能性(具体)

| 在り処 | 見つかる可能性が高いもの |
|--------|------------------------|
| git履歴(`git log -S`/`git show`) | 削除された**ファイル本体**(管理下限定) |
| queue/archive | 過去の**queueスナップショット**(inbox/task等・そのまま読める) |
| logs/dashboard_archive・logs/daily | **要約**(cmd番号・日付・登場語)——本文は残らない |
| 手元セッション記録(jsonl) | このAIエージェント自身の**思考過程・発話・ツール呼出の入力**(発話とツール入力の両方) |

## 限界(正直に書く・過信するな)

- jsonlは**機体ローカル**である。別の機体(別Mac・別worktreeの別プロセス)や
  `/clear`後の他エージェントの記憶までは覆わない。「探せば必ず見つかる」
  という誤った安心を与えてはならない。
- logs/dashboard_archive と logs/daily は**要約は残るが本文は残らない**
  (事故2で実測済み)。検索語源として使い、復元源として期待しないこと。
- git履歴は**管理下のファイルのみ**。`.gitignore` 対象(本swarmでは
  `queue/reports/` `context/` 等)は構造的に空振りになる——試す前に
  一(git check-ignore)で判定してから進むこと。
- ★★jsonlには**秘密値が平文で混じりうる**。掘り当てた断片を報告書やPRへ
  そのまま貼らないこと。必要な部分だけを写し、資格情報は伏せる。

## 実際に呼べることの実測(cmd_844② ashigaru5・2026-09-17実施)

「入れたつもり」を防ぐため、mainリポ(`/Users/hal/tools/multi-agent-shogun`)の
`.claude/skills/` `.agents/skills/` へ本SKILL.mdを一時的に配置し、Skill tool
から `search-before-declaring-unrecoverable` を実際に呼び出した。結果:
skill一覧に登場し、`Skill({skill: "search-before-declaring-unrecoverable"})`
呼出で本文全体(本セクションを除く)が正しく展開されることを実測で確認した。
確認後、mainリポには反映せず(PR merge順は①③→②のため)一時配置分は
削除し、workingtreeがcleanであることを確認した(`git status --short`)。

## 無効な言い訳

| 言い訳 | なぜ無効か |
|--------|-----------|
| 「設計上どこにも平文で残らないはず」 | 設計者の意図であって実測ではない。事故1はまさにこれ |
| 「jsonlを1語grepしたが無かった」 | 1語では当たりすぎる(958件)か当たらなすぎるかのいずれか。2語以上ANDで絞れ |
| 「このcwdのjsonlには無かった」 | worktreeごとに別ディレクトリ。全projectディレクトリを横断せよ |
| 「発話を全部読んだが無かった」 | 本文はツール呼出の入力(heredoc等)に在ることがある。文字列フィールドを再帰的に歩け |
| 「git logで見なかったから無い」 | `.gitignore`対象は構造的に空振り。git管理下かを先に判定せよ |

## 関連

- [[feedback_search_logs_before_declaring_unrecoverable]](事故1・2026-09-13 ntfy_topic紛失)
- [verification-before-completion](../verification-before-completion/SKILL.md)
