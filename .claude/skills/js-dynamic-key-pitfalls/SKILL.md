---
name: js-dynamic-key-pitfalls
description: JSオブジェクトのキーを動的に組み立てる/上書きするコード(spread結合・Object.defineProperty・ユーザ入力をプロパティ名にする処理)を書く・レビューする際に、spread順序の後勝ち・definePropertyの再定義制約・__proto__特殊扱いの3つの罠を確認する。geonicdb-console PR#184(Issue#102 S1)で実際に2件のバグが出た。
---

# js-dynamic-key-pitfalls

## 目的

JS/TS で「オブジェクトのキーを動的に決める・複数のオブジェクトを合成する」コードは、
言語仕様の癖により見た目が正しくても壊れる。geonicdb-console PR#184
(Issue#102 S1 エンティティ作成、ashigaru3 担当)で、この根から実際に **2件の
バグが CodeRabbit に指摘され是正が必要になった**。同じ根の罠をもう1つ知って
おくべきだったので、あわせて3件として記録する。

## 適用範囲

**引かれるべき場面**:
- 複数オブジェクトを `{ ...a, ...b }` で合成し、どちらの値が勝つかが結果を左右するコード
- `Object.defineProperty` で先に定義したプロパティに、後から同名で書き込む/再定義するコード
- ユーザ入力・外部入力の文字列をオブジェクトのプロパティ名(キー)として使うコード
  (`obj[userInput] = value` 等)

**引かれるべきでない場面**:
- 固定キーのみを扱う通常のオブジェクト操作(このskillの対象外)
- 配列操作・型定義のみの変更

## 罠1: spreadの順序(後勝ちの罠)

`{ ...a, ...b }` は **後に書いた方が勝つ**。呼び出し側が意図せず先に書いたはずの
値を上書きしてしまう事故が起きる。

**PR#184の実例** (`src/lib/sdk-client.ts` の `createEntity`):

```ts
// ❌ 是正前 — 呼び出し側 entity に @context があると、こちらの
//    NGSI_LD_CORE_CONTEXT を上書きしてしまう(entityが後に展開されるため)
await writeJson("POST", "/ngsi-ld/v1/entities", { "@context": NGSI_LD_CORE_CONTEXT, ...entity })

// ✅ 是正後 — 固定したい値は必ず最後に展開し、常にこちらが勝つようにする
await writeJson("POST", "/ngsi-ld/v1/entities", { ...entity, "@context": NGSI_LD_CORE_CONTEXT })
```

CodeRabbit指摘: 「呼び出し側の `entity["@context"]` が core context を上書き・削除しうる」。
是正はcommit `e860854`。

**チェック方法**: `{ ...a, ...b }` を書いたら、「a と b の両方が同じキーを持っていたら
どちらが勝つべきか」を明示的に自問する。固定したい値・信頼できる側の値は必ず
**最後**に展開する。

## 罠2: Object.defineProperty の再定義制約

`Object.defineProperty` で一度定義したプロパティは、既定で `configurable: false`
になる。同名のプロパティを **後から `defineProperty` で再定義しようとすると
`TypeError` が投げられる**(通常の代入 `obj.key = value` とは挙動が違う)。

**PR#184の実例** (`src/pages/entity/EntityForm.tsx`):

エンティティの `id`/`type` を先に `Object.defineProperty` で定義したあと、
ユーザがプロパティ名として自由入力できる欄に `id` や `type` と同じ名前を
入力すると、同じ関数内で再度 `Object.defineProperty(entity, "id", ...)` に
相当する処理が走り `TypeError` が発生していた。しかも `onSubmit` 呼び出しより
**前**で例外が起きるため、ダイアログのエラー表示にすら届かず、送信ボタンを
押しても無反応に見える最悪の壊れ方になる。

```ts
// ✅ 是正 — defineProperty へ進める前に、予約語(id/type/@context)・重複名を検証する
const RESERVED_PROPERTY_NAMES = new Set(["id", "type", "@context"])

function findPropertyNameIssue(rows: EntityFormPropertyRow[]) {
  const seen = new Set<string>()
  for (const row of rows) {
    const name = row.name.trim()
    if (!name) continue
    if (RESERVED_PROPERTY_NAMES.has(name)) return { key: "reserved", name }
    if (seen.has(name)) return { key: "duplicate", name }
    seen.add(name)
  }
  return null
}
// handleSubmit 内、Object.defineProperty で積む前に呼び、issueがあれば送信を止めて
// role="alert" でエラー表示する(例外を投げっぱなしにしない)
```

CodeRabbit指摘: 「送信処理で `Object.defineProperty` を実行する前に、プロパティ名を
検証すべき。`id`・`type`・既に登録済みの重複名には該当フィールドのエラーを表示し、
無効な入力では `onSubmit` まで進まないようにすべき」。是正はcommit `e860854`。

**チェック方法**: `defineProperty` を使うコードで、同じキー空間に **ユーザ入力や
複数ソース由来の名前** が混ざるなら、`defineProperty` を呼ぶ前に予約語・重複を
検証する。「例外は投げられるが catch していないので実質バリデーション」という
設計は、呼び出し元の期待(onSubmit到達→エラー処理)を裏切る。

## 罠3: __proto__ の特殊扱い(プロトタイプ汚染)

**★これはPR#184で実際に事故になった訳ではない** — ashigaru3 が実装時に
最初から回避していた設計であり、CodeRabbit指摘ではない。だが同じ「動的キー」
の根から生じる罠として、モデル知識として重要なので併記する。

ユーザ入力の文字列をキーとして通常の object literal / 代入で書き込むと、
`"__proto__"` という文字列が入力された場合に **own property を作らず
プロトタイプそのものを差し替えてしまう**(プロトタイプ汚染)。

```ts
// ❌ 罠 — name が "__proto__" だと own property にならず、
//    Object.prototype (または entity 自身) のプロトタイプが書き換わる
const entity: Record<string, unknown> = {}
entity[name] = value  // name = "__proto__" なら危険

// ✅ 対策1 — プロトタイプを持たないオブジェクトを土台にし、defineProperty で積む
//    (defineProperty は "__proto__" という名前でも常に own property を作る)
const entity: Record<string, unknown> = Object.create(null)
Object.defineProperty(entity, name, { value, enumerable: true })

// ✅ 対策2(spreadで統合する場合) — spread の結果は必ず own property になるため、
//    最後に `{ ...built }` として通常のオブジェクトへ落とし込めば以降は安全に扱える
onSubmit({ ...entity })
```

**チェック方法**: ユーザ入力・外部入力の文字列を **オブジェクトのキーとして** 使う
コードでは、必ず「入力が `__proto__`・`constructor`・`prototype` だったらどうなるか」
を自問する。`Object.create(null)` + `Object.defineProperty` の組み合わせ、または
`Map` の使用(キーが文字通りの値として扱われプロトタイプに影響しない)のいずれかで防ぐ。

## チェックリスト(レビュー時に上から順に当てる)

1. `{ ...a, ...b }` がある → どちらが「信頼できる/固定したい」側か。信頼できる側が
   **後**に展開されているか。
2. `Object.defineProperty` がある → 同じキー空間に複数ソース(ユーザ入力・固定値)が
   混ざるか。混ざるなら、定義前に予約語・重複の検証があるか。
3. オブジェクトのキーがユーザ入力・外部入力そのものである箇所 → `__proto__` 等の
   特殊名が渡った場合の挙動を確認したか(`Object.create(null)` か `Map` を使っているか)。
4. 上記いずれも、**例外を投げっぱなしにせず、呼び出し元のエラー処理経路に乗るか**
   を確認する(罠2の実例のように、検証漏れは「無反応に見えるUI」という最悪の壊れ方をする)。

## 実測: skillとして呼べることの確認

- `.claude/skills/js-dynamic-key-pitfalls/SKILL.md` と
  `.agents/skills/js-dynamic-key-pitfalls/SKILL.md` の両方に本ファイルを設置。
- `ls .claude/skills/ .agents/skills/` で両方に `js-dynamic-key-pitfalls` が
  1件ずつ現れることを確認済み。
- ★2026-09-17、軍師QC是正(F2)を受け、mainリポの実作業ディレクトリ
  (`/Users/hal/tools/multi-agent-shogun`)へ本ファイルを一時配置した上で
  実際に `Skill` ツールから `js-dynamic-key-pitfalls` を呼び出し、以下を
  実測した(単なる`ls`での存在確認と、呼び出し可能であることの実測は別物
  であるため、両方を分けて記録する):
  1. 呼び出し前は available skills 一覧に `js-dynamic-key-pitfalls` が
     存在しなかった。
  2. `Skill({ skill: "js-dynamic-key-pitfalls" })` を実行すると、本SKILL.md
     の本文全体(罠1〜3・チェックリスト)がそのまま展開された。
  3. 呼び出し後、available skills 一覧に `js-dynamic-key-pitfalls`(この
     descriptionのまま)が現れることを確認した。
  4. 検証後、一時配置した2ファイル・2ディレクトリを `rm -rf` で撤去し、
     `git status --short` が空(クリーン)であることを確認した。

## 関連

- [systematic-debugging](../systematic-debugging/SKILL.md): 罠を踏んだ後の root cause 特定
- [code-review-expert](../code-review-expert/SKILL.md): レビュー観点の補完
- geonicdb-console PR#184: https://github.com/geolonia/geonicdb-console/pull/184
  (commit `f66f079` で罠混入 → CodeRabbit指摘 → commit `e860854` で是正)
