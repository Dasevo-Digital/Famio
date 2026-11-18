#!/usr/bin/env python3
"""A throwaway Famio server that a device test may restart in between.

tool/integration_tests.sh starts it instead of the bare server for a test
file with the line `// e2e-control: restore` (catalog SIC-123: put a backup
back in place while the server is stopped, then sign in again).

    tool/e2e_server.py <control port> <server binary>

The server's settings come from the environment (FAMIO_DATA_DIR,
FAMIO_PORT, …); its output goes to this script's output. Control, on
127.0.0.1 only:

    POST /restore?name=...  stops the server, restores the backup selected
                          through the admin API and starts the server again;
                          answers {"ok", "output", "aside": [files set aside]}.
"""

import http.server
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

RESTORE = Path(__file__).resolve().parents[2] / "tool" / "famio-restore-backup.sh"
CONTROL_PORT, BINARY = int(sys.argv[1]), sys.argv[2]
DATA = Path(os.environ["FAMIO_DATA_DIR"])
PORT = os.environ["FAMIO_PORT"]
lock = threading.Lock()
server = None


def start():
    global server
    server = subprocess.Popen([BINARY])
    for _ in range(120):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/api/health", timeout=1)
            return
        except OSError:
            time.sleep(0.5)
    raise RuntimeError("Der Server ist nicht wieder angelaufen.")


def stop():
    if server and server.poll() is None:
        server.terminate()
        try:
            server.wait(30)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()


def restore(name):
    if not re.fullmatch(r"famio-[0-9]{8}-[0-9]{6}(?:-[0-9]{6})?", name):
        return {"ok": False, "output": "Ungültiger Sicherungsname."}
    backup = DATA / "backups" / name
    if not (backup / "famio.db").is_file():
        return {"ok": False, "output": "Keine Sicherung mit diesem Namen."}
    stop()
    done = subprocess.run(
        ["sh", str(RESTORE), str(backup), str(DATA)],
        capture_output=True, text=True,
    )
    start()
    aside = sorted(
        str(p.relative_to(DATA)) for p in DATA.glob("before-restore-*/*")
    )
    return {
        "ok": done.returncode == 0,
        "output": done.stdout + done.stderr,
        "aside": aside,
    }


class Control(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path != "/restore":
            self.send_error(404)
            return
        with lock:
            try:
                name = urllib.parse.parse_qs(url.query).get("name", [""])[0]
                answer = restore(name)
            except Exception as e:  # noqa: BLE001 - told to the test
                answer = {"ok": False, "output": str(e)}
        body = json.dumps(answer).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def quit_(*_):
    stop()
    os._exit(0)


signal.signal(signal.SIGTERM, quit_)
signal.signal(signal.SIGINT, quit_)
start()
http.server.ThreadingHTTPServer(("127.0.0.1", CONTROL_PORT), Control).serve_forever()
