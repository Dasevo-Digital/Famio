#!/usr/bin/env python3
"""Runs integration_test/review_android_test.dart on an Android emulator.

    tool/android_review_tests.py emulator-5554 [--play-models] [--name TEXT]

Starts a throwaway server, signs nobody's real Famio in and answers what the
test asks for with `E2E-HOST …` lines: permissions a person would grant,
emulator positions and shares from outside the app (text with `am start`,
files through the Files app). Famio runs as
"Famio Dev" (flavor dev). Emulators only: the test shares files, moves the
device and switches on location sharing.
"""

import argparse
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

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("device")
    parser.add_argument(
        "--play-models",
        action="store_true",
        help="text recognition from Google Play services (64-bit release APK)",
    )
    parser.add_argument("--name", help="only tests whose name matches this regex")
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
            "flutter", "test", "integration_test/review_android_test.dart",
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
        env = dict(os.environ)
        if args.play_models:
            # Like the 64-bit release APK (tool/release.sh).
            env["ORG_GRADLE_PROJECT_famioArm64"] = "true"
        test = subprocess.Popen(
            command, cwd=APP_DIR, env=env, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        for line in test.stdout:
            print(line, end="", flush=True)
            found = re.search(r"E2E-HOST (\S+)(?: (.*))?$", line.rstrip())
            if not found:
                continue
            what, rest = found.group(1), (found.group(2) or "").split()
            try:
                if what == "grant":
                    device.grant()
                elif what == "geo":
                    device.geo(*rest)
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
                    continue
                print(f"== host: {what} {' '.join(rest)} erledigt", flush=True)
            except Exception as e:  # noqa: BLE001 - reported, test then fails
                print(f"!! host: {what} fehlgeschlagen: {e}", flush=True)
        status = test.wait()
        if status != 0:
            print("== Serverprotokoll (Ende):", flush=True)
            print("".join((work / "server.log").read_text().splitlines(True)[-40:]))
        return status
    finally:
        if server:
            server.terminate()
            server.wait()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
