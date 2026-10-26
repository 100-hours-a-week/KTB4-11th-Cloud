"""Market-only ECS metadata exporter. Reads ECS APIs; never reads CloudWatch."""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGION = "ap-northeast-2"
ACCOUNT = "250832562715"
CLUSTER = "stockspoon-v2-prod-cluster"
SERVICE = "stockspoon-v2-prod-market-http"
SERVICE_ARN = f"arn:aws:ecs:{REGION}:{ACCOUNT}:service/{CLUSTER}/{SERVICE}"
LABELS = {"environment": "prod", "cluster": CLUSTER,
          "service_name": "market-http", "ecs_service": SERVICE}


def sample(name, value, labels=None):
    dimensions = LABELS | (labels or {})
    encoded = ",".join(f"{key}={json.dumps(value)}" for key, value in dimensions.items())
    return f"{name}{{{encoded}}} {float(value)}\n"


def collect(client):
    response = client.describe_services(cluster=CLUSTER, services=[SERVICE])
    if response.get("failures") or len(response.get("services", [])) != 1:
        raise ValueError("Cannot resolve approved market service")
    service = response["services"][0]
    if service.get("serviceArn") != SERVICE_ARN or service.get("status") != "ACTIVE":
        raise ValueError("Unexpected service identity or state")
    lines = []
    for state in ("desired", "running", "pending"):
        lines.append(sample(f"stockspoon_ecs_service_{state}_tasks", service[state + "Count"]))
    arns = []
    for page in client.get_paginator("list_tasks").paginate(
            cluster=CLUSTER, serviceName=SERVICE, desiredStatus="RUNNING"):
        arns.extend(page["taskArns"])
    observed = 0
    for index in range(0, len(arns), 100):
        response = client.describe_tasks(cluster=CLUSTER, tasks=arns[index:index + 100])
        if response.get("failures") or len(response.get("tasks", [])) != len(arns[index:index + 100]):
            raise ValueError("Incomplete Task metadata; do not publish partial capacity")
        for task in response["tasks"]:
            if task.get("group") != f"service:{SERVICE}":
                raise ValueError("Task outside approved market service")
            if task["lastStatus"] != "RUNNING":
                continue
            task_arn = task["taskArn"]
            if not task_arn.startswith(f"arn:aws:ecs:{REGION}:{ACCOUNT}:task/{CLUSTER}/"):
                raise ValueError("Task outside approved account or cluster")
            cpu = float(task.get("cpu") or 0) / 1024
            memory = float(task.get("memory") or 0) * 1024 * 1024
            if cpu <= 0 or memory <= 0:
                raise ValueError("Missing Task reservations; no guessed percentages")
            labels = {"task_id": task_arn.rsplit("/", 1)[1]}
            lines.append(sample("stockspoon_ecs_task_cpu_reserved_cores", cpu, labels))
            lines.append(sample("stockspoon_ecs_task_memory_reserved_bytes", memory, labels))
            observed += 1
    lines.append(sample("stockspoon_ecs_observed_running_tasks", observed))
    return "".join(lines)


class Cache:
    def __init__(self):
        self.lock = threading.Lock()
        self.payload = ""
        self.success = False
        self.last_success = 0

    def update(self, client):
        try:
            payload = collect(client)
        except Exception as error:
            # No API responses, container environment or credentials in logs.
            print(json.dumps({"collection_error": type(error).__name__}), flush=True)
            with self.lock:
                self.success, self.payload = False, ""
            return
        with self.lock:
            self.payload, self.success, self.last_success = payload, True, time.time()

    def render(self):
        with self.lock:
            healthy = self.success and time.time() - self.last_success <= 75
            return (sample("stockspoon_ecs_collector_success", int(healthy))
                    + sample("stockspoon_ecs_collector_last_success_timestamp_seconds", self.last_success)
                    + (self.payload if healthy else ""))


def main():
    import boto3
    from botocore.config import Config
    client = boto3.client("ecs", region_name=REGION, config=Config(
        connect_timeout=3, read_timeout=5, retries={"total_max_attempts": 2}))
    cache = Cache()

    def refresh():
        while True:
            cache.update(client)
            time.sleep(30)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/metrics":
                self.send_error(404)
                return
            payload = cache.render().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_):
            pass

    threading.Thread(target=refresh, daemon=True).start()
    ThreadingHTTPServer((os.environ.get("BIND_HOST", "0.0.0.0"), 9190), Handler).serve_forever()


if __name__ == "__main__":
    main()
