import importlib.util
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "authorize_onedrive_personal.py"
SPEC = importlib.util.spec_from_file_location("authorize_onedrive_personal", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AuthorizeOneDrivePersonalTest(unittest.TestCase):
    def test_refresh_token_is_sent_through_stdin(self):
        with patch.object(MODULE.subprocess, "run") as run:
            MODULE.store_github_secret("owner/private", "secret-refresh-token")
        args, kwargs = run.call_args
        self.assertNotIn("secret-refresh-token", args[0])
        self.assertEqual(kwargs["input"], "secret-refresh-token")
        self.assertTrue(kwargs["check"])

    def test_scope_is_read_only(self):
        self.assertEqual(MODULE.SCOPES, "offline_access Files.Read")
        self.assertNotIn("ReadWrite", MODULE.SCOPES)

    def test_workbook_is_verified_before_secret_can_be_stored(self):
        response = {"value": [{"id": "item", "name": "master.xlsx", "size": 10, "file": {"mimeType": "xlsx"}}]}
        mock_response = MagicMock()
        mock_response.__enter__.return_value.read.return_value = __import__("json").dumps(response).encode()
        with patch.object(MODULE.urllib.request, "urlopen", return_value=mock_response):
            MODULE.verify_workbook("access", "Apps/IPS CRM Excel Sync", "master.xlsx")


if __name__ == "__main__":
    unittest.main()
