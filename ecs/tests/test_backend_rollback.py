"""Controller decisions and retry safety; no AWS calls or credentials."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location("backend_rollback", Path(__file__).parents[1] / "lambda/backend_rollback.py")
rollback = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rollback)


class RollbackTests(unittest.TestCase):
    def setUp(self):
        self.config = dict(account="123", region="ap-northeast-2", parameter="/latch", rule_arn="rule", v1="blue", v2="green", alarms=["errors", "unhealthy"], schedule_arn="schedule")
        self.event = {"source": "aws.events", "detail-type": "Scheduled Event", "account": "123", "region": "ap-northeast-2", "resources": ["schedule"], "id": "event-1"}
        self.elb, self.ssm, self.cw = Mock(), Mock(), Mock()
        self.latch("armed")
        self.cw.describe_alarms.return_value = {"MetricAlarms": [{"AlarmName": "errors", "StateValue": "ALARM"}, {"AlarmName": "unhealthy", "StateValue": "OK"}]}
        self.elb.describe_target_health.return_value = {"TargetHealthDescriptions": [{"TargetHealth": {"State": "healthy"}}]}
        self.elb.describe_rules.side_effect = [self.rule(0, 100), self.rule(100, 0)]

    def latch(self, state):
        self.ssm.get_parameter.return_value = {"Parameter": {"Value": state}}

    @staticmethod
    def rule(blue, green):
        return {"Rules": [{"Actions": [{"Type": "forward", "ForwardConfig": {"TargetGroups": [{"TargetGroupArn": "blue", "Weight": blue}, {"TargetGroupArn": "green", "Weight": green}]}}]}]}

    def run_controller(self):
        return rollback.reconcile(self.event, self.config, self.elb, self.ssm, self.cw)

    def test_rolls_back_and_persists_latch_before_mutation(self):
        order = Mock()
        order.attach_mock(self.ssm, "ssm")
        order.attach_mock(self.elb, "elb")
        self.assertEqual(self.run_controller()["status"], "rolled_back")
        names = [c[0] for c in order.mock_calls]
        self.assertLess(names.index("ssm.put_parameter"), names.index("elb.modify_rule"))
        self.assertEqual(self.elb.modify_rule.call_args.kwargs["RuleArn"], "rule")
        groups = self.elb.modify_rule.call_args.kwargs["Actions"][0]["ForwardConfig"]["TargetGroups"]
        self.assertEqual(groups, [{"TargetGroupArn": "blue", "Weight": 100}, {"TargetGroupArn": "green", "Weight": 0}])

    def test_disarmed_never_mutates_or_checks_alarms(self):
        self.latch("disarmed")
        self.assertEqual(self.run_controller()["status"], "disarmed")
        self.elb.describe_rules.assert_not_called()
        self.cw.describe_alarms.assert_not_called()

    def test_recovered_alarm_is_ignored(self):
        self.cw.describe_alarms.return_value["MetricAlarms"][0]["StateValue"] = "OK"
        self.assertEqual(self.run_controller()["status"], "healthy")
        self.elb.modify_rule.assert_not_called()

    def test_tripped_reconciles_drift_even_when_alarms_recover(self):
        self.latch("tripped")
        self.cw.describe_alarms.return_value["MetricAlarms"][0]["StateValue"] = "OK"
        self.assertEqual(self.run_controller()["status"], "rolled_back")
        self.ssm.put_parameter.assert_not_called()

    def test_duplicate_is_idempotent(self):
        self.latch("tripped")
        self.elb.describe_rules.side_effect = [self.rule(100, 0)]
        self.assertEqual(self.run_controller()["status"], "already_v1")
        self.elb.modify_rule.assert_not_called()
        self.ssm.put_parameter.assert_not_called()

    def test_v1_unhealthy_blocks_rollback(self):
        self.elb.describe_target_health.return_value = {"TargetHealthDescriptions": [{"TargetHealth": {"State": "unhealthy"}}]}
        with self.assertRaisesRegex(RuntimeError, "V1 has no healthy"):
            self.run_controller()
        self.elb.modify_rule.assert_not_called()
        self.ssm.put_parameter.assert_not_called()

    def test_latch_write_failure_prevents_alb_mutation(self):
        self.ssm.put_parameter.side_effect = RuntimeError("denied")
        with self.assertRaisesRegex(RuntimeError, "denied"):
            self.run_controller()
        self.elb.modify_rule.assert_not_called()

    def test_modify_failure_keeps_latch_tripped_for_retry(self):
        self.elb.modify_rule.side_effect = RuntimeError("timeout")
        with self.assertRaisesRegex(RuntimeError, "timeout"):
            self.run_controller()
        self.ssm.put_parameter.assert_called_once_with(Name="/latch", Value="tripped", Type="String", Overwrite=True)

    def test_confirmation_failure_is_not_reported_as_success(self):
        self.elb.describe_rules.side_effect = [self.rule(0, 100), self.rule(0, 100)]
        with self.assertRaisesRegex(RuntimeError, "not yet confirmed"):
            self.run_controller()

    def test_unexpected_rule_groups_are_not_overwritten(self):
        bad = self.rule(0, 100)
        bad["Rules"][0]["Actions"][0]["ForwardConfig"]["TargetGroups"][1]["TargetGroupArn"] = "other-service"
        self.elb.describe_rules.side_effect = [bad]
        with self.assertRaisesRegex(RuntimeError, "Unexpected target"):
            self.run_controller()
        self.elb.modify_rule.assert_not_called()

    def test_unknown_latch_fails_closed(self):
        self.latch("typo")
        with self.assertRaisesRegex(ValueError, "Invalid rollback latch"):
            self.run_controller()
        self.elb.modify_rule.assert_not_called()

    def test_foreign_event_rejected(self):
        self.event["account"] = "other"
        with self.assertRaises(ValueError):
            self.run_controller()
        self.ssm.get_parameter.assert_not_called()

    def test_unrelated_schedule_rejected(self):
        self.event["resources"] = ["another-schedule"]
        with self.assertRaises(ValueError):
            self.run_controller()

    def test_missing_alarm_fails_instead_of_silent_success(self):
        self.cw.describe_alarms.return_value = {"MetricAlarms": []}
        with self.assertRaisesRegex(RuntimeError, "alarms missing"):
            self.run_controller()

    def test_alarm_event_validated_then_rechecked(self):
        self.event.update(source="aws.cloudwatch", **{"detail-type": "CloudWatch Alarm State Change", "resources": ["arn:aws:cloudwatch:ap-northeast-2:123:alarm:errors"], "detail": {"alarmName": "errors", "state": {"value": "ALARM"}}})
        self.assertEqual(self.run_controller()["status"], "rolled_back")

    def test_unrelated_alarm_rejected(self):
        self.event.update(source="aws.cloudwatch", **{"detail-type": "CloudWatch Alarm State Change", "resources": ["arn:aws:cloudwatch:ap-northeast-2:123:alarm:other"], "detail": {"alarmName": "other", "state": {"value": "ALARM"}}})
        with self.assertRaises(ValueError):
            self.run_controller()


if __name__ == "__main__":
    unittest.main()
