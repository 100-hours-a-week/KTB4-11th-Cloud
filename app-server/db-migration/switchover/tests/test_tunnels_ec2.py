"""Local tunnel reuse planning tests; no AWS sessions are opened."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

module_path = Path(__file__).parents[1] / "tunnels_ec2.py"
spec = importlib.util.spec_from_file_location("tunnels_ec2", module_path)
tunnels_ec2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tunnels_ec2)


class TunnelReuseTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "proxy_admin": {"host": "127.0.0.1", "port": 16032},
            "proxy_app": {"host": "127.0.0.1", "port": 16033},
        }
        self.forwards = [("proxy_admin", 6032), ("proxy_app", 6033)]

    def test_existing_forward_ports_are_reused(self):
        with patch.object(tunnels_ec2.socket, "socket") as socket_factory:
            reused, to_start = tunnels_ec2.plan_forwards(
                self.config, self.forwards, listener=Mock(return_value=True))
        self.assertEqual(reused, ["proxy_admin", "proxy_app"])
        self.assertEqual(to_start, [])
        socket_factory.assert_not_called()

    def test_only_missing_forward_is_started(self):
        listener = Mock(side_effect=[True, False])
        with patch.object(tunnels_ec2.socket, "socket") as socket_factory:
            reused, to_start = tunnels_ec2.plan_forwards(self.config, self.forwards, listener=listener)
        self.assertEqual(reused, ["proxy_admin"])
        self.assertEqual(to_start, [("proxy_app", 6033)])
        socket_factory.return_value.__enter__.return_value.bind.assert_called_once_with(("127.0.0.1", 16033))

    def test_non_loopback_proxy_endpoint_is_rejected(self):
        self.config["proxy_admin"]["host"] = "0.0.0.0"
        with self.assertRaisesRegex(RuntimeError, "127.0.0.1"):
            tunnels_ec2.plan_forwards(self.config, self.forwards, listener=Mock())

    def test_occupied_non_accepting_port_has_clear_error(self):
        with patch.object(tunnels_ec2.socket, "socket") as socket_factory:
            socket_factory.return_value.__enter__.return_value.bind.side_effect = OSError("address in use")
            with self.assertRaisesRegex(RuntimeError, "occupied but not accepting"):
                tunnels_ec2.plan_forwards(self.config, self.forwards, listener=Mock(return_value=False))


if __name__ == "__main__":
    unittest.main()
