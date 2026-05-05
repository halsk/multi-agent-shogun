# careful_mode

careful_mode は Autonomous-by-default の例外モードである。
`queue/system/mode.yaml` の `careful_mode: true` の時のみ有効になる。

## 目的

外部引き渡し、法務・契約、予算超過など、誤判断の影響が大きい局面で
HITL ブロッカー型の確認ゲートを復活させる。

## トリガー条件

- 大里様等への引き渡し直前 (handoff)
- 法務・契約絡みの判断
- 予算超過リスクのある作業
- 重大な品質欠陥により `blocking_flag: true` が立った時
- Karo または Gunshi が、先行実行の損害が大きいと判断した時

## SSoT

```yaml
mode: autonomous
set_at: "2026-05-05T11:00:00+09:00"
set_by: "karo"
careful_mode: true
notes: "handoff前確認のため一時的にHITLゲート復活"
```

`mode` は `autonomous` のままでもよい。例外判定は
`careful_mode` フィールドで行う。

## 制約内容

- 殿確認ゲートを復活させる
- 重要判断は事前確認必須とする
- ASK は回答待ちにできる
- 全重要 ntfy を殿へ転送する
- 軍師 QC の CONDITIONAL や FAIL は殿確認対象にできる
- dashboard.md の 🚨要対応に判断待ち項目を集約する

## Role 別の振る舞い

### Shogun

- dashboard.md の 🚨要対応を確認し、殿判断を cmd または指示として流す
- careful_mode の解除可否を判断する

### Karo

- 重要判断に確認ゲートを挿入する
- 足軽を非 blocking 作業へ逃がせる場合は並列を維持する
- Tier 1 絶対禁止事項は殿確認があっても実行しない

### Ashigaru

- task YAML の確認ゲートに従う
- 法務・契約・予算超過・handoff 判断を自律 retry で突破しない
- 失敗時は report YAML に blocker と確認事項を明記する

### Gunshi

- CONDITIONAL / FAIL の根拠を明確にし、blocking かどうかを判定する
- `blocking_flag: true` の場合は dashboard.md の 🚨要対応へ集約する

## 解除条件

以下がすべて満たされたら `careful_mode: false` に戻す:
- handoff / 法務 / 予算リスクの局面が終了した
- blocking_flag の未解決項目がない
- 殿確認が必要な ASK が残っていない
- Karo が通常の Autonomous-by-default で進められると判断した

## 戻し方

`queue/system/mode.yaml` を編集する:

```yaml
careful_mode: false
notes: "careful_mode解除。Autonomous-by-defaultへ復帰"
```
