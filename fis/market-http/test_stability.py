import copy
import unittest
from stability import evaluate


class StabilityTests(unittest.TestCase):
    def setUp(self):
        self.rows = [{'at_ms': i * 10000, 'desired': 2, 'running': 2, 'pending': 0,
                      'task_ids': ['a', 'b'], 'healthy_task_ids': ['a', 'b'], 'alarms_ok': True, 'metrics_fresh': True,
                      'metrics': {t: {'cpu': 0.05, 'working_set_bytes': 200 * 1024**2,
                                      'queue_full_total': 0} for t in ['a', 'b']}}
                     for i in range(19)]

    def test_stable_and_incomplete_or_stale_window(self):
        self.assertTrue(evaluate(self.rows, 2, 180000)['stable'])
        self.assertFalse(evaluate(self.rows[1:], 2, 180000)['stable'])
        self.assertFalse(evaluate(self.rows, 2, 210000)['stable'])
        self.assertFalse(evaluate([], 2, 180000)['stable'])

    def test_replacement_gaps_and_missing_health_fail_closed(self):
        for mutation in ['replacement', 'gap', 'alarm', 'health', 'metric', 'pending', 'nan']:
            rows = copy.deepcopy(self.rows)
            if mutation == 'replacement': rows[-1]['task_ids'] = ['a', 'c']
            if mutation == 'gap': del rows[3:6]
            if mutation == 'alarm': rows[-1]['alarms_ok'] = False
            if mutation == 'health': rows[-1]['healthy_task_ids'] = ['a']
            if mutation == 'metric': del rows[-1]['metrics']['a']
            if mutation == 'pending': rows[-1]['pending'] = 1
            if mutation == 'nan': rows[-1]['metrics']['a']['cpu'] = float('nan')
            with self.subTest(mutation=mutation):
                self.assertFalse(evaluate(rows, 2, 180000)['stable'])

    def test_cpu_memory_growth_overflow_and_counter_reset(self):
        for field, value in [('cpu', 0.9), ('working_set_bytes', 250 * 1024**2),
                             ('queue_full_total', 1)]:
            rows = copy.deepcopy(self.rows);rows[-1]['metrics']['a'][field] = value
            self.assertFalse(evaluate(rows, 2, 180000)['stable'])
        rows = copy.deepcopy(self.rows)
        for row in rows: row['metrics']['a']['queue_full_total'] = 4
        rows[-1]['metrics']['a']['queue_full_total'] = 0
        self.assertFalse(evaluate(rows, 2, 180000)['stable'])


if __name__ == '__main__':
    unittest.main()
