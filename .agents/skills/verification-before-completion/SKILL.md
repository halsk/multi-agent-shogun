---
name: verification-before-completion
description: status:done を書く前にテスト・ビルド・ファイル存在を実証する手順。Iron Law #1「証拠なき完了禁止」の skill 化。完了報告 / マージ / 任務完了宣言の前に呼び出すこと。
---

# verification-before-completion

## 目的

Iron Law #1 **「証拠なき完了禁止」** を実行可能な手順として具体化する。
`status: done` を書く・宣言する前に、以下の **証拠** を実証する。
「さっき確認した」「些細な変更だから検証不要」「ローカルでは動く」はいずれも証拠ではない。

## 適用範囲

- 足軽の subtask 完了報告
- 家老の cmd 完了判定
- 将軍のマージ前判断
- 任意エージェントの「動いた」と主張する全ての場面

## 手順

### Step 1: テスト実行

テストコマンドを明示し、**実行する**。

```bash
# 例
npm test
pytest
cargo test
pnpm test:e2e   # E2E が要件なら別途
```

- **全 PASS** を確認
- **SKIP は FAIL 扱い** (Iron Law #3)
- 最終出力の末尾 (`X tests passed` 等) を完了報告に含める

### Step 2: ビルド実行

ビルドコマンドを明示し、実行する。

```bash
# 例
npm run build
cargo build --release
tsc -p .
go build ./...
```

- エラーなく完了することを確認
- warning が新規発生していないかも目視

### Step 3: 静的検証

```bash
# Lint / typecheck (lefthook 等で auto なら省略可、明示が安全)
npm run lint
npm run typecheck
```

### Step 4: 成果物の存在確認

期待する成果物が実在するかを `ls` / `stat` / `gh pr view` 等で確認。

| タスク種別 | 確認手段 |
|-----------|---------|
| ファイル作成 | `ls -la <path>` で実在確認 |
| PR 作成 | `gh pr view <N> --json state` で `OPEN` 等を確認 |
| デプロイ | デプロイ先 endpoint への curl で HTTP 200 確認 |
| DB 投入 | `SELECT count(*)` 等で件数確認 |

### Step 5: 証拠を完了報告に同梱

完了報告 YAML / inbox / dashboard 更新に、以下を含める：

```yaml
evidence:
  test:
    command: "npm test"
    last_line: "Tests:  42 passed, 0 failed, 0 skipped"
    timestamp: "2026-06-05T13:42:00+09:00"
  build:
    command: "npm run build"
    exit_code: 0
  artifact:
    pr_url: "https://github.com/halsk/repo/pull/N"
    pr_state: "OPEN / MERGED"
```

### Step 4.5: ブラウザ / クライアント描画物の検証

`curl` の HTTP 200 やユニットテストの緑は「描画が正しい」ことを証明しない。
ブラウザ・Obsidian プラグイン・Dataview 等のクライアント描画物を QC する際は、
結論を出す前に以下を確認する。

#### (a) アプリ同一性 — 「正しいアプリを見ているか」（cmd_664 教訓）

swarm の複数 worktree が同一 dev-server port（Vite 5173 等）で衝突し、
無関係アプリを検分してしまう事故が起きる。ブラウザ/視覚 QC の前に確認する:

- page `<title>` / URL / 期待コンテンツ（固有の文言・要素）が対象アプリのものか
- その port を今検証中の worktree が所有しているか（他 worktree の dev-server でないか）
- 疑わしければ build → preview を固有 port で起動し直してから検証する

#### (b) 実描画・実ランタイムで検証せよ — 模擬で代替するな（cmd_679 教訓）

クライアント側で解釈・描画される成果物（Obsidian Tasks プラグイン / Dataview /
ブラウザ JS 等）は、別スクリプトでロジックを模擬した結果を証拠にしてはならない。

- 実プラグイン / 実ランタイムに実際に parse・描画させて確認する（例: build→preview→
  Playwright で実描画、computed style / DOM を実測）
- 実行が困難なら、実装（プラグイン本体 `main.js` 等）の parse ルールを読み、
  使用する構文が確実に認識されることをソースで裏取りする
- ★JS 模擬が通っても実環境が通るとは限らない（cmd_679: JS 模擬は通ったが実 Tasks
  プラグインは boolean OR の行構成で構文エラーを吐いた）

## 失敗時の対応

1 つでも失敗 → **`status: done` を書かない**。
- 「未完了」「blocked」「failed」のいずれかで報告
- 未完了理由 + 次の action を明記
- 殿/家老の判断を仰ぐ

## 無効な言い訳一覧

| 言い訳 | なぜ無効か |
|--------|----------|
| 「些細な変更だから検証不要」 | 些細な変更が本番障害を起こした実例あり |
| 「さっきテスト通った」 | その後にコードを変更していないか？ 同じ HEAD で再実行せよ |
| 「SKIP テストは元から」 | SKIP = FAIL（誰がいつ SKIP したかは無関係）|
| 「ローカル環境特有」 | 再現性なき主張は証拠にならない |
| 「とりあえず動いた」 | 偶然・部分動作は証明にならない |
| 「PR 作っただけで動作確認はしてない」 | 動作確認まで含めて完了 |
| 「curl で 200 が返った」 | 200 は「正しいアプリが正しく描画された」証明にならない（別 worktree の混線・空描画あり）|
| 「別スクリプトのロジック模擬では正しかった」 | 実プラグイン/実ランタイムの parse・描画で裏取りせよ |

## 関連

- Iron Law #1: 証拠なき完了禁止
- Iron Law #3: SKIP = FAIL
- [systematic-debugging](../systematic-debugging/SKILL.md): バグ修正完了時の前段
- [code-review-expert](../code-review-expert/SKILL.md): 静的品質側の補完
