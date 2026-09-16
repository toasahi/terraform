# ADR-0001: One region-parameterized root module, applied per region

## Status
Accepted (Phase 1)

## Context
The spec requires that the Osaka DR deployment be "the same stack re-applied"
(§9.4) and that queue and table names carry no region.

## Decision
`stacks/regional` is the only root module. Tokyo and Osaka differ only by
`envs/prod/<region>.tfvars` (`role = primary | secondary`) and by their backend
config. Region-specific behaviour is expressed through a handful of variables
(`journal_replicas`, `keep_db_replicate_source_arn`, `dns_failover_role`, …),
never through separate code paths. State for each region is stored in a bucket
in that region so a Tokyo outage cannot block a DR apply.

## Consequences
* Phase 3 is additive: apply Tokyo with the replication variables set, then apply Osaka.
* Global resources (the Route 53 record set, ECR replication configuration,
  DynamoDB global tables, Secrets Manager replication) are owned by the primary stack.
