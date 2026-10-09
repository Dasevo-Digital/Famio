"""The action famio.dashboard: a ready-made dashboard of the family.

Home Assistant cannot create dashboards from an integration, so the action
answers with the dashboard's YAML: Settings → Dashboards → Add dashboard →
"New dashboard from scratch" → ⋮ → Raw configuration editor → paste.
"""

from __future__ import annotations

from typing import Any

import voluptuous as vol

from homeassistant.core import (
    HomeAssistant,
    ServiceCall,
    ServiceResponse,
    SupportsResponse,
)
from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers import config_validation as cv, entity_registry as er
from homeassistant.util.yaml import dump

from .const import DOMAIN, MEMBER_LOCATIONS, SHOPPING_LISTS
from .coordinator import FamioConfigEntry

SERVICE_DASHBOARD = "dashboard"
ATTR_CONFIG_ENTRY = "config_entry_id"

SCHEMA = vol.Schema({vol.Optional(ATTR_CONFIG_ENTRY): cv.string})


# Titles in Home Assistant's language (English for the others).
_TEXTS = {
    "de": {"family": "Familie", "member": "Mitglied"},
    "en": {"family": "Family", "member": "Member"},
    "es": {"family": "Familia", "member": "Miembro"},
}


def build_dashboard(hass: HomeAssistant, entry: FamioConfigEntry) -> dict[str, Any]:
    """Lovelace configuration: family calendar, one column per member (next
    event, open tasks, points, their to-do list), shopping lists and map."""
    registry = er.async_get(hass)
    prefix = entry.unique_id or entry.entry_id
    data = entry.runtime_data.data

    def entity(domain: str, key: str) -> str | None:
        return registry.async_get_entity_id(domain, DOMAIN, f"{prefix}_{key}")

    texts = _TEXTS.get(hass.config.language.split("-")[0], _TEXTS["en"])
    cards: list[dict[str, Any]] = []
    calendars = [entity("calendar", "calendar")] + [
        entity("calendar", f"member_{m['id']}_calendar") for m in data.family
    ]
    if calendars := [c for c in calendars if c]:
        cards.append(
            {"type": "calendar", "initial_view": "listWeek", "entities": calendars}
        )

    for member in data.family:
        mid = member["id"]
        rows = [
            e
            for e in (
                entity("sensor", f"member_{mid}_next_event"),
                entity("sensor", f"member_{mid}_open_tasks"),
                # Points are the children's thing.
                entity("sensor", f"member_{mid}_points")
                if member.get("role") == "child"
                else None,
            )
            if e
        ]
        stack: list[dict[str, Any]] = [
            {
                "type": "heading",
                "heading": member.get("displayName") or texts["member"],
                "icon": "mdi:account-heart",
            }
        ]
        if tracker := entity("device_tracker", f"location_{mid}"):
            stack[0]["badges"] = [{"type": "entity", "entity": tracker}]
        if rows:
            stack.append({"type": "entities", "entities": rows})
        if todo := entity("todo", f"member_{mid}_tasks"):
            stack.append({"type": "todo-list", "entity": todo, "hide_completed": True})
        cards.append({"type": "vertical-stack", "cards": stack})

    for list_id in data.collection(SHOPPING_LISTS):
        if todo := entity("todo", f"shopping_{list_id}"):
            cards.append({"type": "todo-list", "entity": todo, "hide_completed": True})

    trackers = [
        t
        for member_id in data.collection(MEMBER_LOCATIONS)
        if (t := entity("device_tracker", f"location_{member_id}"))
    ]
    if trackers:
        cards.append({"type": "map", "entities": trackers, "hours_to_show": 0})

    return {
        "title": "Famio",
        "views": [
            {
                "title": texts["family"],
                "path": "famio",
                "icon": "mdi:home-heart",
                "cards": cards,
            }
        ],
    }


def async_register(hass: HomeAssistant) -> None:
    async def handle(call: ServiceCall) -> ServiceResponse:
        entries: list[FamioConfigEntry] = [
            e
            for e in hass.config_entries.async_loaded_entries(DOMAIN)
            if ATTR_CONFIG_ENTRY not in call.data
            or e.entry_id == call.data[ATTR_CONFIG_ENTRY]
        ]
        if not entries:
            raise ServiceValidationError(
                translation_domain=DOMAIN, translation_key="no_entry"
            )
        dashboard = build_dashboard(hass, entries[0])
        return {"yaml": dump(dashboard), "dashboard": dashboard}

    hass.services.async_register(
        DOMAIN,
        SERVICE_DASHBOARD,
        handle,
        schema=SCHEMA,
        supports_response=SupportsResponse.ONLY,
    )
