"""AlertEventJournal access (DynamoDB).

Key: event_id (PK) + transition_id (SK).
"""

from __future__ import annotations

import os
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

KEEP_PENDING = "pending"
KEEP_ACCEPTED = "accepted"
KEEP_CONFIRMED = "confirmed"
KEEP_FAILED = "failed"

NOTIFY_PENDING = "pending"
NOTIFY_DELIVERED = "delivered"

_TTL_DAYS = int(os.environ.get("JOURNAL_TTL_DAYS", "90"))


class Journal:
    def __init__(self, table_name: str | None = None, client: Any | None = None):
        self.table_name = table_name or os.environ["JOURNAL_TABLE"]
        self._ddb = client or boto3.resource("dynamodb")
        self._table = self._ddb.Table(self.table_name)

    # ---- Normalize --------------------------------------------------------------

    def put_new_transition(self, item: dict) -> bool:
        """Conditional put. Returns False when the transition already exists."""
        item = dict(item)
        item.setdefault("keep_status", KEEP_PENDING)
        item.setdefault("notification_status", NOTIFY_PENDING)
        item.setdefault("direct_enqueued", False)
        item.setdefault("keep_enqueued", False)
        item.setdefault("keep_redelivery_count", 0)
        item.setdefault("expires_at", int(time.time()) + _TTL_DAYS * 86400)
        try:
            self._table.put_item(
                Item=item,
                ConditionExpression="attribute_not_exists(event_id) AND attribute_not_exists(transition_id)",
            )
            return True
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    def get(self, event_id: str, transition_id: str) -> dict | None:
        resp = self._table.get_item(Key={"event_id": event_id, "transition_id": transition_id}, ConsistentRead=True)
        return resp.get("Item")

    def mark_enqueued(self, event_id: str, transition_id: str, flag: str) -> None:
        self._table.update_item(
            Key={"event_id": event_id, "transition_id": transition_id},
            UpdateExpression="SET #f = :t",
            ExpressionAttributeNames={"#f": flag},
            ExpressionAttributeValues={":t": True},
        )

    # ---- Dispatcher / Reconciler ---------------------------------------------------

    def set_keep_status(self, event_id: str, transition_id: str, status: str, **extra: Any) -> None:
        names = {"#ks": "keep_status"}
        values: dict[str, Any] = {":s": status}
        sets = ["#ks = :s"]
        for i, (k, v) in enumerate(extra.items()):
            names[f"#e{i}"] = k
            values[f":e{i}"] = v
            sets.append(f"#e{i} = :e{i}")
        self._table.update_item(
            Key={"event_id": event_id, "transition_id": transition_id},
            UpdateExpression="SET " + ", ".join(sets),
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
        )

    def increment_keep_redelivery(self, event_id: str, transition_id: str) -> int:
        resp = self._table.update_item(
            Key={"event_id": event_id, "transition_id": transition_id},
            UpdateExpression="SET keep_redelivery_count = if_not_exists(keep_redelivery_count, :z) + :one",
            ExpressionAttributeValues={":z": 0, ":one": 1},
            ReturnValues="UPDATED_NEW",
        )
        return int(resp["Attributes"]["keep_redelivery_count"])

    def query_pending(self, index: str, status_attr: str, before_iso: str, limit: int = 100) -> list[dict]:
        resp = self._table.query(
            IndexName=index,
            KeyConditionExpression="#s = :p AND received_at < :t",
            ExpressionAttributeNames={"#s": status_attr},
            ExpressionAttributeValues={":p": "pending", ":t": before_iso},
            Limit=limit,
        )
        return resp.get("Items", [])

    def mark_escalated(self, event_id: str, transition_id: str, when_iso: str) -> bool:
        try:
            self._table.update_item(
                Key={"event_id": event_id, "transition_id": transition_id},
                UpdateExpression="SET escalated_at = :w",
                ConditionExpression="attribute_not_exists(escalated_at)",
                ExpressionAttributeValues={":w": when_iso},
            )
            return True
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    # ---- Router --------------------------------------------------------------------

    def claim_notification(self, event_id: str, transition_id: str, origin: str, when_iso: str) -> bool:
        """pending -> delivered exactly once, whichever path arrives first."""
        try:
            self._table.update_item(
                Key={"event_id": event_id, "transition_id": transition_id},
                UpdateExpression="SET notification_status = :d, delivered_at = :w, delivered_via = :o",
                ConditionExpression="attribute_exists(event_id) AND notification_status = :p",
                ExpressionAttributeValues={
                    ":d": NOTIFY_DELIVERED,
                    ":p": NOTIFY_PENDING,
                    ":w": when_iso,
                    ":o": origin,
                },
            )
            return True
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    def release_notification(self, event_id: str, transition_id: str) -> None:
        """Undo a claim after the post to the communication tool failed."""
        self._table.update_item(
            Key={"event_id": event_id, "transition_id": transition_id},
            UpdateExpression="SET notification_status = :p REMOVE delivered_at, delivered_via",
            ConditionExpression="notification_status = :d",
            ExpressionAttributeValues={":p": NOTIFY_PENDING, ":d": NOTIFY_DELIVERED},
        )

    def mark_enriched(self, event_id: str, transition_id: str, enrichment: dict, when_iso: str) -> None:
        self._table.update_item(
            Key={"event_id": event_id, "transition_id": transition_id},
            UpdateExpression="SET keep_status = :c, enriched_at = :w, keep_enrichment = :e",
            ConditionExpression="attribute_exists(event_id)",
            ExpressionAttributeValues={":c": KEEP_CONFIRMED, ":w": when_iso, ":e": enrichment},
        )
