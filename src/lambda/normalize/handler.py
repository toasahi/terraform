"""Normalize Lambda: ingress.standard -> Journal (+ alerts.fifo for critical) -> keep-delivery.fifo.

Success condition for deleting an ingress message (spec 7.2):
  critical     : Journal put OK AND alerts.fifo send OK AND keep-delivery.fifo send OK
  non-critical : Journal put OK AND keep-delivery.fifo send OK
Heartbeats follow the critical rule so both paths are measured.
Keep's availability plays no part in any of this.
"""

from __future__ import annotations

import json
import logging
import os

from adapters import Skip, adapt
from alertpipe_common import KIND_HEARTBEAT, ORIGIN_DIRECT
from alertpipe_common.journal import Journal
from alertpipe_common.metrics import emit
from alertpipe_common.queues import send_fifo

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ALERTS_FIFO_URL = os.environ["ALERTS_FIFO_URL"]
KEEP_DELIVERY_FIFO_URL = os.environ["KEEP_DELIVERY_FIFO_URL"]

_journal: Journal | None = None


def _get_journal() -> Journal:
    global _journal
    if _journal is None:
        _journal = Journal()
    return _journal


def _attributes(alert) -> dict[str, str]:
    return {"origin": ORIGIN_DIRECT, "severity": alert.severity, "kind": alert.kind, "source": alert.source}


def _process_alert(alert) -> None:
    journal = _get_journal()
    body = alert.to_json()
    item = {
        "event_id": alert.event_id,
        "transition_id": alert.transition_id,
        "fingerprint": alert.fingerprint,
        "name": alert.name,
        "status": alert.status,
        "severity": alert.severity,
        "critical": alert.critical,
        "kind": alert.kind,
        "service": alert.service,
        "source": alert.source,
        "received_at": alert.received_at,
        "source_event_time": alert.source_event_time,
        "region": alert.region,
        "payload": body,
    }

    is_new = journal.put_new_transition(item)
    direct_needed = alert.critical or alert.kind == KIND_HEARTBEAT
    direct_done = False
    keep_done = False
    if not is_new:
        existing = journal.get(alert.event_id, alert.transition_id) or {}
        direct_done = bool(existing.get("direct_enqueued"))
        keep_done = bool(existing.get("keep_enqueued"))
        if (direct_done or not direct_needed) and keep_done:
            emit("Duplicates", source=alert.source)
            logger.info(json.dumps({"msg": "duplicate transition", "transition_id": alert.transition_id}))
            return
        logger.warning(json.dumps({"msg": "resuming partially enqueued transition", "transition_id": alert.transition_id}))

    if direct_needed and not direct_done:
        send_fifo(ALERTS_FIFO_URL, body, alert.fingerprint, f"{alert.transition_id}:{ORIGIN_DIRECT}", _attributes(alert))
        journal.mark_enqueued(alert.event_id, alert.transition_id, "direct_enqueued")
        emit("CriticalDirectEnqueued" if alert.critical else "HeartbeatDirectEnqueued", source=alert.source)

    if not keep_done:
        send_fifo(KEEP_DELIVERY_FIFO_URL, body, alert.fingerprint, alert.transition_id, _attributes(alert))
        journal.mark_enqueued(alert.event_id, alert.transition_id, "keep_enqueued")

    emit("AlertsNormalized", severity=alert.severity, source=alert.source)
    logger.info(
        json.dumps(
            {
                "msg": "normalized",
                "event_id": alert.event_id,
                "transition_id": alert.transition_id,
                "fingerprint": alert.fingerprint,
                "status": alert.status,
                "severity": alert.severity,
                "critical": alert.critical,
            }
        )
    )


def _process_record(record: dict) -> None:
    attrs = record.get("messageAttributes") or {}
    source = (attrs.get("source") or {}).get("stringValue", "unknown")
    payload = json.loads(record["body"])
    try:
        alerts = adapt(source, payload)
    except Skip as why:
        logger.info(json.dumps({"msg": "skipped", "source": source, "reason": str(why)}))
        return
    for alert in alerts:
        _process_alert(alert)


def lambda_handler(event: dict, _context) -> dict:
    failures = []
    for record in event.get("Records", []):
        try:
            _process_record(record)
        except Exception:  # noqa: BLE001 - report and let SQS retry / DLQ
            logger.exception("normalize failed for message %s", record.get("messageId"))
            emit("NormalizeErrors")
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
