"""Routing tool (内製ツール v1): alerts.fifo -> Journal claim -> room lookup -> communication tool.

Responsibilities (spec 7.5):
  1. parse the common schema from alerts.fifo (direct or keep origin)
  2. claim notification_status pending -> delivered with a Conditional Update; only the
     winner posts. This is what makes "direct or keep, whichever first, exactly once" true.
  3. service -> room lookup in the routing table (never in Keep)
  4. on post failure: release the claim, leave the message (SQS retries, then DLQ)
  5. a later Keep-origin copy updates enrichment only; no second notification
Heartbeat messages emit CloudWatch metrics and are never posted.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request

import boto3

from alertpipe_common import KIND_HEARTBEAT, ORIGIN_DIRECT, ORIGIN_KEEP
from alertpipe_common.journal import Journal
from alertpipe_common.metrics import emit
from alertpipe_common.schema import utcnow_iso
from alertpipe_common.secrets import get_json

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ROUTING_TABLE = os.environ["ROUTING_TABLE"]
COMM_SECRET_ARN = os.environ["COMM_TOOL_SECRET_ARN"]
TIMEOUT = float(os.environ.get("COMM_TOOL_TIMEOUT_SECONDS", "10"))
DEFAULT_ROUTE_KEY = "default"

_ddb = boto3.resource("dynamodb")
_routing = _ddb.Table(ROUTING_TABLE)
_journal: Journal | None = None
_route_cache: dict[str, dict] = {}


def _get_journal() -> Journal:
    global _journal
    if _journal is None:
        _journal = Journal()
    return _journal


def resolve_room(service: str) -> dict:
    for key in (service, DEFAULT_ROUTE_KEY):
        if key in _route_cache:
            return _route_cache[key]
        item = _routing.get_item(Key={"service": key}).get("Item")
        if item:
            _route_cache[key] = item
            return item
    raise LookupError(f"no route for service '{service}' and no default route")


def build_message(alert: dict, route: dict) -> dict:
    status = alert["status"].upper()
    sev = alert["severity"].upper()
    mentions = " ".join(route.get("mentions") or []) if alert.get("critical") else ""
    text = f"[{status}][{sev}] {alert['name']} ({alert['service']})"
    if alert.get("description"):
        text += f"\n{alert['description']}"
    if alert.get("url"):
        text += f"\n{alert['url']}"
    if mentions:
        text = f"{mentions} {text}"
    return {
        "room": route["room"],
        "text": text,
        "idempotency_key": alert["transition_id"],
        "alert": {
            k: alert.get(k)
            for k in (
                "event_id",
                "transition_id",
                "fingerprint",
                "name",
                "status",
                "severity",
                "critical",
                "service",
                "source",
                "source_event_time",
                "origin",
            )
        },
    }


def post(message: dict) -> int:
    cfg = get_json(COMM_SECRET_ARN)
    headers = {
        "Content-Type": "application/json",
        "Idempotency-Key": message["idempotency_key"],
        cfg.get("auth_header", "Authorization"): cfg.get("auth_value", ""),
    }
    req = urllib.request.Request(cfg["webhook_url"], data=json.dumps(message).encode("utf-8"), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:  # noqa: S310 - URL from Secrets Manager
        return resp.status


def _handle_heartbeat(alert: dict) -> None:
    origin = alert.get("origin", ORIGIN_DIRECT)
    source = alert.get("source", "")
    if origin == ORIGIN_KEEP and source == "keep-scheduler":
        emit("KeepProcessingHeartbeat")  # Keep scheduler + workflow engine alive
    elif origin == ORIGIN_KEEP:
        emit("IngressHeartbeat", path="keep")  # ingress -> normalize -> keep -> alerts.fifo -> router
    else:
        emit("IngressHeartbeat", path="direct")  # ingress -> normalize -> alerts.fifo -> router


def _handle_alert(alert: dict) -> None:
    journal = _get_journal()
    origin = alert.get("origin", ORIGIN_DIRECT)
    now = utcnow_iso()
    claimed = journal.claim_notification(alert["event_id"], alert["transition_id"], origin, now)

    if origin == ORIGIN_KEEP:
        journal.mark_enriched(alert["event_id"], alert["transition_id"], alert.get("keep") or {}, now)

    if not claimed:
        emit("NotificationsSkipped", origin=origin)
        logger.info(json.dumps({"msg": "already delivered", "transition_id": alert["transition_id"], "origin": origin}))
        return

    try:
        route = resolve_room(alert["service"])
        status = post(build_message(alert, route))
    except Exception:
        journal.release_notification(alert["event_id"], alert["transition_id"])
        raise
    emit("NotificationsDelivered", origin=origin, severity=alert["severity"])
    logger.info(
        json.dumps(
            {
                "msg": "delivered",
                "transition_id": alert["transition_id"],
                "origin": origin,
                "room": route["room"],
                "http_status": status,
            }
        )
    )


def lambda_handler(event: dict, _context) -> dict:
    failures = []
    for record in event.get("Records", []):
        try:
            alert = json.loads(record["body"])
            if alert.get("kind") == KIND_HEARTBEAT:
                _handle_heartbeat(alert)
            else:
                _handle_alert(alert)
        except Exception:  # noqa: BLE001
            logger.exception("routing failed for %s", record.get("messageId"))
            emit("RouterErrors")
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
