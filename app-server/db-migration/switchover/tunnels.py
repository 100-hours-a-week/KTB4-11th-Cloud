#!/usr/bin/env python3
"""Keep four authenticated SSM tunnels open; creates no AWS resources."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    cfg = json.loads(Path(args.config).read_text())
    aws_cfg = cfg["aws"]
    command = ["aws", "--region", aws_cfg["region"]]

    def aws(*arguments):
        return json.loads(subprocess.check_output(command + list(arguments) + ["--output", "json"], text=True, timeout=20))

    def stable_task():
        service = aws("ecs", "describe-services", "--cluster", aws_cfg["cluster"], "--services", aws_cfg["service"])["services"][0]
        if service["desiredCount"] != 1 or service["runningCount"] != 1 or service["pendingCount"] != 0 or len(service["deployments"]) != 1:
            raise RuntimeError("ProxySQL must have exactly one stable running task; finish ECS deployment first")
        tasks = aws("ecs", "list-tasks", "--cluster", aws_cfg["cluster"], "--service-name", aws_cfg["service"], "--desired-status", "RUNNING")["taskArns"]
        if len(tasks) != 1:
            raise RuntimeError("Expected exactly one Fargate task")
        return tasks[0]

    task_arn = stable_task()
    task = aws("ecs", "describe-tasks", "--cluster", aws_cfg["cluster"], "--tasks", task_arn)["tasks"][0]
    if task.get("launchType") != "FARGATE" or not task.get("enableExecuteCommand"):
        raise RuntimeError("Expected a Fargate task with ECS Exec enabled")
    container = next(c for c in task["containers"] if c["name"] == aws_cfg["container"])
    target = f"ecs:{aws_cfg['cluster']}_{task_arn.rsplit('/', 1)[1]}_{container['runtimeId']}"
    forwards = []
    for name in ("source", "target"):
        endpoint = cfg[name]
        forwards.append((name, aws_cfg[name + "_instance"], "AWS-StartPortForwardingSessionToRemoteHost",
                         {"host": [endpoint["server_host"]], "portNumber": [str(endpoint["server_port"])],
                          "localPortNumber": [str(endpoint["port"])]}))
    for name, port in (("proxy_admin", 6032), ("proxy_app", 6033)):
        forwards.append((name, target, "AWS-StartPortForwardingSession",
                         {"portNumber": [str(port)], "localPortNumber": [str(cfg[name]["port"])]}))
    for name, _, _, _ in forwards:
        if cfg[name]["host"] != "127.0.0.1":
            raise RuntimeError("Tunnel endpoints must use 127.0.0.1")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", cfg[name]["port"]))
    processes = []
    log_dir = Path(tempfile.mkdtemp(prefix="db-switchover-tunnels-"))
    print(f"Task: {task_arn}\nSSM logs: {log_dir}", flush=True)
    try:
        for name, remote, document, parameters in forwards:
            with open(log_dir / (name + ".log"), "w") as log:
                child = subprocess.Popen(command + ["ssm", "start-session", "--target", remote,
                                                    "--document-name", document, "--parameters", json.dumps(parameters)],
                                         stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
                processes.append(child)
        deadline = time.monotonic() + 45
        pending = {name for name, *_ in forwards}
        while pending:
            if any(p.poll() is not None for p in processes):
                raise RuntimeError(f"SSM session failed; inspect {log_dir}")
            for name in list(pending):
                try:
                    with socket.create_connection(("127.0.0.1", cfg[name]["port"]), timeout=0.5):
                        pending.remove(name)
                except OSError:
                    pass
            if time.monotonic() > deadline:
                raise RuntimeError(f"Tunnels not ready: {sorted(pending)}; inspect {log_dir}")
            time.sleep(0.5)
        print("READY: leave this terminal open. Run switchover.py in another terminal; Ctrl+C closes tunnels.", flush=True)
        while True:
            if any(p.poll() is not None for p in processes) or stable_task() != task_arn:
                raise RuntimeError("ProxySQL deployment/tunnel changed; closing connections to stop the operation")
            time.sleep(5)
    finally:
        for process in processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
        for process in processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        main()
    except KeyboardInterrupt:
        pass
