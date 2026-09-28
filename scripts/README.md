# scripts/ 運用メモ

## cr_retrigger — CodeRabbit rate-limited PR 自動再引き金 (cmd_908)

設計: `queue/reports/cmd908_ratelimit_retrigger_design.md`(§1〜§11)。

構成ファイル:
- `scripts/cr_retrigger.py` — 判定規則の純関数群 + 薄い `main()`
- `scripts/test_cr_retrigger.py` — 回帰試験(`python3 -m unittest scripts.test_cr_retrigger -v`)
- `config/cr_retrigger.yaml` — allowlist・予算・fallback_mode/query_policy
- `scripts/cr-retrigger-launcher.sh` — launchd ラッパー(Keychain から HC ping URL を注入)
- `scripts/com.swarm.cr-retrigger.plist` — launchd 登録の雛形

**このリポの実装(T1)は上のファイルを置くのみ。本番の Healthchecks・
Keychain・launchctl への登録は T2(家老・`.guard-authorized` のもとで)の
範囲であり、ここでは行わない。**

### T2 の登録手順(家老が行う。ここでは手順を記すのみで実行はしない)

設計 §10.4 のとおり、一度の作業で続けて行う(check だけ先に作らない):

1. 本 PR が merge され、対象 Mac の checkout に入ったことを確かめる。
2. Healthchecks API で check `cr-retrigger` を作る(timeout 600秒・grace 1200秒・
   `channels: "*"`)。返った `ping_url` を Keychain へ `hc-ping-url-cr-retrigger`
   として収める(値は画面に出さない)。
3. `.guard-authorized` を置く(task_id・期限つき。launchctl とは別の Bash 呼び出しで)。
4. `scripts/com.swarm.cr-retrigger.plist` を `~/Library/LaunchAgents/` へ写し、load する。
5. 20分以内に次の3つを確かめる: HC の check が `up` / 直近 ping の本文が
   `runner=launchd` / その `run_id` の行が `logs/cr_retrigger.jsonl` にある。
   20分たっても `new` のままなら失敗とし、plist を unload して真因を調べる。
6. `.guard-authorized` を外し、`logs/` と dashboard に使った旨を記す。
