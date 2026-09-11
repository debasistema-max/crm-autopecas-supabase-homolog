import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch


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

    def test_scope_is_limited_to_app_folder(self):
        self.assertEqual(MODULE.SCOPES, "offline_access Files.ReadWrite.AppFolder")
        self.assertNotIn("Files.ReadWrite.All", MODULE.SCOPES)


if __name__ == "__main__":
    unittest.main()
