# Architecture notes (implementation view)

## Message flow and durability boundaries

| Step | Durable store | Success condition |
|---|---|---|
| API Gateway → `ingress` | SQS Standard (14 d) | SQS 200 → client gets 202. No Lambda in the path. |
| Normalize | Journal (DynamoDB) + `alerts.fifo` (critical) + `keep-delivery.fifo` | All writes OK → ingress message deleted. Partial failure resumes from Journal flags (`direct_enqueued`, `keep_enqueued`). |
| Dispatcher → Keep | `keep-delivery.fifo` | Keep 2xx → `keep_status = accepted`. Anything else stays in the queue. |
| Keep workflow → `alerts.fifo` | `alerts.fifo` | Keep is not a durability boundary; the Reconciler re-delivers `pending` after N minutes. |
| Router → comm tool | Journal `notification_status` | Conditional `pending → delivered`, released on post failure; SQS retries then DLQ. |

## Identifiers (ADR-0003)

```
fingerprint        "<source>:<source fingerprint or hash of labels>"
event_id           sha256(fingerprint | firing_start)[:32]
transition_id      sha256(fingerprint | status | source_event_time)[:32]
```

## Journal item

| Attribute | Written by | Values |
|---|---|---|
| `keep_status` | Normalize / Dispatcher / Router / Reconciler | pending → accepted → confirmed, or failed |
| `notification_status` | Normalize / Router | pending → delivered (`delivered_via` = direct / keep) |
| `direct_enqueued`, `keep_enqueued` | Normalize | resume flags |
| `keep_redelivery_count`, `escalated_at` | Reconciler | re-delivery attempts, one-time SNS escalation |
| `payload` | Normalize | common schema JSON (re-delivery source) |
| `expires_at` | Normalize | TTL (90 days) |

GSIs: `fingerprint-received_at`, `keep_status-received_at`, `notification_status-received_at`.

## Common schema (every queue)

`schema_version, origin (direct|keep), kind (alert|heartbeat), event_id, transition_id, fingerprint, name, status, severity, critical, service, source, source_event_time, firing_start, received_at, description, url, labels, region`

Keep-origin messages additionally carry `keep: {alert_id, incident, assignee}`.

## Failure modes → implementation

| Failure | Where handled |
|---|---|
| EKS down | Nothing here runs on EKS; ops-account VPC |
| Normalize down | `ingress` retention 14 d, DLQ alarm, oldest-message alarm |
| Keep down | critical via direct path; `keep-delivery.fifo` backlog; `keep-api-unhealthy` alarm |
| Keep 202 without persistence | Reconciler: `keep_status = pending` > 10 min → re-enqueue (distinct dedup id per attempt) |
| Keep → alerts.fifo failed | Same as above (status never reaches confirmed) |
| Redis lost | ARQ jobs are re-driven from the Journal |
| Router down | `alerts.fifo` backlog + DLQ/age alarms → SNS; critical `notification_status = pending` > 5 min → SNS escalation |
| Silent ingress failure | canary → `IngressHeartbeat{path}` missing → SNS |
| Silent Keep failure | interval workflow → `KeepProcessingHeartbeat` missing → SNS |
| AZ failure | 2-AZ Fargate, Regional NAT, RDS/Redis Multi-AZ, ALB health checks |
| Keep upgrade | ECS rolling (min 100 %, max 200 %), circuit breaker rollback, immutable ECR tags |

## Cost knobs

| Variable | Default | Spec assumption |
|---|---|---|
| `keep_api_desired_count`, `api_cpu/memory` | 2 × (1 vCPU, 2 GiB) | Fargate ≈ 126 USD (with the UI task) |
| `keep_db_instance_class` | db.t4g.medium Multi-AZ | RDS ≈ 137 USD |
| `keep_redis_node_type` | 2 × cache.t4g.small | Redis ≈ 60 USD |
| `enable_interface_endpoints` | false | Regional NAT ≈ 90 USD carries the traffic |
