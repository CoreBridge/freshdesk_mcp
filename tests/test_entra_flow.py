"""Sign-in flow selection (interactive vs device code) and token-cache encryption handling."""

import asyncio
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import azure.identity

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src.freshdesk_mcp import auth  # noqa: E402
from src.freshdesk_mcp.auth import (  # noqa: E402
    FLOW_DEVICE_CODE,
    FLOW_INTERACTIVE,
    AuthConfigError,
    EntraTokenProvider,
    load_settings,
)

GATEWAY = "cus-cb-fd-gateway-abc.centralus-01.azurewebsites.net"
LIBSECRET_FAILURE = (
    "Cache encryption is impossible because libsecret dependencies are not installed or are "
    "unusable, for example because no display is available (as in an SSH session)."
)


class RecordingCredential:
    """Captures how a credential class was constructed."""

    instances = []

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        RecordingCredential.instances.append((type(self).__name__, kwargs))


class FakeInteractive(RecordingCredential):
    pass


class FakeDeviceCode(RecordingCredential):
    pass


class FlowSettingsTests(unittest.TestCase):
    def test_interactive_is_the_default(self):
        s = load_settings({"FRESHDESK_DOMAIN": GATEWAY})
        self.assertEqual(s.entra_flow, FLOW_INTERACTIVE)
        self.assertFalse(s.allow_unencrypted_cache)
        self.assertIsNone(s.error)

    def test_device_code_is_selectable(self):
        for spelling in ("device_code", "Device-Code", " devicecode "):
            with self.subTest(spelling=spelling):
                s = load_settings({"FRESHDESK_DOMAIN": GATEWAY, "FRESHDESK_ENTRA_FLOW": spelling})
                self.assertEqual(s.entra_flow, FLOW_DEVICE_CODE)
                self.assertIsNone(s.error)

    def test_unknown_flow_is_a_configuration_error(self):
        s = load_settings({"FRESHDESK_DOMAIN": GATEWAY, "FRESHDESK_ENTRA_FLOW": "password"})
        self.assertIn("FRESHDESK_ENTRA_FLOW", s.error)

    def test_unencrypted_cache_is_an_explicit_opt_in(self):
        for value, expected in (("1", True), ("true", True), ("YES", True), ("0", False), ("", False)):
            with self.subTest(value=value):
                s = load_settings(
                    {"FRESHDESK_DOMAIN": GATEWAY, "FRESHDESK_ENTRA_ALLOW_UNENCRYPTED_CACHE": value}
                )
                self.assertEqual(s.allow_unencrypted_cache, expected)


class CredentialConstructionTests(unittest.TestCase):
    def setUp(self):
        RecordingCredential.instances = []
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {"FRESHDESK_ENTRA_AUTH_RECORD": str(Path(self.tmp.name) / "record.json")}
        patcher_i = patch.object(azure.identity, "InteractiveBrowserCredential", FakeInteractive)
        patcher_d = patch.object(azure.identity, "DeviceCodeCredential", FakeDeviceCode)
        patcher_i.start()
        patcher_d.start()
        self.addCleanup(patcher_i.stop)
        self.addCleanup(patcher_d.stop)

    def build(self, extra):
        settings = load_settings(dict({"FRESHDESK_DOMAIN": GATEWAY}, **extra))
        return EntraTokenProvider(settings, self.env)._get_credential()

    def test_interactive_flow_builds_browser_credential_with_persistent_cache(self):
        cred = self.build({})
        self.assertIsInstance(cred, FakeInteractive)
        self.assertEqual(cred.kwargs["client_id"], auth.DEFAULT_ENTRA_CLIENT_ID)
        self.assertEqual(cred.kwargs["tenant_id"], auth.DEFAULT_ENTRA_TENANT_ID)
        options = cred.kwargs["cache_persistence_options"]
        self.assertEqual(options.name, "freshdesk-mcp")
        self.assertFalse(options.allow_unencrypted_storage)

    def test_device_code_flow_builds_device_code_credential_with_stderr_prompt(self):
        cred = self.build({"FRESHDESK_ENTRA_FLOW": "device_code"})
        self.assertIsInstance(cred, FakeDeviceCode)
        self.assertEqual(cred.kwargs["client_id"], auth.DEFAULT_ENTRA_CLIENT_ID)
        self.assertIn("cache_persistence_options", cred.kwargs)

        with patch("sys.stderr") as fake_stderr, patch("sys.stdout") as fake_stdout:
            cred.kwargs["prompt_callback"]("https://microsoft.com/devicelogin", "ABC123", None)
        written = "".join(c.args[0] for c in fake_stderr.write.call_args_list)
        self.assertIn("https://microsoft.com/devicelogin", written)
        self.assertIn("ABC123", written)
        fake_stdout.write.assert_not_called()  # stdout is the MCP stdio channel

    def test_unencrypted_opt_in_reaches_the_cache_options(self):
        cred = self.build({"FRESHDESK_ENTRA_ALLOW_UNENCRYPTED_CACHE": "1"})
        self.assertTrue(cred.kwargs["cache_persistence_options"].allow_unencrypted_storage)


class EncryptionUnavailableCredential:
    def authenticate(self, scopes):
        raise ValueError(LIBSECRET_FAILURE)

    def get_token(self, *scopes):
        raise ValueError(LIBSECRET_FAILURE)


class CacheEncryptionFailureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {"FRESHDESK_ENTRA_AUTH_RECORD": str(Path(self.tmp.name) / "record.json")}
        self.settings = load_settings({"FRESHDESK_DOMAIN": GATEWAY})

    def assert_actionable(self, exc):
        message = str(exc)
        self.assertIn("PyGObject", message)
        self.assertIn("FRESHDESK_ENTRA_ALLOW_UNENCRYPTED_CACHE", message)

    def test_get_token_reports_an_actionable_configuration_error(self):
        provider = EntraTokenProvider(self.settings, self.env, credential=EncryptionUnavailableCredential())
        with self.assertRaises(AuthConfigError) as ctx:
            asyncio.run(provider.get_token())
        self.assert_actionable(ctx.exception)

    def test_login_reports_an_actionable_configuration_error(self):
        provider = EntraTokenProvider(self.settings, self.env, credential=EncryptionUnavailableCredential())
        with self.assertRaises(AuthConfigError) as ctx:
            provider.login()
        self.assert_actionable(ctx.exception)

    def test_unrelated_value_errors_are_not_rewritten(self):
        class Broken:
            def get_token(self, *scopes):
                raise ValueError("something else")

            def authenticate(self, scopes):
                raise ValueError("something else")

        provider = EntraTokenProvider(self.settings, self.env, credential=Broken())
        with self.assertRaises(ValueError) as ctx:
            asyncio.run(provider.get_token())
        self.assertNotIsInstance(ctx.exception, AuthConfigError)


if __name__ == "__main__":
    unittest.main()
