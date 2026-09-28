"""Setup: server address, confirming its certificate, signing in."""

from __future__ import annotations

from collections.abc import Mapping
import hashlib
from typing import Any

import voluptuous as vol

from homeassistant.config_entries import ConfigFlow, ConfigFlowResult
from homeassistant.const import (
    CONF_CODE,
    CONF_PASSWORD,
    CONF_TOKEN,
    CONF_URL,
    CONF_USERNAME,
)
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .api import (
    FamioAuthError,
    FamioTwoFactorError,
    FamioCertificateError,
    FamioClient,
    FamioConnectionError,
    FamioError,
    certificate_is_trusted,
    fetch_certificate,
    normalize_url,
    spki_fingerprint,
)
from .const import CONF_CERT_SHA256, CONF_MEMBER_ID, CONF_PIN, DOMAIN

USER_SCHEMA = vol.Schema(
    {
        vol.Required(CONF_URL): str,
        vol.Required(CONF_USERNAME): str,
        vol.Required(CONF_PASSWORD): str,
    }
)


def _error(err: FamioError) -> str:
    """The form error for a failed sign-in."""
    if isinstance(err, FamioCertificateError):
        return "invalid_cert"
    if isinstance(err, FamioConnectionError):
        return "cannot_connect"
    if err.code == "two_factor_setup_required":
        return "two_factor_setup"
    if err.code == "challenge_expired":
        return "code_expired"
    if isinstance(err, FamioAuthError):
        return "invalid_auth"
    return "unknown"


class FamioConfigFlow(ConfigFlow, domain=DOMAIN):
    """Connects Home Assistant to a Famio server as one member."""

    VERSION = 1

    def __init__(self) -> None:
        self._input: dict[str, Any] = {}
        self._url = ""
        self._pin: str | None = None
        self._cert_sha256: str | None = None
        self._client: FamioClient
        self._challenge = ""

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            self._input = user_input
            try:
                self._url = normalize_url(user_input[CONF_URL])
            except ValueError:
                errors[CONF_URL] = "invalid_url"
            else:
                try:
                    return await self._check_certificate()
                except FamioConnectionError:
                    errors["base"] = "cannot_connect"
        return self.async_show_form(
            step_id="user",
            data_schema=self.add_suggested_values_to_schema(
                USER_SCHEMA, user_input or {}
            ),
            errors=errors,
        )

    async def _check_certificate(self) -> ConfigFlowResult:
        """Own certificate of the Famio server: the user compares its
        fingerprint with the server log, as in the apps."""
        self._pin = self._cert_sha256 = None
        if self._url.startswith("https://") and not await certificate_is_trusted(
            async_get_clientsession(self.hass), self._url
        ):
            der = await fetch_certificate(self._url)
            self._pin = spki_fingerprint(der)
            self._cert_sha256 = hashlib.sha256(der).hexdigest()
            return await self.async_step_certificate()
        return await self._sign_in()

    async def async_step_certificate(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        if user_input is None:
            return self.async_show_form(
                step_id="certificate",
                data_schema=vol.Schema({}),
                description_placeholders={
                    "fingerprint": self._pin or "",
                    "url": self._url,
                },
            )
        return await self._sign_in()

    async def _sign_in(self) -> ConfigFlowResult:
        self._client = FamioClient(
            async_get_clientsession(self.hass),
            self._url,
            pin=self._pin,
            cert_sha256=self._cert_sha256,
        )
        try:
            member = await self._client.login(
                self._input[CONF_USERNAME], self._input[CONF_PASSWORD]
            )
        except FamioTwoFactorError as err:
            # Password right: now the code from the authenticator app.
            self._challenge = err.challenge
            return await self.async_step_two_factor()
        except FamioError as err:
            return self._password_form(_error(err))
        return await self._finish(member)

    async def async_step_two_factor(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Two-factor login: asked once, Home Assistant keeps the session."""
        errors: dict[str, str] = {}
        if user_input is not None:
            try:
                member = await self._client.login_two_factor(
                    self._challenge, user_input[CONF_CODE]
                )
            except FamioError as err:
                if err.code != "invalid_code":
                    # Expired or too many tries: start with the password.
                    return self._password_form(_error(err))
                errors["base"] = "invalid_code"
            else:
                return await self._finish(member)
        return self.async_show_form(
            step_id="two_factor",
            data_schema=vol.Schema({vol.Required(CONF_CODE): str}),
            description_placeholders={"username": self._input[CONF_USERNAME]},
            errors=errors,
        )

    async def _finish(self, member: dict[str, Any]) -> ConfigFlowResult:
        client = self._client
        # Two-factor login is mandatory for this member but not set up yet:
        # the session could not read anything.
        try:
            await client.members()
        except FamioAuthError as err:
            try:
                await client.logout()
            except FamioError:
                pass
            return self._password_form(_error(err))
        except FamioError as err:
            return self._password_form(_error(err))

        data = {
            CONF_URL: self._url,
            CONF_TOKEN: client.token,
            CONF_PIN: self._pin,
            CONF_CERT_SHA256: client.cert_sha256,
            CONF_MEMBER_ID: member["id"],
            CONF_USERNAME: member["username"],
        }
        await self.async_set_unique_id(member["id"])
        if self.source == "reauth":
            return self.async_update_reload_and_abort(
                self._get_reauth_entry(), data=data
            )
        self._abort_if_unique_id_configured()
        return self.async_create_entry(
            title=f"Famio ({member.get('displayName') or member['username']})",
            data=data,
        )

    def _password_form(self, error: str) -> ConfigFlowResult:
        """Back to the password, with what went wrong."""
        if self.source == "reauth":
            return self.async_show_form(
                step_id="reauth_confirm",
                data_schema=vol.Schema({vol.Required(CONF_PASSWORD): str}),
                description_placeholders={"username": self._input[CONF_USERNAME]},
                errors={"base": error},
            )
        return self.async_show_form(
            step_id="user",
            data_schema=self.add_suggested_values_to_schema(
                USER_SCHEMA, {**self._input, CONF_PASSWORD: ""}
            ),
            errors={"base": error},
        )

    # --- the session was revoked (e.g. signed out in the app) ---------------

    async def async_step_reauth(
        self, entry_data: Mapping[str, Any]
    ) -> ConfigFlowResult:
        self._url = entry_data[CONF_URL]
        self._pin = entry_data.get(CONF_PIN)
        self._cert_sha256 = entry_data.get(CONF_CERT_SHA256)
        self._input = {
            CONF_URL: self._url,
            CONF_USERNAME: entry_data.get(CONF_USERNAME, ""),
        }
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        if user_input is None:
            return self.async_show_form(
                step_id="reauth_confirm",
                data_schema=vol.Schema({vol.Required(CONF_PASSWORD): str}),
                description_placeholders={
                    "username": self._input[CONF_USERNAME]
                },
            )
        self._input[CONF_PASSWORD] = user_input[CONF_PASSWORD]
        return await self._sign_in()
