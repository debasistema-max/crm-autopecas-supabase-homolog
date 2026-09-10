import importlib.util
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "build_excel_sync_payload.py"
SPEC = importlib.util.spec_from_file_location("excel_sync_payload", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ExcelSyncAdapterTest(unittest.TestCase):
    def test_product_codes_from_excel(self):
        self.assertEqual(MODULE.product_code(6111032201), "6111032201")
        self.assertEqual(MODULE.product_code(" 6111032201.0 "), "6111032201")
        self.assertEqual(MODULE.product_code("6.111032201E+9"), "6111032201")
        self.assertEqual(MODULE.product_code("\u200bABC-01\ufeff"), "ABC-01")

    def test_explicit_zero_is_not_missing(self):
        fields = {}
        MODULE.put(fields, "stock_qty", MODULE.number(0))
        self.assertIn("stock_qty", fields)
        self.assertEqual(fields["stock_qty"], 0)

    def test_empty_and_invalid_numbers_are_missing(self):
        self.assertIsNone(MODULE.number(""))
        self.assertIsNone(MODULE.number("ABC"))

    def test_percentages_become_fractional(self):
        self.assertEqual(MODULE.rate("9.75%"), 0.0975)
        self.assertEqual(MODULE.rate(15), 0.15)
        self.assertEqual(MODULE.rate(0), 0.0)

    def test_workbook_changed_during_read_is_rejected(self):
        class ChangingSource:
            name = "master.xlsx"

            def __init__(self):
                self.read_count = 0

            def stat(self):
                return SimpleNamespace(st_mtime=1, st_mtime_ns=1, st_size=3)

            def read_bytes(self):
                self.read_count += 1
                return b"one" if self.read_count == 1 else b"two"

        workbook = SimpleNamespace(close=MagicMock())
        with patch.object(MODULE, "load_workbook", return_value=workbook), \
                patch.object(MODULE, "read_products"), patch.object(MODULE, "read_stock"), \
                patch.object(MODULE, "read_prices"):
            with self.assertRaisesRegex(RuntimeError, "EXCEL_ALTERADO_DURANTE_LEITURA"):
                MODULE.build(ChangingSource())
        workbook.close.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
