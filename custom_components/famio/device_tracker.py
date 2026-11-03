"""Shared locations of family members (Famio "Standort")."""

from __future__ import annotations

from typing import Any

from homeassistant.components.device_tracker import SourceType, TrackerEntity
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from .const import MEMBER_LOCATIONS, PLACES
from .coordinator import FamioConfigEntry, FamioCoordinator
from .entity import FamioEntity


async def async_setup_entry(
    hass: HomeAssistant,
    entry: FamioConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    coordinator = entry.runtime_data
    known: set[str] = set()

    @callback
    def add_members() -> None:
        locations = coordinator.data.collection(MEMBER_LOCATIONS)
        new = [
            FamioMemberTracker(coordinator, member_id)
            for member_id in locations
            if member_id not in known
        ]
        known.update(locations)
        if new:
            async_add_entities(new)

    add_members()
    entry.async_on_unload(coordinator.async_add_listener(add_members))


# What makes a new position. Battery, last contact and the sharing state
# change while the position stays the same (a paused device keeps
# reporting its battery, for example).
_POSITION = ("latitude", "longitude", "accuracy", "at", "placeId")


def _position(location: dict[str, Any]) -> tuple[Any, ...]:
    return tuple(location.get(key) for key in _POSITION)


class FamioMemberTracker(FamioEntity, TrackerEntity):
    """Where a family member is, as far as they share it in Famio.

    The tracker changes only with a new position. Home Assistant's person
    entity follows the GPS tracker that was updated last; a battery update
    alone made an old Famio position newer than a fresh one from the Home
    Assistant app, and the person jumped between zones several times a day.
    The attributes therefore keep the state of the last position; the
    current battery and sharing state are sensors of the member.
    """

    _attr_source_type = SourceType.GPS

    def __init__(self, coordinator: FamioCoordinator, member_id: str) -> None:
        super().__init__(coordinator, f"location_{member_id}")
        self._member_id = member_id
        self._location = self._latest()

    def _latest(self) -> dict[str, Any]:
        return self.coordinator.data.collection(MEMBER_LOCATIONS).get(
            self._member_id, {}
        )

    @callback
    def _handle_coordinator_update(self) -> None:
        latest = self._latest()
        if _position(latest) == _position(self._location) and bool(latest) == bool(
            self._location
        ):
            return
        self._location = latest
        self.async_write_ha_state()

    @property
    def name(self) -> str:
        return self.coordinator.data.member_name(self._member_id) or "Mitglied"

    @property
    def available(self) -> bool:
        # Not tied to the connection: unavailable and back again would write
        # the old position anew and make it the newest for the person.
        return bool(self._location)

    @property
    def latitude(self) -> float | None:
        return self._location.get("latitude")

    @property
    def longitude(self) -> float | None:
        return self._location.get("longitude")

    @property
    def location_accuracy(self) -> float:
        return float(self._location.get("accuracy") or 0)

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        location = self._location
        place = self.coordinator.data.collection(PLACES).get(
            location.get("placeId") or ""
        )
        return {
            "freigabe": location.get("state", "active"),
            "zuletzt": location.get("at"),
            "famio_ort": (place or {}).get("name"),
            "pausiert_bis": location.get("pausedUntil"),
            "akku": location.get("battery"),
        }
