from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('metrics_task', ROOT / 'scripts/prepare-backend-metrics-task.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class MetricsTaskTest(unittest.TestCase):
    def task(self):
        return {'taskDefinition': {
            'family': 'stockspoon-v2-prod-backend', 'revision': 55, 'status': 'ACTIVE',
            'cpu': '1024', 'memory': '2048', 'taskRoleArn': 'existing-task-role',
            'containerDefinitions': [{'name': 'backend', 'image': 'existing-image',
                'secrets': [{'name': 'JWT_SECRET', 'valueFrom': 'existing-ssm-arn'}],
                'environment': [{'name': 'REDIS_HOST', 'value': 'existing-host'},
                    {'name': 'SPRING_APPLICATION_JSON', 'value': json.dumps({
                        'management': {'endpoint': {'health': {'show-details': 'never'}},
                                       'endpoints': {'web': {'exposure': {'include': 'health'}}}},
                        'spring': {'datasource': {'url': 'existing-jdbc'}}})}]}]},
            'tags': [{'key': 'Environment', 'value': 'prod'}]}

    def test_only_metric_environment_and_requested_image_change(self):
        source = self.task()
        before = deepcopy(source)
        task = prepare.merge_task(source, 'metrics-capable-image')
        self.assertEqual(source, before)
        self.assertNotIn('revision', task)
        self.assertNotIn('status', task)
        self.assertEqual(task['cpu'], '1024')
        self.assertEqual(task['memory'], '2048')
        backend = task['containerDefinitions'][0]
        self.assertEqual(backend['image'], 'metrics-capable-image')
        self.assertEqual(backend['secrets'], source['taskDefinition']['containerDefinitions'][0]['secrets'])
        env = {e['name']: e['value'] for e in backend['environment']}
        self.assertEqual(env['REDIS_HOST'], 'existing-host')
        config = json.loads(env['SPRING_APPLICATION_JSON'])
        self.assertEqual(config['spring.datasource.url'], 'existing-jdbc')
        self.assertEqual(config['management.endpoint.health.show-details'], 'never')
        self.assertEqual(config['management.endpoints.web.exposure.include'], 'health,metrics,prometheus')
        self.assertIs(config['server.tomcat.mbeanregistry.enabled'], True)
        self.assertNotIn('BACKEND_METRICS_COOKIE', env)
        self.assertEqual(task['tags'], source['tags'])

    def test_other_families_and_secret_json_are_rejected(self):
        source = self.task()
        source['taskDefinition']['family'] = 'stockspoon-v2-prod-market-http'
        with self.assertRaises(ValueError):
            prepare.merge_task(source, None)
        source = self.task()
        source['taskDefinition']['containerDefinitions'][0]['secrets'].append({
            'name': 'SPRING_APPLICATION_JSON', 'valueFrom': 'secret'})
        with self.assertRaises(ValueError):
            prepare.merge_task(source, None)

    def test_no_image_override_preserves_the_current_image(self):
        task = prepare.merge_task(self.task(), None)
        self.assertEqual(task['containerDefinitions'][0]['image'], 'existing-image')


if __name__ == '__main__':
    unittest.main()
