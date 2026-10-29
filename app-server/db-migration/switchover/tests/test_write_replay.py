import sys
from pathlib import Path
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).parents[1]))
from write_replay import drain, validate_options


def result(status="queue_empty", applied=0, duplicates=0, already=0, **details):
    return dict(status=status, processed=applied + duplicates + already,
                applied=applied, duplicates=duplicates, alreadySatisfied=already, **details)


class ReplayRecoveryTests(unittest.TestCase):
    def run_drain(self, results, **options):
        invoke = Mock(side_effect=results)
        sleep = Mock()
        outcome = drain(invoke, sleep=sleep, **options)
        return outcome, invoke, sleep

    def test_message_and_runtime_limits_resume_until_quiet_and_keep_all_counts(self):
        outcome, invoke, _ = self.run_drain([
            result("message_limit", applied=100), result("runtime_limit", applied=1),
            result(already=1), result()])
        self.assertTrue(outcome["drainComplete"])
        self.assertEqual(outcome["status"], "queue_empty")
        self.assertEqual((outcome["processed"], outcome["applied"], outcome["alreadySatisfied"]), (102, 101, 1))
        self.assertEqual(invoke.call_count, 4)

    def test_retryable_head_is_reinvoked_only_after_visibility_was_released(self):
        outcome, invoke, sleep = self.run_drain([
            result("blocked", retryable=True, releasedForRetry=True), result(duplicates=1), result()])
        self.assertTrue(outcome["drainComplete"])
        self.assertEqual(outcome["duplicates"], 1)
        self.assertEqual(invoke.call_count, 3)
        sleep.assert_any_call(2)

    def test_business_conflict_and_unreleased_heads_stop_without_bypassing_fifo(self):
        for details in [dict(retryable=False, releasedForRetry=True),
                        dict(retryable=True, releasedForRetry=False)]:
            with self.subTest(details=details):
                outcome, invoke, _ = self.run_drain([result("blocked", **details)])
                self.assertFalse(outcome["drainComplete"])
                self.assertEqual(outcome["status"], "blocked")
                self.assertEqual(invoke.call_count, 1)

    def test_work_arriving_after_an_empty_drain_restarts_quiet_confirmation(self):
        outcome, invoke, _ = self.run_drain([result(), result(applied=1), result()])
        self.assertTrue(outcome["drainComplete"])
        self.assertEqual(invoke.call_count, 3)
        self.assertEqual(outcome["quietPasses"], 2)

    def test_unconfirmed_invocation_never_starts_another_consumer(self):
        outcome, invoke, _ = self.run_drain([TimeoutError("response lost")])
        self.assertEqual(outcome["status"], "invocation_unconfirmed")
        self.assertEqual(outcome["invocations"], 1)
        self.assertFalse(outcome["drainComplete"])
        self.assertEqual(invoke.call_count, 1)

    def test_malformed_or_inconsistent_lambda_response_is_not_success(self):
        for response in [dict(StatusCode=200), result(applied=True),
                         {**result(applied=1), "processed": 2}]:
            with self.subTest(response=response):
                outcome, invoke, _ = self.run_drain([response])
                self.assertEqual(outcome["status"], "invalid_response")
                self.assertFalse(outcome["drainComplete"])

    def test_repeated_limits_stop_at_bounded_invocation_count(self):
        outcome, invoke, _ = self.run_drain([result("runtime_limit")] * 2, max_invocations=2)
        self.assertEqual(outcome["status"], "recovery_invocation_limit")
        self.assertEqual(invoke.call_count, 2)
        self.assertFalse(outcome["drainComplete"])

    def test_invalid_configuration_is_rejected_before_switchover(self):
        base = {"function_name": "stockspoon-v2-prod-db-write-replay-forwarder"}
        for invalid in [{"function_name": "teammate-order-consumer"},
                        {"max_messages": 0}, {"max_invocations": 0}, {"budget_seconds": 20},
                        {"retry_delay_seconds": 61}, {"quiet_passes": True}]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                validate_options({**base, **invalid})


if __name__ == "__main__":
    unittest.main()
