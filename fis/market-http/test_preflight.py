import copy
import unittest

from preflight import ACCOUNT, CLUSTER, REGION, SERVICE, validate_snapshot


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.arn = f"arn:aws:ecs:{REGION}:{ACCOUNT}:task/{CLUSTER}/" + "a" * 32
        self.service = {"serviceName": SERVICE, "status": "ACTIVE", "desiredCount": 2,
                        "runningCount": 2, "pendingCount": 0, "taskDefinition": "definition:40",
                        "deployments": [{"rolloutState": "COMPLETED"}]}
        self.tasks = [{"taskArn": self.arn, "group": f"service:{SERVICE}",
                       "lastStatus": "RUNNING", "healthStatus": "HEALTHY",
                       "taskDefinitionArn": "definition:40", "attachments": [{"details": [
                           {"name": "privateIPv4Address", "value": "10.0.1.1"}]}]}]
        other = copy.deepcopy(self.tasks[0])
        other["taskArn"] = self.arn[:-32] + "b" * 32
        other["attachments"][0]["details"][0]["value"] = "10.0.1.2"
        self.tasks.append(other)
        self.targets = [{"Target": {"Id": ip}, "TargetHealth": {"State": "healthy"}}
                        for ip in ("10.0.1.1", "10.0.1.2")]
        self.alarms = [{"StateValue": "OK"}]

    def check(self):
        validate_snapshot(self.service, self.tasks, self.arn, self.targets, self.alarms)

    def test_healthy_service(self):
        self.check()

    def test_backend_membership_is_rejected(self):
        self.tasks[0]["group"] = "service:stockspoon-v2-prod-backend"
        with self.assertRaises(ValueError):
            self.check()

    def test_replaced_task_is_rejected(self):
        self.arn = self.arn[:-32] + "c" * 32
        with self.assertRaises(ValueError):
            self.check()

    def test_pending_deployment_is_rejected(self):
        self.service["deployments"][0]["rolloutState"] = "IN_PROGRESS"
        with self.assertRaises(ValueError):
            self.check()

    def test_alarm_or_missing_alarm_is_rejected(self):
        for alarms in ([], [{"StateValue": "ALARM"}], [{"StateValue": "INSUFFICIENT_DATA"}]):
            self.alarms = alarms
            with self.assertRaises(ValueError):
                self.check()

    def test_unhealthy_or_foreign_target_is_rejected(self):
        self.targets[0]["Target"]["Id"] = "10.0.99.99"
        with self.assertRaises(ValueError):
            self.check()


if __name__ == "__main__":
    unittest.main()
