"""Per member: an emergency (SOS) is running."""

from __future__ import annotations

from typing import Any

from homeassistant.components.binary_sensor import (
    BinarySensorDeviceClass,
    BinarySensorEntity,
)
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from .const import SOS_ALERTS
from .coordinator import FamioConfigEntry, FamioCoordinator
from .entity import FamioMemberEntity


async def async_setup_entry(
    hass: HomeAssistant,
    entry: FamioConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    coordinator = entry.runtime_data
    known: set[str] = set()

    @callback
    def add_members() -> None:
        new = []
        for member in coordinator.data.family:
            if member["id"] not in known:
                known.add(member["id"])
                new.append(FamioSosSensor(coordinator, member["id"]))
        if new:
            async_add_entities(new)

    add_members()
    entry.async_on_unload(coordinator.async_add_listener(add_members))


class FamioSosSensor(FamioMemberEntity, BinarySensorEntity):
    """On while the member's emergency is open (not yet ended)."""

    _attr_device_class = BinarySensorDeviceClass.SAFETY
    _attr_translation_key = "sos"

    def __init__(self, coordinator: FamioCoordinator, member_id: str) -> None:
        super().__init__(coordinator, member_id, "sos")

    def _open(self) -> dict[str, Any] | None:
        open_alerts = [
            a
            for a in self.coordinator.data.collection(SOS_ALERTS).values()
            if a.get("memberId") == self.member_id and a.get("state") != "resolved"
        ]
        return max(open_alerts, key=lambda a: a.get("startedAt") or "", default=None)

    @property
    def is_on(self) -> bool:
        return self._open() is not None

    @property
    def extra_state_attributes(self) -> dict[str, Any] | None:
        alert = self._open()
        if alert is None:
            return None
        return {
            "state": alert.get("state"),
            "started_at": alert.get("startedAt"),
            "latitude": alert.get("latitude"),
            "longitude": alert.get("longitude"),
            "coming": self.coordinator.data.member_name(alert.get("comingBy")),
        }
