# Keep configuration (Git-managed)

Nothing in Keep is edited through the UI. Two mechanisms carry configuration:

| What | Mechanism | Where |
|---|---|---|
| Providers (amazonsqs → alerts.fifo) | `KEEP_PROVIDERS` env var (JSON, no secrets; the ECS task role authenticates) | `modules/keep_service` |
| Workflows | `KEEP_WORKFLOWS_DIRECTORY=/opt/keep/workflows`, baked into the mirrored image | `keep/workflows/*.yaml` |
| Provider secrets, API keys, alerts | PostgreSQL (`SECRET_MANAGER_TYPE=DB`) → replicated to Osaka by the RDS read replica | RDS |

Build and push the mirrored images with:

```
KEEP_VERSION=<upstream tag> ./scripts/mirror-keep-images.sh <aws-region> <name-prefix>
```

then set `keep_image_tag = "<upstream tag>"` in the region's tfvars.
