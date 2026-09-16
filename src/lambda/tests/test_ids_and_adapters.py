import json

import pytest

import adapters
from alertpipe_common.ids import event_id, transition_id

AM_PAYLOAD = {
    "version": "4",
    "status": "firing",
    "alerts": [
        {
            "status": "firing",
            "labels": {"alertname": "PodCrashLooping", "severity": "critical", "service": "payments"},
            "annotations": {"description": "pod restarted 5 times"},
            "startsAt": "2026-09-16T10:00:00.123456789Z",
            "endsAt": "0001-01-01T00:00:00Z",
            "generatorURL": "http://prom/graph",
            "fingerprint": "abc123",
        }
    ],
}


def test_ids_are_deterministic():
    assert event_id("fp", "t0") == event_id("fp", "t0")
    assert transition_id("fp", "firing", "t0") != transition_id("fp", "resolved", "t1")


def test_alertmanager_critical_and_ids():
    alerts = adapters.alertmanager("alertmanager", AM_PAYLOAD)
    assert len(alerts) == 1
    a = alerts[0]
    assert a.critical is True and a.severity == "critical"
    assert a.service == "payments"
    assert a.fingerprint == "alertmanager:abc123"
    assert a.source_event_time == "2026-09-16T10:00:00.123Z"
    assert a.firing_start == a.source_event_time
    # a repeat delivery of the same firing produces the same transition
    again = adapters.alertmanager("alertmanager", AM_PAYLOAD)[0]
    assert (again.event_id, again.transition_id) == (a.event_id, a.transition_id)


def test_alertmanager_resolved_shares_event_id():
    firing = adapters.alertmanager("alertmanager", AM_PAYLOAD)[0]
    resolved_payload = json.loads(json.dumps(AM_PAYLOAD))
    resolved_payload["alerts"][0]["status"] = "resolved"
    resolved_payload["alerts"][0]["endsAt"] = "2026-09-16T10:30:00Z"
    resolved = adapters.alertmanager("alertmanager", resolved_payload)[0]
    assert resolved.status == "resolved"
    assert resolved.event_id == firing.event_id
    assert resolved.transition_id != firing.transition_id


def test_refire_after_resolve_is_new_event():
    first = adapters.alertmanager("alertmanager", AM_PAYLOAD)[0]
    later = json.loads(json.dumps(AM_PAYLOAD))
    later["alerts"][0]["startsAt"] = "2026-09-16T11:00:00Z"
    second = adapters.alertmanager("alertmanager", later)[0]
    assert second.event_id != first.event_id


def test_cloudwatch_alarm_state_change():
    payload = {
        "detail-type": "CloudWatch Alarm State Change",
        "account": "123456789012",
        "region": "ap-northeast-1",
        "detail": {
            "alarmName": "critical-rds-cpu",
            "state": {"value": "ALARM", "timestamp": "2026-09-16T10:00:00.000+0000", "reason": "cpu"},
            "previousState": {"value": "OK", "timestamp": "2026-09-16T09:00:00.000+0000"},
            "configuration": {"description": "payments: primary db"},
        },
    }
    a = adapters.cloudwatch("cloudwatch", payload)[0]
    assert a.critical is True
    assert a.service == "payments"
    assert a.status == "firing"


def test_cloudwatch_insufficient_data_is_skipped():
    payload = {"detail": {"alarmName": "x", "state": {"value": "INSUFFICIENT_DATA"}, "previousState": {"value": "OK"}}}
    with pytest.raises(adapters.Skip):
        adapters.cloudwatch("cloudwatch", payload)


def test_generic_heartbeat_is_never_critical():
    a = adapters.generic(
        "canary",
        {
            "kind": "heartbeat",
            "name": "ingress-canary",
            "status": "firing",
            "severity": "critical",
            "service": "alertpipe-canary",
            "source_event_time": "2026-09-16T10:00:00Z",
        },
    )[0]
    assert a.kind == "heartbeat" and a.critical is False


def test_keep_payload_carries_ids_in_labels():
    from handler import to_keep_alert  # keep_dispatcher/handler.py

    a = adapters.alertmanager("alertmanager", AM_PAYLOAD)[0]
    body = to_keep_alert(a)
    assert body["labels"]["transition_id"] == a.transition_id
    assert body["fingerprint"] == a.fingerprint
    assert body["severity"] == "critical"
