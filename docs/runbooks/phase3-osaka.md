# Runbook: Phase 3 – Osaka pilot light

Prerequisites: Phase 2 Go conditions met in Tokyo; PagerDuty still running.

1. **Tokyo: enable replication** (`envs/prod/tokyo.tfvars`)
   * `journal_replicas = { "ap-northeast-3" = { kms_key_arn = "<Osaka kms_key_arn output>" } }`
     – requires the Osaka stack's KMS key first: apply Osaka once with
     `role = "secondary"` will fail on the Journal lookup, so create the key
     by applying Osaka with `-target=module.kms` first.
   * `secret_replica_regions = ["ap-northeast-3"]`, `ecr_replication_regions = ["ap-northeast-3"]`
   * `make apply ENV=tokyo`
2. **Mirror images into Tokyo ECR** if not done; replication copies them to Osaka.
3. **Osaka: fill the three REPLACE-ME ARNs** in `osaka.tfvars` from Tokyo outputs
   (`keep.db_instance_arn`; the secret ARNs are the *replica* ARNs in ap-northeast-3).
4. `make init ENV=osaka && make plan ENV=osaka && make apply ENV=osaka`
5. **Flip DNS to failover** in Tokyo:
   `dns_failover_role = "PRIMARY"`,
   `dns_health_check = { type = "cloudwatch_alarm", alarm_name = "<Osaka canary_posted_alarm_name>", alarm_region = "ap-northeast-3" }`
   then `make apply ENV=tokyo`. Sources keep using the same DNS name.
6. **GameDay: Tokyo isolation.** Expected: critical via Osaka within minutes
   (no Keep needed); then promote the RDS replica, set
   `keep_api_desired_count = 2`, `keep_create_redis = true` in Osaka and apply.
   Measure RTO/RPO and record them as SLOs.
7. Fail-back: never start Tokyo Keep against the old database (keep
   `keep_api_desired_count = 0` in Tokyo until the database direction is
   reversed with a planned outage).
