"""Reconciler (Phase 2), scheduled every few minutes.

Journal -> Keep : keep_status still pending after KEEP_PENDING_MINUTES -> re-enqueue to
                  keep-delivery.fifo (up to MAX_KEEP_REDELIVERIES, then keep_status=failed).
Journal -> 通知 : notification_status pending for a critical alert after NOTIFY_PENDING_MINUTES
                  -> publish on the independent SNS path (once per transition).
"""

from __future__ import annotations

import json
import logging
import os
from datetime import UTC, datetime, timedelta

import boto3

from alertpipe_common.journal import KEEP_FAILED, Journal
from alertpipe_common.metrics import emit
from alertpipe_common.queues import send_fifo
from alertpipe_common.schema import utcnow_iso

logger = logging.getLogger()
logger.setLevel(logging.INFO)

KEEP_DELIVERY_FIFO_URL = os.environ["KEEP_DELIVERY_FIFO_URL"]
SNS_TOPIC_ARN = os.environ["INDEPENDENT_SNS_TOPIC_ARN"]
KEEP_PENDING_MINUTES = int(os.environ.get("KEEP_PENDING_MINUTES", "10"))
NOTIFY_PENDING_MINUTES = int(os.environ.get("NOTIFY_PENDING_MINUTES", "5"))
MAX_KEEP_REDELIVERIES = int(os.environ.get("MAX_KEEP_REDELIVERIES", "5"))
BATCH = int(os.environ.get("RECONCILER_BATCH", "100"))

_sns = boto3.client("sns")
_journal: Journal | None = None


def _get_journal() -> Journal:
    global _journal
    if _journal is None:
        _journal = Journal()
    return _journal


def _cutoff(minutes: int) -> str:
    return (datetime.now(UTC) - timedelta(minutes=minutes)).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def reconcile_keep() -> int:
    journal = _get_journal()
    redriven = 0
    for item in journal.query_pending("keep_status-received_at-index", "keep_status", _cutoff(KEEP_PENDING_MINUTES), BATCH):
        count = journal.increment_keep_redelivery(item["event_id"], item["transition_id"])
        if count > MAX_KEEP_REDELIVERIES:
            journal.set_keep_status(item["event_id"], item["transition_id"], KEEP_FAILED, keep_failed_at=utcnow_iso())
            emit("KeepRedeliveryGaveUp")
            logger.error(json.dumps({"msg": "keep redelivery exhausted", "transition_id": item["transition_id"]}))
            continue
        # A distinct dedup id per attempt so the 5-minute FIFO window never swallows the retry.
        send_fifo(
            KEEP_DELIVERY_FIFO_URL,
            item["payload"],
            item["fingerprint"],
            f"{item['transition_id']}:r{count}",
            {"origin": "reconciler", "attempt": str(count)},
        )
        redriven += 1
    emit("KeepRedelivered", value=redriven)
    return redriven


def reconcile_notifications() -> int:
    journal = _get_journal()
    escalated = 0
    for item in journal.query_pending(
        "notification_status-received_at-index", "notification_status", _cutoff(NOTIFY_PENDING_MINUTES), BATCH
    ):
        if not item.get("critical") or item.get("kind") == "heartbeat":
            continue
        now = utcnow_iso()
        if not journal.mark_escalated(item["event_id"], item["transition_id"], now):
            continue
        subject = f"[UNDELIVERED CRITICAL] {item.get('name', '?')} ({item.get('service', '?')})"[:100]
        _sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=json.dumps(
                {
                    "reason": f"critical alert not delivered to a room within {NOTIFY_PENDING_MINUTES} minutes",
                    "name": item.get("name"),
                    "service": item.get("service"),
                    "status": item.get("status"),
                    "fingerprint": item.get("fingerprint"),
                    "event_id": item["event_id"],
                    "transition_id": item["transition_id"],
                    "received_at": item.get("received_at"),
                    "region": item.get("region"),
                    "escalated_at": now,
                },
                ensure_ascii=False,
                indent=2,
            ),
        )
        escalated += 1
    emit("CriticalEscalated", value=escalated)
    return escalated


def lambda_handler(_event: dict, _context) -> dict:
    result = {"keep_redelivered": reconcile_keep(), "critical_escalated": reconcile_notifications()}
    logger.info(json.dumps({"msg": "reconciled", **result}))
    return result
