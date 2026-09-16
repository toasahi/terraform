"""Ingress synthetic heartbeat (Phase 2: Tokyo-internal; Phase 3: run from Osaka).

Posts a heartbeat alert through the PUBLIC ingress URL. Normalize enqueues it on
both paths; the routing tool turns each arrival into an IngressHeartbeat metric
(path=direct / path=keep). A missing metric fires the independent SNS alarm.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.request
from datetime import UTC, datetime

from alertpipe_common import KIND_HEARTBEAT
from alertpipe_common.metrics import emit
from alertpipe_common.secrets import get_json

logger = logging.getLogger()
logger.setLevel(logging.INFO)

INGRESS_URL = os.environ["INGRESS_ALERTS_URL"].rstrip("/")
SOURCE = os.environ.get("CANARY_SOURCE", "canary")
TOKENS_SECRET_ARN = os.environ["SOURCE_TOKENS_SECRET_ARN"]
CANARY_REGION = os.environ.get("CANARY_REGION", os.environ.get("AWS_REGION", ""))


def lambda_handler(_event: dict, _context) -> dict:
    now = datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    token = get_json(TOKENS_SECRET_ARN)[SOURCE]
    body = {
        "kind": KIND_HEARTBEAT,
        "name": "ingress-canary",
        "status": "firing",
        "severity": "info",
        "service": "alertpipe-canary",
        "fingerprint": f"canary-{CANARY_REGION}-{now}",
        "source_event_time": now,
        "labels": {"canary_region": CANARY_REGION},
    }
    req = urllib.request.Request(
        f"{INGRESS_URL}/{SOURCE}",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json", "X-Alert-Token": token},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:  # noqa: S310
            status = resp.status
    except Exception:  # noqa: BLE001
        logger.exception("canary post failed")
        emit("CanaryPostFailed", canary_region=CANARY_REGION)
        raise
    emit("CanaryPosted", canary_region=CANARY_REGION)
    return {"status": status, "emitted_at": now}
