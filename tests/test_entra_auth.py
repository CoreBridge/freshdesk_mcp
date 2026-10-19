"""Tests for API-key vs Entra (gateway) mode selection, URL building and auth headers."""

import asyncio
import base64
import importlib
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src.freshdesk_mcp import auth  # noqa: E402
from src.freshdesk_mcp.auth import (  # noqa: E402
    MODE_API_KEY,
    MODE_ENTRA,
    AuthConfigError,
    EntraTokenProvider,
    FreshdeskAuth,
    detect_auth_mode,
    load_settings,
    normalize_base_url,
)

GATEWAY = "cus-cb-fd-gateway-abc.centralus-01.azurewebsites.net"
FRESHDESK = "atomology.freshdesk.com"


def run(coro):
    return asyncio.run(coro)


class DetectAuthModeTests(unittest.TestCase):
    def test_api_key_and_freshdesk_domain_is_apikey(self):
        self.assertEqual(detect_auth_mode(FRESHDESK, "k"), MODE_API_KEY)

    def test_missing_api_key_is_entra(self):
        self.assertEqual(detect_auth_mode(GATEWAY, None), MODE_ENTRA)
        self.assertEqual(detect_auth_mode(GATEWAY, "   "), MODE_ENTRA)

    def test_azure_domain_is_entra_even_with_an_api_key(self):
        self.assertEqual(detect_auth_mode(GATEWAY, "k"), MODE_ENTRA)
        self.assertEqual(detect_auth_mode(f"https://{GATEWAY}/", "k"), MODE_ENTRA)

    def test_override_wins(self):
        self.assertEqual(detect_auth_mode(FRESHDESK, "k", "entra"), MODE_ENTRA)
        self.assertEqual(detect_auth_mode(GATEWAY, None, "APIKEY"), MODE_API_KEY)
        self.assertEqual(detect_auth_mode(GATEWAY, "k", "auto"), MODE_ENTRA)

    def test_invalid_override_raises(self):
        with self.assertRaises(AuthConfigError):
            detect_auth_mode(FRESHDESK, "k", "oauth")


class NormalizeBaseUrlTests(unittest.TestCase):
    def test_variants(self):
        self.assertEqual(normalize_base_url("Atomology.Freshdesk.com"), "https://atomology.freshdesk.com")
        self.assertEqual(normalize_base_url("https://host.example/"), "https://host.example")
        self.assertEqual(normalize_base_url("http://localhost:5000/x"), "http://localhost:5000")
        self.assertEqual(normalize_base_url(None), "")
        self.assertEqual(normalize_base_url("  "), "")


class LoadSettingsTests(unittest.TestCase):
    def test_apikey_mode_matches_original_urls(self):
        s = load_settings({"FRESHDESK_DOMAIN": FRESHDESK, "FRESHDESK_API_KEY": "k"})
        self.assertEqual(s.mode, MODE_API_KEY)
        self.assertEqual(s.api_base, f"https://{FRESHDESK}/api/v2")
        self.assertIsNone(s.error)

    def test_entra_mode_targets_staff_surface(self):
        s = load_settings({"FRESHDESK_DOMAIN": GATEWAY})
        self.assertEqual(s.mode, MODE_ENTRA)
        self.assertEqual(s.api_base, f"https://{GATEWAY}/staff/fd/api/v2")
        self.assertIsNone(s.error)
        self.assertEqual(s.client_id, auth.DEFAULT_ENTRA_CLIENT_ID)
        self.assertEqual(s.scope, auth.DEFAULT_ENTRA_SCOPE)

    def test_entra_overrides(self):
        s = load_settings(
            {
                "FRESHDESK_DOMAIN": GATEWAY,
                "FRESHDESK_ENTRA_CLIENT_ID": "client",
                "FRESHDESK_ENTRA_TENANT_ID": "tenant",
                "FRESHDESK_ENTRA_SCOPE": "api://x/y",
            }
        )
        self.assertEqual((s.client_id, s.tenant_id, s.scope), ("client", "tenant", "api://x/y"))

    def test_missing_key_on_freshdesk_host_is_an_error_not_a_token_leak(self):
        s = load_settings({"FRESHDESK_DOMAIN": FRESHDESK})
        self.assertEqual(s.mode, MODE_ENTRA)
        self.assertIn("Freshdesk host", s.error)

    def test_entra_over_plain_http_is_refused_except_loopback(self):
        self.assertIn("https", load_settings({"FRESHDESK_DOMAIN": "http://gw.example"}).error)
        self.assertIsNone(load_settings({"FRESHDESK_DOMAIN": "http://localhost:5000"}).error)

    def test_missing_domain_and_forced_apikey_without_key(self):
        self.assertIn("FRESHDESK_DOMAIN", load_settings({}).error)
        s = load_settings({"FRESHDESK_DOMAIN": FRESHDESK, "FRESHDESK_AUTH_MODE": "apikey"})
        self.assertIn("FRESHDESK_API_KEY", s.error)

    def test_invalid_override_is_reported_not_raised(self):
        s = load_settings({"FRESHDESK_DOMAIN": GATEWAY, "FRESHDESK_AUTH_MODE": "nope"})
        self.assertIn("FRESHDESK_AUTH_MODE", s.error)

    def test_gateway_env_is_an_explicit_opt_in_header(self):
        self.assertEqual(load_settings({"FRESHDESK_DOMAIN": GATEWAY}).extra_headers, {})
        s = load_settings({"FRESHDESK_DOMAIN": GATEWAY, "FRESHDESK_GATEWAY_ENV": " Prod "})
        self.assertEqual(s.extra_headers, {"X-CB-Env": "prod"})
        self.assertIsNone(s.error)

    def test_invalid_gateway_env_is_an_error(self):
        s = load_settings({"FRESHDESK_DOMAIN": GATEWAY, "FRESHDESK_GATEWAY_ENV": "production"})
        self.assertIn("FRESHDESK_GATEWAY_ENV", s.error)

    def test_gateway_env_header_is_never_sent_in_apikey_mode(self):
        s = load_settings(
            {"FRESHDESK_DOMAIN": FRESHDESK, "FRESHDESK_API_KEY": "k", "FRESHDESK_GATEWAY_ENV": "prod"}
        )
        self.assertEqual(s.mode, MODE_API_KEY)
        self.assertEqual(s.extra_headers, {})


class FakeToken:
    def __init__(self, token, expires_on):
        self.token, self.expires_on = token, expires_on


class FakeRecord:
    username = "alex@corebridge.net"

    def serialize(self):
        return "{}"


class FakeCredential:
    def __init__(self):
        self.authenticate_calls = 0
        self.get_token_calls = 0
        self.scopes = []

    def authenticate(self, scopes):
        self.authenticate_calls += 1
        self.scopes.append(tuple(scopes))
        return FakeRecord()

    def get_token(self, *scopes):
        self.get_token_calls += 1
        self.scopes.append(scopes)
        return FakeToken("fake-entra-token", 4_000_000_000)


class EntraTokenProviderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.record_path = Path(self.tmp.name) / "record.json"
        self.env = {"FRESHDESK_ENTRA_AUTH_RECORD": str(self.record_path)}
        self.settings = load_settings({"FRESHDESK_DOMAIN": GATEWAY})

    def provider(self, credential):
        return EntraTokenProvider(self.settings, self.env, credential=credential)

    def test_first_call_signs_in_once_saves_record_and_caches_token(self):
        cred = FakeCredential()
        provider = self.provider(cred)

        self.assertEqual(run(provider.get_token()), "fake-entra-token")
        self.assertEqual(run(provider.get_token()), "fake-entra-token")

        self.assertEqual(cred.authenticate_calls, 1)
        self.assertEqual(cred.get_token_calls, 1)  # second call served from memory
        self.assertTrue(self.record_path.exists())
        self.assertIn((auth.DEFAULT_ENTRA_SCOPE,), cred.scopes)

    def test_existing_record_skips_interactive_sign_in(self):
        self.record_path.write_text("{}", encoding="utf-8")
        cred = FakeCredential()

        self.assertEqual(run(self.provider(cred).get_token()), "fake-entra-token")
        self.assertEqual(cred.authenticate_calls, 0)

    def test_login_persists_record_and_returns_username(self):
        cred = FakeCredential()
        self.assertEqual(self.provider(cred).login(), "alex@corebridge.net")
        self.assertTrue(self.record_path.exists())

    def test_expiring_token_is_refreshed(self):
        cred = FakeCredential()
        provider = self.provider(cred)
        run(provider.get_token())
        provider._expires_on = 0  # force expiry
        run(provider.get_token())
        self.assertEqual(cred.get_token_calls, 2)


class FreshdeskAuthTests(unittest.TestCase):
    def test_apikey_header_is_unchanged_from_original_scheme(self):
        settings = load_settings({"FRESHDESK_DOMAIN": FRESHDESK, "FRESHDESK_API_KEY": "secret"})
        header = run(FreshdeskAuth(settings).authorization_header())
        expected = "Basic " + base64.b64encode(b"secret:X").decode()
        self.assertEqual(header, expected)

    def test_entra_header_is_bearer(self):
        settings = load_settings({"FRESHDESK_DOMAIN": GATEWAY})
        with tempfile.TemporaryDirectory() as tmp:
            env = {"FRESHDESK_ENTRA_AUTH_RECORD": str(Path(tmp) / "record.json")}
            provider = EntraTokenProvider(settings, env, credential=FakeCredential())
            header = run(FreshdeskAuth(settings, provider).authorization_header())
        self.assertEqual(header, "Bearer fake-entra-token")

    def test_config_error_raises_instead_of_sending_a_request(self):
        settings = load_settings({"FRESHDESK_DOMAIN": FRESHDESK})  # no key, freshdesk host
        with self.assertRaises(AuthConfigError):
            run(FreshdeskAuth(settings).authorization_header())

    def test_httpx_client_applies_header_to_each_request(self):
        seen = []

        def handler(request: httpx.Request) -> httpx.Response:
            seen.append((str(request.url), request.headers.get("authorization")))
            return httpx.Response(200, json=[])

        settings = load_settings({"FRESHDESK_DOMAIN": FRESHDESK, "FRESHDESK_API_KEY": "secret"})

        async def go():
            async with httpx.AsyncClient(
                auth=FreshdeskAuth(settings), transport=httpx.MockTransport(handler)
            ) as client:
                await client.get(f"{settings.api_base}/tickets", headers={})

        run(go())
        self.assertEqual(seen[0][0], f"https://{FRESHDESK}/api/v2/tickets")
        self.assertTrue(seen[0][1].startswith("Basic "))


class ServerIntegrationTests(unittest.TestCase):
    """Import the real server module under a given environment and call a real tool."""

    def load_server(self, env):
        with patch.dict(os.environ, env, clear=True):
            import src.freshdesk_mcp.server as server

            return importlib.reload(server)

    def call_get_tickets(self, server, fake_header):
        seen = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["url"] = str(request.url)
            seen["authorization"] = request.headers.get("authorization")
            return httpx.Response(200, json=[{"id": 1, "subject": "s"}])

        class FakeAuth(httpx.Auth):
            async def async_auth_flow(self, request):
                request.headers["Authorization"] = fake_header
                yield request

        def fake_client():
            return httpx.AsyncClient(auth=FakeAuth(), transport=httpx.MockTransport(handler))

        with patch.object(server, "http_client", fake_client):
            result = run(server.get_tickets(page=1, per_page=5))
        return result, seen

    def test_entra_mode_calls_staff_surface_with_bearer(self):
        server = self.load_server({"FRESHDESK_DOMAIN": GATEWAY})
        self.assertEqual(server.SETTINGS.mode, MODE_ENTRA)

        result, seen = self.call_get_tickets(server, "Bearer fake")

        self.assertEqual(
            seen["url"], f"https://{GATEWAY}/staff/fd/api/v2/tickets?page=1&per_page=5"
        )
        self.assertEqual(seen["authorization"], "Bearer fake")
        self.assertEqual(result["tickets"][0]["id"], 1)

    def test_apikey_mode_calls_freshdesk_api_unchanged(self):
        server = self.load_server({"FRESHDESK_DOMAIN": FRESHDESK, "FRESHDESK_API_KEY": "k"})
        self.assertEqual(server.SETTINGS.mode, MODE_API_KEY)

        _, seen = self.call_get_tickets(server, "Basic fake")

        self.assertEqual(seen["url"], f"https://{FRESHDESK}/api/v2/tickets?page=1&per_page=5")

    def test_real_http_client_carries_the_environment_header(self):
        server = self.load_server({"FRESHDESK_DOMAIN": GATEWAY, "FRESHDESK_GATEWAY_ENV": "prod"})
        self.assertEqual(server.http_client().headers.get("x-cb-env"), "prod")

        server = self.load_server({"FRESHDESK_DOMAIN": GATEWAY})
        self.assertIsNone(server.http_client().headers.get("x-cb-env"))

    def test_delete_ticket_is_disabled_through_the_gateway(self):
        server = self.load_server({"FRESHDESK_DOMAIN": GATEWAY})
        result = run(server.delete_ticket(123))
        self.assertIn("not available through the Freshdesk gateway", result)


if __name__ == "__main__":
    unittest.main()
