"""Famio sensors: open tasks, shopping, the next event and chore points."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorEntityDescription,
)
from homeassistant.core import HomeAssistant, callback
from homeassistant.util import dt as dt_util
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from .const import POINT_ENTRIES, SHOPPING_ITEMS, SHOPPING_LISTS, TASKS
from .coordinator import FamioConfigEntry, FamioCoordinator, parse_start
from .entity import FamioEntity, FamioMemberEntity


def _open_tasks(c: FamioCoordinator) -> list[dict[str, Any]]:
    return [t for t in c.data.collection(TASKS).values() if not t.get("done")]


def _open_items(c: FamioCoordinator) -> list[dict[str, Any]]:
    return [
        i for i in c.data.collection(SHOPPING_ITEMS).values() if not i.get("checked")
    ]


def _mine(c: FamioCoordinator) -> list[dict[str, Any]]:
    return [t for t in _open_tasks(c) if t.get("assigneeId") == c.member_id]


def _points(c: FamioCoordinator) -> dict[str, int]:
    """Confirmed points per member id."""
    balances: dict[str, int] = {}
    for e in c.data.collection(POINT_ENTRIES).values():
        if e.get("status", "approved") != "approved":
            continue
        member = e.get("memberId") or ""
        balances[member] = balances.get(member, 0) + int(e.get("points") or 0)
    return balances


def _pending(c: FamioCoordinator) -> int:
    return sum(
        1
        for e in c.data.collection(POINT_ENTRIES).values()
        if e.get("status") == "pending"
    )


def _theirs(c: FamioCoordinator, member_id: str) -> list[dict[str, Any]]:
    """Open tasks of [member_id], by due date."""
    return sorted(
        (t for t in _open_tasks(c) if t.get("assigneeId") == member_id),
        key=lambda t: t.get("due") or "9999",
    )


def _overdue(tasks: list[dict[str, Any]]) -> int:
    today = dt_util.now().date().isoformat()
    return sum(1 for t in tasks if (t.get("due") or "9999")[:10] < today)


@dataclass(frozen=True, kw_only=True)
class FamioMemberSensorDescription(SensorEntityDescription):
    value: Callable[[FamioCoordinator, str], Any]
    attributes: Callable[[FamioCoordinator, str], dict[str, Any]] | None = None


def _event_attributes(e: dict[str, Any] | None) -> dict[str, Any]:
    if not e:
        return {}
    return {
        "titel": "Belegt" if e.get("confidential") else e.get("title"),
        "ganztaegig": e.get("allDay", False),
        "ort": None if e.get("confidential") else e.get("location") or None,
        "kalender": e.get("calendar"),
    }


# Per family member, on the member's device ("Famio Lena").
MEMBER_SENSORS = (
    FamioMemberSensorDescription(
        key="open_tasks",
        translation_key="open_tasks",
        state_class="measurement",
        value=lambda c, m: len(_theirs(c, m)),
        attributes=lambda c, m: {
            "aufgaben": [t.get("title") for t in _theirs(c, m)][:20],
            "ueberfaellig": _overdue(_theirs(c, m)),
        },
    ),
    FamioMemberSensorDescription(
        key="next_event",
        translation_key="next_event",
        device_class=SensorDeviceClass.TIMESTAMP,
        value=lambda c, m: parse_start(e) if (e := c.next_event(member_id=m)) else None,
        attributes=lambda c, m: _event_attributes(c.next_event(member_id=m)),
    ),
    FamioMemberSensorDescription(
        key="points",
        translation_key="points",
        state_class="measurement",
        value=lambda c, m: _points(c).get(m, 0),
    ),
)


@dataclass(frozen=True, kw_only=True)
class FamioSensorDescription(SensorEntityDescription):
    value: Callable[[FamioCoordinator], Any]
    attributes: Callable[[FamioCoordinator], dict[str, Any]] | None = None


SENSORS = (
    FamioSensorDescription(
        key="open_tasks",
        translation_key="open_tasks",
        state_class="measurement",
        value=lambda c: len(_open_tasks(c)),
        attributes=lambda c: {
            "aufgaben": [t.get("title") for t in _open_tasks(c)][:20],
        },
    ),
    FamioSensorDescription(
        key="my_tasks",
        translation_key="my_tasks",
        state_class="measurement",
        value=lambda c: len(_mine(c)),
        attributes=lambda c: {"aufgaben": [t.get("title") for t in _mine(c)][:20]},
    ),
    FamioSensorDescription(
        key="shopping",
        translation_key="shopping",
        state_class="measurement",
        value=lambda c: len(_open_items(c)),
        attributes=lambda c: {
            "listen": {
                (l.get("name") or list_id): [
                    i.get("name")
                    for i in _open_items(c)
                    if i.get("listId") == list_id
                ]
                for list_id, l in c.data.collection(SHOPPING_LISTS).items()
            }
        },
    ),
    FamioSensorDescription(
        key="points",
        translation_key="points",
        state_class="measurement",
        value=lambda c: _points(c).get(c.member_id or "", 0),
        attributes=lambda c: {
            "punkte": {
                (c.data.member_name(m) or m): p for m, p in _points(c).items()
            },
            "offene_anfragen": _pending(c),
        },
    ),
    FamioSensorDescription(
        key="next_event",
        translation_key="next_event",
        device_class=SensorDeviceClass.TIMESTAMP,
        value=lambda c: parse_start(e) if (e := c.next_event()) else None,
        attributes=lambda c: (
            {
                "titel": "Belegt" if e.get("confidential") else e.get("title"),
                "ganztaegig": e.get("allDay", False),
                "ort": None if e.get("confidential") else e.get("location") or None,
                "kalender": e.get("calendar"),
            }
            if (e := c.next_event())
            else {}
        ),
    ),
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: FamioConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    coordinator = entry.runtime_data
    async_add_entities(FamioSensor(coordinator, d) for d in SENSORS)
    known: set[str] = set()

    @callback
    def add_members() -> None:
        new = []
        for member in coordinator.data.family:
            if member["id"] not in known:
                known.add(member["id"])
                new.extend(
                    FamioMemberSensor(coordinator, member["id"], d)
                    for d in MEMBER_SENSORS
                )
        if new:
            async_add_entities(new)

    add_members()
    entry.async_on_unload(coordinator.async_add_listener(add_members))


class FamioSensor(FamioEntity, SensorEntity):
    entity_description: FamioSensorDescription

    def __init__(
        self, coordinator: FamioCoordinator, description: FamioSensorDescription
    ) -> None:
        super().__init__(coordinator, description.key)
        self.entity_description = description

    @property
    def native_value(self) -> Any:
        return self.entity_description.value(self.coordinator)

    @property
    def extra_state_attributes(self) -> dict[str, Any] | None:
        if self.entity_description.attributes is None:
            return None
        return self.entity_description.attributes(self.coordinator)


class FamioMemberSensor(FamioMemberEntity, SensorEntity):
    entity_description: FamioMemberSensorDescription

    def __init__(
        self,
        coordinator: FamioCoordinator,
        member_id: str,
        description: FamioMemberSensorDescription,
    ) -> None:
        super().__init__(coordinator, member_id, description.key)
        self.entity_description = description

    @property
    def native_value(self) -> Any:
        return self.entity_description.value(self.coordinator, self.member_id)

    @property
    def extra_state_attributes(self) -> dict[str, Any] | None:
        if self.entity_description.attributes is None:
            return None
        return self.entity_description.attributes(self.coordinator, self.member_id)
