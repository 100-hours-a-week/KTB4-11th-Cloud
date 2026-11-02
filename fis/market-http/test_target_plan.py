import copy
import json
import unittest
from target_plan import validate

OLD = 'arn:aws:ecs:ap-northeast-2:250832562715:task/stockspoon-v2-prod-cluster/' + '1' * 32
NEW = OLD.rsplit('/', 1)[0] + '/' + '2' * 32


class TargetPlanTests(unittest.TestCase):
    def setUp(self):
        before = {'target': [{'resource_arns': [OLD], 'parameters': {}}],
                  'action': [{'duration': 'PT10M'}]}
        after = copy.deepcopy(before);after['target'][0] = {'resource_arns': [NEW], 'parameters': None}
        self.plan = {'resource_changes': [{'address': 'aws_fis_experiment_template.stop_peak',
                      'change': {'actions': ['update'], 'before': before, 'after': after, 'after_unknown': {}}}]}

    def test_only_task_update_and_iam_policy_references(self):
        before = {'policy': json.dumps({'Statement': [{'Resource': OLD, 'Action': 'ecs:StopTask'}]})}
        after = {'policy': json.dumps({'Statement': [{'Action': 'ecs:StopTask', 'Resource': NEW}]})}
        self.plan['resource_changes'].append({'address': 'aws_iam_role_policy.fis',
            'change': {'actions': ['update'], 'before': before, 'after': after}})
        self.assertEqual(len(validate(self.plan, NEW)['updates']), 2)
        after['policy'] = json.dumps({'Statement': [{'Action': 'ecs:StopTask', 'Resource': '*'}]})
        with self.assertRaises(ValueError):validate(self.plan, NEW)

    def test_other_changes_and_unknown_values_rejected(self):
        for mutation in ['create', 'resource', 'duration', 'unknown', 'other-target', 'two-targets']:
            plan = copy.deepcopy(self.plan);r = plan['resource_changes'][0];c = r['change']
            if mutation == 'create': c['actions'] = ['delete', 'create']
            if mutation == 'resource': r['address'] = 'aws_ecs_service.market_http'
            if mutation == 'duration': c['after']['action'][0]['duration'] = 'PT12M'
            if mutation == 'unknown': c['after_unknown'] = {'role_arn': True}
            if mutation == 'other-target': c['after']['target'][0]['resource_arns'] = [OLD]
            if mutation == 'two-targets': c['after']['target'][0]['resource_arns'] = [NEW, OLD]
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):validate(plan, NEW)


if __name__ == '__main__':
    unittest.main()
