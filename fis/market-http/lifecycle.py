import argparse
import datetime as dt
import json
import os
from pathlib import Path
import selectors
import subprocess
import time

from capture import inspect_task, process_start


def collect(container, output, seconds, max_bytes):
    pid = container['State']['Pid']
    start = process_start(pid)
    cid = container['Id']
    task = container['verified_task_id']
    since = dt.datetime.now(dt.timezone.utc).isoformat()
    output.mkdir(parents=True, exist_ok=False)
    manifest = {'task_id': task, 'container_id': cid, 'pid': pid, 'since': since,
                'seconds': seconds, 'clock': {'utc': since, 'monotonic': time.monotonic()},
                'scope': 'kernel OOM candidate lines and selected container events; candidates require PID/cgroup correlation'}
    (output / 'manifest.json').write_text(json.dumps(manifest))
    commands = {
        'kernel': ['journalctl', '-k', '--since', since, '-f', '-o', 'json', '--no-pager'],
        'docker': ['docker', 'events', '--since', since, '--filter', 'container=' + cid, '--format', '{{json .}}'],
    }
    children = {}
    selector = selectors.DefaultSelector()
    deadline, total, next_tc = time.monotonic() + seconds, 0, 0
    try:
        with (output / 'events.jsonl').open('x', buffering=1) as log:
            def write(kind, **values):
                nonlocal total
                row = json.dumps({'utc': dt.datetime.now(dt.timezone.utc).isoformat(),
                                  'monotonic': time.monotonic(), 'kind': kind, **values}) + '\n'
                total += len(row.encode())
                if total > max_bytes:
                    raise ValueError('lifecycle byte budget exceeded')
                log.write(row)
            for kind, command in commands.items():
                child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                children[kind] = child
                os.set_blocking(child.stdout.fileno(), False)
                selector.register(child.stdout, selectors.EVENT_READ, kind)
            pending = {kind: b'' for kind in commands}
            while time.monotonic() < deadline:
                for key, _ in selector.select(timeout=0.2):
                    kind = key.data
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        write('collector_stream_closed', source=kind, returncode=children[kind].poll())
                        continue
                    pending[kind] += chunk
                    if len(pending[kind]) > 1024**2:
                        raise ValueError('oversized lifecycle line')
                    lines = pending[kind].split(b'\n')
                    pending[kind] = lines.pop()
                    for raw in lines:
                        line = raw.decode(errors='replace')
                        try:
                            json.loads(line)
                        except ValueError:
                            write('collector_diagnostic', source=kind, line=line[:32768])
                            continue
                        if kind == 'docker' or any(word in line.lower() for word in (task, str(pid), 'out of memory', 'oom', 'killed process')):
                            write(kind, line=line)
                if time.monotonic() >= next_tc:
                    if process_start(pid) == start and start is not None:
                        try:
                            result = subprocess.run(['nsenter', '-t', str(pid), '-n', 'tc', '-j', 'qdisc', 'show'],
                                                    capture_output=True, text=True, timeout=0.5)
                            write('tc_qdisc', returncode=result.returncode, data=result.stdout[:32768])
                        except (OSError, subprocess.TimeoutExpired) as error:
                            write('tc_unavailable', error_type=type(error).__name__)
                    else:
                        write('target_process_gone')
                    next_tc = time.monotonic() + 0.5
            write('collector_finished')
    finally:
        selector.close()
        for child in children.values():
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            child.stdout.close()


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description='Finite read-only host evidence; no faults, task stops or AWS writes')
    p.add_argument('--container-id', required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--seconds', type=int, default=1200)
    p.add_argument('--max-mb', type=int, default=64)
    a = p.parse_args()
    if not 1 <= a.seconds <= 1800 or not 1 <= a.max_mb <= 256:
        p.error('invalid finite collection limits')
    collect(inspect_task(a.container_id), a.output, a.seconds, a.max_mb * 1024**2)


if __name__ == '__main__':
    main()
