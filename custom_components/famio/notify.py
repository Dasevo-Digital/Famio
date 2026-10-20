"""Messages from Home Assistant to the family ("Waschmaschine fertig"): into
the family chat, or as a direct message to one member. Famio delivers them
like any chat message, with its push notification (quiet hours included).
The account of the integration must be allowed to change data."""

from __future__ import annotations

from datetime import datetime, timezone
import uuid

from homeassistant.components.notify import NotifyEntity, NotifyEntityFeature
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import FamioConfigEntry
from .api import FamioError
from .const import CHAT_MESSAGES, FAMILY_CHAT
from .coordinator import FamioCoordinator
from .entity import FamioEntity, FamioMemberEntity


def direct_chat_id(a: str, b: str) -> str:
    """The id of the direct chat of two members, as Famio derives it
    (ChatIds.direct): the same from either side."""

    def short(member_id: str) -> str:
        return member_id.replace("-", "").ljust(16, "0")[:16]

    first, second = sorted([a, b])
    return f"dm-{short(first)}-{short(second)}"


def message_text(message: str, title: str | None) -> str:
    """A title becomes the first line."""
    return f"{title}\n{message}" if title else message


async def _send(
    coordinator: FamioCoordinator,
    chat_id: str,
    text: str,
    visible_to: list[str] | None = None,
) -> None:
    if coordinator.data.access != "full":
        raise HomeAssistantError(
            "Das Famio-Konto von Home Assistant darf keine Nachrichten "
            "schreiben (in Famio Zugriff „Lesen und ändern“ geben)."
        )
    if not text.strip():
        raise HomeAssistantError("Leere Nachricht")
    data = {
        "chatId": chat_id,
        "authorId": coordinator.member_id,
        "sentAt": datetime.now(timezone.utc).isoformat(),
        "text": text.strip(),
        "attachment": None,
        # Direct messages: only the two see them (and get the push).
        "visibleTo": visible_to,
    }
    try:
        await coordinator.async_write(CHAT_MESSAGES, uuid.uuid4().hex, data)
    except FamioError as err:
        raise HomeAssistantError(str(err)) from err


async def async_setup_entry(
    hass: HomeAssistant,
    entry: FamioConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    coordinator = entry.runtime_data
    async_add_entities([FamioFamilyChat(coordinator)])
    known: set[str] = set()

    @callback
    def add_members() -> None:
        new = [
            FamioDirectMessage(coordinator, member["id"])
            for member in coordinator.data.family
            if member["id"] not in known and member["id"] != coordinator.member_id
        ]
        known.update(entity.member_id for entity in new)
        if new:
            async_add_entities(new)

    add_members()
    entry.async_on_unload(coordinator.async_add_listener(add_members))


class FamioFamilyChat(FamioEntity, NotifyEntity):
    """notify.send_message to the family chat."""

    _attr_translation_key = "family_chat"
    _attr_supported_features = NotifyEntityFeature.TITLE

    def __init__(self, coordinator: FamioCoordinator) -> None:
        super().__init__(coordinator, "notify_family_chat")

    async def async_send_message(self, message: str, title: str | None = None) -> None:
        await _send(self.coordinator, FAMILY_CHAT, message_text(message, title))


class FamioDirectMessage(FamioMemberEntity, NotifyEntity):
    """notify.send_message to one member: a direct message from Home
    Assistant, which only this member sees."""

    _attr_translation_key = "direct_message"
    _attr_supported_features = NotifyEntityFeature.TITLE

    def __init__(self, coordinator: FamioCoordinator, member_id: str) -> None:
        super().__init__(coordinator, member_id, "notify")

    async def async_send_message(self, message: str, title: str | None = None) -> None:
        me = self.coordinator.member_id
        await _send(
            self.coordinator,
            direct_chat_id(me, self.member_id),
            message_text(message, title),
            [me, self.member_id],
        )
