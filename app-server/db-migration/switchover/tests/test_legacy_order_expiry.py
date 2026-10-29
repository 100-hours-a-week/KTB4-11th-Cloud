import io
from pathlib import Path
import sys
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).parents[1]))
from check_legacy_order_expiry import inspect_archive


class LegacyOrderExpiryTests(unittest.TestCase):
    def inspect(self, service, subscription, path="BOOT-INF/classes/com/stock_spoon/river_be/order/"):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            archive.writestr(path + "OrderService.class", service)
            archive.writestr(path + "OrderSubscriptionService.class", subscription)
        with zipfile.ZipFile(data) as archive:
            return inspect_archive(archive)

    def test_legacy_expiry_code_blocks_rehearsal_without_changing_the_container(self):
        result = self.inspect(b"cancelExpiredPendingOrders", b"cancelExpiredPendingOrders")
        self.assertFalse(result["readyForOffHoursRehearsal"])
        self.assertEqual(result["status"], "legacy_expiry_code_detected")
        self.assertEqual(len(result["classSha256"]), 2)

    def test_current_package_layout_without_legacy_method_is_compatible(self):
        result = self.inspect(b"cancelPending", b"refresh", path="com/stock_spoon/river_be/order/service/")
        self.assertTrue(result["readyForOffHoursRehearsal"])

    def test_unknown_jar_layout_is_not_reported_as_compatible(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w"):
            pass
        with zipfile.ZipFile(data) as archive:
            self.assertFalse(inspect_archive(archive)["readyForOffHoursRehearsal"])
