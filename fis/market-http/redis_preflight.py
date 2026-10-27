#!/usr/bin/env python3
"""Read-only network prerequisites; never starts an experiment or deploys a Task."""
import argparse
import datetime as dt
import json
from pathlib import Path

from preflight import CLUSTER, aws, capture


def network_issues(task, definition, instances):
    issues = []
    if task.get('enableExecuteCommand'):
        issues.append('ECS Exec must be disabled')
    if definition.get('pidMode') != 'task':
        issues.append('Task Definition requires pidMode=task')
    if definition.get('networkMode') != 'awsvpc':
        issues.append('This setup requires awsvpc network isolation')
    if definition.get('enableFaultInjection') is not True:
        issues.append('Task Definition requires enableFaultInjection=true')
    sidecars = [c for c in definition.get('containerDefinitions', [])
                if c.get('name') == 'amazon-ssm-agent']
    running = {c['name'] for c in task.get('containers', []) if c.get('lastStatus') == 'RUNNING'}
    if len(sidecars) != 1 or 'amazon-ssm-agent' not in running:
        issues.append('A running amazon-ssm-agent sidecar is required')
    elif not any(e.get('name') == 'MANAGED_INSTANCE_ROLE_NAME' and e.get('value')
                 for e in sidecars[0].get('environment', [])):
        issues.append('Sidecar requires MANAGED_INSTANCE_ROLE_NAME')
    if len(instances) != 1 or instances[0].get('PingStatus') != 'Online':
        issues.append('Exactly one Online SSM managed instance tagged with this ECS_TASK_ARN is required')
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--task-arn', required=True)
    parser.add_argument('--scenario', choices=['R1', 'R2', 'R3'], required=True)
    parser.add_argument('--stop-alarm-arn', action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Preserve previous evidence; choose a new output path')
    snapshot = capture(args.task_arn, args.stop_alarm_arn, 3 if args.scenario == 'R3' else 2)
    task = next(t for t in snapshot['tasks'] if t['taskArn'] == args.task_arn)
    definition = aws('ecs', 'describe-task-definition', '--task-definition', task['taskDefinitionArn'])['taskDefinition']
    instances = aws('ssm', 'describe-instance-information', '--filters',
                    f'Key=tag:ECS_TASK_ARN,Values={args.task_arn}')['InstanceInformationList']
    issues = network_issues(task, definition, instances)
    for instance in instances:
        tags = aws('ssm', 'list-tags-for-resource', '--resource-type', 'ManagedInstance',
                   '--resource-id', instance['InstanceId'])['TagList']
        if {t['Key']: t['Value'] for t in tags}.get('FAULT_INJECTION_SIDECAR') != 'true':
            issues.append('Managed instance requires FAULT_INJECTION_SIDECAR=true')
    if task.get('containerInstanceArn'):
        hosts = aws('ecs', 'describe-container-instances', '--cluster', CLUSTER,
                    '--container-instances', task['containerInstanceArn'])['containerInstances']
        version = hosts[0]['versionInfo']['agentVersion']
        if tuple(int(x) for x in version.split('.')) < (1, 100, 0):
            issues.append('This template requires ECS Agent >=1.100.0')
    result = {'captured_at': dt.datetime.now(dt.timezone.utc).isoformat(),
              'scenario': args.scenario, 'target_task_arn': args.task_arn,
              'task_definition_arn': task['taskDefinitionArn'],
              'prerequisites_ready': not issues, 'issues': issues,
              'scope': 'Configuration checks only; direction, dependencies, IAM and workload still require runtime verification'}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    raise SystemExit(1 if issues else 0)


if __name__ == '__main__':
    main()
