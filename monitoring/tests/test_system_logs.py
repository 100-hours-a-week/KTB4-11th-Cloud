from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/deploy/system-logs.sh'


class SystemJournalDiscoveryTest(unittest.TestCase):
    def discover(self, root):
        return subprocess.run(
            ['bash', '-c', 'source "$1"; detect_system_journal "$2"',
             'journal-test', str(HELPER), str(root)],
            text=True, capture_output=True,
        )

    def test_empty_persistent_directory_does_not_hide_active_volatile_journal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'var/log/journal').mkdir(parents=True)
            active = root / 'run/log/journal/machine/system.journal'
            active.parent.mkdir(parents=True)
            active.touch()
            result = self.discover(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), '/host/run/log/journal')

    def test_persistent_journal_is_selected_when_both_stores_exist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for store in ['var', 'run']:
                journal = root / store / 'log/journal/machine/system.journal'
                journal.parent.mkdir(parents=True)
                journal.touch()
            result = self.discover(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), '/host/var/log/journal')

    def test_missing_journal_fails_without_creating_host_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.discover(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
            self.assertIn('configuration was not installed', result.stderr)
            self.assertEqual(list(root.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
