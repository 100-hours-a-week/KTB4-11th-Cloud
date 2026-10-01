import json
import os
from datetime import datetime
import time
import urllib.error
import urllib.parse
import urllib.request

import boto3


secrets_manager = boto3.client("secretsmanager")
ssm = boto3.client("ssm")

DOCKER_STATS_ALARM_KEYWORDS = ("cpu", "container")
DOCKER_DIAGNOSTIC_COMMANDS = [
    "set -e",
    "printf 'CONTAINER STATUS\\n'",
    "docker ps -a --format 'table {{.Names}}\\t{{.Status}}\\t{{.Image}}'",
    "printf '\\nRESOURCE SNAPSHOT\\n'",
    (
        "docker stats --no-stream --format "
        "'table {{.Name}}\\t{{.CPUPerc}}\\t{{.MemUsage}}\\t{{.MemPerc}}"
        "\\t{{.NetIO}}\\t{{.BlockIO}}\\t{{.PIDs}}'"
    ),
]
SSM_TERMINAL_STATUSES = {
    "Success",
    "Cancelled",
    "TimedOut",
    "Failed",
    "Cancelling",
}


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
        "name": alarm_data.get("alarmName", "AI CloudWatch alarm"),
        "state": state_data.get("value", "UNKNOWN"),
        "reason": state_data.get("reason", "No alarm details were included."),
        "region": event.get("region", "ap-northeast-2"),
        "account": event.get("accountId", "unknown"),
        "timestamp": timestamp,
        "alarm_arn": event.get("alarmArn", "unknown"),
        "description": alarm_config.get("description", ""),
    }


def _should_collect_docker_stats(alarm):
    if alarm["state"] != "ALARM":
        return False

    alarm_name = alarm["name"].lower()
    return any(keyword in alarm_name for keyword in DOCKER_STATS_ALARM_KEYWORDS)


def _collect_docker_stats():
    instance_id = os.environ["AI_INSTANCE_ID"]
    response = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": DOCKER_DIAGNOSTIC_COMMANDS},
        TimeoutSeconds=30,
        Comment="Collect Docker stats for an AI CloudWatch alarm",
    )
    command_id = response["Command"]["CommandId"]
    deadline = time.monotonic() + 12

    while time.monotonic() < deadline:
        try:
            invocation = ssm.get_command_invocation(
                CommandId=command_id,
                InstanceId=instance_id,
            )
        except ssm.exceptions.InvocationDoesNotExist:
            time.sleep(1)
            continue

        status = invocation["Status"]
        if status not in SSM_TERMINAL_STATUSES:
            time.sleep(1)
            continue

        stdout = invocation.get("StandardOutputContent", "").strip()
        stderr = invocation.get("StandardErrorContent", "").strip()
        if status == "Success":
            return stdout or "No running containers were returned."

        detail = stderr or stdout or "No command output was returned."
        return f"Collection failed ({status}): {detail}"

    return "Collection timed out while waiting for SSM Run Command."


def _docker_stats_content(docker_stats):
    if not docker_stats:
        return None

    # Discord content is limited to 2,000 characters. Keep room for the title
    # and code fences, and prevent command errors from closing the code block.
    safe_stats = docker_stats.replace("```", "'''")
    max_stats_length = 1900
    if len(safe_stats) > max_stats_length:
        safe_stats = f"{safe_stats[:max_stats_length - 16]}\n... (truncated)"

    return f"**AI EC2 Docker diagnostics**\n```text\n{safe_stats}\n```"


def _discord_payload(alarm, docker_stats=None):
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
            {"name": "Server", "value": "AI", "inline": True},
            {"name": "Region", "value": alarm["region"], "inline": True},
            {"name": "Account", "value": alarm["account"], "inline": True},
            {"name": "Alarm", "value": alarm["alarm_arn"][:1024], "inline": False},
        ],
        "footer": {"text": "Stockspoon AI CloudWatch alarm"},
    }
    if alarm["description"]:
        embed["fields"].append(
            {"name": "Description", "value": alarm["description"][:1024], "inline": False}
        )
    if alarm["timestamp"]:
        embed["timestamp"] = alarm["timestamp"]

    payload = {
        "username": "Stockspoon AI CloudWatch",
        "allowed_mentions": {"parse": []},
        "embeds": [embed],
    }
    content = _docker_stats_content(docker_stats)
    if content:
        payload["content"] = content

    return payload


def _send_discord(alarm, docker_stats=None):
    request = urllib.request.Request(
        _get_webhook_url(),
        data=json.dumps(_discord_payload(alarm, docker_stats)).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "StockspoonAICloudWatchNotifier/1.0",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            if response.status < 200 or response.status >= 300:
                raise RuntimeError(f"Discord returned HTTP status {response.status}")
    except urllib.error.HTTPError as error:
        try:
            response_data = json.loads(error.read(4096).decode("utf-8", errors="replace"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            response_data = {}

        discord_code = response_data.get("code", "unknown")
        discord_message = str(response_data.get("message", "No message returned"))[:300]
        raise RuntimeError(
            f"Discord returned HTTP {error.code}; code={discord_code}; "
            f"message={discord_message}"
        ) from error


def handler(event, context):
    alarm = _alarm_details(event)
    docker_stats = None
    if _should_collect_docker_stats(alarm):
        try:
            docker_stats = _collect_docker_stats()
        except Exception as error:
            # The primary alarm must still be delivered when the instance is
            # unreachable or SSM/Docker is temporarily unavailable.
            print(f"Docker stats collection failed: {type(error).__name__}: {error}")
            docker_stats = f"Collection failed: {type(error).__name__}: {error}"

    _send_discord(alarm, docker_stats)
    return {
        "sent": ["discord"],
        "alarm": alarm["name"],
        "state": alarm["state"],
        "docker_stats_included": docker_stats is not None,
    }
