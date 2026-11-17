#!/usr/bin/env python3
"""Runs integration_test/review_open_test.dart in an iOS simulator.

    tool/ios_review_tests.py <simulator id> [--file integration_test/<x>_test.dart]

Starts a throwaway server and answers the test's `E2E-HOST …` lines: what
the share extension would leave in the app group (`share-sheet`, written
with `xcrun simctl get_app_container`). Simulators only, never a phone: the
test signs in to the throwaway server.
"""

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_review_tests import HostResults, _text, free_port  # noqa: E402

APP_DIR = Path(__file__).resolve().parent.parent
SERVER_DIR = APP_DIR.parent / "server"
BUNDLE = "de.dasevo.famio"


def simctl(*args, check=True):
    return subprocess.run(
        ["xcrun", "simctl", *args], check=check, capture_output=True, text=True
    ).stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("device", help="simulator id (xcrun simctl list)")
    parser.add_argument("--file", default="integration_test/review_open_test.dart")
    args = parser.parse_args()
    listed = simctl("list", "devices")
    line = next((l for l in listed.splitlines() if args.device in l), "")
    if not line:
        sys.exit("Kein Simulator mit dieser Kennung (nur Simulatoren, keine Telefone).")
    if "(Booted)" not in line:
        simctl("boot", args.device)
        simctl("bootstatus", args.device, "-b")

    work = Path(tempfile.mkdtemp(prefix="famio-ios-review-"))
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
            stdout=log, stderr=subprocess.STDOUT,
        )
        base = f"http://127.0.0.1:{port}"
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
        urllib.request.urlopen(urllib.request.Request(
            f"{base}/api/auth/setup",
            data=json.dumps({
                "username": "admin", "displayName": "Admin",
                "password": password, "setupCode": code,
            }).encode(),
            headers={"content-type": "application/json"},
        ), timeout=10)

        results = HostResults()
        command = [
            "flutter", "test", args.file, "-d", args.device,
            "--dart-define=FAMIO_ENV=e2e",
            "--dart-define=FAMIO_FRESH_START=true",
            f"--dart-define=FAMIO_URL={base}",
            "--dart-define=FAMIO_USER=admin",
            f"--dart-define=FAMIO_PASSWORD={password}",
            f"--dart-define=FAMIO_E2E_HOST_PORT={results.port}",
        ]
        test = subprocess.Popen(
            command, cwd=APP_DIR, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        for line in test.stdout:
            print(line, end="", flush=True)
            found = re.search(r"E2E-HOST (\S+)(?: (.*))?$", line.rstrip())
            if not found:
                continue
            what, rest = found.group(1), (found.group(2) or "").split()
            key = next((r[4:] for r in rest if r.startswith("@id=")), None)
            rest = [r for r in rest if not r.startswith("@id=")]
            try:
                if what == "share-sheet":
                    # As ShareViewController leaves it; its link the test
                    # hands over itself (simctl openurl would wait for the
                    # system's "Open in Famio?" question).
                    share = json.loads(_text(rest[0]))
                    group = Path(simctl(
                        "get_app_container", args.device, BUNDLE,
                        f"group.{BUNDLE}",
                    ))
                    folder = group / "Share" / (
                        f"{int(time.time() * 1000):013d}-{uuid.uuid4()}"
                    )
                    folder.mkdir(parents=True)
                    (folder / "share.json").write_text(json.dumps({
                        "text": share.get("text", ""),
                        "subject": share.get("subject", ""),
                        "files": [],
                    }))
                elif what == "grant":
                    pass  # The simulator asks nothing the test needs here.
                else:
                    raise RuntimeError(f"unbekannter Auftrag: {what}")
                print(f"== host: {what} erledigt", flush=True)
                if key:
                    results.results[key] = {"ok": True, "out": ""}
            except Exception as e:  # noqa: BLE001 - reported to the test
                print(f"!! host: {what} fehlgeschlagen: {e}", flush=True)
                if key:
                    results.results[key] = {"ok": False, "out": str(e)}
        sys.exit(test.wait())
    finally:
        if server:
            server.terminate()


if __name__ == "__main__":
    main()
