"""CloudWatch Embedded Metric Format emitter (no SDK calls, no extra latency)."""

from __future__ import annotations

import json
import os
import time

NAMESPACE = os.environ.get("METRICS_NAMESPACE", "AlertPipe")


def emit(metric: str, value: float = 1, unit: str = "Count", **dimensions: str) -> None:
    dims = {k: str(v) for k, v in dimensions.items()}
    dims.setdefault("Region", os.environ.get("AWS_REGION", "unknown"))
    payload = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": NAMESPACE,
                    "Dimensions": [list(dims.keys())],
                    "Metrics": [{"Name": metric, "Unit": unit}],
                }
            ],
        },
        metric: value,
        **dims,
    }
    print(json.dumps(payload))
