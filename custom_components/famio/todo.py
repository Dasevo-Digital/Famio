"""Famio tasks and shopping lists as Home Assistant to-do lists."""

from __future__ import annotations

from datetime import date, datetime
from typing import Any
import uuid

from homeassistant.components.todo import (
    TodoItem,
    TodoItemStatus,
    TodoListEntity,
    TodoListEntityFeature,
)
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback
from homeassistant.util import dt as dt_util

from .api import FamioError
from .const import SHOPPING_ITEMS, SHOPPING_LISTS, TASKS
from .coordinator import FamioConfigEntry, FamioCoordinator
from .entity import FamioEntity, FamioMemberEntity

_ALL = (
    TodoListEntityFeature.CREATE_TODO_ITEM
    | TodoListEntityFeature.UPDATE_TODO_ITEM
    | TodoListEntityFeature.DELETE_TODO_ITEM
    | TodoListEntityFeature.SET_DESCRIPTION_ON_ITEM
)
_DUE = (
    TodoListEntityFeature.SET_DUE_DATE_ON_ITEM
    | TodoListEntityFeature.SET_DUE_DATETIME_ON_ITEM
)
_NONE = TodoListEntityFeature(0)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: FamioConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    coordinator = entry.runtime_data
    async_add_entities([FamioTasks(coordinator)])
    known: set[str] = set()
    known_members: set[str] = set()

    @callback
    def add_lists() -> None:
        lists = coordinator.data.collection(SHOPPING_LISTS)
        new: list[TodoListEntity] = [
            FamioShoppingList(coordinator, i) for i in lists if i not in known
        ]
        known.update(lists)
        for member in coordinator.data.family:
            if member["id"] not in known_members:
                known_members.add(member["id"])
                new.append(FamioMemberTasks(coordinator, member["id"]))
        if new:
            async_add_entities(new)

    add_lists()
    entry.async_on_unload(coordinator.async_add_listener(add_lists))


def _new_id() -> str:
    return uuid.uuid4().hex


async def _write(
    coordinator: FamioCoordinator,
    collection: str,
    record_id: str,
    data: dict[str, Any] | None,
) -> None:
    try:
        await coordinator.async_write(collection, record_id, data)
    except FamioError as err:
        raise HomeAssistantError(str(err)) from err


def _due(value: Any) -> date | datetime | None:
    """Famio stores the due time as local date-time; midnight means a day."""
    if not isinstance(value, str) or not value:
        return None
    moment = dt_util.parse_datetime(value)
    if moment is None:
        day = dt_util.parse_date(value[:10])
        return day
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=dt_util.get_default_time_zone())
    if (moment.hour, moment.minute, moment.second) == (0, 0, 0):
        return moment.date()
    return dt_util.as_local(moment)


def _due_value(due: date | datetime | None) -> str | None:
    if due is None:
        return None
    if isinstance(due, datetime):
        return dt_util.as_local(due).replace(tzinfo=None).isoformat()
    return datetime(due.year, due.month, due.day).isoformat()


class FamioTasks(FamioEntity, TodoListEntity):
    """The family's tasks (all the member may see)."""

    _attr_translation_key = "tasks"

    def __init__(self, coordinator: FamioCoordinator) -> None:
        super().__init__(coordinator, "tasks")

    # Service accounts may be limited to ticking off, or to reading.
    @property
    def supported_features(self) -> TodoListEntityFeature:
        match self.coordinator.data.access:
            case "readOnly":
                return _NONE
            case "everyday":
                return TodoListEntityFeature.UPDATE_TODO_ITEM
        return _ALL | _DUE

    # None: everyone's tasks; else the assignee's.
    _assignee: str | None = None

    @property
    def todo_items(self) -> list[TodoItem]:
        tasks = {
            task_id: task
            for task_id, task in self.coordinator.data.collection(TASKS).items()
            if self._assignee is None or task.get("assigneeId") == self._assignee
        }
        items = [
            TodoItem(
                uid=task_id,
                summary=task.get("title") or "",
                status=TodoItemStatus.COMPLETED
                if task.get("done")
                else TodoItemStatus.NEEDS_ACTION,
                due=_due(task.get("due")),
                description=task.get("notes") or None,
            )
            for task_id, task in tasks.items()
        ]
        # Open first, by due date.
        return sorted(
            items,
            key=lambda i: (
                i.status == TodoItemStatus.COMPLETED,
                str(i.due or "9999"),
                i.summary.lower(),
            ),
        )

    async def async_create_todo_item(self, item: TodoItem) -> None:
        now = datetime.now().isoformat()
        done = item.status == TodoItemStatus.COMPLETED
        await _write(
            self.coordinator,
            TASKS,
            _new_id(),
            {
                "title": item.summary or "",
                "notes": item.description or "",
                "done": done,
                "due": _due_value(item.due),
                "assigneeId": self._assignee,
                "completedAt": now if done else None,
                "createdAt": now,
                "remindAt": None,
            },
        )

    async def async_update_todo_item(self, item: TodoItem) -> None:
        existing = self.coordinator.data.collection(TASKS).get(item.uid or "")
        if existing is None:
            raise HomeAssistantError("Aufgabe nicht gefunden")
        done = item.status == TodoItemStatus.COMPLETED
        data = {
            **existing,
            "title": item.summary or existing.get("title", ""),
            "done": done,
            "completedAt": (existing.get("completedAt") or datetime.now().isoformat())
            if done
            else None,
        }
        # Only what really changed: service accounts that may just tick off
        # would be refused over an empty note written back.
        if (item.description or "") != (existing.get("notes") or ""):
            data["notes"] = item.description or ""
        if _due(existing.get("due")) != item.due:
            data["due"] = _due_value(item.due)
        await _write(self.coordinator, TASKS, item.uid, data)

    async def async_delete_todo_items(self, uids: list[str]) -> None:
        for uid in uids:
            await _write(self.coordinator, TASKS, uid, None)


class FamioMemberTasks(FamioMemberEntity, FamioTasks):
    """The tasks of one member ("Famio Lena – Aufgaben"); new ones are
    assigned to them."""

    _attr_translation_key = "tasks"

    def __init__(self, coordinator: FamioCoordinator, member_id: str) -> None:
        FamioMemberEntity.__init__(self, coordinator, member_id, "tasks")
        self._assignee = member_id


class FamioShoppingList(FamioEntity, TodoListEntity):
    """One Famio shopping list."""

    @property
    def supported_features(self) -> TodoListEntityFeature:
        return _NONE if self.coordinator.data.access == "readOnly" else _ALL

    def __init__(self, coordinator: FamioCoordinator, list_id: str) -> None:
        super().__init__(coordinator, f"shopping_{list_id}")
        self._list_id = list_id

    @property
    def name(self) -> str:
        shopping = self.coordinator.data.collection(SHOPPING_LISTS).get(self._list_id)
        return f"Einkauf {(shopping or {}).get('name') or ''}".strip()

    @property
    def available(self) -> bool:
        return super().available and self._list_id in self.coordinator.data.collection(
            SHOPPING_LISTS
        )

    @property
    def todo_items(self) -> list[TodoItem]:
        items = [
            TodoItem(
                uid=item_id,
                summary=item.get("name") or "",
                status=TodoItemStatus.COMPLETED
                if item.get("checked")
                else TodoItemStatus.NEEDS_ACTION,
                description=item.get("quantity") or None,
            )
            for item_id, item in self.coordinator.data.collection(SHOPPING_ITEMS).items()
            if item.get("listId") == self._list_id
        ]
        return sorted(
            items,
            key=lambda i: (i.status == TodoItemStatus.COMPLETED, i.summary.lower()),
        )

    async def async_create_todo_item(self, item: TodoItem) -> None:
        await _write(
            self.coordinator,
            SHOPPING_ITEMS,
            _new_id(),
            {
                "listId": self._list_id,
                "name": item.summary or "",
                "quantity": item.description or "",
                "checked": item.status == TodoItemStatus.COMPLETED,
                "category": "",
            },
        )

    async def async_update_todo_item(self, item: TodoItem) -> None:
        existing = self.coordinator.data.collection(SHOPPING_ITEMS).get(item.uid or "")
        if existing is None:
            raise HomeAssistantError("Eintrag nicht gefunden")
        await _write(
            self.coordinator,
            SHOPPING_ITEMS,
            item.uid,
            {
                **existing,
                "name": item.summary or existing.get("name", ""),
                "quantity": item.description or "",
                "checked": item.status == TodoItemStatus.COMPLETED,
            },
        )

    async def async_delete_todo_items(self, uids: list[str]) -> None:
        for uid in uids:
            await _write(self.coordinator, SHOPPING_ITEMS, uid, None)
