"""The Famio family calendar (own events, series and shared calendars)."""

from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Any
import uuid

from homeassistant.components.calendar import (
    CalendarEntity,
    CalendarEntityFeature,
    CalendarEvent,
)
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback
from homeassistant.util import dt as dt_util

from .api import FamioError
from .const import EVENTS
from .coordinator import FamioConfigEntry, FamioCoordinator, parse_end, parse_start
from .entity import FamioEntity


async def async_setup_entry(
    hass: HomeAssistant,
    entry: FamioConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    async_add_entities([FamioCalendar(entry.runtime_data)])


def to_calendar_event(occurrence: dict[str, Any]) -> CalendarEvent:
    all_day = occurrence.get("allDay", False)
    start: date | datetime
    end: date | datetime
    if all_day:
        start = dt_util.parse_date(occurrence["start"])
        end = dt_util.parse_date(occurrence["end"])
    else:
        start = parse_start(occurrence)
        end = parse_end(occurrence)
    confidential = occurrence.get("confidential", False)
    calendar = occurrence.get("calendar")
    notes = occurrence.get("notes") or ""
    if calendar:
        notes = f"{notes}\n\nKalender: {calendar}".strip()
    return CalendarEvent(
        start=start,
        end=end,
        # Confidential events (doctor, surprises …) only as "busy".
        summary="Belegt" if confidential else occurrence.get("title") or "",
        description=None if confidential or not notes else notes,
        location=None if confidential else occurrence.get("location") or None,
        uid=occurrence.get("id"),
    )


class FamioCalendar(FamioEntity, CalendarEntity):
    _attr_translation_key = "calendar"
    _attr_supported_features = (
        CalendarEntityFeature.CREATE_EVENT | CalendarEntityFeature.DELETE_EVENT
    )

    def __init__(self, coordinator: FamioCoordinator) -> None:
        super().__init__(coordinator, "calendar")

    @property
    def event(self) -> CalendarEvent | None:
        occurrence = self.coordinator.next_event()
        return to_calendar_event(occurrence) if occurrence else None

    async def async_get_events(
        self, hass: HomeAssistant, start_date: datetime, end_date: datetime
    ) -> list[CalendarEvent]:
        events: list[CalendarEvent] = []
        # The server answers up to 400 days at a time.
        chunk = timedelta(days=365)
        begin = start_date
        try:
            while begin < end_date:
                stop = min(begin + chunk, end_date)
                events.extend(
                    to_calendar_event(o)
                    for o in await self.coordinator.client.occurrences(begin, stop)
                )
                begin = stop
        except FamioError as err:
            raise HomeAssistantError(str(err)) from err
        return events

    async def async_create_event(self, **kwargs: Any) -> None:
        if kwargs.get("rrule"):
            raise HomeAssistantError(
                "Serientermine bitte in der Famio-App anlegen."
            )
        start = kwargs["dtstart"]
        end = kwargs["dtend"]
        all_day = not isinstance(start, datetime)

        def instant(value: datetime) -> str:
            if value.tzinfo is None:
                value = value.replace(tzinfo=dt_util.get_default_time_zone())
            return dt_util.as_utc(value).isoformat().replace("+00:00", "Z")

        data = {
            "title": kwargs.get("summary") or "",
            "start": start.isoformat() if all_day else instant(start),
            "end": end.isoformat() if all_day else instant(end),
            "allDay": all_day,
            "location": kwargs.get("location") or "",
            "notes": kwargs.get("description") or "",
            "memberIds": [],
            "recurrence": None,
            "exceptions": [],
            "reminderMinutes": None,
        }
        try:
            await self.coordinator.async_write(EVENTS, uuid.uuid4().hex, data)
            await self.coordinator.async_request_refresh()
        except FamioError as err:
            raise HomeAssistantError(str(err)) from err

    async def async_delete_event(
        self,
        uid: str,
        recurrence_id: str | None = None,
        recurrence_range: str | None = None,
    ) -> None:
        event = self.coordinator.data.collection(EVENTS).get(uid)
        if event is None:
            raise HomeAssistantError(
                "Nur Famio-Termine lassen sich löschen, keine abonnierten."
            )
        if event.get("recurrence"):
            raise HomeAssistantError("Serientermine bitte in der Famio-App löschen.")
        try:
            await self.coordinator.async_write(EVENTS, uid, None)
            await self.coordinator.async_request_refresh()
        except FamioError as err:
            raise HomeAssistantError(str(err)) from err
