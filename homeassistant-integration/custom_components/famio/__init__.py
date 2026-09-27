"""Famio – the family organizer in Home Assistant.

Connects to a Famio server (Proxmox container, Docker or the Famio add-on)
as one family member: calendar, tasks and shopping lists as to-do lists,
sensors and the family's shared locations.
"""

from __future__ import annotations

from homeassistant.const import CONF_TOKEN, CONF_URL, Platform
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .api import FamioClient, FamioError
from .const import CONF_CERT_SHA256, CONF_PIN
from .coordinator import FamioConfigEntry, FamioCoordinator

PLATFORMS = [
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
    )


async def async_setup_entry(hass: HomeAssistant, entry: FamioConfigEntry) -> bool:
    coordinator = FamioCoordinator(hass, entry, client_for(hass, entry))
    await coordinator.async_config_entry_first_refresh()
    entry.runtime_data = coordinator
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
