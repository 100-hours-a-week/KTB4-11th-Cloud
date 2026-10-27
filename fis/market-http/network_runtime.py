"""Read-only evidence helpers for market-http network experiments."""
import datetime as dt
import json
import re

from preflight import ACCOUNT, CLUSTER, REGION, SERVICE


def list_invocations(aws, managed_instance, after, document, experiment_id=None):
    if not re.fullmatch(r'mi-[a-zA-Z0-9]+', managed_instance):
        raise ValueError('Expected an SSM managed-instance ID')
    timestamp = dt.datetime.fromisoformat(after.replace('Z', '+00:00'))
    if timestamp.tzinfo is None:
        raise ValueError('Invocation cutoff must include timezone')
    if document not in {'AWSFIS-Run-Network-Packet-Loss-ECS', 'AWSFIS-Run-Network-Latency-ECS'}:
        raise ValueError('Unsupported network experiment document')
    response = aws('ssm', 'list-command-invocations', '--instance-id', managed_instance,
                   '--details', '--filters', json.dumps([{'key': 'InvokedAfter', 'value': after}]))
    return [row for row in response['CommandInvocations']
            if row.get('InstanceId') == managed_instance
            and row.get('DocumentName', '').rsplit('/', 1)[-1] == document
            and (experiment_id is None or row.get('Comment') == 'FIS-' + experiment_id)]


def stopped_network_namespace(aws, task):
    """A removed awsvpc namespace is an alternative to a live endpoint status.

    An absent/offline SSM agent alone is never evidence of fault removal.
    """
    prefix = f'arn:aws:ecs:{REGION}:{ACCOUNT}:task/{CLUSTER}/'
    if not re.fullmatch(re.escape(prefix) + r'[a-f0-9]{32}', task):
        raise ValueError('Task is outside the approved cluster')
    response = aws('ecs', 'describe-tasks', '--cluster', CLUSTER, '--tasks', task)
    rows = response.get('tasks', [])
    if response.get('failures') or len(rows) != 1:
        raise RuntimeError('Cannot verify selected Task lifecycle')
    row = rows[0]
    if row.get('taskArn') != task or row.get('group') != 'service:' + SERVICE:
        raise ValueError('Selected Task is not a market-http service Task')
    if row.get('lastStatus') != 'STOPPED':
        return None
    attachments = [a for a in row.get('attachments', []) if a.get('type') == 'ElasticNetworkInterface']
    containers = row.get('containers', [])
    if (not attachments or any(a.get('status') != 'DELETED' for a in attachments)
            or not containers or any(c.get('lastStatus') != 'STOPPED' for c in containers)):
        raise RuntimeError('Stopped Task network namespace removal is not confirmed')
    return {'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'task': task,
            'operation': 'verify-task-network-removal', 'status': 'not-running',
            'verification_method': 'all containers STOPPED and awsvpc ENI attachments DELETED',
            'stop_code': row.get('stopCode'), 'stop_reason': row.get('stoppedReason'),
            'containers': [{k: c.get(k) for k in ['name', 'lastStatus', 'exitCode', 'reason']}
                           for c in containers]}
