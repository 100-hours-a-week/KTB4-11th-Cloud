#!/usr/bin/env python3
"""Evaluate finite market-only observations; never changes AWS resources."""
import argparse
import json
import math
import time
from pathlib import Path


def evaluate(samples, expected_tasks, now_ms, window_ms=180000, max_cpu=0.35,
             max_memory_range=32 * 1024**2, max_memory_growth_per_minute=4 * 1024**2):
    issues = []
    if not samples:
        return {'stable': False, 'issues': ['no observations']}
    rows = [s for s in samples if now_ms - window_ms - 20000 <= s['at_ms'] <= now_ms]
    if not rows or now_ms - rows[-1]['at_ms'] > 20000:
        issues.append('latest observation missing or stale')
    if len(rows) < 10 or rows[-1]['at_ms'] - rows[0]['at_ms'] < window_ms:
        issues.append('full stability window not observed')
    if any(b['at_ms'] <= a['at_ms'] or b['at_ms'] - a['at_ms'] > 20000
           for a, b in zip(rows, rows[1:])):
        issues.append('observation gap or clock order invalid')
    identities = [set(s.get('task_ids', [])) for s in rows]
    tasks = identities[-1] if identities else set()
    if len(tasks) != expected_tasks or any(ids != tasks for ids in identities):
        issues.append('task identities changed or count incorrect')
    for s in rows:
        if (s.get('desired'), s.get('running'), s.get('pending')) != (expected_tasks, expected_tasks, 0):
            issues.append('service capacity not stable')
        if set(s.get('healthy_task_ids', [])) != tasks or not s.get('alarms_ok'):
            issues.append('target health or stop alarm not OK')
        if set(s.get('metrics', {})) != tasks or s.get('metrics_fresh') is not True:
            issues.append('task metrics missing')
    summaries = {}
    for task in sorted(tasks):
        values = [s.get('metrics', {}).get(task, {}) for s in rows]
        fields = ['cpu', 'working_set_bytes', 'queue_full_total']
        if any(not isinstance(v.get(k), (int, float)) or not math.isfinite(v[k]) or v[k] < 0
               for v in values for k in fields):
            issues.append('numeric task metrics missing or invalid')
            continue
        memory = [v['working_set_bytes'] for v in values]
        span = rows[-1]['at_ms'] - rows[0]['at_ms']
        growth = (memory[-1] - memory[0]) / (span / 60000) if span else 0
        summaries[task] = {'cpu_max': max(v['cpu'] for v in values),
                           'memory_range_bytes': max(memory) - min(memory),
                           'memory_growth_bytes_per_minute': growth,
                           'queue_full_start': values[0]['queue_full_total'],
                           'queue_full_end': values[-1]['queue_full_total']}
        if summaries[task]['cpu_max'] > max_cpu:
            issues.append('CPU above idle stability threshold')
        if max(memory) - min(memory) > max_memory_range or growth > max_memory_growth_per_minute:
            issues.append('working set not settled')
        if any(b['queue_full_total'] != a['queue_full_total'] for a, b in zip(values, values[1:])):
            issues.append('queue overflow counter changed')
    return {'stable': not issues, 'issues': sorted(set(issues)), 'tasks': summaries,
            'window_ms': window_ms, 'observations': len(rows),
            'policy': 'Operational idle gate, not a service SLO or proof of absence of leaks.'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--observations', type=Path, required=True)
    p.add_argument('--expected-tasks', type=int, choices=[2, 3], required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    rows = [json.loads(line) for line in args.observations.read_text().splitlines() if line.strip()]
    result = evaluate(rows, args.expected_tasks, time.time_ns() // 1000000)
    with args.output.open('x') as out:
        json.dump(result, out, indent=2)
    print(json.dumps(result))
    raise SystemExit(0 if result['stable'] else 1)


if __name__ == '__main__':
    main()
