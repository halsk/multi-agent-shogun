---
name: whole-vault-deadlink-scan
description: vault やリンク付きノート集合を破壊的に削除/backfill する前後に、被参照(dead link)を whole-vault で走査し巻き添えを防ぐ手順。削除・アーカイブ・大量編集の実行前後に呼び出すこと。
---

# whole-vault-deadlink-scan

## 目的
リンクで相互参照するノート集合（Obsidian vault 等）を破壊的に削除/backfill する際、
被参照の見落としによる dead link・巻き添えを防ぐ。cmd_677 で被参照走査を `wiki/` に
限定し scrapbox-public 等の dead link を見落とした教訓の skill 化。

## 適用範囲
- ノート/概念/エンティティの削除・アーカイブ
- backfill クリーンアップ（汚染除去等）
- 大量リネーム（リンク切れを伴う操作）

## 手順
### Step 1: 削除対象の確定（マニフェスト化）
削除/温存/保持を分類したマニフェストを作り、殿/家老レビューを経る（Tier2 破壊操作は裁可必須）。

### Step 2: 被参照走査は whole-vault で
各削除対象について被参照を **vault 全域**で走査する。`wiki/` 等一部フォルダに限定しない。
参照は scrapbox-public/・raw/articles/・diary/・templates/ 等どこからでも来る。
```bash
# 例: [[名前]] と [[名前|alias]] と [[名前#見出し]] を全域で
grep -rl '\[\[<対象>\(]]\||\|#\)' <VAULT>   # フォルダ限定にしない
```

### Step 3: 温存ファイル内リンクの Class 整合確認
部分温存するファイル（Class B）の本文・関連リンクリストが、削除対象（Class A）を
指していないか確認する。指していれば温存指定と矛盾 → 参照記述の除去も削除計画に含める。

### Step 4: 実行後の dead link ゼロ検証（whole-vault）
削除実行後、削除対象への生存参照が **vault 全域で 0 件**であることを再走査で実証する。
source 層（raw/articles 等・Layer1）からの参照は残す判断もありうるが、その場合も
「curated graph は 0・source 層は N 件を許容」と明示的に切り分けて報告する。

### Step 5: 異常時は stop-and-report
走査中に想定外（マニフェスト矛盾・温存対象からの被参照・カスケード）を発見したら、
**独断で代替対応せず即座に停止し、家老/殿へ報告**して裁可を得てから実行する。
タスク YAML の明示手順（例:「dead link 発見時は削除取消」）が状況にそぐわない場合も、
勝手に別対応へ切替えず報告する（結果が正でも手続き逸脱は別問題）。

## 失敗時の対応
dead link が 1 件でも残る/巻き添えを検知 → 実行を止め報告。復元 or 参照除去の
いずれが正しいかは削除の意図（汚染除去なら復元は誤り）に照らして裁可を仰ぐ。

## 関連
- CLAUDE.md「Destructive Operation Safety」（Tier1/2 禁止則）
- verification-before-completion（完了検証の一般手順）
