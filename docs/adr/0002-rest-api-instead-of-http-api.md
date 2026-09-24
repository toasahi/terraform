# ADR-0002: API Gateway REST API (REGIONAL) instead of HTTP API

## Status
Accepted (ruling on a spec inconsistency)

## Context
§7.1 names "API Gateway (HTTP API)". §7.6 requires "発信元 IP を公開している SaaS は
WAF の IP 許可リストで絞る". AWS WAFv2 can be associated with REST API stages,
ALBs, CloudFront, AppSync and Cognito, but **not** with HTTP APIs (v2).

## Options
1. HTTP API + CloudFront in front + WAF on CloudFront: adds a global component
   and a second hop in the critical path.
2. HTTP API and enforce source IPs in the Lambda authorizer: drops WAF and its
   managed rules / rate limiting.
3. REST API (REGIONAL) with WAF attached to the stage.

## Decision
Option 3. REST API supports the same direct SQS integration (no Lambda in the
receive path), Lambda REQUEST authorizers, stage throttling and WAF. At ~5,000
alerts/month the price difference (3.50 vs 1.00 USD per million requests) is
below one cent.

## Consequences
* Terraform uses `aws_api_gateway_*` resources; the deployment is re-created
  from a hash of the method/integration resources.
* A mock `GET /healthz` is exposed for Route 53 HTTPS health checks.
