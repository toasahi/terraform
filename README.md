# PagerDuty → Keep 置き換え: アラート配送基盤 (Terraform)

仕様書「PagerDuty → Keep 置き換えアーキテクチャ 検討サマリー（v4）」の案 C（v3 = 最終形）を
Terraform で実装したもの。東京 MVP → フェーズ 2（Go 条件充足）→ 大阪 DR の 3 段階を、
**同じルートモジュール** (`stacks/regional`) をリージョン別 tfvars で適用する形で扱う。

```
監視ソース ─HTTPS─▶ alerts.example.com (Route 53 public)
                     └▶ API Gateway REST (Lambda authorizer / WAF / throttling)
                          └▶ ingress (SQS Standard, 14d, DLQ)
                               └▶ Normalize Lambda ── Journal (DynamoDB, Conditional Put)
                                    ├─ critical ──▶ alerts.fifo  (origin=direct)
                                    └─ 全件 ─────▶ keep-delivery.fifo
                                                     └▶ Keep Dispatcher Lambda (VPC) ─▶ Keep API (ECS Fargate ×2, RDS Multi-AZ, Redis Multi-AZ)
                                                                                           └▶ workflow amazonsqs ─▶ alerts.fifo (origin=keep)
alerts.fifo ─▶ Router Lambda (内製ツール v1): Journal claim → 対応表 → コミュニケーションツール API
横: Reconciler Lambda (Journal→Keep 再投入 / critical 未配送→独立 SNS)、canary、Keep heartbeat、DLQ/滞留アラーム
```

## リポジトリ構成

| パス | 内容 |
|---|---|
| `stacks/regional/` | ルートモジュール（1 リージョン分すべて）。`role = primary / secondary` |
| `envs/prod/tokyo.tfvars`, `osaka.tfvars` | リージョン別の値。`backend-*.hcl` は S3 バックエンド（`use_lockfile`） |
| `modules/network` | VPC 2AZ、private / data サブネット、**Regional NAT Gateway**、Gateway エンドポイント、フローログ |
| `modules/kms` | リージョン CMK（SQS / DynamoDB / Secrets / Logs / RDS / Redis / SNS） |
| `modules/queues` | `ingress`(Standard)、`alerts.fifo`、`keep-delivery.fifo` + DLQ。名前にリージョンを含めない |
| `modules/journal` | AlertEventJournal（PK event_id / SK transition_id、Streams、PITR、GSI×3）と service→room 対応表 |
| `modules/ingress` | REST API → SQS 直接統合、Lambda REQUEST authorizer、WAF（レート制限 + ソース別 IP 許可）、カスタムドメイン |
| `modules/acm_certificate`, `modules/dns_record` | 証明書と公開レコード。`failover_role` でフェーズ 3 のフェイルオーバーに切替 |
| `modules/keep_datastore` | RDS PostgreSQL 16 Multi-AZ（replica モードあり）、ElastiCache Redis Multi-AZ、接続シークレット |
| `modules/keep_service` | ECR ミラー、ECS Fargate（api ×2 / ui ×1）、内部 ALB、`KEEP_PROVIDERS` / `KEEP_WORKFLOWS_DIRECTORY` |
| `modules/keep_dispatcher` | keep-delivery.fifo → Keep API push（唯一の VPC 内 Lambda） |
| `modules/lambda_function`, `modules/lambda_layer` | 最小権限ロール・KMS ログ・部分バッチ失敗レポート付きの共通ラッパー |
| `modules/reconciler`, `modules/observability` | フェーズ 2（`enable_phase2 = true`）: Reconciler、canary、アラーム、独立 SNS 経路 |
| `src/lambda/` | Python 3.12 ハンドラ（authorizer / normalize / keep_dispatcher / router / reconciler / canary）と共通レイヤー、pytest |
| `keep/` | Keep の Git 管理設定: ワークフロー YAML と派生イメージの Dockerfile |
| `scripts/mirror-keep-images.sh` | 上流イメージを ECR にミラー（ワークフロー同梱） |
| `docs/adr/` | 仕様書の曖昧・矛盾点に対する裁定記録 |
| `docs/runbooks/` | フェーズ 3 手順 |

## 仕様書からの裁定（要点）

| # | 裁定 | ADR |
|---|---|---|
| 1 | **REST API を採用**（仕様は HTTP API）。WAFv2 は HTTP API に関連付けできず、仕様の WAF IP 許可リストを満たせないため | 0002 |
| 2 | Journal は **PK event_id + SK transition_id**。firing / resolved を 1 レコードずつ持ち、通知冪等性は transition_id | 0003 |
| 3 | alerts.fifo の MessageDeduplicationId は **`transition_id:direct` / `transition_id:keep`**。SQS の 5 分窓ではなく Journal の Conditional Update が exactly-once の実体 | 0004 |
| 4 | Keep 設定は Git 管理: プロバイダは `KEEP_PROVIDERS`、ワークフローはイメージ同梱、状態は全て RDS（`SECRET_MANAGER_TYPE=DB`）。DR レプリカで丸ごと運べる | 0005 |
| 5 | Keep は内部 ALB + VPC 内 HTTP、Redis は TLS なし（Keep 側に TLS 設定がない） | 0006 |
| 6 | critical 経路（Normalize / Router）は **VPC 外**。VPC 内は Dispatcher だけ | 0007 |
| 7 | heartbeat は出口（Router）で計測、独立 SNS 経路へ集約。大阪 canary の成功アラームがフェーズ 3 の Route 53 ヘルスチェック | 0008 |
| 8 | CloudWatch アラームの critical 判定はアラーム名に `critical` を含むかで行う（アラーム名規約）。Alertmanager は `severity` ラベル | — |
| 9 | 内製ツールの DB は持たず Journal を共用。対応表は tfvars（Git）→ DynamoDB に実体化 | — |

## 前提となる外部作業

1. 公開ホストゾーン（`public_zone_name`）が同一アカウントにあること
2. `scripts/mirror-keep-images.sh` で Keep イメージを ECR にミラーし、`keep_image_tag` を設定
3. apply 後、`<name>/router/communication-tool` シークレットの `auth_value` を手動投入
4. `<name>/ingress/source-tokens` からソース別トークンを取り出し、Alertmanager / SaaS に `X-Alert-Token` ヘッダを設定
   * Alertmanager: `webhook_configs: - url: https://alerts.example.com/v1/alerts/alertmanager` + `http_config.authorization`
     ではなくカスタムヘッダが必要なため、`http_config` の `headers` に `X-Alert-Token` を設定する（Alertmanager 0.27+）

## 使い方

```bash
make init  ENV=tokyo     # terraform init -backend-config=envs/prod/backend-tokyo.hcl
make plan  ENV=tokyo
make apply ENV=tokyo
make validate            # ルート + 全モジュールの validate
make test                # Lambda 単体テスト
make lint                # tflint
```

フェーズ切替は tfvars だけで行う。

| フェーズ | 変更 |
|---|---|
| 1 東京 MVP | `tokyo.tfvars` をそのまま |
| 2 Go 条件 | `enable_phase2 = true`、`escalation_*` を設定 |
| 3 大阪 DR | `docs/runbooks/phase3-osaka.md` |

## MVP 完了条件の確認方法（§9.1）

| 条件 | 確認 |
|---|---|
| 1 両経路で届き通知は 1 回 | Router のログ `delivered`（origin=direct）と `already delivered`（origin=keep）が同じ transition_id で 1 回ずつ |
| 2 firing→resolved→firing が 3 回とも通知 | Journal に event_id が 2 つ、transition が 3 つ |
| 3 Keep 全停止でも critical 到達 | `aws ecs update-service --desired-count 0` 後に critical を投入 → ルーム到達 |
| 4 Keep 停止中の非 critical が復旧後に届く | keep-delivery.fifo 滞留 → desired-count 2 → Router `delivered`（origin=keep） |
| 5 二重投入でも通知 1 回 | 同一ペイロードを 2 回 POST → Normalize メトリクス `Duplicates` = 1、通知 1 回 |

## セキュリティ / IAM（§7.7）

* Keep タスクロール: `alerts.fifo` への `sqs:SendMessage`（+ プロバイダ自己検証用 `GetQueueAttributes`）のみ
* Router Lambda: alerts.fifo の Receive/Delete/ChangeVisibility、Journal の `UpdateItem`、対応表の `GetItem`、通信ツール秘密の読取のみ
* 全キュー・テーブル・シークレット・ログ・RDS・Redis を同一 CMK で SSE-KMS
* 受信口: ソース別トークン（Secrets Manager、authorizer で定数時間比較、ポリシーはそのソースのパスに限定）、WAF レート制限 + 既知不正入力ルール + ソース別 IP 許可、ステージスロットリング

## 未確認事項に依存している箇所

| 仕様 §12 | 実装上の仮置き |
|---|---|
| 4 通信ツール API の冪等性 | Router は `Idempotency-Key: <transition_id>` ヘッダと本文 `idempotency_key` を送る。受け側の仕様に合わせて `src/lambda/router/handler.py` の `build_message` / `post` を調整 |
| 5, 6 Keep API 認証・属性保持 | `X-API-KEY` + `/alerts/event/keep`（Keep ソースで確認済み）。ID はラベルとトップレベル両方に載せ、ワークフローはラベルを参照 |
| 7 Keep の重複排除 | 同一 fingerprint の再発は `lastReceived` が変わるため既定の重複排除では抑止されない想定。GameDay で確認 |
| 10 arm64 | x86_64 で固定 |
