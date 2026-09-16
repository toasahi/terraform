# ADR-0008: Two heartbeats measured at the exit, one independent SNS path

## Status
Accepted (Phase 2)

## Context
§6.2-6: entry→exit synthetic monitoring must be separate from the Keep
processing heartbeat.

## Decision
* Ingress canary (Lambda on a 1-minute schedule) posts a `kind=heartbeat`
  alert through the **public** ingress URL. Normalize fans it out on both
  paths; the routing tool emits `IngressHeartbeat{path=direct|keep}` and never
  posts heartbeats to a room.
* Keep processing heartbeat: an interval workflow inside Keep writes a
  heartbeat message to `alerts.fifo`; the routing tool emits
  `KeepProcessingHeartbeat`.
* Alarms on missing heartbeats, DLQ depth, oldest-message age, Lambda errors,
  ingress 5xx and Keep target health all notify one SNS topic that has e-mail /
  SMS / HTTPS subscribers and no dependency on the pipeline.
* The Reconciler escalates undelivered critical transitions on the same topic.
* Phase 3: the Osaka canary's `CanaryPosted` alarm becomes the Route 53
  health check of the Tokyo PRIMARY record.
