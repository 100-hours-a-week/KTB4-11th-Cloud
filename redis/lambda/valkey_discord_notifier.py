import json
import os
from datetime import datetime
import urllib.error
import urllib.parse
import urllib.request

import boto3


secrets_manager = boto3.client("secretsmanager")


def _get_webhook_url():
    response = secrets_manager.get_secret_value(
        SecretId=os.environ["DISCORD_WEBHOOK_SECRET_ARN"]
    )
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
        "name": alarm_data.get("alarmName", "Valkey CloudWatch alarm"),
        "state": state_data.get("value", "UNKNOWN"),
        "reason": state_data.get("reason", "No alarm details were included."),
        "description": alarm_config.get("description", ""),
        "region": event.get("region", "unknown"),
        "account": event.get("accountId", "unknown"),
        "alarm_arn": event.get("alarmArn", "unknown"),
        "timestamp": timestamp,
    }


def _discord_payload(alarm):
    embed = {
        "title": f"ALARM: {alarm['name']}"[:256],
        "description": alarm["reason"][:4000],
        "color": 0xE74C3C,
        "fields": [
            {"name": "Region", "value": alarm["region"], "inline": True},
            {"name": "Account", "value": alarm["account"], "inline": True},
            {"name": "Alarm", "value": alarm["alarm_arn"][:1024]},
        ],
        "footer": {"text": "StockSpoon Valkey alarm"},
    }

    if alarm["description"]:
        embed["fields"].append(
            {"name": "Description", "value": alarm["description"][:1024]}
        )
    if alarm["timestamp"]:
        embed["timestamp"] = alarm["timestamp"]

    return {
        "username": "StockSpoon Valkey",
        "allowed_mentions": {"parse": []},
        "embeds": [embed],
    }


def handler(event, context):
    alarm = _alarm_details(event)
    if alarm["state"] != "ALARM":
        return {"sent": False, "alarm": alarm["name"], "state": alarm["state"]}

    request = urllib.request.Request(
        _get_webhook_url(),
        data=json.dumps(_discord_payload(alarm)).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "StockSpoonValkeyAlarm/1.0",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            if response.status < 200 or response.status >= 300:
                raise RuntimeError(f"Discord returned HTTP status {response.status}")
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Discord returned HTTP {error.code}") from error

    return {"sent": True, "alarm": alarm["name"], "state": alarm["state"]}
