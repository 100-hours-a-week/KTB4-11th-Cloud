from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import lifecycle


class LifecycleTests(unittest.TestCase):
    def test_permission_error_is_preserved_and_children_are_reaped(self):
        container = {'State': {'Pid': 123}, 'Id': 'a' * 64, 'verified_task_id': 'b' * 32}
        original = lifecycle.subprocess.Popen
        children = []

        def spawn(*args, **kwargs):
            child = original([sys.executable, '-c', "print('permission denied', flush=True)"], **kwargs)
            children.append(child)
            return child
        with tempfile.TemporaryDirectory() as root, \
             patch.object(lifecycle, 'process_start', return_value=None), \
             patch.object(lifecycle.subprocess, 'Popen', side_effect=spawn):
            output = Path(root) / 'capture'
            lifecycle.collect(container, output, .1, 100000)
            text = (output / 'events.jsonl').read_text()
            self.assertIn('collector_stream_closed', text)
            self.assertIn('permission denied', text)
            self.assertIn('target_process_gone', text)
            self.assertTrue(all(c.poll() is not None for c in children))
