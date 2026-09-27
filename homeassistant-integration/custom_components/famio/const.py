"""Constants of the Famio integration."""

from datetime import timedelta
from typing import Final

DOMAIN: Final = "famio"

CONF_PIN: Final = "pin"
CONF_CERT_SHA256: Final = "cert_sha256"
CONF_MEMBER_ID: Final = "member_id"

# The server's HTTPS port for the home network (FAMIO_TLS_PORT).
DEFAULT_TLS_PORT: Final = 8766

DEVICE_NAME: Final = "Home Assistant"

# Fallback when the live connection (WebSocket) is down.
POLL_INTERVAL: Final = timedelta(minutes=5)

# How far ahead the calendar entity and sensor look for the next event.
UPCOMING_WINDOW: Final = timedelta(days=30)

TASKS: Final = "tasks"
SHOPPING_LISTS: Final = "shopping_lists"
SHOPPING_ITEMS: Final = "shopping_items"
EVENTS: Final = "events"
MEMBER_LOCATIONS: Final = "member_locations"
PLACES: Final = "places"
