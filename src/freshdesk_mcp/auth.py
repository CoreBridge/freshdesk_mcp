"""Endpoint and authentication selection for the Freshdesk MCP server.

The server talks to one of two backends, chosen from the environment:

* ``apikey`` - Freshdesk directly: ``https://<domain>/api/v2/...`` with HTTP Basic
  auth (``FRESHDESK_API_KEY``). This is the original behaviour.
* ``entra``  - the CoreBridge Freshdesk gateway: ``https://<gateway>/staff/fd/api/v2/...``
  with an Entra ID (Azure AD) bearer token for the signed-in user.

Mode detection (first match wins):

1. ``FRESHDESK_AUTH_MODE`` = ``entra`` or ``apikey`` forces a mode (``auto`` or unset = detect).
2. ``FRESHDESK_API_KEY`` is missing/blank          -> ``entra``
3. ``FRESHDESK_DOMAIN`` is an Azure host
   (``*.azurewebsites.net``)                       -> ``entra``
4. otherwise                                       -> ``apikey``

Entra mode never sends a token to a Freshdesk host or over plain HTTP to a non-loopback
host: those configurations are reported as errors on the first request instead.

Everything in this module is importable without the MCP stack so it can be unit tested.
"""

from __future__ import annotations

import asyncio
import base64
import logging
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, AsyncGenerator, Mapping, Optional
from urllib.parse import urlsplit

import httpx

logger = logging.getLogger(__name__)

MODE_API_KEY = "apikey"
MODE_ENTRA = "entra"

# The gateway serves the account-wide Entra surface under this prefix.
GATEWAY_PATH_PREFIX = "/staff/fd"

# CoreBridge defaults. None of these are secrets; each can be overridden by env var.
#   tenant : the CoreBridge Entra tenant
#   client : "Freshdesk Gateway Client" (public client, interactive sign-in)
#   scope  : delegated scope exposed by "Freshdesk Gateway API"
DEFAULT_ENTRA_TENANT_ID = "d7cb89e7-e0c6-44c5-8ac2-53b553372019"
DEFAULT_ENTRA_CLIENT_ID = "b00e08ff-9e23-42f4-97b2-da02455ae39b"
DEFAULT_ENTRA_SCOPE = "api://1e49e52c-b843-401e-9f97-8983655c5260/access_as_user"

# The gateway picks the data source from this request header. An Entra caller that sends none
# gets a cache-only, non-production environment (live lists/searches and writes are refused), so
# reaching live Freshdesk data is an explicit opt-in: set FRESHDESK_GATEWAY_ENV (prod/preview).
GATEWAY_ENV_HEADER = "X-CB-Env"
GATEWAY_ENVIRONMENTS = ("dev", "qa", "preview", "prod")

# Refresh a cached token when it has less than this long left.
_TOKEN_REFRESH_MARGIN_SECONDS = 120

_AZURE_HOST_SUFFIXES = (".azurewebsites.net",)
_FRESHDESK_HOST_SUFFIXES = (".freshdesk.com",)
_LOOPBACK_HOSTS = ("localhost", "127.0.0.1", "::1")


class AuthConfigError(RuntimeError):
    """The environment does not describe a usable Freshdesk/gateway configuration."""


def _clean(value: Optional[str]) -> str:
    return (value or "").strip()


def _split_domain(raw: str) -> tuple[str, str, Optional[int]]:
    """Return ``(scheme, hostname, port)`` for a domain or URL; scheme defaults to https."""
    text = _clean(raw)
    if not text:
        return "https", "", None
    parsed = urlsplit(text if "://" in text else f"https://{text}")
    return parsed.scheme.lower() or "https", (parsed.hostname or "").lower(), parsed.port


def normalize_base_url(raw_domain: Optional[str]) -> str:
    """Normalize ``FRESHDESK_DOMAIN`` (bare host or full URL) to ``scheme://host[:port]``."""
    scheme, host, port = _split_domain(_clean(raw_domain))
    if not host:
        return ""
    return f"{scheme}://{host}" + (f":{port}" if port else "")


def _host_matches(host: str, suffixes: tuple[str, ...]) -> bool:
    return any(host == s.lstrip(".") or host.endswith(s) for s in suffixes)


def is_freshdesk_host(host: str) -> bool:
    return _host_matches(host.lower(), _FRESHDESK_HOST_SUFFIXES)


def is_azure_host(host: str) -> bool:
    return _host_matches(host.lower(), _AZURE_HOST_SUFFIXES)


def detect_auth_mode(
    domain: Optional[str],
    api_key: Optional[str],
    override: Optional[str] = None,
) -> str:
    """Pick ``apikey`` or ``entra`` from the environment (see module docstring)."""
    forced = _clean(override).lower()
    if forced in (MODE_ENTRA, MODE_API_KEY):
        return forced
    if forced not in ("", "auto"):
        raise AuthConfigError(
            f"FRESHDESK_AUTH_MODE='{override}' is not valid; use 'entra', 'apikey' or 'auto'."
        )

    if not _clean(api_key):
        return MODE_ENTRA

    _, host, _ = _split_domain(_clean(domain))
    if is_azure_host(host):
        return MODE_ENTRA

    return MODE_API_KEY


@dataclass(frozen=True)
class Settings:
    """Resolved configuration. ``error`` is set when the configuration is unusable."""

    mode: str
    base_url: str
    api_base: str
    api_key: str
    tenant_id: str
    client_id: str
    scope: str
    gateway_env: str = ""
    error: Optional[str] = None

    @property
    def extra_headers(self) -> dict[str, str]:
        """Headers sent on every request in addition to Authorization."""
        if self.mode == MODE_ENTRA and self.gateway_env:
            return {GATEWAY_ENV_HEADER: self.gateway_env}
        return {}


def _validate(mode: str, base_url: str, api_key: str, gateway_env: str = "") -> Optional[str]:
    if not base_url:
        return "FRESHDESK_DOMAIN is not set."

    scheme, host, _ = _split_domain(base_url)

    if mode == MODE_API_KEY:
        if not api_key:
            return "FRESHDESK_AUTH_MODE=apikey requires FRESHDESK_API_KEY."
        return None

    # Entra mode: refuse to send an Entra token anywhere it should not go.
    if is_freshdesk_host(host):
        return (
            f"Entra mode sends an Entra bearer token and must target the gateway, but "
            f"FRESHDESK_DOMAIN is a Freshdesk host ({host}). Set FRESHDESK_API_KEY to call "
            f"Freshdesk directly, or point FRESHDESK_DOMAIN at the gateway."
        )
    if scheme != "https" and host not in _LOOPBACK_HOSTS:
        return f"Entra mode requires https for {host}; refusing to send a bearer token over {scheme}."
    if gateway_env and gateway_env not in GATEWAY_ENVIRONMENTS:
        return (
            f"FRESHDESK_GATEWAY_ENV='{gateway_env}' is not valid; use one of "
            f"{', '.join(GATEWAY_ENVIRONMENTS)}."
        )
    return None


def load_settings(env: Optional[Mapping[str, str]] = None) -> Settings:
    """Build :class:`Settings` from ``env`` (defaults to ``os.environ``). Never raises."""
    env = os.environ if env is None else env
    domain = env.get("FRESHDESK_DOMAIN")
    api_key = _clean(env.get("FRESHDESK_API_KEY"))
    base_url = normalize_base_url(domain)
    gateway_env = _clean(env.get("FRESHDESK_GATEWAY_ENV")).lower()

    try:
        mode = detect_auth_mode(domain, api_key, env.get("FRESHDESK_AUTH_MODE"))
        error = _validate(mode, base_url, api_key, gateway_env)
    except AuthConfigError as exc:
        mode, error = MODE_ENTRA, str(exc)

    prefix = GATEWAY_PATH_PREFIX if mode == MODE_ENTRA else ""
    return Settings(
        mode=mode,
        base_url=base_url,
        api_base=f"{base_url}{prefix}/api/v2",
        api_key=api_key,
        tenant_id=_clean(env.get("FRESHDESK_ENTRA_TENANT_ID")) or DEFAULT_ENTRA_TENANT_ID,
        client_id=_clean(env.get("FRESHDESK_ENTRA_CLIENT_ID")) or DEFAULT_ENTRA_CLIENT_ID,
        scope=_clean(env.get("FRESHDESK_ENTRA_SCOPE")) or DEFAULT_ENTRA_SCOPE,
        gateway_env=gateway_env,
        error=error,
    )


def basic_auth_header(api_key: str) -> str:
    """Freshdesk HTTP Basic header: the API key as the user, ``X`` as the password."""
    return "Basic " + base64.b64encode(f"{api_key}:X".encode()).decode()


def _auth_record_path(env: Mapping[str, str]) -> Path:
    override = _clean(env.get("FRESHDESK_ENTRA_AUTH_RECORD"))
    if override:
        return Path(override)
    return Path.home() / ".freshdesk-mcp" / "entra_auth_record.json"


class EntraTokenProvider:
    """Acquires delegated Entra access tokens for the gateway API.

    Uses ``azure.identity.InteractiveBrowserCredential`` (authorization code + PKCE against
    the registered ``http://localhost`` public-client redirect) with a persistent, encrypted
    token cache and a saved ``AuthenticationRecord``, so the browser opens once per refresh
    token lifetime rather than once per process. Blocking MSAL calls run in a worker thread
    and are serialized so concurrent tool calls cannot open several sign-in windows.
    """

    def __init__(
        self,
        settings: Settings,
        env: Optional[Mapping[str, str]] = None,
        credential: Any = None,
    ) -> None:
        self._settings = settings
        self._record_path = _auth_record_path(os.environ if env is None else env)
        self._credential = credential
        self._lock = asyncio.Lock()
        self._token: Optional[str] = None
        self._expires_on: float = 0.0

    # ---- credential / record plumbing (imports azure-identity lazily) ----------

    def _load_record(self) -> Any:
        from azure.identity import AuthenticationRecord

        try:
            record = AuthenticationRecord.deserialize(self._record_path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except Exception as exc:  # corrupt record: sign in again rather than fail
            logger.warning("Ignoring unreadable Entra auth record %s: %s", self._record_path, exc)
            return None

        # A record for a different tenant/client must not be reused.
        if (
            record.client_id.lower() != self._settings.client_id.lower()
            or record.tenant_id.lower() != self._settings.tenant_id.lower()
        ):
            return None
        return record

    def _save_record(self, record: Any) -> None:
        self._record_path.parent.mkdir(parents=True, exist_ok=True)
        self._record_path.write_text(record.serialize(), encoding="utf-8")

    def _get_credential(self) -> Any:
        if self._credential is None:
            from azure.identity import InteractiveBrowserCredential, TokenCachePersistenceOptions

            self._credential = InteractiveBrowserCredential(
                tenant_id=self._settings.tenant_id,
                client_id=self._settings.client_id,
                cache_persistence_options=TokenCachePersistenceOptions(name="freshdesk-mcp"),
                authentication_record=self._load_record(),
            )
        return self._credential

    # ---- public API ------------------------------------------------------------

    def login(self) -> str:
        """Run the interactive sign-in now and persist the result. Returns the account name."""
        record = self._get_credential().authenticate(scopes=[self._settings.scope])
        self._save_record(record)
        return str(record.username)

    def _get_token_sync(self) -> str:
        now = time.time()
        if self._token and self._expires_on - now > _TOKEN_REFRESH_MARGIN_SECONDS:
            return self._token

        credential = self._get_credential()
        if not self._record_path.exists():
            # First run: sign in once and remember who, so later processes go silent.
            self._save_record(credential.authenticate(scopes=[self._settings.scope]))

        access = credential.get_token(self._settings.scope)
        self._token, self._expires_on = access.token, float(access.expires_on)
        return self._token

    async def get_token(self) -> str:
        async with self._lock:
            return await asyncio.to_thread(self._get_token_sync)


class FreshdeskAuth(httpx.Auth):
    """``httpx`` auth that applies the right ``Authorization`` header for the active mode."""

    def __init__(
        self,
        settings: Settings,
        token_provider: Optional[EntraTokenProvider] = None,
    ) -> None:
        self.settings = settings
        self._token_provider = token_provider

    async def authorization_header(self) -> str:
        if self.settings.error:
            raise AuthConfigError(self.settings.error)
        if self.settings.mode == MODE_API_KEY:
            return basic_auth_header(self.settings.api_key)

        if self._token_provider is None:
            self._token_provider = EntraTokenProvider(self.settings)
        return f"Bearer {await self._token_provider.get_token()}"

    async def async_auth_flow(self, request: httpx.Request) -> AsyncGenerator[httpx.Request, httpx.Response]:
        request.headers["Authorization"] = await self.authorization_header()
        yield request


def login_cli(env: Optional[Mapping[str, str]] = None) -> int:
    """``freshdesk-mcp login``: sign in interactively ahead of time (Entra mode only)."""
    settings = load_settings(env)
    if settings.error:
        print(f"Configuration error: {settings.error}", file=sys.stderr)
        return 2
    if settings.mode != MODE_ENTRA:
        print("Not in Entra mode (API key auth is active); nothing to sign in to.", file=sys.stderr)
        return 0

    username = EntraTokenProvider(settings, env).login()
    print(f"Signed in as {username}. Gateway: {settings.api_base}", file=sys.stderr)
    return 0
