import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "build_yokomitsu_catalog_sync", ROOT / "scripts" / "build_yokomitsu_catalog_sync.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class YokomitsuCatalogSyncTest(unittest.TestCase):
    def test_normalizes_official_metadata_and_fallback_image(self):
        record = MODULE.normalize_product({
            "code": 6111032201,
            "name": " Caixa de direção ",
            "productLineName": "Direção",
            "productLineSlug": "direcao",
            "applicationPreview": ["Hilux 2016", "SW4 2017"],
            "updatedAt": "2026-09-17T10:00:00Z",
        })
        self.assertEqual(record["product_code"], "6111032201")
        self.assertEqual(record["applications"], "Hilux 2016 • SW4 2017")
        self.assertEqual(
            record["official_image_url"],
            "https://www.yokomitsu.com.br/uploads/products/6111032201/site/6111032201.webp",
        )

    def test_normalizes_full_product_details(self):
        record = MODULE.normalize_product(
            {"code": "7170505900", "name": "Caixa", "applicationPreview": ["KICKS 16/21"]},
            {
                "code": "7170505900",
                "name": "Caixa de direção",
                "productLineName": "CAIXA DE DIREÇÃO",
                "detailsRaw": "(axial 12mm)",
                "eanGtin": "7898778856942",
                "weightKg": 6,
                "applications": [{"automaker": "NISSAN", "vehicleLabel": "KICKS", "yearLabel": "16/21"}],
                "oemReferences": [{"label": "48001SRA0A"}],
                "similarReferences": [{"label": "27043", "support": "AMPRI"}],
            },
        )
        self.assertEqual(record["applications"], "NISSAN KICKS 16/21")
        self.assertTrue(record["applications_complete"])
        self.assertEqual(record["catalog_details"]["details"], "(axial 12mm)")
        self.assertEqual(record["catalog_details"]["oem_references"][0]["label"], "48001SRA0A")

    def test_reads_all_pages_and_deduplicates_by_product_code(self):
        pages = {
            1: {"pages": 2, "products": [{"code": "100", "name": "A"}]},
            2: {"pages": 2, "products": [{"code": "100", "name": "A2"}, {"code": "200", "name": "B"}]},
        }
        with patch.object(MODULE, "fetch_page", side_effect=lambda page, timeout: pages[page]):
            records = MODULE.build_records(3, include_details=False)
        self.assertEqual([row["product_code"] for row in records], ["100", "200"])
        self.assertEqual(records[0]["product_name"], "A2")

    def test_generates_idempotent_sql_payload(self):
        record = MODULE.normalize_product({"code": "100", "name": "Produto"})
        sql, source_version = MODULE.build_sql([record])
        self.assertIn("sync_yokomitsu_catalog_metadata", sql)
        self.assertIn('"product_code":"100"', sql)
        self.assertRegex(source_version, r"^[a-f0-9]{64}$")
        self.assertIn(f"'{source_version}'", sql)


if __name__ == "__main__":
    unittest.main()
