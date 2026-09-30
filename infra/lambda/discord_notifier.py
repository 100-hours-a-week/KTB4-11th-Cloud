import json
import os
from datetime import datetime
import urllib.error
import urllib.parse
import urllib.request

import boto3


secrets_manager = boto3.client("secretsmanager")
ses = boto3.client("ses")


def _get_webhook_url():
    secret_arn = os.environ["DISCORD_WEBHOOK_SECRET_ARN"]
    response = secrets_manager.get_secret_value(SecretId=secret_arn)
    webhook_url = response.get("SecretString", "").strip()

    parsed_url = urllib.parse.urlparse(webhook_url)
    if (
        parsed_url.scheme != "https"
        or parsed_url.hostname not in {"discord.com", "discordapp.com"}
        or not parsed_url.path.startswith("/api/webhooks/")
    ):
        raise ValueError("The configured secret is not a valid Discord webhook URL")

    return webhook_url


def _alarm_details(event):
    alarm_data = event.get("alarmData", {})
    state_data = alarm_data.get("state", {})
    alarm_config = alarm_data.get("configuration", {})

    timestamp = state_data.get("timestamp") or event.get("time")
    if timestamp:
        try:
            timestamp = datetime.fromisoformat(
                timestamp.replace("Z", "+00:00")
            ).isoformat()
        except ValueError:
            timestamp = None

    return {
        "name": alarm_data.get("alarmName", "CloudWatch alarm"),
        "state": state_data.get("value", "UNKNOWN"),
        "reason": state_data.get("reason", "No alarm details were included."),
        "region": event.get("region", "ap-northeast-2"),
        "account": event.get("accountId", "unknown"),
        "timestamp": timestamp,
        "alarm_arn": event.get("alarmArn", "unknown"),
        "description": alarm_config.get("description", ""),
    }


def _discord_payload(alarm):
    colors = {
        "ALARM": 0xE74C3C,
        "OK": 0x2ECC71,
        "INSUFFICIENT_DATA": 0xF1C40F,
    }

    embed = {
        "title": f"{alarm['state']}: {alarm['name']}"[:256],
        "description": alarm["reason"][:4000],
        "color": colors.get(alarm["state"], 0x5865F2),
        "fields": [
            {"name": "Region", "value": alarm["region"], "inline": True},
            {"name": "Account", "value": alarm["account"], "inline": True},
            {"name": "Alarm", "value": alarm["alarm_arn"][:1024], "inline": False},
        ],
        "footer": {"text": "CloudWatch alarm notification"},
    }
    if alarm["description"]:
        embed["fields"].append(
            {"name": "Description", "value": alarm["description"][:1024], "inline": False}
        )
    if alarm["timestamp"]:
        embed["timestamp"] = alarm["timestamp"]

    return {
        "username": "Stockspoon CloudWatch",
        "allowed_mentions": {"parse": []},
        "embeds": [embed],
    }


def _send_discord(alarm):
    request = urllib.request.Request(
        _get_webhook_url(),
        data=json.dumps(_discord_payload(alarm)).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "StockspoonCloudWatchNotifier/1.0",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            if response.status < 200 or response.status >= 300:
                raise RuntimeError(f"Discord returned HTTP status {response.status}")
    except urllib.error.HTTPError as error:
        # Log only Discord's structured error fields. Never log the request URL,
        # which contains the webhook token.
        try:
            response_data = json.loads(error.read(4096).decode("utf-8", errors="replace"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            response_data = {}

        discord_code = response_data.get("code", "unknown")
        discord_message = str(response_data.get("message", "No message returned"))[:300]
        safe_header_names = ("Content-Type", "Server", "CF-Ray", "Via", "Retry-After")
        response_headers = {
            name.lower(): error.headers.get(name)
            for name in safe_header_names
            if error.headers and error.headers.get(name)
        }
        raise RuntimeError(
            f"Discord returned HTTP {error.code}; code={discord_code}; "
            f"message={discord_message}; headers={json.dumps(response_headers, sort_keys=True)}"
        ) from error


def _send_email(alarm):
    state = alarm["state"]
    subject = f"[{state}] {alarm['name']}"[:200]
    body = "\n".join(
        [
            f"CloudWatch alarm: {alarm['name']}",
            f"State: {state}",
            f"Region: {alarm['region']}",
            f"AWS account: {alarm['account']}",
            f"Time: {alarm['timestamp'] or 'unknown'}",
            f"Alarm ARN: {alarm['alarm_arn']}",
            f"Description: {alarm['description'] or 'none'}",
            "",
            f"Reason: {alarm['reason']}",
        ]
    )

    source = os.environ["SES_FROM_EMAIL"]
    recipient = os.environ["ALERT_EMAIL_RECIPIENT"]
    print(f"SES send attempt: From={source}")

    ses.send_email(
        Source=source,
        Destination={"ToAddresses": [recipient]},
        Message={
            "Subject": {"Data": subject, "Charset": "UTF-8"},
            "Body": {"Text": {"Data": body, "Charset": "UTF-8"}},
        },
    )


def handler(event, context):
    alarm = _alarm_details(event)
    errors = []

    # Try both destinations so a temporary failure in one does not prevent
    # the other notification from being attempted.
    for destination, send in (("Discord", _send_discord), ("SES email", _send_email)):
        try:
            send(alarm)
        except Exception as error:
            print(f"{destination} delivery failed: {type(error).__name__}: {error}")
            errors.append(destination)

    if errors:
        raise RuntimeError(f"Alarm notification delivery failed for: {', '.join(errors)}")

    return {"sent": ["discord", "ses_email"], "alarm": alarm["name"], "state": alarm["state"]}
