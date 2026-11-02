#!/usr/bin/env python3
"""Approve only concrete FIS target-ARN updates in a saved Terraform plan JSON."""
import argparse
import json
import re
from pathlib import Path

TASK = re.compile(r'arn:aws:ecs:ap-northeast-2:250832562715:task/stockspoon-v2-prod-cluster/[a-f0-9]{32}')
TEMPLATES = {'aws_fis_experiment_template.' + name for name in
             ['stop_one', 'stop_peak', 'stop_limit', 'redis["R1"]', 'redis["R2"]', 'redis["R3"]']}
POLICIES = {'aws_iam_role_policy.fis', 'aws_iam_role_policy.redis_fis'}


def has_unknown(value):
    if isinstance(value, dict):
        return any(has_unknown(v) for v in value.values())
    if isinstance(value, list):
        return any(has_unknown(v) for v in value)
    return value is True


def normalized(value, target, after=False, key=None):
    if key == 'policy' and isinstance(value, str):
        return normalized(json.loads(value), target, after)
    if isinstance(value, dict):
        return {k: normalized(v, target, after, k) for k, v in value.items()}
    if isinstance(value, list):
        return [normalized(v, target, after) for v in value]
    if isinstance(value, str) and TASK.fullmatch(value):
        if after and value != target:
            raise ValueError('Plan references a different after-target Task')
        return '$SELECTED_MARKET_TASK'
    return value


def validate(plan, target):
    if not TASK.fullmatch(target):
        raise ValueError('Target must be one long Task ARN in the approved market cluster')
    changes = []
    for resource in plan.get('resource_changes', []):
        change = resource['change']
        if change['actions'] == ['no-op']:
            continue
        address = resource['address']
        if address not in TEMPLATES | POLICIES or change['actions'] != ['update']:
            raise ValueError('Outside target-update authorization: ' + address)
        if has_unknown(change.get('after_unknown', {})):
            raise ValueError('Unknown values prevent concrete review: ' + address)
        before = json.loads(json.dumps(change['before']))
        after = json.loads(json.dumps(change['after']))
        if address in TEMPLATES:
            targets = after.get('target', [])
            if len(targets) != 1 or targets[0].get('resource_arns') != [target]:
                raise ValueError('Template does not select exactly the approved Task: ' + address)
            # AWS/provider normalize an unused parameters map from {} to null.
            for obj in [before, after]:
                for block in obj.get('target', []):
                    if block.get('parameters') in ({}, None):
                        block['parameters'] = None
        if normalized(before, target) != normalized(after, target, after=True):
            raise ValueError('Plan changes more than Task ARNs: ' + address)
        changes.append(address)
    return {'target_update_only': True, 'target_task_arn': target, 'updates': changes,
            'creates': 0, 'deletes': 0,
            'scope': 'Task ARN references and unused target.parameters normalization only; no apply performed'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--plan-json', type=Path, required=True)
    p.add_argument('--task-arn', required=True)
    args = p.parse_args()
    print(json.dumps(validate(json.loads(args.plan_json.read_text()), args.task_arn), indent=2))


if __name__ == '__main__':
    main()
