#!/usr/bin/env python3
"""Forward only Fargate ProxySQL ports from the migration EC2 using ECS Exec."""
import argparse
import json
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time


def port_is_open(host, port, timeout=0.5):
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def plan_forwards(cfg, forwards, listener=port_is_open):
    """Reuse accepting local endpoints and start only the missing forwards."""
    reused, to_start = [], []
    for name, remote_port in forwards:
        endpoint = cfg[name]
        if endpoint["host"] != "127.0.0.1":
            raise RuntimeError("ProxySQL tunnel endpoints must use 127.0.0.1")
        local_port = int(endpoint["port"])
        if listener("127.0.0.1", local_port):
            reused.append(name)
            continue
        try:
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", local_port))
        except OSError as error:
            raise RuntimeError(
                f"Local ProxySQL port {local_port} is occupied but not accepting connections; "
                "inspect the listener before retrying"
            ) from error
        to_start.append((name, remote_port))
    return reused, to_start


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    cfg = json.loads(Path(args.config).read_text())
    aws_cfg = cfg["aws"]
    aws_command = ["aws", "--region", aws_cfg["region"]]
    require(shutil.which("aws"), "AWS CLI is required on the migration EC2")
    require(shutil.which("session-manager-plugin"), "Install the Session Manager plugin on the migration EC2")

    def aws(*arguments):
        result = subprocess.check_output(aws_command + list(arguments) + ["--output", "json"],
                                        text=True, timeout=20)
        return json.loads(result)

    def stable_task():
        service = aws("ecs", "describe-services", "--cluster", aws_cfg["cluster"],
                      "--services", aws_cfg["service"])["services"][0]
        if (service["desiredCount"] != 1 or service["runningCount"] != 1
                or service["pendingCount"] != 0 or len(service["deployments"]) != 1):
            raise RuntimeError("ProxySQL must have exactly one stable running task")
        tasks = aws("ecs", "list-tasks", "--cluster", aws_cfg["cluster"],
                    "--service-name", aws_cfg["service"], "--desired-status", "RUNNING")["taskArns"]
        if len(tasks) != 1:
            raise RuntimeError("Expected exactly one Fargate ProxySQL task")
        task = aws("ecs", "describe-tasks", "--cluster", aws_cfg["cluster"], "--tasks", tasks[0])["tasks"][0]
        if task.get("launchType") != "FARGATE" or not task.get("enableExecuteCommand"):
            raise RuntimeError("Expected a Fargate task with ECS Exec enabled")
        container = next((c for c in task["containers"] if c["name"] == aws_cfg["container"]), None)
        if not container or not container.get("runtimeId"):
            raise RuntimeError("ProxySQL container runtime ID is unavailable")
        target = f"ecs:{aws_cfg['cluster']}_{tasks[0].rsplit('/', 1)[1]}_{container['runtimeId']}"
        return tasks[0], target

    task_arn, session_target = stable_task()
    for name in ("source", "target"):
        endpoint = cfg[name]
        try:
            with socket.create_connection((endpoint["host"], int(endpoint["port"])), timeout=5):
                pass
        except OSError as error:
            raise RuntimeError(f"Cannot reach {name} MySQL at {endpoint['host']}:{endpoint['port']} from this EC2: {error}") from error

    forwards = [("proxy_admin", 6032), ("proxy_app", 6033)]
    reused, to_start = plan_forwards(cfg, forwards)
    for name in reused:
        print(f"REUSING: {name} at 127.0.0.1:{cfg[name]['port']}", flush=True)

    log_dir = Path(tempfile.mkdtemp(prefix="db-switchover-ec2-tunnels-"))
    processes = []
    print(f"Task: {task_arn}\nSSM logs: {log_dir}", flush=True)
    try:
        for name, remote_port in to_start:
            endpoint = cfg[name]
            parameters = {"portNumber": [str(remote_port)],
                          "localPortNumber": [str(endpoint["port"])]}
            with open(log_dir / (name + ".log"), "w") as log:
                process = subprocess.Popen(
                    aws_command + ["ssm", "start-session", "--target", session_target,
                                   "--document-name", "AWS-StartPortForwardingSession",
                                   "--parameters", json.dumps(parameters)],
                    stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                    start_new_session=True)
                processes.append(process)

        deadline = time.monotonic() + 45
        pending = {name for name, _ in to_start}
        while pending:
            if any(process.poll() is not None for process in processes):
                raise RuntimeError(f"ProxySQL SSM port-forward failed; inspect {log_dir}")
            for name in tuple(pending):
                port = int(cfg[name]["port"])
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                        pending.remove(name)
                except OSError:
                    pass
            if time.monotonic() > deadline:
                raise RuntimeError(f"ProxySQL tunnels not ready: {sorted(pending)}; inspect {log_dir}")
            time.sleep(0.5)

        if not to_start:
            print("No new SSM sessions needed; existing local endpoints will be reused.", flush=True)
        print("READY: keep this terminal open. Run switchover.py in another terminal on this EC2.", flush=True)
        while True:
            if any(process.poll() is not None for process in processes) or stable_task()[0] != task_arn:
                raise RuntimeError("ProxySQL task changed or tunnel ended; closing the port forwards")
            closed = [name for name in reused if not port_is_open("127.0.0.1", cfg[name]["port"])]
            if closed:
                raise RuntimeError(f"Reused ProxySQL endpoint closed: {', '.join(closed)}")
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


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as error:
        raise SystemExit(f"ERROR: {error}") from error
