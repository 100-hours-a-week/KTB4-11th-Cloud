"""Read-only DB recovery observer; never calls a DB, ECS mutation, or FIS action."""
import datetime as dt
import json
import math
import os
from pathlib import Path
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlencode
from urllib.request import Request, urlopen

GROUP = "/ecs/stockspoon-v2-prod/repman"
JOBS = 'job=~"mysql-(primary|private-replica)"'
WRITERS = 'timestamp(proxysql_connpool_conns_status{job="proxysql-fargate",hostgroup="10"} == 1)'
STATE = re.compile(r"Server ([0-9.]+:3306) state transition from (\w+) changed to: (\w+)")
SWITCH = re.compile(r"Master switch on ([0-9.]+:3306) complete")
SOURCE_TIME = re.compile(r'time="([^"]+)"')


def sample(name, value, **labels):
    if not math.isfinite(float(value)):
        raise ValueError("Non-finite metric")
    dimensions = {"environment": "prod", "cluster": "stockspoon", **labels}
    encoded = ",".join(f"{k}={json.dumps(str(v))}" for k, v in dimensions.items())
    return f"{name}{{{encoded}}} {float(value)}\n"


def classify(message):
    """Only emit allowlisted fields, never arbitrary log messages or credentials."""
    match = STATE.search(message)
    if match:
        endpoint, previous, current = match.groups()
        return {"event": "repman_server_state", "endpoint": endpoint,
                "previous_state": previous, "state": current, "timing": "source_log"}
    match = SWITCH.search(message)
    if match:
        # This line is used for both failover and planned switchover.
        return {"event": "repman_switch_complete", "endpoint": match[1], "timing": "source_log"}
    if 'msg="Failover proxies"' in message:
        return {"event": "repman_proxy_update_started", "endpoint": "cluster", "timing": "source_log"}
    return None


def event_time(entry):
    match = SOURCE_TIME.search(entry["message"])
    if match:
        return dt.datetime.fromisoformat(match[1].replace("Z", "+00:00")).timestamp()
    return entry["timestamp"] / 1000


class Observer:
    def __init__(self, directory, logs=None, query=None, push=None, clock=time.time):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.clock, self.logs, self.query, self.push = clock, logs, query, push
        self.path = self.directory / "state.json"
        self.state = json.loads(self.path.read_text()) if self.path.exists() else {
            "cursor_ms": 0, "seen": [], "servers": {}, "events": {}, "writer": None}
        self.health, self.writer_samples = {}, None
        self.lock = threading.RLock()

    def save(self):
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.state))
        temporary.replace(self.path)

    def emit(self, value):
        record = {"schema_version": 1, "environment": "prod", "cluster": "stockspoon",
                  "observed_at_seconds": self.clock(), **value}
        path = self.directory / "events.jsonl"
        if path.exists() and path.stat().st_size > 10 * 1024 * 1024:
            for index in range(4, 0, -1):
                older = self.directory / f"events.{index}.jsonl"
                if older.exists():
                    older.replace(self.directory / f"events.{index + 1}.jsonl")
            path.replace(self.directory / "events.1.jsonl")
        with path.open("a") as output:
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
        print(json.dumps(record, ensure_ascii=False), flush=True)
        key = record["event"] + "|" + record.get("endpoint", "cluster")
        previous = self.state["events"].get(key)
        if previous is None or record["source_timestamp_seconds"] >= previous["source_timestamp_seconds"]:
            self.state["events"][key] = record
        if self.push:
            try:
                self.push(record)
                self.health["loki"] = (True, self.clock())
            except Exception:
                # The durable local ledger and CloudWatch source remain available.
                self.health["loki"] = (False, self.clock())

    def collect_logs(self):
        now = self.clock()
        start = max(0, self.state["cursor_ms"] - 300000) if self.state["cursor_ms"] else int((now - 300) * 1000)
        seen = set(self.state["seen"])
        args = {"logGroupName": GROUP, "startTime": start, "endTime": int(now * 1000), "limit": 1000}
        new_ids, entries = [], []
        # Complete pagination before advancing the durable cursor.
        for _ in range(20):
            response = self.logs.filter_log_events(**args)
            entries.extend(response.get("events", []))
            token = response.get("nextToken")
            if not token:
                break
            args["nextToken"] = token
        else:
            raise RuntimeError("CloudWatch pagination budget exceeded")
        for entry in sorted(entries, key=lambda item: item["timestamp"]):
            event_id = entry["eventId"]
            if event_id in seen:
                continue
            seen.add(event_id)
            new_ids.append(event_id)
            value = classify(entry["message"])
            if value is None:
                continue
            at = event_time(entry)
            value.update(source_timestamp_seconds=at, cloudwatch_timestamp_seconds=entry["timestamp"] / 1000,
                         source_event_id=event_id, log_stream=entry.get("logStreamName", ""))
            if value["event"] == "repman_server_state":
                endpoint = value["endpoint"]
                old = self.state["servers"].get(endpoint)
                # Do not let late, old log events overwrite a more recent state.
                if old and at < old["source_timestamp_seconds"]:
                    continue
                self.state["servers"][endpoint] = value
                if old is None or old["state"] != value["state"]:
                    self.emit(value)
                if value["state"].lower() == "failed":
                    # Native state event, not a new failure on every poll.
                    if old is None or old["state"].lower() != "failed":
                        self.emit({**value, "event": "repman_node_failed"})
            else:
                self.emit(value)
        self.state["seen"] = (self.state["seen"] + new_ids)[-5000:]
        self.state["cursor_ms"] = int(now * 1000)
        self.health["repman_logs"] = (True, now)
        self.save()

    def collect_writer(self):
        result = self.query(WRITERS)
        now = self.clock()
        writers = sorted((row["metric"].get("instance", ""), row["metric"].get("endpoint", ""),
                          float(row["value"][1])) for row in result)
        if any(not endpoint or not math.isfinite(at) or now - at > 20 or at > now + 1
               for _, endpoint, at in writers):
            raise RuntimeError("Missing writer identity or stale ProxySQL samples")
        self.writer_samples = writers
        if len(writers) == 1:
            _, endpoint, at = writers[0]
            old = self.state["writer"]
            if old is not None and old["endpoint"] != endpoint:
                self.emit({"event": "proxysql_writer_observed", "endpoint": endpoint,
                           "previous_endpoint": old["endpoint"], "timing": "sampled",
                           "source_timestamp_seconds": at,
                           "previous_sample_timestamp_seconds": old["at"]})
            self.state["writer"] = {"endpoint": endpoint, "at": at}
        self.health["proxysql"] = (True, now)
        self.save()

    def update(self):
        with self.lock:
            for source, collector in [("repman_logs", self.collect_logs), ("proxysql", self.collect_writer)]:
                try:
                    collector()
                except Exception as error:
                    self.health[source] = (False, self.clock())
                    if source == "proxysql":
                        self.writer_samples = None
                    print(json.dumps({"event": "observer_collection_failed", "source": source,
                                      "error_type": type(error).__name__}), flush=True)

    def render(self):
        with self.lock:
            now = self.clock()
            lines = []
            for source in ["repman_logs", "proxysql"]:
                ok, at = self.health.get(source, (False, 0))
                lines.append(sample("stockspoon_db_fis_observer_source_up", int(ok and now - at < 30), source=source))
            if "loki" in self.health:
                ok, at = self.health["loki"]
                lines.append(sample("stockspoon_db_fis_loki_last_delivery_success", int(ok)))
                lines.append(sample("stockspoon_db_fis_loki_last_delivery_attempt_timestamp_seconds", at))
            logs_ok = self.health.get("repman_logs", (False, 0))
            if logs_ok[0] and now - logs_ok[1] < 30:
                for endpoint, value in self.state["servers"].items():
                    at = value["source_timestamp_seconds"]
                    lines.append(sample("stockspoon_db_fis_repman_last_state_timestamp_seconds", at, endpoint=endpoint))
                    if now - at < 90:
                        lines.append(sample("stockspoon_db_fis_repman_server_state", 1, endpoint=endpoint, state=value["state"]))
            for value in self.state["events"].values():
                if value["event"] != "repman_server_state":
                    lines.append(sample("stockspoon_db_fis_event_timestamp_seconds", value["source_timestamp_seconds"],
                                        event=value["event"], endpoint=value["endpoint"], timing=value["timing"]))
            return "".join(lines)


def main():
    import boto3
    from botocore.config import Config
    prom = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090")
    loki = os.environ.get("LOKI_URL", "http://loki:3100")

    def query(expression):
        with urlopen(prom + "/api/v1/query?" + urlencode({"query": expression}), timeout=5) as response:
            value = json.load(response)
        if value.get("status") != "success":
            raise RuntimeError("Prometheus query failed")
        return value["data"]["result"]

    def push(record):
        body = {"streams": [{"stream": {"job": "db-fis", "environment": "prod", "component": "observer"},
                              "values": [[str(int(record["source_timestamp_seconds"] * 1e9)), json.dumps(record)]]}]}
        request = Request(loki + "/loki/api/v1/push", data=json.dumps(body).encode(),
                          headers={"Content-Type": "application/json"})
        with urlopen(request, timeout=5) as response:
            response.read()

    logs = boto3.client("logs", region_name=os.environ.get("AWS_REGION", "ap-northeast-2"),
                        config=Config(connect_timeout=3, read_timeout=5, retries={"max_attempts": 1}))
    observer = Observer(os.environ.get("DATA_DIR", "/data"), logs, query, push)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/metrics":
                self.send_error(404)
                return
            payload = observer.render().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_):
            pass

    def refresh():
        while True:
            observer.update()
            time.sleep(5)

    threading.Thread(target=refresh, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 9191), Handler).serve_forever()


if __name__ == "__main__":
    main()
