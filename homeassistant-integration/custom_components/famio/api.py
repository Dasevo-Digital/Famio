"""Client for the Famio server API.

Famio servers in the home network use their own certificate. Like the Famio
apps, the integration pins the SHA-256 of the certificate's public key (the
fingerprint shown in the server log and in the apps). Renewed certificates
keep the key, so the pin stays valid; the certificate hash used for the TLS
check is updated automatically when the key still matches.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
import hashlib
import ssl
from typing import Any
from urllib.parse import urlsplit

import aiohttp
from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from .const import DEFAULT_TLS_PORT, DEVICE_NAME


class FamioError(Exception):
    """Base error with a user-facing German message."""

    def __init__(self, message: str = "", code: str | None = None) -> None:
        super().__init__(message)
        # The server's error code, e.g. "invalid_code".
        self.code = code


class FamioConnectionError(FamioError):
    """Server not reachable."""


class FamioAuthError(FamioError):
    """Login rejected or session revoked."""


class FamioTwoFactorError(FamioError):
    """The password was right; the code from the authenticator app follows
    (see [FamioClient.login_two_factor])."""

    def __init__(self, challenge: str) -> None:
        super().__init__("two-factor login", "two_factor")
        self.challenge = challenge


class FamioCertificateError(FamioError):
    """The server shows another key than the confirmed one."""


def normalize_url(text: str) -> str:
    """Like the apps: a bare address means HTTPS on the home network port."""
    text = text.strip().rstrip("/")
    if "://" not in text:
        host = text
        if ":" in host and not host.startswith("["):
            host, _, port = host.partition(":")
            # The plain HTTP port of the server: use its HTTPS port instead.
            if port in ("8765", ""):
                port = str(DEFAULT_TLS_PORT)
            return f"https://{host}:{port}"
        return f"https://{host}:{DEFAULT_TLS_PORT}"
    parts = urlsplit(text)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError(text)
    return text


def format_fingerprint(digest: bytes) -> str:
    return ":".join(f"{b:02X}" for b in digest)


def spki_fingerprint(der: bytes) -> str:
    """SHA-256 of the certificate's SubjectPublicKeyInfo, as the apps show it."""
    cert = x509.load_der_x509_certificate(der)
    spki = cert.public_key().public_bytes(
        Encoding.DER, PublicFormat.SubjectPublicKeyInfo
    )
    return format_fingerprint(hashlib.sha256(spki).digest())


async def fetch_certificate(url: str) -> bytes:
    """The certificate the server presents (not verified)."""
    parts = urlsplit(url)
    # Only to read the certificate; the connection is closed right away.
    # (No default CA certificates: loading them would block the event loop.)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        _, writer = await asyncio.wait_for(
            asyncio.open_connection(
                parts.hostname,
                parts.port or 443,
                ssl=context,
                server_hostname=parts.hostname,
            ),
            timeout=10,
        )
    except (OSError, TimeoutError) as err:
        raise FamioConnectionError(f"Server nicht erreichbar ({err})") from err
    try:
        ssl_object = writer.get_extra_info("ssl_object")
        der = ssl_object.getpeercert(binary_form=True)
    finally:
        writer.close()
    if not der:
        raise FamioConnectionError("Server zeigt kein Zertifikat")
    return der


async def certificate_is_trusted(session: aiohttp.ClientSession, url: str) -> bool:
    """Whether the server's certificate is valid without pinning (e.g. a
    Let's Encrypt certificate behind a reverse proxy)."""
    try:
        async with session.get(
            f"{url}/api/health", timeout=aiohttp.ClientTimeout(total=10)
        ):
            return True
    except aiohttp.ClientConnectorCertificateError:
        return False
    except aiohttp.ClientSSLError:
        return False


def _utc(moment: datetime) -> str:
    if moment.tzinfo is None:
        moment = moment.astimezone()
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


class FamioClient:
    """Talks to one Famio server as one member."""

    def __init__(
        self,
        session: aiohttp.ClientSession,
        url: str,
        *,
        token: str | None = None,
        pin: str | None = None,
        cert_sha256: str | None = None,
        on_certificate_renewed: Callable[[str], Awaitable[None] | None]
        | None = None,
    ) -> None:
        self._session = session
        self.url = url.rstrip("/")
        self.token = token
        self.pin = pin
        self.cert_sha256 = cert_sha256
        self._on_renewed = on_certificate_renewed

    # --- transport ---------------------------------------------------------

    def _ssl(self) -> Any:
        if not self.url.startswith("https://") or self.pin is None:
            return True
        if self.cert_sha256 is None:
            return False  # Checked by _refresh_certificate first.
        return aiohttp.Fingerprint(bytes.fromhex(self.cert_sha256))

    async def _refresh_certificate(self) -> None:
        """The server shows another certificate: accept it only with the
        confirmed key (renewal), otherwise refuse."""
        der = await fetch_certificate(self.url)
        if spki_fingerprint(der) != self.pin:
            raise FamioCertificateError(
                "Das Zertifikat des Servers passt nicht zum bestätigten "
                "Fingerabdruck. Wurde der Server neu eingerichtet? Dann die "
                "Integration neu einrichten."
            )
        self.cert_sha256 = hashlib.sha256(der).hexdigest()
        if self._on_renewed is not None:
            result = self._on_renewed(self.cert_sha256)
            if result is not None:
                await result

    def _headers(self) -> dict[str, str]:
        headers = {"accept": "application/json"}
        if self.token:
            headers["authorization"] = f"Bearer {self.token}"
        return headers

    async def request(
        self,
        method: str,
        path: str,
        *,
        json: Any = None,
        params: dict[str, str] | None = None,
        timeout: float = 30,
    ) -> Any:
        if self.pin is not None and self.cert_sha256 is None:
            await self._refresh_certificate()
        for attempt in range(2):
            try:
                async with self._session.request(
                    method,
                    f"{self.url}/{path}",
                    json=json,
                    params=params,
                    headers=self._headers(),
                    ssl=self._ssl(),
                    timeout=aiohttp.ClientTimeout(total=timeout),
                ) as response:
                    body = await response.json(content_type=None)
                    error = body.get("error") if isinstance(body, dict) else None
                    message = body.get("message") if isinstance(body, dict) else None
                    # 403 two_factor_*: two-factor login became mandatory for
                    # this member – sign in again with a code.
                    if response.status == 401 or error in (
                        "two_factor_required",
                        "two_factor_setup_required",
                    ):
                        raise FamioAuthError(message or "Nicht angemeldet", error)
                    if response.status >= 400:
                        raise FamioError(
                            message or f"Fehler {response.status}", error
                        )
                    return body
            except aiohttp.ServerFingerprintMismatch:
                if attempt:
                    raise
                await self._refresh_certificate()
            except (aiohttp.ClientError, TimeoutError) as err:
                raise FamioConnectionError(
                    f"Server nicht erreichbar ({err})"
                ) from err
        raise FamioConnectionError("Server nicht erreichbar")

    async def websocket(self) -> aiohttp.ClientWebSocketResponse:
        """Live notifications ({"type": "rev"} after every change)."""
        if self.pin is not None and self.cert_sha256 is None:
            await self._refresh_certificate()
        url = self.url.replace("https://", "wss://", 1).replace(
            "http://", "ws://", 1
        )
        try:
            return await self._session.ws_connect(
                f"{url}/api/ws",
                headers=self._headers(),
                ssl=self._ssl(),
                heartbeat=45,
            )
        except aiohttp.ServerFingerprintMismatch:
            await self._refresh_certificate()
            return await self._session.ws_connect(
                f"{url}/api/ws",
                headers=self._headers(),
                ssl=self._ssl(),
                heartbeat=45,
            )

    # --- API ---------------------------------------------------------------

    async def health(self) -> dict[str, Any]:
        return await self.request("GET", "api/health")

    async def login(self, username: str, password: str) -> dict[str, Any]:
        """Signs in; returns the member. The session appears as
        "Home Assistant" in the member's devices."""
        answer = await self.request(
            "POST",
            "api/auth/login",
            json={
                "username": username,
                "password": password,
                "device": DEVICE_NAME,
            },
        )
        if answer.get("twoFactorRequired"):
            raise FamioTwoFactorError(answer["challenge"])
        self.token = answer["token"]
        return answer["member"]

    async def login_two_factor(self, challenge: str, code: str) -> dict[str, Any]:
        """Second step: the 6-digit code from the authenticator app (or a
        recovery code). Home Assistant then keeps the session; it only needs
        a code again when the session is signed out."""
        answer = await self.request(
            "POST",
            "api/auth/login/two-factor",
            json={"challenge": challenge, "code": code.replace(" ", "")},
        )
        self.token = answer["token"]
        return answer["member"]

    async def logout(self) -> None:
        await self.request("POST", "api/auth/logout", json={})

    async def me(self) -> dict[str, Any]:
        return await self.request("GET", "api/me")

    async def members(self) -> list[dict[str, Any]]:
        return (await self.request("GET", "api/members"))["members"]

    async def sync(
        self, since: int, changes: list[dict[str, Any]] | None = None
    ) -> dict[str, Any]:
        return await self.request(
            "POST",
            "api/sync",
            json={"since": since, "changes": changes or []},
        )

    async def occurrences(
        self, start: datetime, end: datetime
    ) -> list[dict[str, Any]]:
        answer = await self.request(
            "GET",
            "api/calendar/occurrences",
            params={"from": _utc(start), "to": _utc(end)},
        )
        return answer["occurrences"]
