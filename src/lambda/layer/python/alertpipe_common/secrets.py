"""Secrets Manager with a per-container cache."""

from __future__ import annotations

import json
import time

import boto3

_cache: dict[str, tuple[float, dict]] = {}
_client = None
_TTL = 300


def get_json(secret_arn: str) -> dict:
    global _client
    now = time.time()
    hit = _cache.get(secret_arn)
    if hit and hit[0] > now:
        return hit[1]
    if _client is None:
        _client = boto3.client("secretsmanager")
    value = json.loads(_client.get_secret_value(SecretId=secret_arn)["SecretString"])
    _cache[secret_arn] = (now + _TTL, value)
    return value
