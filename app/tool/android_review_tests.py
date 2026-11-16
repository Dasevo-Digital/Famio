#!/usr/bin/env python3
"""Runs integration_test/review_android_test.dart on an Android emulator.

    tool/android_review_tests.py emulator-5554 [--play-models] [--name TEXT]
        [--file integration_test/<other>_test.dart]

Starts a throwaway server, signs nobody's real Famio in and answers what the
test asks for with `E2E-HOST …` lines: permissions a person would grant,
emulator positions and shares from outside the app (text with `am start`,
files through the Files app). Famio runs as
"Famio Dev" (flavor dev). Emulators only: the test shares files, moves the
device and switches on location sharing.
"""

import argparse
import base64
import http.server
import json
import os
import re
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zlib
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent.parent
SERVER_DIR = APP_DIR.parent / "server"
PACKAGE = "de.status403.famio.dev"
# Set for the app lock test only, cleared again at its end.
PIN = "1234"
ACTIVITY = f"{PACKAGE}/de.status403.famio.MainActivity"
ADB = shutil.which("adb") or str(
    Path("/opt/homebrew/share/android-commandlinetools/platform-tools/adb")
)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def png(width=160, height=120):
    """A small orange picture, as a photo from the gallery."""
    row = b"\x00" + bytes([240, 140, 60]) * width
    raw = zlib.compress(row * height)

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(
            ">I", zlib.crc32(body) & 0xFFFFFFFF
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", raw)
        + chunk(b"IEND", b"")
    )


def pdf():
    """A one-page PDF, as an attachment from the mail."""
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>",
    ]
    out = b"%PDF-1.4\n"
    offsets = []
    for i, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objects) + 1,
        xref,
    )
    return out


class Device:
    def __init__(self, serial):
        self.serial = serial

    def adb(self, *args, check=True):
        result = subprocess.run(
            [ADB, "-s", self.serial, *args],
            capture_output=True,
            text=True,
        )
        if check and result.returncode != 0:
            raise RuntimeError(f"adb {' '.join(args)}: {result.stderr.strip()}")
        return result.stdout

    def shell(self, command):
        return self.adb("shell", command)

    def grant(self):
        for permission in [
            "POST_NOTIFICATIONS",
            "ACCESS_FINE_LOCATION",
            "ACCESS_COARSE_LOCATION",
            "ACCESS_BACKGROUND_LOCATION",
        ]:
            self.adb(
                "shell", "pm", "grant", PACKAGE, f"android.permission.{permission}",
                check=False,
            )
        self.shell(f"appops set {PACKAGE} SCHEDULE_EXACT_ALARM allow")
        # A 24-hour clock, as on a German phone (the tests type times).
        self.shell("settings put system time_12_24 24")
        # Background work would otherwise wait for the next maintenance
        # window of an idle emulator.
        self.shell(f"cmd deviceidle whitelist +{PACKAGE}")

    def window_secure(self):
        """Whether Famio's window is set to stay out of screenshots."""
        windows = self.shell("dumpsys window windows")
        ours = [b for b in windows.split("Window #") if PACKAGE in b.split("\n")[0]]
        return any(re.search(r"fl=.*\bSECURE\b", b) for b in ours)

    def geo(self, lat, lon):
        """Moves the emulator; like a real GPS, the position keeps coming
        for a minute (one fix alone may not reach the location service)."""

        def feed():
            for _ in range(12):
                # The emulator console takes the longitude first.
                self.adb("emu", "geo", "fix", lon, lat, check=False)
                time.sleep(5)

        threading.Thread(target=feed, daemon=True).start()

    def download(self, name, data):
        """[data] as a file in Downloads, where the Files app lists it."""
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(data)
        try:
            self.adb("push", f.name, f"/sdcard/Download/{name}")
        finally:
            os.unlink(f.name)

    def screen(self):
        """What Android shows outside Flutter: (text, description, centre)."""
        self.shell("uiautomator dump /sdcard/e2e-ui.xml")
        xml = self.shell("cat /sdcard/e2e-ui.xml")
        nodes = []
        for node in re.findall(r"<node [^>]*>", xml):
            text = re.search(r' text="([^"]*)"', node).group(1)
            desc = re.search(r' content-desc="([^"]*)"', node).group(1)
            x1, y1, x2, y2 = map(
                int, re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node).groups()
            )
            nodes.append((text, desc, ((x1 + x2) // 2, (y1 + y2) // 2)))
        return nodes

    def find(self, text=None, desc=None, tries=10, scroll=False):
        for _ in range(tries):
            for t, d, centre in self.screen():
                if (text and t == text) or (desc and d == desc):
                    return centre
            if scroll:
                self.shell("input swipe 540 2000 540 1000 400")
            time.sleep(1)
        raise RuntimeError(f"not on screen: {text or desc}")

    def share_file(self, name):
        """Like a person: Files app → Downloads → hold the file → Share →
        Famio Dev. Files hands over a URI Famio may read, which a shell
        cannot grant."""
        self.shell(
            "am start -a android.intent.action.VIEW -t vnd.android.document/root "
            "-d content://com.android.providers.downloads.documents/root/downloads "
            "--activity-clear-task"
        )
        x, y = self.find(text=name)
        self.shell(f"input swipe {x} {y} {x} {y} 900")
        x, y = self.find(desc="Share")
        self.shell(f"input tap {x} {y}")
        x, y = self.find(text="Famio Dev", scroll=True)
        self.shell(f"input tap {x} {y}")

    def share(self, mime, text="", subject=""):
        """Text as another app sends it with "Teilen" → Famio Dev."""
        args = ["am", "start", "-a", "android.intent.action.SEND", "-t", mime]
        # mksh: $'…' keeps the line breaks.
        quoted = text.replace("\\", "\\\\").replace("'", "\\'")
        quoted = quoted.replace("\n", "\\n")
        args += ["--es", "android.intent.extra.TEXT", f"$'{quoted}'"]
        if subject:
            args += ["--es", "android.intent.extra.SUBJECT", f"'{subject}'"]
        args += ["-n", ACTIVITY]
        self.shell(" ".join(args))

    # --- for the catalog tests (integration_test/catalog_android_test.dart) ---

    def nodes(self):
        """Like [screen], with resource id and package: dicts."""
        for _ in range(3):
            out = self.shell("uiautomator dump /sdcard/e2e-ui.xml; cat /sdcard/e2e-ui.xml")
            if "<hierarchy" in out:
                break
            time.sleep(1)
        result = []
        for node in re.findall(r"<node [^>]*>", out):
            def attr(name):
                found = re.search(rf' {name}="([^"]*)"', node)
                return found.group(1) if found else ""
            bounds = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
            x1, y1, x2, y2 = map(int, bounds.groups()) if bounds else (0, 0, 0, 0)
            result.append({
                "text": attr("text").replace("&amp;", "&").replace("&quot;", '"'),
                "desc": attr("content-desc"),
                "id": attr("resource-id"),
                "pkg": attr("package"),
                "centre": ((x1 + x2) // 2, (y1 + y2) // 2),
            })
        return result

    def tap(self, centre):
        self.shell(f"input tap {centre[0]} {centre[1]}")

    def find_any(self, texts, seconds=15, exact_first=True):
        """The first node whose text or description is one of [texts]
        (else contains one of them)."""
        end = time.time() + seconds
        while True:
            nodes = self.nodes()
            for exact in ([True, False] if exact_first else [False]):
                for want in texts:
                    for n in nodes:
                        for have in (n["text"], n["desc"]):
                            if have and (have == want if exact else want in have):
                                return n
            if time.time() > end:
                return None
            time.sleep(1)

    def answer_permissions(self, allow, seconds=10):
        """Taps Android's permission dialogs like a person: [allow] or not.
        Stops after 3 quiet seconds; the number of answers."""
        pattern = (
            r"permission_allow(_foreground_only|_one_time)?_button"
            if allow else r"permission_deny(_and_dont_ask_again)?_button"
        )
        texts = (["While using the app", "Allow"] if allow
                 else ["Don’t allow", "Don't allow", "Nicht zulassen",
                       "Keep approximate location"])
        answered = 0
        end = time.time() + seconds
        quiet_since = time.time()
        while time.time() < end:
            focus = self.shell("dumpsys window | grep mCurrentFocus")
            asking = "permissioncontroller" in focus
            hit = None
            if asking:
                for n in self.nodes():
                    if n["pkg"].endswith("permissioncontroller") and (
                        re.search(pattern, n["id"]) or n["text"] in texts
                    ):
                        hit = n
                        break
            if hit:
                self.tap(hit["centre"])
                answered += 1
                quiet_since = time.time()
                time.sleep(1.5)
            elif asking and not allow:
                # The dialog's buttons were not readable: back says no too.
                self.shell("input keyevent KEYCODE_BACK")
                answered += 1
                quiet_since = time.time()
                time.sleep(1.5)
            elif time.time() - quiet_since > 3 and (answered or time.time() - quiet_since > 5):
                break
            else:
                time.sleep(0.7)
        return answered

    def now_ms(self):
        return int(self.shell("date +%s").strip()) * 1000

    def set_clock(self, ms):
        """The device's wall clock (alarms that are due then fire)."""
        self.shell("settings put global auto_time 0")
        self.adb("shell", "cmd", "time_detector", "set_auto_detection_enabled",
                 "false", check=False)
        for prefix in ("", "su 0 "):
            self.shell(f"{prefix}cmd alarm set-time {ms} >/dev/null 2>&1; true")
            if abs(self.now_ms() - ms) < 5000:
                return
        raise RuntimeError("Uhr ließ sich nicht stellen")

    def screen_dark(self):
        """Share of non-black pixels in the middle of the screen (raw
        screencap: header, then RGBA)."""
        raw = subprocess.run(
            [ADB, "-s", self.serial, "exec-out", "screencap"], capture_output=True
        ).stdout
        width, height = struct.unpack("<II", raw[:8])
        header = len(raw) - width * height * 4
        lit = total = 0
        for y in range(int(height * 0.3), int(height * 0.7), 13):
            row = header + y * width * 4
            for x in range(int(width * 0.15), int(width * 0.85), 11):
                r, g, b = raw[row + x * 4: row + x * 4 + 3]
                total += 1
                if r + g + b > 40:
                    lit += 1
        return lit / max(total, 1)

    def famio_notifications_private(self):
        """Famio's messages and reminders: shown on the lock screen only as
        their public version (vis=PRIVATE or SECRET)."""
        out = self.shell("dumpsys notification --noredact")
        found = []
        for block in out.split("NotificationRecord(")[1:]:
            if f"pkg={PACKAGE} " not in block.split("\n")[0]:
                continue
            first = block.split("\n")[0]
            channel = re.search(r"channel=(\S+)", first)
            vis = re.search(r"vis=(\w+)", first)
            found.append((channel.group(1) if channel else "?", vis.group(1) if vis else "?"))
        public = [c for c, v in found if v == "PUBLIC" and c not in ("sos", "famio_alarm")]
        return found, public

    def famio_tasks(self):
        recents = self.shell("dumpsys activity recents")
        tasks = [
            line for line in recents.splitlines()
            if "Recent #" in line
            and (f"I={PACKAGE}/" in line or f":{PACKAGE}" in line)
        ]
        acts = self.shell("dumpsys activity activities")
        records = set(re.findall(
            r"ActivityRecord\{(\w+) u0 " + re.escape(PACKAGE) + r"/de\.status403\.famio\.MainActivity",
            acts,
        ))
        return len(tasks), len(records)

    def files_app(self):
        self.shell(
            "am start -a android.intent.action.VIEW -t vnd.android.document/root "
            "-d content://com.android.providers.downloads.documents/root/downloads "
            "--activity-clear-task"
        )

    def share_files(self, names):
        """Several files at once from the Files app: hold the first, tap
        the others, Share, Famio Dev."""
        self.files_app()
        x, y = self.find(text=names[0])
        self.shell(f"input swipe {x} {y} {x} {y} 900")
        time.sleep(1)
        for name in names[1:]:
            x, y = self.find(text=name)
            self.shell(f"input tap {x} {y}")
            time.sleep(0.7)
        x, y = self.find(desc="Share")
        self.shell(f"input tap {x} {y}")
        x, y = self.find(text="Famio Dev", scroll=True)
        self.shell(f"input tap {x} {y}")

    def open_file(self, name):
        """A file opened (tapped) in the Files app; Famio Dev if asked."""
        self.files_app()
        x, y = self.find(text=name)
        self.shell(f"input tap {x} {y}")
        end = time.time() + 10
        while time.time() < end:
            focus = self.shell("dumpsys window | grep mCurrentFocus")
            if PACKAGE in focus:
                return
            for n in self.nodes():
                if n["text"] in ("Famio Dev", "Just once", "Nur einmal"):
                    self.tap(n["centre"])
                    break
            time.sleep(1)
        raise RuntimeError(f"Famio öffnete {name} nicht")

    def sos_token(self):
        xml = self.shell(f"run-as {PACKAGE} cat shared_prefs/famio_sos_launch.xml")
        found = re.search(r'name="token">([0-9a-f]+)<', xml)
        if not found:
            raise RuntimeError("kein Notruf-Geheimnis")
        return found.group(1)

    def launcher_shortcut(self, labels):
        """Long press on Famio Dev in the app drawer, then the shortcut."""
        icon = None
        seen = ""
        for attempt in range(3):
            self.shell("input keyevent KEYCODE_HOME")
            time.sleep(2)
            # Up from the middle of the home screen: the app drawer (from
            # the bottom edge it would be the gesture for "home"/recents).
            self.shell("input swipe 540 1500 540 300 600")
            time.sleep(2.5)
            icon = self.find_any(["Famio Dev"], seconds=6)
            for _ in range(4):
                if icon is not None:
                    break
                # Further down the alphabetical list.
                self.shell("input swipe 540 1800 540 900 500")
                time.sleep(1.5)
                icon = self.find_any(["Famio Dev"], seconds=3)
            if icon is not None:
                break
            seen = " | ".join(n["text"] or n["desc"] for n in self.nodes()
                              if n["text"] or n["desc"])[:400]
        if icon is None:
            raise RuntimeError(f"Famio Dev nicht in der App-Übersicht: {seen}")
        x, y = icon["centre"]
        self.shell(f"input swipe {x} {y} {x} {y} 1200")
        time.sleep(1)
        item = self.find_any(labels, seconds=8)
        if item is None:
            raise RuntimeError("Verknüpfung nicht angeboten")
        self.tap(item["centre"])


def _text(arg):
    """Arguments with spaces come base64-encoded (URL-safe or not)."""
    padded = arg + "=" * (-len(arg) % 4)
    return base64.b64decode(padded.replace("-", "+").replace("_", "/")).decode()


def _cmd_permissions(device, rest, changed):
    allow = rest[0] == "allow"
    seconds = float(rest[1]) if len(rest) > 1 else 10
    return str(device.answer_permissions(allow, seconds))


def _cmd_grant_coarse(device, rest, changed):
    device.adb("shell", "pm", "grant", PACKAGE,
               "android.permission.ACCESS_COARSE_LOCATION", check=False)


def _cmd_battery(device, rest, changed):
    sign = "+" if rest[0] == "exempt" else "-"
    device.shell(f"cmd deviceidle whitelist {sign}{PACKAGE}")


def _cmd_tap_text(device, rest, changed):
    texts = _text(rest[0]).split("|")
    seconds = float(rest[1]) if len(rest) > 1 else 15
    node = device.find_any(texts, seconds)
    if node is None:
        raise RuntimeError(f"nicht auf dem Bildschirm: {texts}")
    device.tap(node["centre"])
    return node["text"] or node["desc"]


def _cmd_find_text(device, rest, changed):
    """The text found (or empty): the test decides."""
    texts = _text(rest[0]).split("|")
    seconds = float(rest[1]) if len(rest) > 1 else 10
    node = device.find_any(texts, seconds, exact_first=False)
    return "" if node is None else (node["text"] or node["desc"])


def _cmd_screen_texts(device, rest, changed):
    return " | ".join(n["text"] or n["desc"] for n in device.nodes()
                      if n["text"] or n["desc"])


def _cmd_font_scale(device, rest, changed):
    device.shell(f"settings put system font_scale {float(rest[0])}")
    changed.add("font")


def _cmd_clock(device, rest, changed):
    changed.add("clock")
    device.set_clock(int(rest[0]))
    return str(device.now_ms())


def _cmd_clock_reset(device, rest, changed):
    RESTORE["clock"](device)
    changed.discard("clock")


def _cmd_screen_dark(device, rest, changed):
    return f"{device.screen_dark():.4f}"


def _cmd_notifications_private(device, rest, changed):
    found, public = device.famio_notifications_private()
    if public:
        raise RuntimeError(f"öffentlich auf dem Sperrbildschirm: {public}")
    return " ".join(f"{c}={v}" for c, v in found)


def _cmd_tasks(device, rest, changed):
    tasks, records = device.famio_tasks()
    return f"{tasks} {records}"


def _cmd_text_share(device, rest, changed):
    device.share(
        "text/plain",
        text=_text(rest[0]),
        subject=_text(rest[1]) if len(rest) > 1 else "",
    )


def _cmd_file(device, rest, changed):
    """A file in Downloads: a PNG of the given size (noise, so it is not
    tiny), or text (base64)."""
    name = rest[0]
    if rest[1] == "png":
        width, height = int(rest[2]), int(rest[3])
        data = png(width, height) if len(rest) < 5 else _noise_png(width, height)
    else:
        data = _text(rest[1]).encode()
    device.download(name, data)


def _noise_png(width, height):
    rows = b"".join(b"\x00" + secrets.token_bytes(width * 3) for _ in range(height))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(
            ">I", zlib.crc32(body) & 0xFFFFFFFF
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(rows, 1)) + chunk(b"IEND", b""))


def _cmd_share_files(device, rest, changed):
    device.share_files(rest)


def _cmd_open_file(device, rest, changed):
    device.open_file(rest[0])


TILE = f"{PACKAGE}/de.status403.famio.SosTileService"


def _cmd_sos(device, rest, changed):
    """The emergency from outside Famio: the quick settings tile, the
    launcher's shortcut, the intent of Famio's own buttons (widget) or an
    intent without the secret, as another app would send it."""
    how = rest[0]
    if how == "tile":
        device.shell(f"cmd statusbar add-tile {TILE}")
        changed.add("tile")
        time.sleep(1)
        device.shell(f"cmd statusbar click-tile {TILE}")
    elif how == "shortcut":
        device.launcher_shortcut(
            ["Famio-Notruf auslösen", "Trigger Famio emergency call",
             "Notruf", "Emergency"]
        )
    elif how == "widget":
        token = device.sos_token()
        device.shell(
            f"am start -a de.status403.famio.SOS -n {ACTIVITY} "
            f"--es de.status403.famio.SOS_TOKEN {token}"
        )
    elif how == "foreign":
        device.shell(f"am start -a de.status403.famio.SOS -n {ACTIVITY}")
        device.shell(
            f"am start -a de.status403.famio.SOS -n {ACTIVITY} "
            "--es de.status403.famio.SOS_TOKEN 00112233445566778899aabbccddeeff"
        )
    else:
        raise RuntimeError(how)


def _cmd_screen(device, rest, changed):
    if rest[0] == "off":
        device.shell("input keyevent KEYCODE_SLEEP")
    else:
        device.shell("input keyevent KEYCODE_WAKEUP")
        time.sleep(1)
        device.shell("wm dismiss-keyguard")
        time.sleep(1)


def _cmd_geo_long(device, rest, changed):
    """Like geo, for [seconds]: a running alarm sends every 20 s."""
    lat, lon, seconds = rest[0], rest[1], float(rest[2])

    def feed():
        end = time.time() + seconds
        while time.time() < end:
            device.adb("emu", "geo", "fix", lon, lat, check=False)
            time.sleep(4)

    threading.Thread(target=feed, daemon=True).start()


def _cmd_services(device, rest, changed):
    """Famio's running services: foreground or not, with which notice."""
    out = device.shell(f"dumpsys activity services {PACKAGE}")
    keep = [
        line.strip() for line in out.splitlines()
        if re.search(r"ServiceRecord|isForeground|foregroundId|foregroundNoti", line)
    ]
    return " | ".join(keep)


def _cmd_home_tap(device, rest, changed):
    """Something on the home screen (a widget), tapped like a person."""
    texts = _text(rest[0]).split("|")
    seconds = float(rest[1]) if len(rest) > 1 else 10
    device.shell("input keyevent KEYCODE_HOME")
    time.sleep(2.5)
    node = device.find_any(texts, seconds)
    if node is None:
        raise RuntimeError(f"nicht auf dem Startbildschirm: {texts}")
    device.tap(node["centre"])
    return node["desc"] or node["text"]


def _cmd_focus(device, rest, changed):
    return device.shell("dumpsys window | grep mCurrentFocus").strip()


def _cmd_recents(device, rest, changed):
    """Android's recent apps with Famio's card: kept as a picture (next to
    the logs) and the number of colours in the card's middle; a card left
    blank (FLAG_SECURE) has hardly any."""
    device.shell("input keyevent KEYCODE_APP_SWITCH")
    time.sleep(3)
    shots = Path.home() / "Famio/release-helpers/famio-release/pruefkatalog/logs/shots"
    shots.mkdir(parents=True, exist_ok=True)
    label = rest[0] if rest else "recents"
    shot = shots / f"{label}-{time.strftime('%H%M%S')}.png"
    shot.write_bytes(subprocess.run(
        [ADB, "-s", device.serial, "exec-out", "screencap", "-p"],
        capture_output=True,
    ).stdout)
    raw = subprocess.run(
        [ADB, "-s", device.serial, "exec-out", "screencap"], capture_output=True
    ).stdout
    width, height = struct.unpack("<II", raw[:8])
    header = len(raw) - width * height * 4
    colours = set()
    for y in range(int(height * 0.3), int(height * 0.65), 7):
        row = header + y * width * 4
        for x in range(int(width * 0.3), int(width * 0.7), 7):
            r, g, b = raw[row + x * 4: row + x * 4 + 3]
            colours.add((r >> 4, g >> 4, b >> 4))
    return f"{len(colours)} {shot}"


def _cmd_shortcuts(device, rest, changed):
    """Famio's dynamic shortcuts as the launcher gets them: id, labels and
    intent (the extras themselves are not listed)."""
    out = device.shell("dumpsys shortcut")
    part = out.split(f"Package: {PACKAGE}", 1)
    if len(part) < 2:
        return ""
    block = re.split(r"\n\s*Package: ", part[1], maxsplit=1)[0]
    keep = [
        line.strip() for line in block.splitlines()
        if re.search(r"ShortcutInfo \{|shortLabel=|longLabel=|intents=|"
                     r"Intent \{|flags=", line)
    ]
    return " | ".join(keep)[:1500]


def _famio_uid(device):
    out = device.shell(f"cmd package list packages -U {PACKAGE}")
    found = re.search(rf"package:{re.escape(PACKAGE)} uid:(\d+)", out)
    return found.group(1) if found else None


def _cmd_audio(device, rest, changed):
    """What Famio plays now (Android's audio players of its uid): usage and
    state per player, e.g. "USAGE_ALARM:started"; empty for none."""
    uid = _famio_uid(device)
    if uid is None:
        return ""
    players = []
    for line in device.shell("dumpsys audio").splitlines():
        if "AudioPlaybackConfiguration" not in line or f"u/pid:{uid}/" not in line:
            continue
        state = re.search(r"state:(\w+)", line)
        usage = re.search(r"usage=(\w+)", line)
        players.append(
            f"{usage.group(1) if usage else '?'}:{state.group(1) if state else '?'}"
        )
    return " ".join(players)


def _cmd_alarm_volume(device, rest, changed):
    """The volume of the alarm stream (the siren's). The shell cannot set it
    on this emulator, the test compares before, during and after."""
    out = device.shell("cmd media_session volume --stream 4 --get")
    found = re.search(r"volume is (\d+)", out)
    if not found:
        raise RuntimeError(f"Lautstärke nicht lesbar: {out.strip()}")
    return found.group(1)


def _cmd_alarms(device, rest, changed):
    """How many alarms Android's AlarmManager holds for Famio (its planned
    reminders)."""
    out = device.shell("dumpsys alarm")
    pattern = re.compile(
        r"^\s*(RTC|RTC_WAKEUP|ELAPSED|ELAPSED_WAKEUP) #\d+: Alarm\{[^}]*\b"
        + re.escape(PACKAGE) + r"\}"
    )
    return str(sum(1 for line in out.splitlines() if pattern.search(line)))


CATALOG_COMMANDS = {
    "audio": _cmd_audio,
    "alarm-volume": _cmd_alarm_volume,
    "alarms": _cmd_alarms,
    "permissions": _cmd_permissions,
    "grant-coarse": _cmd_grant_coarse,
    "battery": _cmd_battery,
    "tap-text": _cmd_tap_text,
    "find-text": _cmd_find_text,
    "screen-texts": _cmd_screen_texts,
    "font-scale": _cmd_font_scale,
    "clock": _cmd_clock,
    "clock-reset": _cmd_clock_reset,
    "screen-dark": _cmd_screen_dark,
    "notifications-private": _cmd_notifications_private,
    "tasks": _cmd_tasks,
    "text-share": _cmd_text_share,
    "file": _cmd_file,
    "share-files": _cmd_share_files,
    "open-file": _cmd_open_file,
    "sos": _cmd_sos,
    "screen": _cmd_screen,
    "geo-long": _cmd_geo_long,
    "focus": _cmd_focus,
    "shortcuts": _cmd_shortcuts,
    "recents": _cmd_recents,
    "services": _cmd_services,
    "home-tap": _cmd_home_tap,
}


def _restore_clock(device):
    device.shell(f"cmd alarm set-time {int(time.time() * 1000)} >/dev/null 2>&1; true")
    if abs(device.now_ms() - time.time() * 1000) > 5000:
        device.shell(f"su 0 cmd alarm set-time {int(time.time() * 1000)}")
    device.adb("shell", "cmd", "time_detector", "set_auto_detection_enabled",
               "true", check=False)
    device.shell("settings put global auto_time 1")


RESTORE = {
    "clock": _restore_clock,
    "font": lambda d: d.shell("settings put system font_scale 1.0"),
    "tile": lambda d: d.shell(f"cmd statusbar remove-tile {TILE}"),
}


class HostResults:
    """Answers of host commands for the test: GET /r/<id> → JSON (404 until
    the command is done). Reached from the emulator as 10.0.2.2."""

    def __init__(self):
        self.results = {}
        results = self.results

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 - http.server API
                key = self.path.rsplit("/", 1)[-1]
                if key not in results:
                    self.send_response(404)
                    self.end_headers()
                    return
                body = json.dumps(results[key]).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("device")
    parser.add_argument(
        "--play-models",
        action="store_true",
        help="text recognition from Google Play services (64-bit release APK)",
    )
    parser.add_argument("--name", help="only tests whose name matches this regex")
    parser.add_argument(
        "--file",
        default="integration_test/review_android_test.dart",
        help="another test file that speaks the same E2E-HOST lines",
    )
    args = parser.parse_args()
    if not args.device.startswith("emulator-"):
        sys.exit("Nur auf einem Emulator: der Test teilt Dateien und Standorte.")
    device = Device(args.device)

    # A fresh Famio Dev: a service left running by an earlier, aborted run
    # (own push, location) would restart the app before the test attaches.
    device.adb("uninstall", PACKAGE, check=False)
    device.adb("forward", "--remove-all", check=False)

    work = Path(tempfile.mkdtemp(prefix="famio-android-review-"))
    server = None
    changed = set()
    try:
        print("== Server bauen", flush=True)
        subprocess.run(["dart", "pub", "get"], cwd=SERVER_DIR, check=True,
                       capture_output=True)
        subprocess.run(
            ["dart", "build", "cli", "-t", "bin/server.dart", "-o",
             str(work / "server")],
            cwd=SERVER_DIR, check=True, capture_output=True,
        )
        binary = next(
            p for p in (work / "server").rglob("server")
            if p.is_file() and os.access(p, os.X_OK)
        )
        port, tls_port = free_port(), free_port()
        log = open(work / "server.log", "w")
        server = subprocess.Popen(
            [str(binary)],
            env={
                **os.environ,
                "FAMIO_DATA_DIR": str(work / "data"),
                "FAMIO_PORT": str(port),
                "FAMIO_TLS_PORT": str(tls_port),
                "FAMIO_TIMEZONE": "Europe/Berlin",
            },
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        base = f"http://localhost:{port}"
        for _ in range(60):
            try:
                urllib.request.urlopen(f"{base}/api/health", timeout=2)
                break
            except OSError:
                time.sleep(0.5)
        code = re.search(
            r"Einrichtungscode für die App: ([A-Z0-9]+)",
            (work / "server.log").read_text(),
        ).group(1)
        password = "ci-" + secrets.token_urlsafe(18)
        request = urllib.request.Request(
            f"{base}/api/auth/setup",
            data=json.dumps({
                "username": "admin",
                "displayName": "Admin",
                "password": password,
                "setupCode": code,
            }).encode(),
            headers={"content-type": "application/json"},
        )
        urllib.request.urlopen(request, timeout=10)

        device.download("e2e-foto.png", png())
        device.download("e2e-zeugnis.pdf", pdf())
        shares = {
            "list": dict(mime="text/plain", text="- Milch\n- Brot\n- Eier"),
            "link": dict(
                mime="text/plain",
                text="https://example.org/rezept",
                subject="E2E Rezept",
            ),
            "text": dict(
                mime="text/plain",
                text="Elternabend am Donnerstag\nBitte Kuchen mitbringen",
            ),
        }
        files = {"photo": "e2e-foto.png", "pdf": "e2e-zeugnis.pdf"}

        command = [
            "flutter", "test", args.file,
            "-d", args.device, "--flavor", "dev",
            "--dart-define=FAMIO_ENV=dev",
            "--dart-define=FAMIO_FRESH_START=true",
            f"--dart-define=FAMIO_URL=http://10.0.2.2:{port}",
            "--dart-define=FAMIO_USER=admin",
            f"--dart-define=FAMIO_PASSWORD={password}",
            "--dart-define=FAMIO_OCR_MODELS="
            + ("play" if args.play_models else "bundled"),
        ]
        if args.name:
            command += ["--name", args.name]
        # Answers to host commands with an id (see HostResults).
        results = HostResults()
        command.append(f"--dart-define=FAMIO_E2E_HOST_PORT={results.port}")
        env = dict(os.environ)
        if args.play_models:
            # Like the 64-bit release APK (tool/release.sh).
            env["ORG_GRADLE_PROJECT_famioArm64"] = "true"
        test = subprocess.Popen(
            command, cwd=APP_DIR, env=env, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        host_failed = False
        for line in test.stdout:
            print(line, end="", flush=True)
            found = re.search(r"E2E-HOST (\S+)(?: (.*))?$", line.rstrip())
            if not found:
                continue
            what, rest = found.group(1), (found.group(2) or "").split()
            key = next((r[4:] for r in rest if r.startswith("@id=")), None)
            rest = [r for r in rest if not r.startswith("@id=")]
            out = ""
            try:
                if what in CATALOG_COMMANDS:
                    out = CATALOG_COMMANDS[what](device, rest, changed) or ""
                elif what == "grant":
                    device.grant()
                elif what == "geo":
                    device.geo(*rest)
                elif what == "back":
                    # The back button, as a person presses it.
                    device.shell("input keyevent KEYCODE_BACK")
                elif what == "home":
                    device.shell("input keyevent KEYCODE_HOME")
                elif what == "front":
                    device.shell(f"am start -n {ACTIVITY}")
                elif what == "pin-set":
                    device.shell(f"locksettings set-pin {PIN}")
                elif what == "pin-clear":
                    device.shell(f"locksettings clear --old {PIN}")
                elif what == "pin-enter":
                    # Android's own screen for the device PIN.
                    device.shell(f"input text {PIN}")
                    device.shell("input keyevent KEYCODE_ENTER")
                elif what in ("secure-on", "secure-off"):
                    wanted = what == "secure-on"
                    if device.window_secure() != wanted:
                        raise RuntimeError(f"FLAG_SECURE ist nicht {wanted}")
                elif what == "shot":
                    shots = Path(tempfile.gettempdir()) / "famio-android-review-shots"
                    shots.mkdir(exist_ok=True)
                    shot = shots / time.strftime("%H%M%S.png")
                    with open(shot, "wb") as f:
                        subprocess.run(
                            [ADB, "-s", device.serial, "exec-out", "screencap", "-p"],
                            stdout=f,
                        )
                    print(f"== Bildschirmfoto: {shot}", flush=True)
                elif what == "share" and rest[0] in files:
                    device.share_file(files[rest[0]])
                elif what == "share":
                    device.share(**shares[rest[0]])
                else:
                    print(f"!! unbekannter Auftrag: {what}", flush=True)
                    if key:
                        results.results[key] = {"ok": False, "out": "unknown"}
                    continue
                print(f"== host: {what} {' '.join(rest)} erledigt {out}", flush=True)
                if key:
                    results.results[key] = {"ok": True, "out": out}
            except Exception as e:  # noqa: BLE001 - reported, test then fails
                print(f"!! host: {what} fehlgeschlagen: {e}", flush=True)
                if key:
                    # The test asked for the answer and decides itself.
                    results.results[key] = {"ok": False, "out": str(e)}
                else:
                    host_failed = True
        status = test.wait() or int(host_failed)
        if status != 0:
            print("== Serverprotokoll (Ende):", flush=True)
            print("".join((work / "server.log").read_text().splitlines(True)[-40:]))
        return status
    finally:
        # What catalog tests changed on the emulator goes back.
        for what in sorted(changed):
            try:
                RESTORE[what](device)
                print(f"== zurückgesetzt: {what}", flush=True)
            except Exception as e:  # noqa: BLE001
                print(f"!! zurücksetzen {what}: {e}", flush=True)
        if server:
            server.terminate()
            server.wait()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
