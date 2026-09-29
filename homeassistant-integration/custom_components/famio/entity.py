"""Common base of Famio entities: one device per Famio connection."""

from __future__ import annotations

from homeassistant.helpers.device_registry import DeviceEntryType, DeviceInfo
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import FamioCoordinator


class FamioEntity(CoordinatorEntity[FamioCoordinator]):
    _attr_has_entity_name = True

    def __init__(self, coordinator: FamioCoordinator, key: str) -> None:
        super().__init__(coordinator)
        entry = coordinator.config_entry
        self._attr_unique_id = f"{entry.unique_id}_{key}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.unique_id or entry.entry_id)},
            name=entry.title,
            manufacturer="Famio",
            model="Familien-Organizer",
            entry_type=DeviceEntryType.SERVICE,
            configuration_url=coordinator.client.url,
        )


class FamioMemberEntity(FamioEntity):
    """An entity of one family member, on the member's own device
    ("Famio Lena") – for dashboards per person."""

    def __init__(self, coordinator: FamioCoordinator, member_id: str, key: str) -> None:
        # Explicitly: the calendar and to-do classes take other arguments.
        FamioEntity.__init__(self, coordinator, f"member_{member_id}_{key}")
        self.member_id = member_id
        entry = coordinator.config_entry
        parent = entry.unique_id or entry.entry_id
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, f"{parent}_member_{member_id}")},
            name=f"Famio {self.member_name}",
            manufacturer="Famio",
            model="Familienmitglied",
            entry_type=DeviceEntryType.SERVICE,
            via_device=(DOMAIN, parent),
        )

    @property
    def member_name(self) -> str:
        return self.coordinator.data.member_name(self.member_id) or "Mitglied"

    @property
    def available(self) -> bool:
        return super().available and self.member_id in self.coordinator.data.members
