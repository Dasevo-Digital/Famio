"""Famio – the family organizer in Home Assistant.

Connects to a Famio server (Proxmox container, Docker or the Famio add-on)
as one family member: calendar, tasks and shopping lists as to-do lists,
sensors and the family's shared locations.
"""

from __future__ import annotations

from homeassistant.const import CONF_TOKEN, CONF_URL, Platform
from homeassistant.core import HomeAssistant
from homeassistant.helpers import config_validation as cv, device_registry as dr
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.typing import ConfigType

from .api import FamioClient, FamioError
from . import dashboard
from .const import CONF_CERT_SHA256, CONF_PIN, DOMAIN
from .coordinator import FamioConfigEntry, FamioCoordinator

CONFIG_SCHEMA = cv.config_entry_only_config_schema(DOMAIN)

PLATFORMS = [
    Platform.BINARY_SENSOR,
    Platform.CALENDAR,
    Platform.DEVICE_TRACKER,
    Platform.SENSOR,
    Platform.TODO,
]


def client_for(hass: HomeAssistant, entry: FamioConfigEntry) -> FamioClient:
    async def renewed(cert_sha256: str) -> None:
        # The server renewed its certificate with the same key.
        hass.config_entries.async_update_entry(
            entry, data={**entry.data, CONF_CERT_SHA256: cert_sha256}
        )

    return FamioClient(
        async_get_clientsession(hass),
        entry.data[CONF_URL],
        token=entry.data[CONF_TOKEN],
        pin=entry.data.get(CONF_PIN),
        cert_sha256=entry.data.get(CONF_CERT_SHA256),
        on_certificate_renewed=renewed,
        language=hass.config.language,
    )


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """The action famio.dashboard (a dashboard of the family as YAML)."""
    dashboard.async_register(hass)
    return True


async def async_setup_entry(hass: HomeAssistant, entry: FamioConfigEntry) -> bool:
    coordinator = FamioCoordinator(hass, entry, client_for(hass, entry))
    await coordinator.async_config_entry_first_refresh()
    entry.runtime_data = coordinator
    # The connection's own device first: the members' devices hang below it.
    hub = dr.async_get(hass).async_get_or_create(
        config_entry_id=entry.entry_id,
        identifiers={(DOMAIN, entry.unique_id or entry.entry_id)},
        name=entry.title,
        manufacturer="Famio",
        model="Familien-Organizer",
        entry_type=dr.DeviceEntryType.SERVICE,
        configuration_url=coordinator.client.url,
    )
    coordinator.hub_device_id = hub.id
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    coordinator.start_listening()
    return True


async def async_unload_entry(hass: HomeAssistant, entry: FamioConfigEntry) -> bool:
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)


async def async_remove_entry(hass: HomeAssistant, entry: FamioConfigEntry) -> None:
    """Ends the session on the server ("Home Assistant" disappears from the
    member's devices)."""
    try:
        await client_for(hass, entry).logout()
    except FamioError:
        pass
