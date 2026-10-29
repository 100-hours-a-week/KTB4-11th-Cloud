import argparse
import json
from pathlib import Path

from model import distribution, event_lines


def analyze(plan, checkpoint, reference_events, events, end_ms, fault_ms=None):
    issues = []
    targets = checkpoint['states']
    expected_keys = {stream + ':' + code for stream, codes in plan['codes'].items() for code in codes}
    if set(targets) != expected_keys or checkpoint.get('reference') != 'independent_pubsub_and_cache':
        issues.append('checkpoint coverage/reference invalid')
    if checkpoint['at_ms'] > end_ms or checkpoint['frozen_at_ms'] > checkpoint['at_ms']:
        issues.append('checkpoint outside observation window')
    kinds = {row['kind'] for row in reference_events}
    if not {'reference_ready', 'reference_checkpoint', 'reference_finished'} <= kinds or 'reference_invalid' in kinds:
        issues.append('reference incomplete or invalid')
    if not any(row['kind'] == 'reference_checkpoint' and row.get('checkpoint_id') == checkpoint.get('checkpoint_id') for row in reference_events):
        issues.append('checkpoint identity missing from reference log')
    if not any(row['kind'] == 'reference_finished' and row['at_ms'] >= end_ms for row in reference_events):
        issues.append('reference does not cover observation end')
    for row in reference_events:
        if (row['kind'] == 'reference_quote' and checkpoint['at_ms'] < row['at_ms'] <= end_ms
                and row['state'] != targets.get(row['key'])):
            issues.append('reference changed after checkpoint')
            break
    subscriptions, latest, first_payload = {}, {}, []
    for event in sorted(events, key=lambda e: e['at_ms']):
        if event['at_ms'] > end_ms:
            continue
        cid = str(event['client_id'])
        if event['kind'] == 'quote_measurement_error':
            issues.append('client fingerprint measurement error')
        if event['kind'] == 'quote_subscription':
            sub = {'stream': event['stream'], 'codes': event['codes'], 'group': event['group']}
            if cid in subscriptions and sub != subscriptions[cid]:
                issues.append('client subscription changed')
            subscriptions[cid] = sub
        if event['kind'] == 'quote_state':
            latest[cid] = event
        if event['kind'] == 'recovery_first_payload' and fault_ms is not None and event['at_ms'] >= fault_ms:
            first_payload.append(event['elapsed_ms'])
    if len(subscriptions) != plan['connections']:
        issues.append('subscription cohort incomplete')
    for group, config in plan['groups'].items():
        if sum(s['group'] == group for s in subscriptions.values()) != config['connections']:
            issues.append('group cohort incomplete: ' + group)
    rows = []
    for cid, sub in subscriptions.items():
        sample = latest.get(cid)
        cfg = plan['groups'].get(sub['group'])
        valid = (cfg is not None and sub['stream'] == cfg['stream'] and len(sub['codes']) == cfg['code_count']
                 and len(set(sub['codes'])) == len(sub['codes'])
                 and set(sub['codes']) <= set(plan['codes'][sub['stream']]))
        if not valid:
            issues.append('invalid subscription: ' + cid)
        state = sample['states'] if sample else {}
        missing = []
        mismatched = []
        received = []
        fresh_sample = sample and checkpoint['at_ms'] <= sample['at_ms'] <= end_ms and end_ms - sample['at_ms'] <= 20000
        for code in sub['codes']:
            target = targets.get(sub['stream'] + ':' + code)
            actual = state.get(code)
            if (not valid or not fresh_sample or target is None or actual is None
                    or any(actual.get(k) != target.get(k) for k in ('hash', 'timestamp_key', 'sequence'))):
                missing.append(code)
                if (actual and target and actual.get('timestamp_key') == target.get('timestamp_key')
                        and actual.get('sequence') == target.get('sequence') and actual.get('hash') != target.get('hash')):
                    mismatched.append(code)
            else:
                received.append(actual['since_ms'])
        reached = max(received) if received and not missing else None
        rows.append({'client_id': cid, 'stream': sub['stream'], 'missing_codes': missing, 'same_version_mismatched_codes': mismatched,
                     'recovered': reached is not None, 'all_matched_at_ms': reached,
                     'regressions': sample['regressions'] if sample else None,
                     'same_version_conflicts': sample['conflicts'] if sample else None})
    recovered = [r for r in rows if r['recovered']]
    origin = fault_ms if fault_ms is not None else checkpoint['frozen_at_ms']
    return {'status': 'INCONCLUSIVE' if issues else 'MEASURED', 'measurement_issues': sorted(set(issues)),
            'expected_clients': plan['connections'], 'observed_clients': len(rows),
            'already_matched_at_origin': sum(r['all_matched_at_ms'] <= origin for r in recovered),
            'recovered_clients': len(recovered), 'recovery_rate': len(recovered) / plan['connections'],
            'unrecovered_clients': plan['connections'] - len(recovered),
            'missing_client_code_pairs': sum(len(r['missing_codes']) for r in rows),
            'unobserved_client_code_pairs': max(0, sum(g['connections'] * g['code_count'] for g in plan['groups'].values()) - sum(len(s['codes']) for s in subscriptions.values())),
            'checkpoint_same_version_mismatch_pairs': sum(len(r['same_version_mismatched_codes']) for r in rows),
            'unobserved_clients': plan['connections'] - len(rows),
            'missing_unique_stream_codes': sorted({r['stream'] + ':' + code for r in rows for code in r['missing_codes']}),
            'time_origin': 'fault_start' if fault_ms is not None else 'input_frozen',
            'all_codes_recovery': distribution([max(0, r['all_matched_at_ms'] - origin) for r in recovered]),
            'checkpoint_to_match': distribution([max(0, r['all_matched_at_ms'] - checkpoint['at_ms']) for r in recovered]),
            'first_post_reconnect_payload': distribution(first_payload),
            'regressions': sum(r['regressions'] or 0 for r in rows),
            'same_version_conflicts': sum(r['same_version_conflicts'] or 0 for r in rows),
            'conflict_detection_scope': 'final checkpoint vs independent reference; client conflicts at its highest observed version. Intermediate cross-reference comparisons are not inferred.',
            'percentiles_population': 'observed recovered clients only; missing clients remain in recovery-rate denominator',
            'coverage': 'final frozen checkpoint; continuous moving-reference convergence is not inferred',
            'clients': rows}


def main():
    p = argparse.ArgumentParser(description='Offline quote comparison; no network/fault/deployment operations')
    for name in ('plan', 'checkpoint', 'reference', 'events', 'output'):
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--end-ms', type=int, required=True)
    p.add_argument('--fault-ms', type=int)
    args = p.parse_args()
    result = analyze(json.loads(args.plan.read_text()), json.loads(args.checkpoint.read_text()),
                     [json.loads(x) for x in args.reference.read_text().splitlines() if x],
                     list(event_lines(args.events.read_text().splitlines())), args.end_ms, args.fault_ms)
    with args.output.open('x') as out:
        json.dump(result, out, indent=2)


if __name__ == '__main__':
    main()
