# ADR-0007: Nothing on the critical path runs inside the VPC

## Status
Accepted

## Context
§6.1: what must survive is critical delivery, not Keep. A Lambda attached to a
VPC depends on ENI provisioning, subnets, NAT and security groups.

## Decision
The Normalize Lambda and the routing Lambda run outside the VPC and talk to
SQS, DynamoDB and Secrets Manager over public AWS endpoints. Only the Keep
Dispatcher is VPC-attached (it must reach the internal ALB). The communication
tool is reached over HTTPS; if it is only reachable privately, the routing
Lambda gets a `vpc_config` and the ADR is revised.

## Consequences
* An AZ or NAT failure cannot stop critical delivery.
* The Regional NAT Gateway carries only Keep (image pulls, AWS APIs) and the
  Dispatcher's Secrets Manager calls.
