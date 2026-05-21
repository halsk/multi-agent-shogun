# n8n 環境: WSL2 → macOS (Mac mini) 移行仕様書

> 対象: Claude Code（Mac mini で実行する Claude エージェント）
> 作成: 2026-05-21
> 親仕様書: `docs/migration-to-macos.md`（multi-agent-shogun 全体移行）の Phase 6 詳細
> 目的: WSL2 上の n8n (`/home/hal/services/ai-worker/`) を Mac mini に移行し、PA-001 等の personal workflow + Geolonia 業務 WF (WF-1/2/8) を **データ完全保全** したまま新環境で稼働させる
> 戦略: **方式 A** (postgres DB dump + restore、credentials 完全保全) + **Soft cutover** (並行稼働、徐々に切替)

---

## ⚠️ Iron Laws（厳守事項）

1. **N8N_ENCRYPTION_KEY を絶対に失わない** — 失うと credentials 復号不可、再 OAuth が大規模に必要
2. **postgres DB を直接編集禁止** — 必ず pg_dump / pg_restore 経由
3. **二重 trigger 禁止** — Soft cutover 中、Gmail Trigger / Webhook 等は WSL2 か Mac mini の **片方のみ稼働**
4. **production n8n (AWS ECS `n8n.hub.geolonia.com`) は移行対象外** — 触らない
5. **証拠なき完了禁止** — 各 Phase の verification ステップを全 pass で「Phase 完了」
6. **Lord 認証必要箇所では停止** — Cloudflare API token / 1Password / OAuth 再認証等
7. **戦国口調** — 報告は sengoku 風維持

---

## ゴール

Mac mini 上で以下が動作する状態:

- `docker ps | grep ai-worker-n8n` で n8n コンテナ稼働
- WSL2 から移行した workflow 一覧が全件存在（PA-001, PA-002, WF-1, WF-2, WF-8, Obsidian-organizer, 他）
- credentials が暗号化されたまま復号可能（OAuth token は再認証不要 or 最小限）
- PA-001 が Plaud email を受信して Vault に summary + transcript を月毎フォルダで書き込み可能
- `n8n.plants-web.jp` (or Lord 確定 domain) が Mac mini を指す

---

## 前提条件

- `docs/migration-to-macos.md` の Phase 0-5 完了済（依存 install + multi-agent-shogun clone + Obsidian repo clone）
- Mac mini に Docker Desktop or OrbStack インストール済
- WSL2 環境がまだ稼働中（並行稼働するため）
- Lord が Cloudflare ダッシュボードアクセス可
- Lord が必要に応じて Gmail/Slack/Plaud 等の OAuth 再認証可

---

## Phase 1: WSL2 側 事前準備 + DB dump

### 1.1 環境変数 backup（最重要）

```bash
# WSL2 側
cd /home/hal/services/ai-worker
cp .env /tmp/n8n-env-backup-$(date +%Y%m%d).txt
# N8N_ENCRYPTION_KEY を特に確認
grep N8N_ENCRYPTION_KEY .env > /tmp/n8n-encryption-key.txt
chmod 600 /tmp/n8n-encryption-key.txt
```

**Lord 対話**: N8N_ENCRYPTION_KEY が `change_me_to_a_long_random_string` のデフォルト値のままなら警告（既に運用してきたなら、credentials は実際にこの "デフォルト" で暗号化されているのでそのまま使う必要あり）。

### 1.2 docker-compose.yml + workflows/ + scripts/ の backup

```bash
cd /home/hal/services
tar czf /tmp/ai-worker-config-$(date +%Y%m%d).tar.gz \
  ai-worker/docker-compose.yml \
  ai-worker/workflows/ \
  ai-worker/scripts/ \
  ai-worker/gitops/ \
  ai-worker/.env
```

### 1.3 n8n を clean shutdown（実行中の workflow 完了待ち）

```bash
cd /home/hal/services/ai-worker

# まず n8n のアクティブな workflow を一時 deactivate（trigger 停止）
# n8n API で全 active workflow を取得
source .env
ACTIVE_WFS=$(curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "${N8N_URL:-http://localhost:5678}/api/v1/workflows?active=true" \
  | jq -r '.data[].id')
echo "Active workflows: $ACTIVE_WFS"

# 各 workflow を deactivate（オプション、dump 中の trigger を防ぐため）
# for wf_id in $ACTIVE_WFS; do
#   curl -X POST -H "X-N8N-API-KEY: $N8N_API_KEY" \
#     "${N8N_URL}/api/v1/workflows/${wf_id}/deactivate"
# done

# 実行中の workflow が無いことを確認
curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "${N8N_URL}/api/v1/executions?status=running&limit=5" | jq '.data | length'
# 0 になるのを待つ
```

**Lord 対話**: 実行中 workflow がある場合、完了まで待つか、Lord 判断で強制停止。

### 1.4 postgres DB dump

```bash
# n8n コンテナはまだ稼働させたまま (DB 読込のみ、書込なし)
# postgres dump (pg_dump)
docker exec ai-worker-postgres-1 \
  pg_dump -U n8n -d n8n --clean --if-exists --no-owner --no-privileges \
  > /tmp/n8n-db-dump-$(date +%Y%m%d-%H%M).sql

ls -lh /tmp/n8n-db-dump-*.sql
# 想定 size: 数 MB〜数十 MB
```

**dump 整合性確認**:
```bash
# dump file の先頭・末尾確認
head -20 /tmp/n8n-db-dump-*.sql | tail -10
tail -5 /tmp/n8n-db-dump-*.sql
# 期待: "PostgreSQL database dump complete" が末尾にあるべし
```

### 1.5 Mac mini へ転送

```bash
# Option A: SCP（Mac mini の IP / hostname が判明している場合）
scp /tmp/n8n-db-dump-*.sql /tmp/ai-worker-config-*.tar.gz /tmp/n8n-env-backup-*.txt \
  hal@<mac-mini-ip>:/tmp/

# Option B: USB / 共有フォルダ経由（Lord 操作）
# Option C: 一時 S3 アップロード等
```

**Lord 対話**: 転送方法を Lord にご相談。SCP の場合 Mac mini 側の SSH server 有効化要（`System Preferences → Sharing → Remote Login`）。

**Phase 1 acceptance**:
- [x] `.env` backup 取得済
- [x] DB dump 完了（末尾 "PostgreSQL database dump complete"）
- [x] config tar.gz 取得済
- [x] Mac mini への転送完了

---

## Phase 2: Mac mini 側 受け入れ準備

### 2.1 Docker Desktop / OrbStack 稼働確認

```bash
docker --version
docker compose version
docker ps  # エラーなく実行できれば OK
```

### 2.2 ディレクトリ構造作成

```bash
mkdir -p ~/services/ai-worker
mkdir -p ~/workspace/obsidian  # vault マウント先（既に Phase 5 で clone 済のはず）
```

### 2.3 config の展開

```bash
cd ~/services
tar xzf /tmp/ai-worker-config-*.tar.gz
ls -la ai-worker/
```

### 2.4 .env の path 書換

```bash
cd ~/services/ai-worker

# /home/hal → /Users/hal の置換（vault path 等）
gsed -i 's|/home/hal|/Users/hal|g' .env

# 中身確認
cat .env | grep -E "VAULT|PATH|HOME" | head -10
```

### 2.5 docker-compose.yml の volume path 書換

```bash
# vault マウント path を書換
gsed -i 's|/home/hal/workspace/obsidian|/Users/hal/workspace/obsidian|g' docker-compose.yml
gsed -i 's|/home/hal|/Users/hal|g' docker-compose.yml

# 差分確認
git diff docker-compose.yml 2>/dev/null || diff docker-compose.yml docker-compose.yml.bak 2>/dev/null
```

**Lord 対話**: diff 確認後、Lord 承認待ち。

**Phase 2 acceptance**:
- [x] Docker 動作確認
- [x] ai-worker config 展開
- [x] .env / docker-compose.yml の path 書換完了
- [x] N8N_ENCRYPTION_KEY が WSL2 と同一であることを確認

---

## Phase 3: postgres restore

### 3.1 postgres コンテナのみ起動

```bash
cd ~/services/ai-worker
docker compose up -d postgres
# n8n は起動しない (まず DB restore を先行)

# postgres が ready になるまで待機
sleep 10
docker exec ai-worker-postgres-1 pg_isready -U n8n
```

### 3.2 DB restore

```bash
# 既存の空 DB に dump を流し込む
docker exec -i ai-worker-postgres-1 psql -U n8n -d n8n < /tmp/n8n-db-dump-*.sql

# エラーがあれば確認 (FK 違反、duplicate key 等)
# --clean --if-exists 付きで dump したため、既存 DB の table drop + recreate
```

### 3.3 restore 検証

```bash
# workflow_entity テーブルの row 数確認
docker exec ai-worker-postgres-1 psql -U n8n -d n8n \
  -c "SELECT COUNT(*) FROM workflow_entity;"
# 期待: WSL2 側と同数

# credentials_entity 確認
docker exec ai-worker-postgres-1 psql -U n8n -d n8n \
  -c "SELECT COUNT(*), MAX(\"updatedAt\") FROM credentials_entity;"

# 特定 workflow ID 確認 (PA-001 = zDCe0OOBAxUzmLbS)
docker exec ai-worker-postgres-1 psql -U n8n -d n8n \
  -c "SELECT id, name, active FROM workflow_entity WHERE id='zDCe0OOBAxUzmLbS';"
# 期待: [PA-001] Plaud to Obsidian、active=true (元は active だった場合)
```

### 3.4 n8n コンテナ起動

```bash
cd ~/services/ai-worker
docker compose up -d n8n

# log 確認
docker logs ai-worker-n8n-1 -f --tail 50
# 期待:
# - "Editor is now accessible via: http://localhost:5678"
# - エラー "Failed to decrypt credentials" が **出ない** こと（出れば N8N_ENCRYPTION_KEY 不一致）
```

**Phase 3 acceptance**:
- [x] postgres コンテナ稼働
- [x] dump restore 完了、workflow_entity / credentials_entity row 数が WSL2 側と一致
- [x] n8n コンテナ起動、log にエラーなし
- [x] credentials の復号成功（"Failed to decrypt" エラーなし）

---

## Phase 4: 動作確認（n8n UI 経由、Cloudflare 抜き）

### 4.1 ローカル UI で動作確認

```bash
# Mac mini で
open http://localhost:5678
# ブラウザで n8n UI が開く
```

**Lord 対話**: Lord にブラウザで UI 確認していただく。
- 全 workflow 一覧が表示されるか
- PA-001 を開いて jsCode が正しく見えるか
- Credentials 一覧で各 OAuth が "Configured" 表示か
- Test execution: PA-001 を **manual trigger** で実行（dummy email 入力 or 既存 message ID 利用）

### 4.2 credentials 健全性確認

```bash
# 各 credentials に「test connection」可能なものは試す（Gmail OAuth 等）
# 一部 OAuth は token expired で再認証必要な可能性あり
```

**Lord 対話**: 認証エラーが出る credentials があれば、Lord に再 OAuth ご対応いただく。
- Gmail: ブラウザ再認証
- Slack: ブラウザ再認証
- Plaud-related: 該当なし（Plaud は AutoFlow メール経由のみ）

### 4.3 PA-001 / PA-002 / Obsidian-organizer の動作確認

**重要: Soft cutover 中ゆえ、まずは Gmail Trigger を停止したまま manual test**

```bash
# PA-001 を deactivate (Gmail Trigger 無効化)
source ~/services/ai-worker/.env
curl -X POST -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "http://localhost:5678/api/v1/workflows/zDCe0OOBAxUzmLbS/deactivate"

# UI から PA-001 を開き、Manual execute (test email や既存メール ID 指定)
# 期待: summary + transcript の 2 ファイルが /Users/hal/workspace/obsidian/raw/meetings/{YYYY-MM}/ に生成
```

**Lord 対話**: PA-001 manual execute 結果を Lord に報告 + 確認依頼。

**Phase 4 acceptance**:
- [x] n8n UI ローカルアクセス可
- [x] 全 workflow 一覧表示
- [x] credentials 「Configured」状態
- [x] PA-001 manual execute 成功（vault に file 生成）
- [x] OAuth 再認証必要 credentials の特定済 (Lord 対応)

---

## Phase 5: Cloudflare Tunnel 再ルーティング

### 5.1 現状確認

```bash
# WSL2 側の cloudflared 設定を確認
docker exec ai-worker-cloudflared-1 cat /etc/cloudflared/config.yml 2>/dev/null
# or
cat ~/services/ai-worker/docker-compose.yml | grep -A 10 cloudflared
```

**Lord 対話**: Cloudflare ダッシュボードで:
- Zero Trust → Networks → Tunnels の現状確認
- 既存 tunnel が `n8n.plants-web.jp` を WSL2 に向けている

### 5.2 移行方針（2 案、Lord 選択）

| 案 | 内容 |
|----|------|
| **A** | Mac mini で新 tunnel 作成、tunnel hostname を `n8n.plants-web.jp` に再 bind |
| **B** | 既存 tunnel の credential を Mac mini にコピーし、cloudflared コンテナを Mac mini で起動（WSL2 側 cloudflared を停止） |

案 B のほうが Cloudflare 側設定不変ゆえ簡潔。案 A は新 tunnel 作成 + DNS 再 route 要。

**Lord 対話**: Lord 判断。デフォルト推奨 B。

### 5.3 案 B 実行手順

```bash
# 1. WSL2 側 cloudflared 停止
cd /home/hal/services/ai-worker
docker compose stop cloudflared

# 2. credential ファイル取得 (~/.cloudflared/<tunnel-id>.json 等)
# tunnel credential の場所を確認
docker cp ai-worker-cloudflared-1:/etc/cloudflared/ /tmp/cloudflared-config/

# 3. Mac mini へ転送 (SCP 等)
scp -r /tmp/cloudflared-config/ hal@<mac-mini-ip>:/Users/hal/services/ai-worker/cloudflared/

# 4. Mac mini で cloudflared コンテナ起動
cd ~/services/ai-worker
docker compose up -d cloudflared

# 5. ログ確認
docker logs ai-worker-cloudflared-1 --tail 30
# 期待: "Registered tunnel connection" 等の成功 log
```

### 5.4 接続確認

```bash
# Mac mini or 外部から
curl -I https://n8n.plants-web.jp/healthz
# 期待: HTTP/2 200 (or n8n の health endpoint)
# Cloudflare Access が有効ゆえ 302 redirect する可能性あり、それは正常
```

**Phase 5 acceptance**:
- [x] WSL2 側 cloudflared 停止
- [x] Mac mini 側 cloudflared 稼働
- [x] `n8n.plants-web.jp` が Mac mini に向いている
- [x] Cloudflare Access 経由でログイン可

---

## Phase 6: gitops コンテナ + 周辺サービス

### 6.1 gitops コンテナ vault path

```bash
# Mac mini で
cd ~/services/ai-worker
# docker-compose.yml の gitops 設定確認
grep -A 15 "gitops:" docker-compose.yml
```

`gitops/server.py` 内に vault path がハードコードされていないか確認:

```bash
grep -nE "vault|workspace|obsidian" gitops/server.py
```

Mac mini 側 path に合うよう必要なら修正。

### 6.2 gitops 動作確認

```bash
docker compose up -d gitops

# Sync test
curl -X POST -H "X-Auth-Token: $PULL_TOKEN" -H "Content-Type: application/json" \
  http://localhost:8899/sync -d '{"message": "test: migration smoke test"}'
# 期待: vault repo に commit + push 成功
```

**Phase 6 acceptance**:
- [x] gitops コンテナ稼働
- [x] vault path 修正済 (path 書換)
- [x] sync エンドポイント動作確認

---

## Phase 7: Soft cutover（並行稼働 + Plaud trigger の片寄せ）

**目的**: WSL2 と Mac mini を **N 日間並行稼働**、Plaud email 等を Mac mini 側で処理させ、WSL2 をホット待機（ロールバック用）にする。

### 7.1 二重 trigger 防止

**最重要**: 同じ Gmail account を WSL2 / Mac mini 両方の n8n が watch すると **2 重処理**で vault に重複ファイル生成。これを避けるため:

```bash
# WSL2 側で PA-001 を deactivate (Plaud email を Mac mini のみが処理する状態に)
# WSL2 にて
source /home/hal/services/ai-worker/.env
curl -X POST -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "http://localhost:5678/api/v1/workflows/zDCe0OOBAxUzmLbS/deactivate"

# Mac mini 側で PA-001 を activate
# Mac mini にて
source ~/services/ai-worker/.env
curl -X POST -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "http://localhost:5678/api/v1/workflows/zDCe0OOBAxUzmLbS/activate"
```

同様に PA-002, WF-1, WF-2, WF-8, Obsidian-organizer 等の active workflow を Mac mini 側のみで稼働させる。

### 7.2 並行稼働期間中の運用

- 日々: Plaud email が Mac mini で処理され vault に書込される
- 毎日 git log を確認、`auto: add ... from Plaud` が正常な filename 含むこと
- 異常があれば即 WSL2 に戻せる準備

### 7.3 WSL2 → Mac mini 切替ロールバック手順

問題発生時の即時ロールバック:

```bash
# Mac mini PA-001 を deactivate
curl -X POST -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "http://localhost:5678/api/v1/workflows/zDCe0OOBAxUzmLbS/deactivate"

# Cloudflare Tunnel を WSL2 に戻す
# Mac mini cloudflared 停止 → WSL2 cloudflared 再起動

# WSL2 PA-001 を activate
# WSL2 にて curl POST .../activate
```

**Phase 7 acceptance**:
- [x] WSL2 側 active workflow を全 deactivate
- [x] Mac mini 側 active workflow を全 activate
- [x] 並行稼働 N 日（Lord 確定、推奨 1-2 週間）
- [x] 障害なく vault 書込確認

---

## Phase 8: 最終切替 + WSL2 retirement

### 8.1 並行稼働期間の品質確認

Lord が問題なしと判断した時点で、WSL2 側 n8n を完全停止:

```bash
# WSL2 側
cd /home/hal/services/ai-worker
docker compose down
# volume はまだ残す（即時 retire しない、N 日間 archive 保持）
```

### 8.2 WSL2 archive 化（保険）

```bash
# WSL2 側で volume を tar 化して保管
docker run --rm -v ai-worker_postgres_data:/data -v /tmp:/backup \
  alpine tar czf /backup/wsl2-postgres-archive-$(date +%Y%m%d).tar.gz /data

# Lord 判断で外部 storage / Mac mini にコピー
```

### 8.3 ドキュメント更新

`docs/migration-to-macos.md` の Phase 6 に「n8n 移行完了」記録を追記。本 spec への参照も保持。

**Phase 8 acceptance**:
- [x] WSL2 n8n container down 確認
- [x] WSL2 postgres volume archive 取得
- [x] Mac mini が唯一の稼働 n8n
- [x] ドキュメント更新済

---

## Lord 対話チェックポイント一覧

| Phase | チェックポイント | 内容 |
|-------|----------------|------|
| 1.1 | N8N_ENCRYPTION_KEY 確認 | デフォルト値か実値か Lord 確認 |
| 1.3 | active workflow 停止判断 | 実行中 workflow がある場合の対応 |
| 1.5 | DB dump 転送方法 | SCP / USB / S3 等 Lord 選択 |
| 2.5 | path 書換 diff 確認 | Lord 確認 |
| 4.1 | n8n UI 動作確認 | ブラウザで Lord 確認 |
| 4.2 | OAuth 再認証必要件 | Lord 対応 |
| 4.3 | PA-001 manual execute | 結果 Lord 確認 |
| 5.2 | Cloudflare Tunnel 移行方式 | A / B 選択 |
| 5.3 | Cloudflare credential 転送 | Lord ご操作 |
| 6.1 | gitops vault path | path 修正範囲確認 |
| 7.1 | 並行稼働開始 | Lord 同意 |
| 7.2 | 並行稼働期間 | N 日（推奨 1-2 週間）Lord 確定 |
| 8.1 | 最終切替 | Lord 判断 |

---

## トラブルシューティング

### Q: n8n コンテナ起動時 "Failed to decrypt credentials"

A: N8N_ENCRYPTION_KEY が WSL2 と Mac mini で不一致。`.env` を再確認、WSL2 と完全一致させる。
   credentials を **再認証** する選択肢もあるが、対象が多いと工数大。

### Q: workflow が deactivate のまま activate できない

A: 多くの場合、credentials が壊れているため。UI の Credentials タブで該当 credential を確認、"test connection" → 必要なら再 OAuth。

### Q: PA-001 が Plaud email を取得しない

A:
- Gmail Trigger が active か確認
- Gmail OAuth token が有効か (UI で test connection)
- `staticData.processedMessageIds` が WSL2 側と引き継がれているか（重複処理防止のため引き継ぎ済が期待される）
- WSL2 側 PA-001 が deactivate されているか（二重 trigger 防止）

### Q: cloudflared コンテナが tunnel に接続できない

A:
- credential file (`*.json`) が正しい場所にマウントされているか
- tunnel ID が Cloudflare ダッシュボードと一致しているか
- Mac mini の network 設定（IPv6 disable 等が影響する場合あり）

### Q: vault への書込が失敗（gitops sync エラー）

A:
- gitops コンテナの vault マウント path 確認
- Mac mini 側で git 認証（SSH 鍵 or token）が機能しているか
- `halsk/obsidian` repo への write 権限確認

### Q: Postgres restore で FK 違反エラー

A:
- pg_dump 時に `--clean --if-exists` 付きで実施したか
- postgres major version が同じか確認 (16 vs 16)
- DB を完全 drop してから restore (`docker compose down -v` で volume 削除 → 再起動 → restore)

---

## 参考資料

- 親仕様書: `docs/migration-to-macos.md` (Phase 6 から本 spec への参照)
- multi-agent-shogun 関連 memory: `memory/project_pa001_restore_plan.md`
- n8n 公式 backup ガイド: https://docs.n8n.io/hosting/cli-commands/#backup-and-restore
- 関連 memory:
  - `memory/feedback_n8n_code_node_credentials.md` (n8n Code ノード credential 制約)
  - n8n 環境情報は MEMORY.md の "n8n 環境情報" 参照

---

## 想定工数

| Phase | 工数 (Claude 実行) | Lord 対話 |
|-------|-------------------|-----------|
| 1: WSL2 dump | 30 分 | ~10 分 (転送方法) |
| 2: Mac mini 準備 | 30 分 | ~5 分 (path diff) |
| 3: postgres restore | 20 分 | - |
| 4: 動作確認 | 30 分 | ~15 分 (UI + OAuth 再認証) |
| 5: Cloudflare Tunnel | 30-60 分 | ~10 分 (方式選択) |
| 6: gitops | 15 分 | ~5 分 |
| 7: Soft cutover (並行稼働) | 5 分 (切替操作) | 1-2 週間並行稼働 |
| 8: 最終切替 | 15 分 | ~10 分 (Lord 同意) |
| **合計** | **3-4 時間** + 並行稼働期間 | **~1 時間** |

---

## 改訂履歴

| 日付 | 変更 |
|------|------|
| 2026-05-21 | 初版作成 (shogun が Lord 指示で起案、戦略 A 方式 + Soft cutover) |
