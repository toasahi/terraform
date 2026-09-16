"""The common alert schema carried on every queue.

This is the only contract between Normalize, the Dispatcher, Keep's workflow
and the routing tool. Keep it additive.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime

from . import KIND_ALERT, SCHEMA_VERSION


def utcnow_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


@dataclass
class NormalizedAlert:
    event_id: str
    transition_id: str
    fingerprint: str
    name: str
    status: str
    severity: str
    service: str
    source: str
    source_event_time: str
    firing_start: str
    received_at: str
    origin: str
    kind: str = KIND_ALERT
    critical: bool = False
    description: str = ""
    url: str = ""
    labels: dict = field(default_factory=dict)
    region: str = ""
    schema_version: int = SCHEMA_VERSION

    def to_json(self) -> str:
        return json.dumps(asdict(self), separators=(",", ":"), ensure_ascii=False)

    @classmethod
    def from_dict(cls, data: dict) -> NormalizedAlert:
        known = {f for f in cls.__dataclass_fields__}  # type: ignore[attr-defined]
        clean = {k: v for k, v in data.items() if k in known}
        return cls(**clean)
