"""SQS helpers."""

from __future__ import annotations

from typing import Any

import boto3

_sqs = None


def client():
    global _sqs
    if _sqs is None:
        _sqs = boto3.client("sqs")
    return _sqs


def send_fifo(queue_url: str, body: str, group_id: str, dedup_id: str, attributes: dict[str, str] | None = None) -> str:
    params: dict[str, Any] = {
        "QueueUrl": queue_url,
        "MessageBody": body,
        "MessageGroupId": group_id,
        "MessageDeduplicationId": dedup_id[:128],
    }
    if attributes:
        params["MessageAttributes"] = {k: {"DataType": "String", "StringValue": str(v)} for k, v in attributes.items()}
    return client().send_message(**params)["MessageId"]
