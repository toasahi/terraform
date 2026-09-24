"""Source adapters: raw payload -> list of NormalizedAlert.

Add a function per source family and register it in ADAPTERS. Unknown
sources fall back to the generic schema (the format the canary and any
in-house sender use).
"""

from __future__ import annotations

import hashlib
import os
from datetime import UTC, datetime

from alertpipe_common import KIND_ALERT, KIND_HEARTBEAT, ORIGIN_DIRECT, STATUS_FIRING, STATUS_RESOLVED
from alertpipe_common.ids import event_id, fingerprint_from_labels, transition_id
from alertpipe_common.schema import NormalizedAlert, utcnow_iso

SEVERITY_LABEL = os.environ.get("SEVERITY_LABEL", "severity")
SERVICE_LABEL = os.environ.get("SERVICE_LABEL", "service")
CRITICAL_SEVERITIES = {s.strip().lower() for s in os.environ.get("CRITICAL_SEVERITIES", "critical,page,p1,sev1").split(",")}
CLOUDWATCH_DEFAULT_SEVERITY = os.environ.get("CLOUDWATCH_DEFAULT_SEVERITY", "warning")
REGION = os.environ.get("AWS_REGION", "")

_SEVERITY_MAP = {
    "critical": "critical",
    "page": "critical",
    "p1": "critical",
    "sev1": "critical",
    "high": "high",
    "p2": "high",
    "sev2": "high",
    "error": "high",
    "warning": "warning",
    "warn": "warning",
    "p3": "warning",
    "info": "info",
    "informational": "info",
    "low": "low",
    "none": "info",
}


class Skip(Exception):
    """Raised by an adapter for a payload that carries no transition (e.g. INSUFFICIENT_DATA)."""


def normalize_severity(raw: str | None) -> tuple[str, bool]:
    key = (raw or "").strip().lower()
    if key in CRITICAL_SEVERITIES:
        return "critical", True
    return _SEVERITY_MAP.get(key, "warning"), False


def _iso(value: str | None) -> str:
    """Normalize RFC3339 timestamps (Alertmanager uses nanoseconds and 0001-01-01 for 'unset')."""
    if not value or value.startswith("0001-01-01"):
        return utcnow_iso()
    v = value.replace("Z", "+00:00")
    if "." in v:
        head, _, tail = v.partition(".")
        frac = "".join(ch for ch in tail if ch.isdigit())[:6]
        tz = tail[len("".join(ch for ch in tail if ch.isdigit())) :]
        v = f"{head}.{frac}{tz}"
    try:
        dt = datetime.fromisoformat(v)
    except ValueError:
        return utcnow_iso()
    return dt.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _build(
    *,
    source: str,
    fingerprint: str,
    name: str,
    status: str,
    severity_raw: str | None,
    service: str,
    source_event_time: str,
    firing_start: str,
    description: str = "",
    url: str = "",
    labels: dict | None = None,
    kind: str = KIND_ALERT,
) -> NormalizedAlert:
    severity, critical = normalize_severity(severity_raw)
    if kind == KIND_HEARTBEAT:
        critical = False
    labels = dict(labels or {})
    return NormalizedAlert(
        event_id=event_id(fingerprint, firing_start),
        transition_id=transition_id(fingerprint, status, source_event_time),
        fingerprint=fingerprint,
        name=name,
        status=status,
        severity=severity,
        service=service or "unknown",
        source=source,
        source_event_time=source_event_time,
        firing_start=firing_start,
        received_at=utcnow_iso(),
        origin=ORIGIN_DIRECT,
        kind=kind,
        critical=critical,
        description=description or "",
        url=url or "",
        labels=labels,
        region=REGION,
    )


# ---- Alertmanager webhook -------------------------------------------------------------


def alertmanager(source: str, payload: dict) -> list[NormalizedAlert]:
    out: list[NormalizedAlert] = []
    for alert in payload.get("alerts", []):
        labels = alert.get("labels", {}) or {}
        annotations = alert.get("annotations", {}) or {}
        status = STATUS_RESOLVED if alert.get("status") == "resolved" else STATUS_FIRING
        starts = _iso(alert.get("startsAt"))
        ends = _iso(alert.get("endsAt")) if status == STATUS_RESOLVED else starts
        fingerprint = alert.get("fingerprint") or fingerprint_from_labels(source, labels)
        out.append(
            _build(
                source=source,
                fingerprint=f"{source}:{fingerprint}",
                name=labels.get("alertname", "unknown"),
                status=status,
                severity_raw=labels.get(SEVERITY_LABEL),
                service=labels.get(SERVICE_LABEL) or labels.get("namespace") or labels.get("job", ""),
                source_event_time=ends if status == STATUS_RESOLVED else starts,
                firing_start=starts,
                description=annotations.get("description") or annotations.get("summary") or "",
                url=alert.get("generatorURL", ""),
                labels=labels,
            )
        )
    return out


# ---- CloudWatch alarm state change (EventBridge -> API destination, or SNS envelope) ----


def cloudwatch(source: str, payload: dict) -> list[NormalizedAlert]:
    if "Message" in payload and isinstance(payload["Message"], str):  # SNS envelope
        import json

        payload = json.loads(payload["Message"])
    detail = payload.get("detail") or payload
    name = detail.get("alarmName") or payload.get("AlarmName")
    if not name:
        raise ValueError("cloudwatch payload without alarmName")
    state = (detail.get("state") or {}).get("value") or payload.get("NewStateValue")
    prev = (detail.get("previousState") or {}).get("value") or payload.get("OldStateValue")
    ts = (detail.get("state") or {}).get("timestamp") or payload.get("StateChangeTime")
    prev_ts = (detail.get("previousState") or {}).get("timestamp")
    if state == "INSUFFICIENT_DATA" or (state == "OK" and prev != "ALARM"):
        raise Skip(f"{name}: {prev} -> {state}")
    status = STATUS_FIRING if state == "ALARM" else STATUS_RESOLVED
    account = payload.get("account") or payload.get("AWSAccountId", "")
    region = payload.get("region") or payload.get("Region", "")
    fingerprint = "cloudwatch:" + hashlib.sha256(f"{account}|{region}|{name}".encode()).hexdigest()[:40]
    when = _iso(ts)
    firing_start = when if status == STATUS_FIRING else _iso(prev_ts)
    severity = "critical" if "critical" in name.lower() else CLOUDWATCH_DEFAULT_SEVERITY
    config = detail.get("configuration") or {}
    return [
        _build(
            source=source,
            fingerprint=fingerprint,
            name=name,
            status=status,
            severity_raw=severity,
            service=(config.get("description") or "").split(":")[0].strip() or "cloudwatch",
            source_event_time=when,
            firing_start=firing_start,
            description=(detail.get("state") or {}).get("reason") or payload.get("NewStateReason", ""),
            labels={"account": account, "region": region, "alarm": name},
        )
    ]


# ---- Generic (canary, in-house senders) -------------------------------------------------
# {"name","status","severity","service","fingerprint"?,"labels"?,"description"?,"url"?,
#  "source_event_time"?,"firing_start"?,"kind"?}


def generic(source: str, payload: dict) -> list[NormalizedAlert]:
    items = payload.get("alerts") if isinstance(payload.get("alerts"), list) else [payload]
    out = []
    for a in items:
        name = a.get("name") or a.get("alertname")
        if not name:
            raise ValueError("generic payload without name")
        labels = a.get("labels") or {}
        status = STATUS_RESOLVED if str(a.get("status", "firing")).lower() == "resolved" else STATUS_FIRING
        when = _iso(a.get("source_event_time"))
        firing_start = _iso(a.get("firing_start")) if a.get("firing_start") else when
        fingerprint = a.get("fingerprint") or fingerprint_from_labels(
            source, {"name": name, "service": a.get("service", ""), **labels}
        )
        out.append(
            _build(
                source=source,
                fingerprint=f"{source}:{fingerprint}",
                name=name,
                status=status,
                severity_raw=a.get("severity") or labels.get(SEVERITY_LABEL),
                service=a.get("service") or labels.get(SERVICE_LABEL, ""),
                source_event_time=when,
                firing_start=firing_start,
                description=a.get("description", ""),
                url=a.get("url", ""),
                labels=labels,
                kind=KIND_HEARTBEAT if a.get("kind") == KIND_HEARTBEAT else KIND_ALERT,
            )
        )
    return out


ADAPTERS = {
    "alertmanager": alertmanager,
    "cloudwatch": cloudwatch,
}


def adapt(source: str, payload: dict) -> list[NormalizedAlert]:
    for prefix, fn in ADAPTERS.items():
        if source == prefix or source.startswith(prefix + "-"):
            return fn(source, payload)
    return generic(source, payload)
