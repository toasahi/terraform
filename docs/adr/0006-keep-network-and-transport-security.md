# ADR-0006: Internal ALB, plain HTTP inside the VPC, Redis without TLS

## Status
Accepted for Phase 1; revisit before Phase 3 sign-off

## Context
Keep's API is reached only by the Dispatcher Lambda (in-VPC) and the UI server
side. Keep's Redis configuration exposes host/port/username/password but no TLS
switch.

## Decision
* One internal ALB with two listeners: `:8080` → keep-api, `:80` → keep-ui.
  The ALB security group admits the Dispatcher security group and the VPC CIDR.
* HTTP inside the VPC; TLS terminates at the public API Gateway. RDS connections
  use `sslmode=require` and `rds.force_ssl=1`.
* ElastiCache with encryption at rest, transit encryption disabled, reachable
  only from the Keep task security group in isolated data subnets.

## Consequences
* Operators reach the UI through the VPC (VPN / SSM port forwarding); there is
  no public Keep endpoint.
* Adding an ACM private certificate to the ALB is a contained follow-up.
