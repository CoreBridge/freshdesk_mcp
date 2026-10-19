"""Every tool, end to end, against a mocked CoreBridge Freshdesk gateway (Entra mode).

The real ``server`` module is loaded in Entra mode, its real ``http_client()`` (real
``FreshdeskAuth`` + ``X-CB-Env`` header) is used, and only two things are faked: the Entra
token provider (no MSAL, no tenant) and the network (an ``httpx.MockTransport`` playing the
gateway). Each row asserts the request a tool puts on the wire: method, ``/staff/fd`` path,
query, JSON body, bearer token and environment header — and that no Freshdesk credential or
host is involved.

The tool NAMES are pinned to the pre-gateway set so support's Cursor workflows do not change,
and, when the gateway repo is checked out next to this one, the routes are checked against the
gateway's own pinned consumer inventory (``route-inventory.json``).

No network, no Entra tenant, no Freshdesk API key.
"""

import asyncio
import importlib
import json
import os
import re
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

GATEWAY_HOST = "gateway.example.invalid"
GATEWAY_ENV = {
    "FRESHDESK_DOMAIN": f"https://{GATEWAY_HOST}",
    "FRESHDESK_GATEWAY_ENV": "prod",
}
TOKEN = "stub-entra-token"

# Sibling checkout of the gateway repo; override with FD_GATEWAY_ROUTE_INVENTORY.
DEFAULT_INVENTORY = (
    Path(__file__).resolve().parents[2]
    / "freshdesk-gateway/tests/Endor.Freshdesk.Gateway.Tests/Routing/route-inventory.json"
)

# The tool names support's workflows use (the set registered on main before the gateway).
PINNED_TOOL_NAMES = {
    "get_ticket_fields", "get_tickets", "create_ticket", "update_ticket", "delete_ticket",
    "get_ticket", "search_tickets", "get_ticket_conversation", "create_ticket_reply",
    "create_ticket_note", "update_ticket_conversation", "get_agents", "list_contacts",
    "get_contact", "search_contacts", "update_contact", "list_canned_responses",
    "list_canned_response_folders", "view_canned_response", "create_canned_response",
    "update_canned_response", "create_canned_response_folder", "update_canned_response_folder",
    "list_solution_articles", "list_solution_folders", "list_solution_categories",
    "view_solution_category", "create_solution_category", "update_solution_category",
    "create_solution_category_folder", "view_solution_category_folder",
    "update_solution_category_folder", "create_solution_article", "view_solution_article",
    "update_solution_article", "view_agent", "create_agent", "update_agent", "search_agents",
    "list_groups", "create_group", "view_group", "create_ticket_field", "view_ticket_field",
    "update_ticket_field", "update_group", "list_contact_fields", "view_contact_field",
    "create_contact_field", "update_contact_field", "get_field_properties", "list_companies",
    "view_company", "search_companies", "find_company_by_name", "list_company_fields",
    "view_ticket_summary", "update_ticket_summary", "delete_ticket_summary",
}

# (tool, method, path under /api/v2, query, JSON body, call kwargs)
TABLE = [
    ("get_ticket_fields", "GET", "/ticket_fields", None, None, {}),
    ("get_tickets", "GET", "/tickets", {"page": 1, "per_page": 30}, None, {}),
    (
        "create_ticket", "POST", "/tickets", None,
        {"subject": "S", "description": "D", "source": 2, "priority": 2, "status": 2,
         "email": "requester@example.com"},
        {"subject": "S", "description": "D", "source": 2, "priority": 2, "status": 2,
         "email": "requester@example.com"},
    ),
    ("update_ticket", "PUT", "/tickets/123", None, {"status": 5},
     {"ticket_id": 123, "ticket_fields": {"status": 5}}),
    ("get_ticket", "GET", "/tickets/123", None, None, {"ticket_id": 123}),
    ("search_tickets", "GET", "/search/tickets", {"query": "priority:3"}, None,
     {"query": "priority:3"}),
    ("get_ticket_conversation", "GET", "/tickets/123/conversations", None, None,
     {"ticket_id": 123}),
    ("create_ticket_reply", "POST", "/tickets/123/reply", None, {"body": "<p>hi</p>"},
     {"ticket_id": 123, "body": "<p>hi</p>"}),
    ("create_ticket_note", "POST", "/tickets/123/notes", None, {"body": "note"},
     {"ticket_id": 123, "body": "note"}),
    ("update_ticket_conversation", "PUT", "/conversations/99", None, {"body": "edit"},
     {"conversation_id": 99, "body": "edit"}),
    ("get_agents", "GET", "/agents", {"page": 1, "per_page": 30}, None, {}),
    ("list_contacts", "GET", "/contacts", {"page": 1, "per_page": 30}, None, {}),
    ("get_contact", "GET", "/contacts/55", None, None, {"contact_id": 55}),
    ("search_contacts", "GET", "/contacts/autocomplete", {"term": "bob"}, None,
     {"query": "bob"}),
    ("update_contact", "PUT", "/contacts/55", None, {"name": "x"},
     {"contact_id": 55, "contact_fields": {"name": "x"}}),
    ("list_canned_responses", "GET", "/canned_response_folders/7/responses", None, None,
     {"folder_id": 7}),
    ("list_canned_response_folders", "GET", "/canned_response_folders", None, None, {}),
    ("view_canned_response", "GET", "/canned_responses/8", None, None,
     {"canned_response_id": 8}),
    (
        "create_canned_response", "POST", "/canned_responses", None,
        {"title": "T", "content_html": "<p>hi</p>", "folder_id": 7, "visibility": 1},
        {"canned_response_fields": {"title": "T", "content_html": "<p>hi</p>",
                                    "folder_id": 7, "visibility": 1}},
    ),
    ("update_canned_response", "PUT", "/canned_responses/8", None,
     {"title": "T", "visibility": 1},
     {"canned_response_id": 8, "canned_response_fields": {"title": "T", "visibility": 1}}),
    ("create_canned_response_folder", "POST", "/canned_response_folders", None,
     {"name": "Folder"}, {"name": "Folder"}),
    ("update_canned_response_folder", "PUT", "/canned_response_folders/7", None,
     {"name": "Folder2"}, {"folder_id": 7, "name": "Folder2"}),
    ("list_solution_articles", "GET", "/solutions/folders/7/articles", None, None,
     {"folder_id": 7}),
    ("list_solution_folders", "GET", "/solutions/categories/2/folders", None, None,
     {"category_id": 2}),
    ("list_solution_categories", "GET", "/solutions/categories", None, None, {}),
    ("view_solution_category", "GET", "/solutions/categories/2", None, None,
     {"category_id": 2}),
    ("create_solution_category", "POST", "/solutions/categories", None, {"name": "Cat"},
     {"category_fields": {"name": "Cat"}}),
    ("update_solution_category", "PUT", "/solutions/categories/2", None, {"name": "Cat"},
     {"category_id": 2, "category_fields": {"name": "Cat"}}),
    ("create_solution_category_folder", "POST", "/solutions/categories/2/folders", None,
     {"name": "F"}, {"category_id": 2, "folder_fields": {"name": "F"}}),
    ("view_solution_category_folder", "GET", "/solutions/folders/7", None, None,
     {"folder_id": 7}),
    ("update_solution_category_folder", "PUT", "/solutions/folders/7", None,
     {"name": "F"}, {"folder_id": 7, "folder_fields": {"name": "F"}}),
    ("create_solution_article", "POST", "/solutions/folders/7/articles", None,
     {"title": "t", "status": 2, "description": "d"},
     {"folder_id": 7, "article_fields": {"title": "t", "status": 2, "description": "d"}}),
    ("view_solution_article", "GET", "/solutions/articles/4", None, None,
     {"article_id": 4}),
    ("update_solution_article", "PUT", "/solutions/articles/4", None, {"title": "t"},
     {"article_id": 4, "article_fields": {"title": "t"}}),
    ("view_agent", "GET", "/agents/17", None, None, {"agent_id": 17}),
    ("create_agent", "POST", "/agents", None, {"email": "a@b.com", "ticket_scope": 1},
     {"agent_fields": {"email": "a@b.com", "ticket_scope": 1}}),
    ("update_agent", "PUT", "/agents/17", None, {"name": "x"},
     {"agent_id": 17, "agent_fields": {"name": "x"}}),
    ("search_agents", "GET", "/agents/autocomplete", {"term": "alice"}, None,
     {"query": "alice"}),
    ("list_groups", "GET", "/groups", {"page": 1, "per_page": 30}, None, {}),
    ("create_group", "POST", "/groups", None,
     {"name": "G", "auto_ticket_assign": 0, "unassigned_for": "30m"},
     {"group_fields": {"name": "G"}}),
    ("view_group", "GET", "/groups/6", None, None, {"group_id": 6}),
    ("create_ticket_field", "POST", "/admin/ticket_fields", None, {"name": "f"},
     {"ticket_field_fields": {"name": "f"}}),
    ("view_ticket_field", "GET", "/admin/ticket_fields/11", None, None,
     {"ticket_field_id": 11}),
    ("update_ticket_field", "PUT", "/admin/ticket_fields/11", None, {"name": "f"},
     {"ticket_field_id": 11, "ticket_field_fields": {"name": "f"}}),
    ("update_group", "PUT", "/groups/6", None,
     {"name": "G", "auto_ticket_assign": 0, "unassigned_for": "30m"},
     {"group_id": 6, "group_fields": {"name": "G"}}),
    ("list_contact_fields", "GET", "/contact_fields", None, None, {}),
    ("view_contact_field", "GET", "/contact_fields/12", None, None,
     {"contact_field_id": 12}),
    (
        "create_contact_field", "POST", "/contact_fields", None,
        {"label": "L", "label_for_customers": "LC", "type": "custom_text",
         "editable_in_signup": False, "position": 1, "required_for_agents": False,
         "customers_can_edit": False, "required_for_customers": False,
         "displayed_for_customers": False},
        {"contact_field_fields": {"label": "L", "label_for_customers": "LC",
                                  "type": "custom_text"}},
    ),
    ("update_contact_field", "PUT", "/contact_fields/12", None, {"label": "L"},
     {"contact_field_id": 12, "contact_field_fields": {"label": "L"}}),
    ("get_field_properties", "GET", "/ticket_fields", None, None,
     {"field_name": "status"}),
    ("list_companies", "GET", "/companies", {"page": 1, "per_page": 30}, None, {}),
    ("view_company", "GET", "/companies/44", None, None, {"company_id": 44}),
    ("search_companies", "GET", "/companies/autocomplete", {"name": "acme"}, None,
     {"query": "acme"}),
    ("find_company_by_name", "GET", "/companies/autocomplete", {"name": "acme"}, None,
     {"name": "acme"}),
    ("list_company_fields", "GET", "/company_fields", None, None, {}),
    ("view_ticket_summary", "GET", "/tickets/123/summary", None, None,
     {"ticket_id": 123}),
    ("update_ticket_summary", "PUT", "/tickets/123/summary", None, {"body": "sum"},
     {"ticket_id": 123, "body": "sum"}),
    ("delete_ticket_summary", "DELETE", "/tickets/123/summary", None, None,
     {"ticket_id": 123}),
]


class StubTokenProvider:
    """Stands in for ``EntraTokenProvider``: no MSAL, no browser, no tenant."""

    def __init__(self):
        self.calls = 0

    async def get_token(self) -> str:
        self.calls += 1
        return TOKEN


def load_gateway_server(extra_env=None):
    env = dict(GATEWAY_ENV, **(extra_env or {}))
    with patch.dict(os.environ, env, clear=True):
        import src.freshdesk_mcp.server as server

        return importlib.reload(server)


class MockedGateway:
    """Routes the server's real ``http_client()`` to an in-process gateway double."""

    def __init__(self, server, responder=None):
        self.server = server
        self.requests = []
        self.tokens = StubTokenProvider()
        self._responder = responder or self._ok
        server._AUTH._token_provider = self.tokens

    @staticmethod
    def _ok(request):
        return httpx.Response(200, json=[] if request.method == "GET" else {})

    def _handler(self, request):
        self.requests.append(request)
        return self._responder(request)

    def call(self, tool_name, **kwargs):
        real_async_client = httpx.AsyncClient
        transport = httpx.MockTransport(self._handler)

        def client_with_mock_transport(*args, **kw):
            kw["transport"] = transport
            return real_async_client(*args, **kw)

        tool = self.server.mcp._tool_manager.get_tool(tool_name)
        assert tool is not None, f"{tool_name} is not registered"
        with patch.object(self.server.httpx, "AsyncClient", client_with_mock_transport):
            return asyncio.run(tool.fn(**kwargs))


class GatewayToolTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = load_gateway_server()

    def test_server_is_in_gateway_mode_without_any_freshdesk_key(self):
        settings = self.server.SETTINGS
        self.assertEqual(settings.mode, "entra")
        self.assertIsNone(settings.error)
        self.assertEqual(settings.api_key, "")
        self.assertEqual(settings.api_base, f"https://{GATEWAY_HOST}/staff/fd/api/v2")

    def test_every_tool_calls_the_gateway_staff_surface(self):
        for name, method, path, query, body, kwargs in TABLE:
            with self.subTest(tool=name):
                gateway = MockedGateway(self.server)
                gateway.call(name, **kwargs)

                self.assertEqual(len(gateway.requests), 1, "one gateway call per tool call")
                request = gateway.requests[0]
                self.assertEqual(request.method, method)
                self.assertEqual(request.url.scheme, "https")
                self.assertEqual(request.url.host, GATEWAY_HOST)
                self.assertEqual(request.url.path, f"/staff/fd/api/v2{path}")
                self.assertEqual(request.headers["authorization"], f"Bearer {TOKEN}")
                self.assertEqual(request.headers["x-cb-env"], "prod")
                self.assertEqual(
                    dict(request.url.params), {k: str(v) for k, v in (query or {}).items()}
                )
                if body is None:
                    self.assertEqual(request.content, b"")
                else:
                    self.assertEqual(json.loads(request.content), body)

    def test_table_covers_every_registered_tool_except_the_refused_delete(self):
        registered = {t.name for t in self.server.mcp._tool_manager.list_tools()}
        self.assertEqual(registered - {"delete_ticket"}, {row[0] for row in TABLE})

    def test_tool_names_are_unchanged_for_support_workflows(self):
        registered = {t.name for t in self.server.mcp._tool_manager.list_tools()}
        self.assertEqual(registered, PINNED_TOOL_NAMES)

    def test_delete_ticket_never_reaches_the_gateway(self):
        gateway = MockedGateway(self.server)
        result = gateway.call("delete_ticket", ticket_id=123)
        self.assertIn("not available through the Freshdesk gateway", result)
        self.assertEqual(gateway.requests, [])

    def test_no_tool_accepts_a_freshdesk_key_or_domain(self):
        for tool in self.server.mcp._tool_manager.list_tools():
            props = {p.lower() for p in (tool.parameters.get("properties") or {})}
            with self.subTest(tool=tool.name):
                self.assertFalse(any("api_key" in p or "domain" in p for p in props))

    def test_gateway_refusal_is_returned_once_and_not_retried(self):
        def refuse(request):
            return httpx.Response(403, json={"status": 403, "message": "env_restricted"})

        gateway = MockedGateway(self.server, refuse)
        result = gateway.call("get_ticket", ticket_id=123)
        self.assertEqual(result, {"status": 403, "message": "env_restricted"})
        self.assertEqual(len(gateway.requests), 1)

    def test_token_is_requested_per_call_and_never_leaks_into_the_url(self):
        gateway = MockedGateway(self.server)
        gateway.call("get_ticket", ticket_id=1)
        gateway.call("search_tickets", query="status:2")
        self.assertEqual(gateway.tokens.calls, 2)
        for request in gateway.requests:
            self.assertNotIn(TOKEN, str(request.url))


class GatewayEnvironmentTests(unittest.TestCase):
    def test_azure_sdk_http_logging_is_quiet(self):
        """azure-core logs every token request/response header at INFO; keep it to WARNING+."""
        import logging

        noisy = logging.getLogger("azure.core.pipeline.policies.http_logging_policy")
        logging.getLogger("azure").setLevel(logging.NOTSET)
        load_gateway_server()
        self.assertGreaterEqual(noisy.getEffectiveLevel(), logging.WARNING)
        self.assertFalse(noisy.isEnabledFor(logging.INFO))
        self.assertGreaterEqual(logging.getLogger("azure.identity").getEffectiveLevel(), logging.WARNING)

    def test_environment_header_follows_configuration(self):
        for env in ("dev", "preview", "prod"):
            with self.subTest(env=env):
                server = load_gateway_server({"FRESHDESK_GATEWAY_ENV": env})
                gateway = MockedGateway(server)
                gateway.call("get_ticket", ticket_id=7)
                self.assertEqual(gateway.requests[0].headers["x-cb-env"], env)

    def test_unset_environment_sends_no_header(self):
        with patch.dict(os.environ, {"FRESHDESK_DOMAIN": f"https://{GATEWAY_HOST}"}, clear=True):
            import src.freshdesk_mcp.server as server

            server = importlib.reload(server)
        gateway = MockedGateway(server)
        gateway.call("get_ticket", ticket_id=7)
        self.assertNotIn("x-cb-env", gateway.requests[0].headers)


def _normalise_path(path):
    return re.sub(r"(?<=/)\d+(?=/|$)", "{id}", path)


class GatewayRouteInventoryTests(unittest.TestCase):
    """The gateway repo pins which freshdesk_mcp routes its policy allows (GW-03)."""

    def setUp(self):
        path = Path(os.environ.get("FD_GATEWAY_ROUTE_INVENTORY", DEFAULT_INVENTORY))
        if not path.is_file():
            self.skipTest(f"gateway route inventory not found at {path}")
        data = json.loads(path.read_text(encoding="utf-8"))
        self.entries = [e for e in data["endpoints"] if e["consumer"] == "freshdesk_mcp"]

    def test_every_tool_route_is_allowed_by_the_gateway(self):
        allowed = {
            e["tool"]: (e["method"], _normalise_path(e["path"]))
            for e in self.entries
            if e["disposition"] != "denied"
        }
        ours = {name: (method, _normalise_path(f"/api/v2{path}"))
                for name, method, path, *_ in TABLE}
        self.assertEqual(ours, allowed)

    def test_the_only_denied_route_is_ticket_deletion(self):
        denied = [e for e in self.entries if e["disposition"] == "denied"]
        self.assertEqual(
            [(e["tool"], e["method"], _normalise_path(e["path"])) for e in denied],
            [("delete_ticket", "DELETE", "/api/v2/tickets/{id}")],
        )


if __name__ == "__main__":
    unittest.main()
