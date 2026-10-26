import copy
import unittest

from redis_preflight import network_issues


class RedisReadinessTests(unittest.TestCase):
    def setUp(self):
        self.task = {'enableExecuteCommand': False,
                     'containers': [{'name': 'amazon-ssm-agent', 'lastStatus': 'RUNNING'}]}
        self.definition = {'pidMode': 'task', 'networkMode': 'awsvpc', 'enableFaultInjection': True,
                           'containerDefinitions': [{'name': 'amazon-ssm-agent', 'environment': [
                               {'name': 'MANAGED_INSTANCE_ROLE_NAME', 'value': 'test-managed-role'}]}]}
        self.instances = [{'PingStatus': 'Online'}]

    def test_missing_live_task_prerequisites_are_reported(self):
        definition = {'networkMode': 'awsvpc', 'containerDefinitions': [{'name': 'market-http'}]}
        issues = network_issues({}, definition, [])
        self.assertEqual(len(issues), 4)
        self.assertTrue(any('pidMode' in issue for issue in issues))
        self.assertTrue(any('enableFaultInjection' in issue for issue in issues))

    def test_shared_host_network_and_exec_are_rejected(self):
        definition = copy.deepcopy(self.definition)
        definition['networkMode'] = 'host'
        self.task['enableExecuteCommand'] = True
        self.assertEqual(len(network_issues(self.task, definition, self.instances)), 2)

    def test_duplicate_or_offline_managed_instance_is_rejected(self):
        for instances in [[{'PingStatus': 'ConnectionLost'}], self.instances * 2]:
            self.assertTrue(network_issues(self.task, self.definition, instances))

    def test_complete_configuration_has_no_static_issues(self):
        self.assertEqual(network_issues(self.task, self.definition, self.instances), [])


if __name__ == '__main__':
    unittest.main()
