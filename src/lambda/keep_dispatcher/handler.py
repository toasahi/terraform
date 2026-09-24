"""Keep Dispatcher: keep-delivery.fifo -> POST {KEEP_API_URL}/alerts/event/keep.

A 2xx from Keep only means "enqueued for processing" (Keep returns 202 before
persisting), so the Journal moves to keep_status=accepted, not confirmed.
The routing tool marks confirmed when the Keep-path message arrives on
alerts.fifo; the Reconciler re-drives anything stuck in pending/accepted.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request

from alertpipe_common.journal import KEEP_ACCEPTED, Journal
from alertpipe_common.metrics import emit
from alertpipe_common.schema import NormalizedAlert, utcnow_iso
from alertpipe_common.secrets import get_json

logger = logging.getLogger()
logger.setLevel(logging.INFO)

KEEP_API_URL = os.environ["KEEP_API_URL"].rstrip("/")
KEEP_APP_SECRET_ARN = os.environ["KEEP_APP_SECRET_ARN"]
PROVIDER_TYPE = os.environ.get("KEEP_PROVIDER_TYPE", "keep")
TIMEOUT = float(os.environ.get("KEEP_TIMEOUT_SECONDS", "10"))

_SEVERITY = {"critical": "critical", "high": "high", "warning": "warning", "info": "info", "low": "low"}

_journal: Journal | None = None


def _get_journal() -> Journal:
    global _journal
    if _journal is None:
        _journal = Journal()
    return _journal


def to_keep_alert(alert: NormalizedAlert) -> dict:
    labels = dict(alert.labels)
    labels.update(
        {
            "event_id": alert.event_id,
            "transition_id": alert.transition_id,
            "source_event_time": alert.source_event_time,
            "kind": alert.kind,
            "source": alert.source,
            "critical": str(alert.critical).lower(),
            "pipeline_region": alert.region,
        }
    )
    body = {
        "name": alert.name,
        "status": alert.status,
        "severity": _SEVERITY.get(alert.severity, "warning"),
        "lastReceived": alert.source_event_time,
        "fingerprint": alert.fingerprint,
        "source": [alert.source],
        "service": alert.service,
        "description": alert.description or alert.name,
        "labels": labels,
        # extra fields (AlertDto allows them) so workflows can use {{ alert.transition_id }} too
        "transition_id": alert.transition_id,
        "pipeline_event_id": alert.event_id,
        "kind": alert.kind,
    }
    if alert.url:
        body["url"] = alert.url
    return body


def push(alert: NormalizedAlert) -> int:
    api_key = get_json(KEEP_APP_SECRET_ARN)["api_key"]
    req = urllib.request.Request(
        f"{KEEP_API_URL}/alerts/event/{PROVIDER_TYPE}",
        data=json.dumps(to_keep_alert(alert)).encode("utf-8"),
        headers={"Content-Type": "application/json", "X-API-KEY": api_key, "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:  # noqa: S310 - internal ALB URL from config
        return resp.status


def lambda_handler(event: dict, _context) -> dict:
    failures = []
    for record in event.get("Records", []):
        try:
            alert = NormalizedAlert.from_dict(json.loads(record["body"]))
            status = push(alert)
            _get_journal().set_keep_status(alert.event_id, alert.transition_id, KEEP_ACCEPTED, keep_accepted_at=utcnow_iso())
            emit("KeepPushAccepted", http_status=str(status))
        except urllib.error.HTTPError as exc:
            logger.error("keep rejected %s: HTTP %s %s", record.get("messageId"), exc.code, exc.read()[:500])
            emit("KeepPushErrors", http_status=str(exc.code))
            failures.append({"itemIdentifier": record["messageId"]})
        except Exception:  # noqa: BLE001
            logger.exception("keep push failed for %s", record.get("messageId"))
            emit("KeepPushErrors", http_status="exception")
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
