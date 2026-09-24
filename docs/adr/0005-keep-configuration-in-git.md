# ADR-0005: Keep configuration is Git-managed and all Keep state lives in PostgreSQL

## Status
Accepted

## Context
§9.4: "Keep のワークフロー・プロバイダ設定は Git 管理し、UI で手編集しない" and
"Keep のイメージは ECR にミラーする". Fargate tasks have no persistent volume.

## Decision
* Providers: `KEEP_PROVIDERS` environment variable (JSON) rendered by
  Terraform. The only provider is `amazonsqs` → `alerts.fifo`; it carries no
  credentials because the ECS task role authenticates.
* Workflows: baked into a thin derivative image (`keep/Dockerfile`) under
  `/opt/keep/workflows`, loaded via `KEEP_WORKFLOWS_DIRECTORY`. The image tag
  equals the upstream Keep version and is pinned in tfvars.
* `SECRET_MANAGER_TYPE=DB`, `AUTH_TYPE=DB`: every piece of Keep state is in
  RDS, which is what the cross-region read replica carries to Osaka.
* `PUSHER_DISABLED=true`: no Soketi/websocket service; the UI polls.

## Consequences
* Changing a workflow = commit + `scripts/mirror-keep-images.sh` + tfvars bump.
* Keep's `x86_64` image is used (arm64 availability is an open item, §12-10).
