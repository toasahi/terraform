"""Shared code for the alert pipeline Lambdas (packaged as a Lambda layer)."""

SCHEMA_VERSION = 1

ORIGIN_DIRECT = "direct"
ORIGIN_KEEP = "keep"

KIND_ALERT = "alert"
KIND_HEARTBEAT = "heartbeat"

STATUS_FIRING = "firing"
STATUS_RESOLVED = "resolved"
