#!/usr/bin/env python3
"""Finite client measurement runner. Never calls AWS or injects a fault."""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid

from model import State, event_lines, make_plan, report, validate_plan

ROOT = Path(__file__).resolve().parent


def write_json(path, data):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    tmp.replace(path)


def read_json(path):
    return json.loads(Path(path).read_text())


def now_ms():
    return int(time.time() * 1000)


def active_k6():
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if (proc / "comm").read_text().strip() in {"k6-sse", "k6"}:
                return int(proc.name)
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
    return None


def run_dir(args):
    return Path(args.run).resolve() if args.run else Path(read_json(ROOT / "runtime/latest.json")["run"])


def read_markers(folder):
    path = folder / "markers.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def resources(previous):
    stat = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
    ticks = list(map(int, stat))[:8]
    total, idle = sum(ticks), ticks[3] + ticks[4]
    cpu = None
    if previous and total > previous[0]:
        cpu = 100 * (1 - (idle - previous[1]) / (total - previous[0]))
    mem = {line.split(":")[0]: int(line.split()[1]) for line in Path("/proc/meminfo").read_text().splitlines()}
    return {"at_ms": now_ms(), "cpu_percent": cpu,
            "available_mb": mem["MemAvailable"] / 1024,
            "disk_free_gb": shutil.disk_usage(ROOT).free / (1024 ** 3)}, (total, idle)


def worker(folder):
    folder = Path(folder).resolve()
    plan = read_json(folder / "plan.json")
    validate_plan(plan)
    (ROOT / "runtime").mkdir(exist_ok=True)
    state = {"running": True, "phase": "starting", "run": str(folder), "test_id": plan["test_id"],
             "ready_for_manual_fault": False, "safety_coverage": "external ECS/Valkey/FIS guard required"}
    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append("operator_signal"))
    signal.signal(signal.SIGINT, lambda *_: stopping.append("operator_signal"))
    lock = (ROOT / "runtime/active.lock").open("a+")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        state.update(running=False, phase="rejected", reason="another FIS worker owns the lock")
        write_json(folder / "status.json", state)
        return 2
    other = active_k6()
    if other:
        state.update(running=False, phase="rejected", reason=f"another k6 process is running: {other}")
        write_json(folder / "status.json", state)
        return 2
    event_path = folder / "events.log"
    event_path.touch(exist_ok=False)
    env = {**os.environ, "FIS_PLAN": str(folder / "plan.json"), "FIS_SUMMARY": str(folder / "k6-summary.json"),
           "K6_NO_USAGE_REPORT": "true"}
    write_json(folder / "k6-config.json", {})
    command = [plan["binary"], "run", "--config", str(folder / "k6-config.json"),
               "--quiet", "--log-format", "raw", "--console-output", str(event_path),
               str(ROOT / "sse.js")]
    write_json(folder / "command.json", {"command": command, "aws_operations": []})
    with (folder / "process.log").open("w") as output:
        child = subprocess.Popen(command, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        start_mono, start_wall = time.monotonic(), now_ms()
        state.update(pid=os.getpid(), k6_pid=child.pid, started_at_ms=start_wall)
        state_model = State(plan["max_source_age_ms"], plan["max_future_skew_ms"],
                            plan["snapshot_interval_ms"] * 3)
        events = []
        previous = None
        hot_since = None
        reason = "execution_budget_ended"
        deadline = start_mono + plan["budget_seconds"]
        last_sample = 0
        current_markers = []
        baseline_since = None
        first_configured_at = None
        partial = ""
        reader = event_path.open()
        try:
            while child.poll() is None:
                mono, wall = time.monotonic(), now_ms()
                elapsed = mono - start_mono
                text = partial + reader.read()
                lines = text.split("\n")
                partial = lines.pop()
                try:
                    for event in event_lines(lines):
                        events.append(event)
                        state_model.feed(event)
                except (ValueError, KeyError, TypeError) as exc:
                    reason = f"safety:invalid_measurement_event:{exc}"
                    break
                current_markers = read_markers(folder)
                fault = next((m for m in current_markers if m["event"] == "fault-start"), None)
                stop = next((m for m in current_markers if m["event"] == "safety-stop"), None)
                measured = state_model.snapshot(wall)
                baseline_end = plan["ramp_seconds"] + plan["baseline_seconds"]
                configured = (elapsed >= plan["ramp_seconds"]
                              and measured["connected_clients"] == plan["connections"])
                if configured and first_configured_at is None:
                    first_configured_at = mono
                baseline_since = (baseline_since if baseline_since is not None else mono) if configured else None
                stable_seconds = mono - baseline_since if baseline_since is not None else 0
                observed_seconds = mono - first_configured_at if first_configured_at is not None else 0
                ready = configured and observed_seconds >= plan["baseline_seconds"]
                if ready and "baseline_ready_at_ms" not in state:
                    state["baseline_ready_at_ms"] = wall
                state.update(measured, elapsed_seconds=round(elapsed, 2), updated_at_ms=wall,
                             connection_baseline_seconds=round(stable_seconds, 2),
                             baseline_observation_seconds=round(observed_seconds, 2),
                             ready_for_manual_fault=bool(ready and not fault and plan["mode"] == "fault"))
                if elapsed < plan["ramp_seconds"]:
                    state["phase"] = "ramp"
                elif elapsed < baseline_end:
                    state["phase"] = "baseline"
                elif fault:
                    state["phase"] = "observe"
                else:
                    state["phase"] = "awaiting_manual_fault" if plan["mode"] == "fault" else "baseline"
                if mono - last_sample >= 5:
                    resource, previous = resources(previous)
                    with (folder / "generator.jsonl").open("a") as f:
                        f.write(json.dumps(resource) + "\n")
                    state["generator"] = resource
                    last_sample = mono
                    if resource["available_mb"] < 256 or resource["disk_free_gb"] < 1:
                        reason = "safety:generator_memory_or_disk"
                        break
                    if resource["cpu_percent"] is not None and resource["cpu_percent"] > 95:
                        hot_since = hot_since or mono
                        if mono - hot_since >= 30:
                            reason = "safety:generator_cpu"
                            break
                    else:
                        hot_since = None
                write_json(folder / "status.json", state)
                with (folder / "observations.jsonl").open("a") as f:
                    f.write(json.dumps({"at_ms": wall, "phase": state["phase"], **measured}) + "\n")
                if abs(wall - start_wall - (mono - start_mono) * 1000) > 1000:
                    reason = "safety:clock_shift_over_1s"
                    break
                if state_model.bad_payloads:
                    reason = "safety:invalid_payload"
                    break
                if stop:
                    reason = "safety:" + stop.get("note", "external_guard")
                    break
                if stopping or (folder / "stop.request").exists():
                    reason = "operator_stop"
                    break
                if fault:
                    # Convert the recorded wall-time action marker to our monotonic observation budget.
                    observe_end = start_mono + (fault["at_ms"] - start_wall) / 1000 + plan["observe_seconds"]
                    if mono >= min(deadline, observe_end):
                        reason = "observation_window_ended"
                        break
                elif plan["mode"] == "fault" and elapsed >= baseline_end + plan["fault_wait_seconds"]:
                    reason = "no_manual_fault_marker"
                    break
                if mono >= deadline:
                    reason = "baseline_completed" if plan["mode"] == "baseline" else "execution_budget_ended"
                    break
                time.sleep(1)
        finally:
            end_ms = now_ms()
            # Freeze the input before stopping our own client. A SIGINT teardown can
            # emit disconnects in the same millisecond and must not become an outage.
            for event in event_lines((partial + reader.read()).splitlines()):
                if event["at_ms"] < end_ms:
                    events.append(event)
            reader.close()
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGINT)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=3)
            if reason == "execution_budget_ended" and child.returncode not in (0, 105, -signal.SIGINT):
                reason = f"runner_exit:{child.returncode}"
            result = report(events, read_markers(folder), end_ms, reason, plan["max_source_age_ms"])
            result.update(test_id=plan["test_id"], k6_exit_code=child.returncode,
                          measurement_clock="generator wall clock; monotonic drift checked; raw timestamps retained")
            write_json(folder / "result.json", result)
            state.update(running=False, ready_for_manual_fault=False, phase="finished", ended_at_ms=end_ms,
                         reason=reason, outcome=result["outcome"])
            write_json(folder / "status.json", state)
            lock.close()
    return 0


def start(args):
    plan = read_json(args.plan)
    validate_plan(plan)
    binary = str(Path(args.binary).resolve())
    if not os.access(binary, os.X_OK):
        raise ValueError(f"executable k6-sse not found: {binary}")
    if active_k6():
        raise ValueError("another k6 is running; existing workloads are never stopped by this tool")
    folder = ROOT / "results" / (plan.get("experiment", "T1").lower() + dt.datetime.now(dt.timezone.utc).strftime("-%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:6])
    folder.mkdir(parents=True, exist_ok=False)
    plan.update(binary=binary, test_id=folder.name)
    write_json(folder / "plan.json", plan)
    write_json(folder / "status.json", {"running": True, "phase": "queued", "ready_for_manual_fault": False})
    (ROOT / "runtime").mkdir(exist_ok=True)
    with (folder / "worker.log").open("w") as log:
        subprocess.Popen([sys.executable, str(ROOT / "fis.py"), "_worker", "--run", str(folder)],
                         stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    write_json(ROOT / "runtime/latest.json", {"run": str(folder)})
    print(json.dumps({"run": str(folder), "fault_injection": "operator AWS CLI or console; client never injects faults"}))


def mark(args):
    folder = run_dir(args)
    status = read_json(folder / "status.json")
    if not status.get("running"):
        raise ValueError("measurement worker is not running")
    at = dt.datetime.fromisoformat(args.at.replace("Z", "+00:00"))
    if at.tzinfo is None:
        raise ValueError("--at must include UTC offset or Z")
    at_ms = int(at.timestamp() * 1000)
    if not status.get("started_at_ms", now_ms()) <= at_ms <= now_ms():
        raise ValueError("marker must be within this run and not in the future")
    marker = {"event": args.event, "at_ms": at_ms, "recorded_at_ms": now_ms(),
              "note": args.note, "experiment_id": args.experiment_id}
    with (folder / "markers.jsonl").open("a+") as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        file.seek(0)
        existing = [json.loads(line) for line in file if line.strip()]
        if args.event == "fault-start":
            baseline_at = status.get("baseline_ready_at_ms")
            if baseline_at is None:
                plan = read_json(folder / "plan.json")
                observations = [json.loads(line) for line in (folder / "observations.jsonl").read_text().splitlines()]
                configured = [row["at_ms"] for row in observations
                              if row["at_ms"] <= at_ms and row["connected_clients"] == plan["connections"]]
                if configured:
                    baseline_at = min(configured) + plan["baseline_seconds"] * 1000
                    marker["baseline_evidence"] = "timestamped observations after first target connection count"
            if baseline_at is None or any(m["event"] == "fault-start" for m in existing):
                raise ValueError("baseline is not ready or a fault marker already exists")
            if at_ms < baseline_at:
                raise ValueError("fault timestamp precedes the completed baseline")
            if not args.experiment_id:
                raise ValueError("fault-start requires --experiment-id from the actual FIS experiment")
        elif args.event in {"task-stopped", "capacity-restored"}:
            fault = next((m for m in existing if m["event"] == "fault-start"), None)
            if not fault or at_ms < fault["at_ms"]:
                raise ValueError("task lifecycle marker requires an earlier fault-start")
            if any(m["event"] == args.event for m in existing):
                raise ValueError("lifecycle marker already exists; preserve the first observation")
        file.seek(0, 2)
        file.write(json.dumps(marker) + "\n")
        file.flush()
        os.fsync(file.fileno())
    print(json.dumps(marker))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan", help="create a plan without HTTP requests")
    plan.add_argument("--base-url", default="https://stock-spoon.com/market")
    plan.add_argument("--connections", type=int, default=900)
    plan.add_argument("--experiment", choices=["T1", "T2", "T3", "R1", "R2", "R3"], default="T1")
    plan.add_argument("--price-codes", required=True)
    plan.add_argument("--orderbook-codes", required=True)
    plan.add_argument("--mode", choices=["baseline", "fault"], default="fault")
    plan.add_argument("--max-source-age-ms", type=int, default=1000,
                      help="per-code freshness criterion, not an upstream watermark guarantee")
    for name, value in (("ramp", 120), ("baseline", 600), ("fault-wait", 300), ("observe", 600)):
        plan.add_argument("--" + name, type=int, default=value, help="seconds")
    plan.add_argument("--output", required=True)
    start_parser = sub.add_parser("start", help="EXPLICITLY start real REST/SSE traffic")
    start_parser.add_argument("--plan", required=True)
    start_parser.add_argument("--binary", default="/usr/local/bin/k6-sse")
    for command in ("status", "stop", "report", "_worker"):
        sub.add_parser(command).add_argument("--run")
    marker = sub.add_parser("mark", help="record a fact; never starts an AWS experiment")
    marker.add_argument("--run")
    marker.add_argument("--event", required=True,
                        choices=["fault-start", "task-stopped", "capacity-restored", "safety-stop", "note"])
    marker.add_argument("--at", required=True, help="actual observed ISO8601 timestamp with offset")
    marker.add_argument("--experiment-id", default="")
    marker.add_argument("--note", default="")
    args = parser.parse_args()
    try:
        if args.command == "plan":
            data = make_plan(args)
            with Path(args.output).open("x") as file:
                json.dump(data, file, ensure_ascii=False, indent=2)
            print(json.dumps({"plan": str(Path(args.output).resolve()), "connections": data["connections"],
                              "groups": data["groups"], "budget_seconds": data["budget_seconds"], "http_requests": 0}))
        elif args.command == "start":
            start(args)
        elif args.command == "mark":
            mark(args)
        elif args.command == "_worker":
            return worker(run_dir(args))
        elif args.command == "status":
            print(json.dumps(read_json(run_dir(args) / "status.json"), ensure_ascii=False, indent=2))
        elif args.command == "stop":
            folder = run_dir(args)
            if read_json(folder / "status.json").get("running"):
                (folder / "stop.request").touch()
            print(json.dumps({"run": str(folder), "stop_requested": True, "aws_operations": []}))
        else:
            print(json.dumps(read_json(run_dir(args) / "result.json"), ensure_ascii=False, indent=2))
    except (ValueError, OSError, KeyError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
