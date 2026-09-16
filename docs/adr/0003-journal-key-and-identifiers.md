# ADR-0003: Journal key = (event_id, transition_id); deterministic identifiers

## Status
Accepted

## Context
§7.4 says the Journal PK is `event_id`, while §7.3 defines `transition_id` as the
idempotency key for notifications and `event_id` as "one firing occurrence".
One occurrence has at least two transitions (firing, resolved), so a table keyed
only by `event_id` cannot hold one notification state per transition.

## Decision
* Partition key `event_id`, sort key `transition_id`. One item per transition.
* `event_id = sha256(fingerprint | firing_start)[:32]`
* `transition_id = sha256(fingerprint | status | source_event_time)[:32]`
  where `source_event_time` is `startsAt` for firing and `endsAt` for resolved.
* Both are computed by the Normalize Lambda from source data only, so a
  duplicate delivery (Alertmanager repeat, ingress replay, DR double write)
  yields the same identifiers and is rejected by the conditional put.
* The identifiers travel to Keep as alert labels (`labels.event_id`,
  `labels.transition_id`) and come back unchanged on the Keep path.

## Consequences
* firing → resolved → firing (a new `startsAt`) creates a new `event_id` and
  is notified again (MVP completion condition 2).
* Alertmanager `repeat_interval` re-sends of the same firing are duplicates and
  do not re-notify. Re-notification cadence, if wanted, is a Keep or on-call tool concern.
