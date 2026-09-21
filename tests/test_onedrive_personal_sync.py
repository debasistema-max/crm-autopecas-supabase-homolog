import importlib.util
import os
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "sync_onedrive_personal.py"
SPEC = importlib.util.spec_from_file_location("onedrive_personal_sync", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class OneDrivePersonalSyncTest(unittest.TestCase):
    def test_missing_configuration_never_echoes_secret(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(MODULE.SyncError, "CONFIGURACAO_AUSENTE:MS_GRAPH_CLIENT_ID"):
                MODULE.synchronize()

    def test_locate_requires_one_exact_xlsx(self):
        responses = [{"value": [
                {"id": "folder-id", "name": "IPS CRM Excel Sync", "folder": {}},
            ]}, {"value": [
                {"id": "wrong", "name": "other.xlsx", "size": 10, "file": {}},
                {"id": "right", "name": "master.xlsx", "size": 100, "file": {"mimeType": "xlsx"}},
            ]}]
        with patch.object(MODULE, "graph_json", side_effect=responses):
            item = MODULE.locate_workbook("token", "master.xlsx", "IPS CRM Excel Sync")
        self.assertEqual(item["id"], "right")

    def test_locate_resolves_exact_folder_to_item_id(self):
        responses = [{"value": [
                {"id": "folder-id", "name": "IPS CRM Excel Sync", "folder": {}},
            ]}, {"value": [
                {"id": "right", "name": "master.xlsx", "size": 100, "file": {"mimeType": "xlsx"}},
            ]}]
        with patch.object(MODULE, "graph_json", side_effect=responses) as graph:
            item = MODULE.locate_workbook("token", "master.xlsx", "IPS CRM Excel Sync")
        self.assertEqual(item["id"], "right")
        self.assertIn("/me/drive/items/folder-id/children", graph.call_args.args[0])

    def test_edge_uses_only_dedicated_scheduler_secret(self):
        with patch.object(MODULE, "request_json", return_value={"ok": True}) as request:
            MODULE.edge_call("https://example.test/sync", "private", {"operation": "create"})
        self.assertEqual(request.call_args.kwargs["headers"], {"x-sync-secret": "private"})
        self.assertNotIn("Authorization", request.call_args.kwargs["headers"])

    def test_process_batch_resumes_in_idempotent_chunks(self):
        responses = [
            {"batch": {"state": "DRAFT"}},
            {"staged_rows": 1},
            {"batch": {"state": "DRAFT"}},
            {"done": True, "batch": {"state": "PREVIEWED"}},
            {"done": False, "processed": 1, "remaining": 1},
            {"done": True, "batch": {"state": "COMMITTED"}},
        ]
        with patch.object(MODULE, "edge_call", side_effect=responses) as edge:
            result = MODULE.process_batch("https://example.test", "secret", "batch", [{"row_number": 1}])
        operations = [call.args[2]["operation"] for call in edge.call_args_list]
        self.assertEqual(operations, ["prepare", "stage", "status", "validate", "commit", "commit"])
        self.assertEqual(result["state"], "COMMITTED")

    def test_process_batch_skips_completed_duplicate(self):
        with patch.object(MODULE, "edge_call", return_value={"batch": {"state": "COMMITTED"}}) as edge:
            result = MODULE.process_batch("https://example.test", "secret", "batch", [])
        self.assertEqual(result["state"], "COMMITTED")
        self.assertEqual(edge.call_count, 1)

    def test_graph_timestamp_overrides_download_mtime(self):
        with patch.dict(os.environ, {
            "MS_GRAPH_CLIENT_ID": "client", "MS_GRAPH_REFRESH_TOKEN": "refresh",
            "ONEDRIVE_WORKBOOK_NAME": "master.xlsx", "DATA_SYNC_EDGE_URL": "https://example.test/sync",
            "DATA_SYNC_SCHEDULER_SECRET": "sync-secret",
        }, clear=True), patch.object(MODULE, "access_token", return_value="access"), \
                patch.object(MODULE, "locate_workbook", return_value={
                    "id": "item", "name": "master.xlsx", "size": 4, "eTag": "etag",
                    "lastModifiedDateTime": "2026-09-10T22:33:33Z", "file": {},
                }), patch.object(MODULE.tempfile, "TemporaryDirectory", return_value=nullcontext(str(Path.cwd()))), \
                patch.object(MODULE, "download_workbook") as download, \
                patch.object(MODULE, "graph_json", return_value={
                    "id": "item", "size": 4, "eTag": "etag", "lastModifiedDateTime": "2026-09-10T22:33:33Z",
                }), patch.object(MODULE.excel_payload, "build", return_value={
                    "source_name": "Excel Mestre", "source_version": "hash", "source_updated_at": "2026-09-10T22:33:33Z",
                    "file_hash": "0" * 64, "original_filename": "master.xlsx", "file_size": 4,
                    "records": [], "summary": {"records": 0},
                    "fiscal_bases": {
                        "ncm_rules": [{"rule_key": "84136019|PR|PR"}],
                        "group_rules": [{"rule_key": "84136019|GRUPO|PR-PR"}],
                    },
                }) as build, patch.object(MODULE, "edge_call", side_effect=[
                    {"duplicate": True, "batch_id": "batch"},
                    {"batch": {"state": "COMMITTED"}},
                    {"source_version": "hash", "ncm_rules": 1, "group_rules": 1},
                ]) as edge:
            result = MODULE.synchronize()
        download.assert_called_once()
        self.assertEqual(build.call_args.args[1], "2026-09-10T22:33:33Z")
        self.assertTrue(result["duplicate"])
        self.assertEqual(edge.call_args_list[-1].args[2]["operation"], "fiscal-bases")
        self.assertEqual(result["fiscal_bases"]["group_rules"], 1)


if __name__ == "__main__":
    unittest.main()
