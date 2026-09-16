# ADR-0004: SQS deduplication ids differ per path; exactly-once lives in the Journal

## Status
Accepted

## Context
§7.3 states that `transition_id` is the MessageDeduplicationId on both paths.
If the direct copy and the Keep copy of the same transition used the same
deduplication id on `alerts.fifo`, SQS would silently drop the Keep copy whenever
it arrives within 5 minutes, and deliver it whenever it arrives later. The
routing tool's enrichment behaviour would depend on Keep's latency.

## Decision
* `alerts.fifo`: `MessageDeduplicationId = "<transition_id>:direct"` and
  `"<transition_id>:keep"`; `MessageGroupId = fingerprint` on both.
* `keep-delivery.fifo`: `MessageDeduplicationId = transition_id`; the
  Reconciler re-deliveries use `"<transition_id>:r<n>"`.
* Exactly-once notification is enforced by the routing tool's conditional
  update `notification_status: pending → delivered` on the Journal (§14-4:
  "SQS FIFO の 5 分窓に依存しない").

## Consequences
* The Keep copy always reaches the routing tool, which records
  `keep_status = confirmed` and Keep enrichment (alert id, incident, assignee).
* Ordering per alert is preserved by the shared `MessageGroupId`.
