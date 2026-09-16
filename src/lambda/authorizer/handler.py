"""API Gateway REQUEST authorizer.

Validates the X-Alert-Token header against the per-source token stored in
Secrets Manager ({"<source>": "<token>", ...}) and returns an IAM policy that
only allows POST on /v1/alerts/<source>. Because API Gateway caches the policy
by token value, a token can never be reused for another source's path.
Self-contained: no layer dependency, so the ingress module can be applied
before the pipeline layer exists.
"""

from __future__ import annotations

import hmac
import json
import logging
import os
import time

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SECRET_ARN = os.environ["SOURCE_TOKENS_SECRET_ARN"]
TOKEN_HEADER = os.environ.get("TOKEN_HEADER", "x-alert-token").lower()

_secrets = boto3.client("secretsmanager")
_cache: dict | None = None
_cache_expiry = 0.0


def _tokens() -> dict:
    global _cache, _cache_expiry
    if _cache is None or time.time() > _cache_expiry:
        _cache = json.loads(_secrets.get_secret_value(SecretId=SECRET_ARN)["SecretString"])
        _cache_expiry = time.time() + 300
    return _cache


def _policy(effect: str, resource: str, source: str) -> dict:
    return {
        "principalId": source,
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [{"Action": "execute-api:Invoke", "Effect": effect, "Resource": resource}],
        },
        "context": {"source": source},
    }


def lambda_handler(event: dict, _context) -> dict:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    presented = headers.get(TOKEN_HEADER, "")
    source = (event.get("pathParameters") or {}).get("source", "")
    method_arn: str = event["methodArn"]

    # arn:aws:execute-api:region:acct:apiId/stage/POST/v1/alerts/<source>
    arn_prefix, _, path = method_arn.partition("/")
    stage = path.split("/")[0]
    scoped_resource = f"{arn_prefix}/{stage}/POST/v1/alerts/{source}"

    expected = _tokens().get(source)
    if not source or not expected or not hmac.compare_digest(presented, expected):
        logger.info(json.dumps({"auth": "deny", "source": source or None}))
        raise Exception("Unauthorized")

    logger.info(json.dumps({"auth": "allow", "source": source}))
    return _policy("Allow", scoped_resource, source)
