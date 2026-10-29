#!/usr/bin/env python3
"""Host-local, finite evidence capture for one verified market-http Task; no AWS writes."""

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import ipaddress
import json
import os
import re
import shutil
import subprocess
import tarfile
import time
from pathlib import Path
from urllib.request import urlopen

FAMILY = "stockspoon-v2-prod-market-http"
TASK = re.compile(
    r"arn:aws:ecs:ap-northeast-2:250832562715:task/stockspoon-v2-prod-cluster/([a-f0-9]{32})$"
)
PROFILE_ROOT = Path("/var/lib/stockspoon/market-memory")
MAX_BYTES = 256 * 1024 * 1024


def inspect_task(container_id):
    container = json.loads(
        subprocess.check_output(["docker", "inspect", container_id], text=True)
    )[0]
    labels = container["Config"].get("Labels") or {}
    match = TASK.fullmatch(labels.get("com.amazonaws.ecs.task-arn", ""))
    if (
        labels.get("com.amazonaws.ecs.task-definition-family") != FAMILY
        or labels.get("com.amazonaws.ecs.container-name") != "market-http"
        or not match
    ):
        raise ValueError(
            "Only the approved production market-http application container is allowed"
        )
    if not container["State"]["Running"] or container["State"]["Pid"] <= 0:
        raise ValueError("Capture/trigger requires a running target; archive does not")
    runtime_hostname = subprocess.check_output(
        [
            "docker",
            "exec",
            container_id,
            "python",
            "-c",
            "import socket; print(socket.gethostname())",
        ],
        text=True,
        timeout=5,
    ).strip()
    if not runtime_hostname or "/" in runtime_hostname:
        raise ValueError("Cannot resolve the target runtime hostname")
    container["Config"]["Hostname"] = runtime_hostname
    container["verified_task_id"] = match[1]
    return container


def task_cgroup(
    pid,
    task_id,
    expected_memory,
    proc_root=Path("/proc"),
    cgroup_root=Path("/sys/fs/cgroup"),
):
    entries = (proc_root / str(pid) / "cgroup").read_text().splitlines()
    unified = [line[3:] for line in entries if line.startswith("0::")]
    if len(unified) != 1:
        raise ValueError("A cgroup v2 host is required")
    root = cgroup_root.resolve()
    current = (root / unified[0].lstrip("/")).resolve()
    if not current.is_relative_to(root):
        raise ValueError("Unexpected cgroup path")
    candidates = []
    while current != root:
        if task_id in current.name and (current / "memory.max").is_file():
            if (current / "memory.max").read_text().strip() == str(expected_memory):
                candidates.append(current)
        current = current.parent
    if len(candidates) != 1:
        raise ValueError(
            "Cannot uniquely resolve the Task cgroup with the expected memory limit"
        )
    return candidates[0]


def profile_source(container):
    mounts = [m for m in container.get("Mounts", []) if m["Destination"] == "/profiles"]
    if (
        len(mounts) != 1
        or mounts[0].get("Type") != "bind"
        or not mounts[0].get("RW")
        or Path(mounts[0]["Source"]).resolve() != PROFILE_ROOT
    ):
        raise ValueError("The reviewed writable host /profiles mount is required")
    return Path(mounts[0]["Source"])


def parse_time(value):
    value = re.sub(r"(\.\d{6})\d+", r"\1", value)
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def armed_profile(container, source, statuses=("armed",)):
    matches = []
    for path in source.glob("*/profile-state.json"):
        if path.is_symlink() or path.parent.is_symlink():
            continue
        state = json.loads(path.read_text())
        if (
            state.get("hostname") == container["Config"]["Hostname"]
            and state.get("status") in statuses
            and parse_time(state["utc"]) >= parse_time(container["State"]["StartedAt"])
        ):
            matches.append(path)
    if len(matches) != 1:
        raise ValueError(
            "Expected exactly one armed profiler for this container startup"
        )
    return matches[0]


def trigger(container, burst=False):
    state_path = armed_profile(
        container,
        profile_source(container),
        ("baseline_ready",) if burst else ("armed",),
    )
    path = state_path.parent / ("capture.burst" if burst else "capture.trigger")
    with path.open("x") as out:
        out.write(dt.datetime.now(dt.timezone.utc).isoformat() + "\n")
    return str(path)


def counters(path):
    return {
        key: int(value)
        for key, value in (line.split() for line in path.read_text().splitlines())
    }


def process_start(pid, proc_root=Path("/proc")):
    try:
        return (proc_root / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()[19]
    except FileNotFoundError:
        return None


def memory_sample(group, pid, proc_root=Path("/proc"), expected_start=None):
    sample = {
        "utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "monotonic": time.monotonic(),
    }
    for name in ["memory.current", "memory.peak", "memory.max"]:
        try:
            value = (group / name).read_text().strip()
            sample[name] = int(value) if value != "max" else value
        except FileNotFoundError:
            sample[name] = None
    for name in ["memory.events", "memory.stat"]:
        try:
            sample[name] = counters(group / name)
        except FileNotFoundError:
            sample[name] = None
    try:
        if (
            expected_start is not None
            and process_start(pid, proc_root) != expected_start
        ):
            raise FileNotFoundError("Target process exited or PID was reused")
        sample["process_rss_bytes"] = int(
            (proc_root / str(pid) / "statm").read_text().split()[1]
        ) * os.sysconf("SC_PAGE_SIZE")
    except FileNotFoundError:
        sample["process_rss_bytes"] = None
    return sample


def metrics_address(container):
    network = container
    mode = container["HostConfig"]["NetworkMode"]
    if mode.startswith("container:"):
        network = json.loads(
            subprocess.check_output(
                ["docker", "inspect", mode.split(":", 1)[1]], text=True
            )
        )[0]
    ips = {
        n["IPAddress"]
        for n in network["NetworkSettings"]["Networks"].values()
        if n.get("IPAddress")
    }
    if not ips:
        address = subprocess.check_output(
            [
                "docker",
                "exec",
                container["Id"],
                "python",
                "-c",
                "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); "
                "s.connect(('192.0.2.1',9)); print(s.getsockname()[0]); s.close()",
            ],
            text=True,
            timeout=5,
        ).strip()
        ips = {address}
    if len(ips) != 1:
        raise ValueError("Expected a single Task IPv4 address")
    ip = ipaddress.ip_address(ips.pop())
    if ip.version != 4 or not ip.is_private:
        raise ValueError("Metrics must use the private Task address")
    return f"http://{ip}:9101/metrics"


def fetch_metrics(url):
    with urlopen(url, timeout=0.4) as response:
        body = response.read(2 * 1024 * 1024 + 1)
    if len(body) > 2 * 1024 * 1024:
        raise ValueError("Unexpected metrics response size")
    lines = [
        line
        for line in body.decode().splitlines()
        if line.startswith(("market_http_", "process_"))
    ]
    return {"utc": dt.datetime.now(dt.timezone.utc).isoformat(), "metrics": lines}


def mirror_profiles(source, destination, hostname, selected=None):
    copied = 0
    for state_path in [selected] if selected else source.glob("*/profile-state.json"):
        if state_path.is_symlink() or state_path.parent.is_symlink():
            continue
        state = json.loads(state_path.read_text())
        if state.get("hostname") != hostname:
            continue
        for path in state_path.parent.rglob("*"):
            if (
                not path.is_file()
                or path.is_symlink()
                or any(p.is_symlink() for p in path.parents)
            ):
                continue
            if path.name.endswith(".partial") or path.suffix not in {
                ".json",
                ".snapshot",
            }:
                continue
            if path.suffix == ".snapshot" and not path.with_suffix(".json").is_file():
                continue
            target = destination / path.relative_to(source)
            if (
                target.exists()
                and target.stat().st_size == path.stat().st_size
                and path.name != "profile-state.json"
            ):
                continue
            if (
                sum(p.stat().st_size for p in destination.rglob("*") if p.is_file())
                + path.stat().st_size
                > MAX_BYTES
            ):
                raise ValueError(
                    "Profile mirror byte budget exceeded; existing evidence retained"
                )
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_suffix(target.suffix + ".partial")
            shutil.copyfile(path, temporary)
            temporary.replace(target)
            copied += 1
    return {"copied_files": copied}


def record(container, output, seconds, interval):
    source = profile_source(container)
    selected = armed_profile(container, source)
    group = task_cgroup(
        container["State"]["Pid"], container["verified_task_id"], 2 * 1024**3
    )
    url = metrics_address(container)
    initial_start = process_start(container["State"]["Pid"])
    if initial_start is None:
        raise ValueError("Target exited before capture")
    output.mkdir(parents=True, exist_ok=False)
    manifest = {
        "tool": "market-http-fis-capture-v1",
        "started_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "task_arn": container["Config"]["Labels"]["com.amazonaws.ecs.task-arn"],
        "container_id": container["Id"],
        "pid": container["State"]["Pid"],
        "cgroup": str(group),
        "seconds": seconds,
        "memory_interval": interval,
        "metrics_interval": 1,
        "profile_root": str(source),
        "profile_state": str(selected),
        "hostname": container["Config"]["Hostname"],
        "image_id": container["Image"],
        "task_definition": container["Config"]["Labels"].get(
            "com.amazonaws.ecs.task-definition-version"
        ),
        "status": "recording",
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2))
    deadline = time.monotonic() + seconds
    jobs = {}
    next_poll = 0
    try:
        with (
            concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool,
            (output / "memory.jsonl").open("x", buffering=1) as memory,
            (output / "metrics.jsonl").open("x", buffering=1) as metrics,
            (output / "capture-events.jsonl").open("x", buffering=1) as events,
        ):
            while time.monotonic() < deadline:
                started = time.monotonic()
                memory.write(
                    json.dumps(
                        memory_sample(
                            group,
                            container["State"]["Pid"],
                            expected_start=initial_start,
                        )
                    )
                    + "\n"
                )
                for name, job in list(jobs.items()):
                    if job.done():
                        try:
                            result = job.result()
                            (metrics if name == "metrics" else events).write(
                                json.dumps(result) + "\n"
                            )
                        except Exception as error:
                            events.write(
                                json.dumps(
                                    {
                                        "utc": dt.datetime.now(
                                            dt.timezone.utc
                                        ).isoformat(),
                                        "job": name,
                                        "error": str(error),
                                    }
                                )
                                + "\n"
                            )
                        del jobs[name]
                if started >= next_poll:
                    if "metrics" not in jobs:
                        jobs["metrics"] = pool.submit(fetch_metrics, url)
                    if "profiles" not in jobs:
                        jobs["profiles"] = pool.submit(
                            mirror_profiles,
                            source,
                            output / "profiles",
                            container["Config"]["Hostname"],
                            selected,
                        )
                    next_poll = started + 1
                if sum(p.stat().st_size for p in output.glob("*.jsonl")) > MAX_BYTES:
                    raise ValueError(
                        "Capture byte budget reached; existing evidence retained"
                    )
                time.sleep(
                    max(
                        0,
                        min(
                            interval - (time.monotonic() - started),
                            deadline - time.monotonic(),
                        ),
                    )
                )
        mirror_profiles(
            source, output / "profiles", container["Config"]["Hostname"], selected
        )
        manifest["status"] = "finished"
    except BaseException:
        manifest["status"] = "interrupted"
        raise
    finally:
        manifest["ended_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2))


def recover(run_dir):
    manifest = json.loads((run_dir / "manifest.json").read_text())
    if manifest.get("tool") != "market-http-fis-capture-v1" or not TASK.fullmatch(
        manifest.get("task_arn", "")
    ):
        raise ValueError("Not a verified capture run")
    source = Path(manifest["profile_root"]).resolve()
    selected = Path(manifest["profile_state"]).resolve()
    if source != PROFILE_ROOT or not selected.is_relative_to(source):
        raise ValueError("Unexpected profile source")
    return mirror_profiles(source, run_dir / "profiles", manifest["hostname"], selected)


def prepare_host(uid, gid):
    if PROFILE_ROOT.is_symlink():
        raise ValueError("Profile root must not be a symlink")
    PROFILE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o750)
    if any(PROFILE_ROOT.iterdir()) and PROFILE_ROOT.stat().st_uid != uid:
        raise ValueError("Existing profile evidence has a different owner")
    os.chown(PROFILE_ROOT, uid, gid)
    PROFILE_ROOT.chmod(0o750)
    return str(PROFILE_ROOT)


def archive(run_dir, output):
    if (
        json.loads((run_dir / "manifest.json").read_text()).get("tool")
        != "market-http-fis-capture-v1"
    ):
        raise ValueError("Not a capture run directory")
    if output.resolve().is_relative_to(run_dir.resolve()):
        raise ValueError("Archive destination must be outside the run directory")
    files = [
        p
        for p in run_dir.rglob("*")
        if p.is_file()
        and not p.is_symlink()
        and not p.name.endswith(".partial")
        and p.name != "sha256.json"
    ]
    hashes = {}
    for path in files:
        with path.open("rb") as handle:
            digest = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
            hashes[str(path.relative_to(run_dir))] = digest.hexdigest()
    checksum = run_dir / "sha256.json"
    checksum.write_text(json.dumps(hashes, indent=2))
    with output.open("xb") as handle, tarfile.open(fileobj=handle, mode="w:gz") as tar:
        for path in files + [checksum]:
            tar.add(path, arcname=str(path.relative_to(run_dir)), recursive=False)
    return str(output)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ["record", "trigger"]:
        p = sub.add_parser(command)
        p.add_argument("--container-id", required=True)
        if command == "trigger":
            p.add_argument("--burst", action="store_true")
        if command == "record":
            p.add_argument("--output", type=Path, required=True)
            p.add_argument("--seconds", type=int, default=180)
            p.add_argument("--interval", type=float, default=0.25)
    p = sub.add_parser("prepare-host")
    p.add_argument("--uid", type=int, default=10001)
    p.add_argument("--gid", type=int, default=10001)
    p = sub.add_parser("recover")
    p.add_argument("--run-dir", type=Path, required=True)
    p = sub.add_parser("archive")
    p.add_argument("--run-dir", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare-host":
        if args.uid < 1 or args.gid < 1:
            parser.error("Use a non-root application UID/GID")
        print(prepare_host(args.uid, args.gid))
        return
    if args.command == "recover":
        print(json.dumps(recover(args.run_dir)))
        return
    if args.command == "archive":
        print(archive(args.run_dir, args.output))
        return
    if args.command == "record" and not (
        1 <= args.seconds <= 1800 and 0.1 <= args.interval <= 1
    ):
        parser.error("Use seconds=1..1800 and memory interval=0.1..1 second")
    container = inspect_task(args.container_id)
    if args.command == "trigger":
        print(trigger(container, args.burst))
    else:
        record(container, args.output, args.seconds, args.interval)
        print(args.output)


if __name__ == "__main__":
    main()
