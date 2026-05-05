# Autonomous-by-default

Multi-Agent Shogun の default 動作は自律実行モード
(autonomous execution mode) である。現在値は
`queue/system/mode.yaml` を Single Source of Truth とし、
`careful_mode: false` を default とする。

## 目的

殿の入力を待つ時間を最小化し、家老・軍師・足軽が recommended 判断で
設計、実装、検証、修正を進める。殿には完了時と失敗時のみ通知し、
途中判断は Slipstream HITL として後追いで吸収する。

## SSoT

```yaml
mode: autonomous
set_at: ""
set_by: "system"
careful_mode: false
notes: "Autonomous-by-default: careful_mode: true の時のみ HITL ブロッカー復活"
```

ファイルが存在しない場合も `careful_mode: false` とみなし、
自律実行モードで動く。

## Role 別の振る舞い

### Shogun

- dashboard.md で家老・軍師の完了/失敗報告を確認する
- 非 blocking ASK でチェーンを止めない
- `blocking_flag: true` の重大案件のみ殿判断待ちとして扱う

### Karo

- cmd 受領後、軍師レビューと足軽発令を殿確認なしで進める
- ASK は recommended 値で先行し、殿回答は後追い patch と lexicon 更新で吸収する
- ntfy は完了時と失敗時のみ送る
- Tier 1 絶対禁止事項は殿確認があっても実行不可

### Ashigaru

- 実装・テスト・修正を 3 回まで自律 retry する
- 3 回失敗したら report YAML に redo 依頼を明記する
- dashboard.md と殿への直接報告は引き続き禁止する

### Gunshi

- QC を即時実行し、dashboard.md に結果を集約する
- CONDITIONAL の改善提案は Karo inbox へ即時送る
- `blocking_flag: true` の重大欠陥のみ殿確認待ちにする

## Slipstream HITL

ASK 項目が発生しても、非 blocking であれば recommended 値で先行する。
殿回答が後から来た場合は patch、lexicon、設計メモ更新で吸収する。
これにより判断待ちで足軽を停止させない。

## Retry サイクル

1. 失敗を検知する
2. 原因を読み、同じ task scope 内で修正する
3. 関連テストまたは build を再実行する
4. 最大 3 回まで繰り返す
5. 3 回失敗したら failed report と redo 依頼を出す

retry は未割当作業へ広げてはならない。

## blocking_flag

`blocking_flag: true` は、先行すると損害が大きい重大欠陥や
殿判断が不可欠な事項にのみ使う。

該当例:
- 法務・契約判断
- 予算超過リスク
- 大里様等への引き渡し直前の品質判断
- Tier 2 停止報告に該当する操作
- 軍師が重大欠陥として FAIL 判定したもの

非該当例:
- 軽微な実装方針差分
- 文言選択
- 後追い patch 可能な ASK
- recommended で十分に進められる設計判断

## careful_mode との差分

| 項目 | autonomous | careful_mode |
|------|------------|--------------|
| default | yes | no |
| 殿確認 | 完了/失敗 + blocking のみ | 重要判断で事前確認 |
| ASK | recommended で先行 | 回答待ち |
| QC | 軍師が即時実行 | 必要に応じ殿確認 |
| ntfy | 完了/失敗のみ | 全重要通知 |

## 入る条件

- `queue/system/mode.yaml` の `careful_mode: false`
- `queue/system/mode.yaml` が存在しない
- careful_mode の解除後

## 出る条件

以下のいずれかで `careful_mode: true` に切り替える:
- 大里様等への引き渡し直前
- 法務・契約絡みの判断
- 予算超過リスク
- Karo または Gunshi が `blocking_flag: true` と判断した重大案件
