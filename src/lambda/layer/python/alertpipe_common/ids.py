"""Identifier derivation.

fingerprint   : what the alert is (from the source when it has one).
event_id      : one firing occurrence = fingerprint + firing start time.
transition_id : one firing/resolved transition = fingerprint + status + source event time.

All three are deterministic, so a duplicate delivery from a source (or a
replay from ingress.standard) produces the same identifiers and is rejected by
the Journal's conditional put. The direct path and the Keep path carry the
same values.
"""

from __future__ import annotations

import hashlib
import json


def _digest(*parts: str, length: int = 32) -> str:
    return hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()[:length]


def fingerprint_from_labels(source: str, labels: dict) -> str:
    canonical = json.dumps(labels, sort_keys=True, separators=(",", ":"))
    return _digest(source, canonical, length=40)


def event_id(fingerprint: str, firing_start: str) -> str:
    return _digest(fingerprint, firing_start)


def transition_id(fingerprint: str, status: str, source_event_time: str) -> str:
    return _digest(fingerprint, status, source_event_time)
