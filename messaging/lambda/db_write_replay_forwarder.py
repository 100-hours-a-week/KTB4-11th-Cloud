import json
import os
import urllib.error
import urllib.parse
import urllib.request

import boto3


secrets_manager = boto3.client("secretsmanager")
_cached_token = None


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


http_client = urllib.request.build_opener(_NoRedirectHandler())


def _endpoint_url():
    url = os.environ.get("DB_WRITE_REPLAY_ENDPOINT_URL", "").strip()
    parsed = urllib.parse.urlparse(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.fragment
    ):
        raise ValueError("DB_WRITE_REPLAY_ENDPOINT_URL must be an HTTPS URL")
    return url


def _bearer_token():
    global _cached_token
    if _cached_token is None:
        response = secrets_manager.get_secret_value(
            SecretId=os.environ["DB_WRITE_REPLAY_TOKEN_SECRET_ARN"]
        )
        _cached_token = response.get("SecretString", "").strip()
        if not _cached_token:
            raise ValueError("The DB write replay token secret is empty")
    return _cached_token


def _forward(record, endpoint, token):
    envelope = json.loads(record["body"])
    request_id = envelope.get("requestId")
    operation = envelope.get("operation")
    if not request_id or not operation:
        raise ValueError("SQS message is missing requestId or operation")

    request = urllib.request.Request(
        endpoint,
        data=json.dumps(envelope, separators=(",", ":")).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Idempotency-Key": request_id,
            "User-Agent": "StockSpoonDbWriteReplay/1.0",
        },
        method="POST",
    )

    try:
        with http_client.open(
            request,
            timeout=int(os.environ.get("DB_WRITE_REPLAY_HTTP_TIMEOUT_SECONDS", "20")),
        ) as response:
            if response.status < 200 or response.status >= 300:
                raise RuntimeError(
                    f"Backend replay endpoint returned HTTP {response.status}"
                )
    except urllib.error.HTTPError as error:
        # Avoid logging response bodies because they may contain request data.
        raise RuntimeError(
            f"Backend replay endpoint returned HTTP {error.code}"
        ) from error

    print(json.dumps({
        "event": "db_write_replay_forwarded",
        "requestId": request_id,
        "operation": operation,
        "sqsMessageId": record.get("messageId", "unknown"),
    }))


def handler(event, context):
    endpoint = _endpoint_url()
    token = _bearer_token()
    records = event.get("Records", [])

    # The event source mapping uses batch_size=1. If that ever changes, any
    # failure must fail the whole FIFO batch so later writes are not acknowledged.
    for record in records:
        _forward(record, endpoint, token)

    return {"forwarded": len(records)}
