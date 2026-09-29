"""Keeps a copy of the member's Famio data, like the apps do.

Famio synchronises "records" (tasks, shopping items, events, locations …).
The coordinator pulls what changed since the last revision, keeps it in
memory and writes changes back the same way. A WebSocket tells it right away
when something changed; polling is only the fallback.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import datetime
import logging
import time
from typing import Any

import aiohttp

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import ConfigEntryAuthFailed
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed
from homeassistant.util import dt as dt_util

from .api import FamioAuthError, FamioClient, FamioError
from .const import DOMAIN, POLL_INTERVAL, UPCOMING_WINDOW

_LOGGER = logging.getLogger(__name__)


@dataclass
class FamioData:
    """What Home Assistant knows of the family."""

    records: dict[str, dict[str, dict[str, Any]]] = field(default_factory=dict)
    members: dict[str, dict[str, Any]] = field(default_factory=dict)
    upcoming: list[dict[str, Any]] = field(default_factory=list)
    # The connected account itself (role, what a service account may change).
    me: dict[str, Any] = field(default_factory=dict)

    @property
    def family(self) -> list[dict[str, Any]]:
        """The family members, without service accounts (Home Assistant)."""
        return sorted(
            (m for m in self.members.values() if m.get("role") != "service"),
            key=lambda m: (m.get("displayName") or "").lower(),
        )

    @property
    def access(self) -> str:
        """full, everyday (tick off and shop) or readOnly."""
        if self.me.get("role") != "service":
            return "full"
        return self.me.get("serviceAccess") or "full"

    def collection(self, name: str) -> dict[str, dict[str, Any]]:
        """Live records of [name] by id (their data)."""
        return self.records.get(name, {})

    def member_name(self, member_id: str | None) -> str | None:
        member = self.members.get(member_id or "")
        return member.get("displayName") if member else None


type FamioConfigEntry = ConfigEntry[FamioCoordinator]


class FamioCoordinator(DataUpdateCoordinator[FamioData]):
    """Syncs one member's Famio data."""

    config_entry: FamioConfigEntry

    def __init__(
        self, hass: HomeAssistant, entry: FamioConfigEntry, client: FamioClient
    ) -> None:
        super().__init__(
            hass,
            _LOGGER,
            config_entry=entry,
            name=DOMAIN,
            update_interval=POLL_INTERVAL,
        )
        self.client = client
        self.member_id: str = entry.data["member_id"]
        self._rev = 0
        self._clock_offset = 0
        self._stored: dict[tuple[str, str], dict[str, Any]] = {}
        self._state = FamioData()
        self._listener: asyncio.Task | None = None
        self._lock = asyncio.Lock()

    # --- pull -----------------------------------------------------------------

    async def _async_update_data(self) -> FamioData:
        try:
            async with self._lock:
                await self._pull()
            members = await self.client.members()
            me = await self.client.me()
            now = dt_util.now()
            upcoming = await self.client.occurrences(now, now + UPCOMING_WINDOW)
        except FamioAuthError as err:
            raise ConfigEntryAuthFailed(str(err)) from err
        except FamioError as err:
            raise UpdateFailed(str(err)) from err
        self._state.members = {m["id"]: m for m in members}
        self._state.me = me
        self._state.upcoming = upcoming
        return self._state

    async def _pull(self, changes: list[dict[str, Any]] | None = None) -> dict:
        """One sync round trip (plus pages); returns the last answer."""
        answer = await self.client.sync(self._rev, changes)
        while True:
            self._apply(answer.get("changes", []))
            self._apply(answer.get("rejected", []))
            self._rev = answer["rev"]
            self._clock_offset = answer["serverTime"] - int(time.time() * 1000)
            if not answer.get("hasMore"):
                return answer
            answer = await self.client.sync(self._rev)

    def _apply(self, records: list[dict[str, Any]]) -> None:
        for record in records:
            key = (record["collection"], record["id"])
            collection = self._state.records.setdefault(record["collection"], {})
            if record.get("deleted"):
                self._stored.pop(key, None)
                collection.pop(record["id"], None)
            else:
                self._stored[key] = record
                collection[record["id"]] = record.get("data") or {}

    # --- write ----------------------------------------------------------------

    async def async_write(
        self,
        collection: str,
        record_id: str,
        data: dict[str, Any] | None,
    ) -> None:
        """Creates, changes or (data None) deletes a record."""
        existing = self._stored.get((collection, record_id))
        now = int(time.time() * 1000) + self._clock_offset
        updated_at = max(now, (existing or {}).get("updatedAt", 0) + 1)
        change = {
            "collection": collection,
            "id": record_id,
            "data": data or {},
            "updatedAt": updated_at,
            "deleted": data is None,
        }
        try:
            async with self._lock:
                answer = await self._pull([change])
        except FamioAuthError as err:
            raise ConfigEntryAuthFailed(str(err)) from err
        if any(
            r["collection"] == collection and r["id"] == record_id
            for r in answer.get("rejected", [])
        ):
            raise FamioError("Famio hat die Änderung abgelehnt (keine Berechtigung).")
        self.async_set_updated_data(self._state)

    # --- live updates -----------------------------------------------------------

    @callback
    def start_listening(self) -> None:
        self._listener = self.config_entry.async_create_background_task(
            self.hass, self._listen(), f"{DOMAIN}_websocket"
        )

    async def _listen(self) -> None:
        delay = 5
        while True:
            try:
                ws = await self.client.websocket()
                delay = 5
                async with ws:
                    async for message in ws:
                        if message.type != aiohttp.WSMsgType.TEXT:
                            continue
                        payload = message.json()
                        kind = payload.get("type")
                        if kind == "rev" and payload.get("rev", 0) > self._rev:
                            await self.async_request_refresh()
                        elif kind == "members":
                            await self.async_request_refresh()
            except asyncio.CancelledError:
                raise
            except (FamioError, aiohttp.ClientError, TimeoutError, ValueError) as err:
                _LOGGER.debug("Famio live connection lost: %s", err)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 300)

    # --- helpers --------------------------------------------------------------

    def next_event(
        self, now: datetime | None = None, member_id: str | None = None
    ) -> dict[str, Any] | None:
        """The current or next upcoming occurrence (of [member_id])."""
        now = now or dt_util.now()
        for occurrence in self._state.upcoming:
            if member_id and member_id not in (occurrence.get("memberIds") or []):
                continue
            if parse_end(occurrence) > now:
                return occurrence
        return None


def parse_start(occurrence: dict[str, Any]) -> datetime:
    return _parse(occurrence["start"], occurrence.get("allDay", False))


def parse_end(occurrence: dict[str, Any]) -> datetime:
    return _parse(occurrence["end"], occurrence.get("allDay", False))


def _parse(value: str, all_day: bool) -> datetime:
    if all_day:
        day = dt_util.parse_date(value)
        return dt_util.start_of_local_day(day)
    moment = dt_util.parse_datetime(value)
    return dt_util.as_local(moment)
