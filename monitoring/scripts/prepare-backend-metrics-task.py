#!/usr/bin/env python3
"""Merge metric environment overrides into a saved ECS task definition; never deploy."""
import argparse
from copy import deepcopy
import json
import os
from pathlib import Path

# describe-task-definition includes read-only fields that RegisterTaskDefinition rejects.
REGISTER_FIELDS = {'family', 'taskRoleArn', 'executionRoleArn', 'networkMode',
                   'containerDefinitions', 'volumes', 'placementConstraints',
                   'requiresCompatibilities', 'cpu', 'memory', 'pidMode', 'ipcMode',
                   'proxyConfiguration', 'inferenceAccelerators', 'ephemeralStorage',
                   'runtimePlatform', 'enableFaultInjection'}


def merge_task(document, image):
    source = document.get('taskDefinition', document)
    if source.get('family') != 'stockspoon-v2-prod-backend':
        raise ValueError('Expected only the production REST backend task family')
    task = {key: deepcopy(value) for key, value in source.items() if key in REGISTER_FIELDS}
    backend = [c for c in task['containerDefinitions'] if c['name'] == 'backend']
    if len(backend) != 1:
        raise ValueError('Expected exactly one backend container')
    container = backend[0]
    if any(secret['name'] == 'SPRING_APPLICATION_JSON' for secret in container.get('secrets', [])):
        raise ValueError('Cannot merge secret-backed SPRING_APPLICATION_JSON without its existing configuration')
    environment = {item['name']: item['value'] for item in container.get('environment', [])}
    application = json.loads(environment.get('SPRING_APPLICATION_JSON', '{}'))
    if not isinstance(application, dict):
        raise ValueError('Existing SPRING_APPLICATION_JSON must be an object')
    # Normalize nested objects before overriding so equivalent nested/flat keys
    # cannot silently override these settings depending on insertion order.
    def flatten(value, prefix=''):
        result = {}
        for key, item in value.items():
            name = prefix + '.' + key if prefix else key
            if isinstance(item, dict):
                result.update(flatten(item, name))
            else:
                result[name] = item
        return result
    application = flatten(application)
    # Flat Spring property names preserve unrelated configuration.
    application.update({
        'management.endpoints.web.exposure.include': 'health,metrics,prometheus',
        'server.tomcat.mbeanregistry.enabled': True,
        'management.metrics.distribution.percentiles-histogram.http.server.requests': True,
        'management.metrics.distribution.minimum-expected-value.http.server.requests': '1ms',
        'management.metrics.distribution.maximum-expected-value.http.server.requests': '30s',
    })
    environment['SPRING_APPLICATION_JSON'] = json.dumps(application, separators=(',', ':'))
    # The ordinary backend does not need the Alloy credential or the JWT signing key copied into env.
    container['environment'] = [{'name': key, 'value': value} for key, value in environment.items()]
    if image:
        container['image'] = image
    if document.get('tags'):
        task['tags'] = deepcopy(document['tags'])
    return task


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--task-definition', type=Path, required=True)
    parser.add_argument('--image', help='Existing image containing micrometer-registry-prometheus; this tool cannot add it')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        task = merge_task(json.loads(args.task_definition.read_text()), args.image)
    except (ValueError, KeyError) as error:
        parser.error(str(error))
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(task, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    print(f'Prepared {args.output}. No AWS request or deployment performed.')
    print('The image must already contain the Prometheus registry. Registration alone is not a service rollout.')


if __name__ == '__main__':
    main()
