import importlib.util
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from openpyxl import Workbook


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

    def test_money_is_rounded_to_cents_before_sync(self):
        self.assertEqual(MODULE.money(197.51999999999998), 197.52)
        self.assertEqual(MODULE.money(49.540000000000006), 49.54)
        self.assertEqual(MODULE.money("10,125"), 10.13)
        self.assertIsNone(MODULE.money(""))

    def test_percentages_become_fractional(self):
        self.assertEqual(MODULE.rate("9.75%"), 0.0975)
        self.assertEqual(MODULE.rate(15), 0.15)
        self.assertEqual(MODULE.rate(0), 0.0)

    def test_excel_fraction_preserves_rates_above_one_hundred_percent(self):
        self.assertEqual(MODULE.workbook_fraction_rate(1.5608946), 1.5608946)
        self.assertAlmostEqual(MODULE.workbook_fraction_rate("156.08946%"), 1.5608946)

    def test_fiscal_bases_include_ncm_and_group_rules(self):
        workbook = Workbook()
        ncm_sheet = workbook.active
        ncm_sheet.title = "Dados Fiscais"
        ncm_sheet.append([
            "NCM", "UF Origem", "UF Destino", "CEST", "MVA SAP", "ICMS Inter",
            "ICMS Interna", "IPI", "Observações",
        ])
        ncm_sheet.append(["84.13.60.19", "pr", "PR", "01.002.00", "87,78%", 0.12, 0.195, 0, "SAP"])
        group_sheet = workbook.create_sheet("Regras por Grupo")
        group_sheet.append(["memória auxiliar"])
        group_sheet.append([
            "NCM", "Grupo de Item", "Rota", "MVA Derivada", "IPI Correto",
            "ICMS Inter", "ICMS Interna", "ST Aplicável", "Base Amostra",
            "Preço SAP", "ST Alvo", "Código Amostra",
        ])
        group_sheet.append([
            "84136019", "752 ROT. BOMBA DIR. (KIT)", "PR-PR", 0.8777275, 0,
            0.12, 0.195, "Sim", 255, 317.77, 62.77, 7182915201,
        ])

        fiscal = MODULE.read_fiscal_bases(workbook)

        self.assertEqual(len(fiscal["ncm_rules"]), 1)
        self.assertEqual(fiscal["ncm_rules"][0]["rule_key"], "84136019|PR|PR")
        self.assertEqual(fiscal["ncm_rules"][0]["cest"], "0100200")
        self.assertTrue(fiscal["ncm_rules"][0]["has_st"])
        self.assertEqual(len(fiscal["group_rules"]), 1)
        self.assertEqual(fiscal["group_rules"][0]["sample_product_code"], "7182915201")
        self.assertEqual(fiscal["group_rules"][0]["sample_final_price"], 317.77)

        group_sheet.append([
            "85115010", "420 ALTERNADOR", "PR-PR", 1.5608946, 0,
            0.12, 0.195, "Sim", 677.80, 934.94, 204.24, 4275521050,
        ])
        fiscal = MODULE.read_fiscal_bases(workbook)
        self.assertEqual(fiscal["group_rules"][1]["mva_rate"], 1.5608946)

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
                patch.object(MODULE, "read_prices"), patch.object(MODULE, "read_fiscal_bases"):
            with self.assertRaisesRegex(RuntimeError, "EXCEL_ALTERADO_DURANTE_LEITURA"):
                MODULE.build(ChangingSource())
        workbook.close.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
