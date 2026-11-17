#!/usr/bin/env python3
"""A local stand-in for Bring! and Microsoft To Do, for end-to-end tests.

    python3 tool/fake_list_services.py --port 4711

tool/integration_tests.sh starts it for a test file with the line
`// e2e-fake: lists` and gives the Famio server
FAMIO_TEST_LIST_SERVICES=http://127.0.0.1:<port>/ (the server follows it
only to this computer). Below that address:

  bring/   the interface of Bring's apps that the server uses
           (server/lib/src/lists/bring.dart)
  login/   Microsoft's device code sign-in (devicecode, token)
  graph/   Microsoft Graph, the To Do lists, tasks and steps
           (server/lib/src/lists/ms_todo.dart)
  devicelogin   the page where the member types the code shown in Famio;
           posting the right code (form field `code`) confirms the sign-in
  _test/   for the test: what both apps hold, and changes made "in the
           other app"

Everything is kept in memory and answers only on 127.0.0.1. Python 3.9+,
standard library only.
"""

import argparse
import datetime
import json
import re
import secrets
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlsplit

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python < 3.9
    ZoneInfo = None

BRING_API_KEY = "cof4Nc6D8saplXjE3h3HXqHH8m7VU2i1Gs0g85Sp"
FAMILY_ZONE = "Europe/Berlin"


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def graph_time(moment):
    """Graph's way of writing a time: seven decimals and Z."""
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%f") + "0Z"


def zone(name):
    if name.upper() in ("UTC", "ETC/UTC"):
        return datetime.timezone.utc
    if ZoneInfo is None:
        return None
    try:
        return ZoneInfo(name)
    except Exception:  # unknown zone
        return None


def due_to_utc(due):
    """What Graph keeps of a `dueDateTime`: the moment in UTC."""
    if not isinstance(due, dict) or not isinstance(due.get("dateTime"), str):
        return None
    text = due["dateTime"].split(".")[0]
    local = datetime.datetime.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")
    where = zone(str(due.get("timeZone") or "UTC"))
    if where is None:
        return {"dateTime": text + ".0000000", "timeZone": due.get("timeZone")}
    moment = local.replace(tzinfo=where).astimezone(datetime.timezone.utc)
    return {
        "dateTime": moment.strftime("%Y-%m-%dT%H:%M:%S") + ".0000000",
        "timeZone": "UTC",
    }


def due_day(due, zone_name):
    """The day a Graph `dueDateTime` falls on in `zone_name`."""
    if not due:
        return None
    text = due["dateTime"].split(".")[0]
    moment = datetime.datetime.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")
    where = zone(str(due.get("timeZone") or "UTC"))
    to = zone(zone_name)
    if where is None or to is None:
        return text[:10]
    return moment.replace(tzinfo=where).astimezone(to).strftime("%Y-%m-%d")


class Fake:
    """Both apps' data. All access holds `lock`."""

    def __init__(self):
        self.lock = threading.RLock()
        self.reset()

    def reset(self):
        self.delay = 0.0
        self.counter = 0
        # Bring!
        self.bring_users = {}  # email -> user uuid
        self.bring_tokens = {}  # access token -> user uuid
        self.bring_refresh = {}  # refresh token -> user uuid
        self.bring_logins = []  # e-mail addresses that signed in
        self.bring_lists = {}  # list uuid -> {name, items: {name: item}}
        for name in ("Zuhause", "Ferienhaus"):
            self.bring_lists[str(uuid.uuid4())] = {"name": name, "items": {}}
        # Microsoft
        self.flows = {}  # device code -> {clientId, userCode, approved, used}
        self.ms_tokens = set()
        self.ms_refresh = {}  # refresh token -> client id
        self.ms_lists = {}  # list id -> {name, wellknown, tasks: {id: task}}
        for name, wellknown in (("Aufgaben", "defaultList"), ("Einkauf", "none")):
            self.ms_lists[self.graph_id("AQMkADAwATM0MDAAMS1")] = {
                "name": name,
                "wellknown": wellknown,
                "tasks": {},
            }
        # How often the services were asked, by area (bring, login, graph).
        self.calls = {"bring": 0, "login": 0, "graph": 0}

    def graph_id(self, prefix):
        # Graph's ids are base64 and may end in "=", which has to travel
        # encoded in paths.
        self.counter += 1
        return "%s%04dAAA=" % (prefix, self.counter)

    # --- Bring! -------------------------------------------------------------

    def bring_list(self, key):
        if key in self.bring_lists:
            return self.bring_lists[key]
        for value in self.bring_lists.values():
            if value["name"] == key:
                return value
        raise KeyError("no Bring! list %s" % key)

    def bring_put(self, items, name, spec, done):
        item = items.get(name)
        if item is None:
            item = items[name] = {"uuid": str(uuid.uuid4())}
        item["spec"] = spec
        item["done"] = done

    # --- Microsoft To Do ---------------------------------------------------

    def ms_list(self, key):
        if key in self.ms_lists:
            return self.ms_lists[key]
        for value in self.ms_lists.values():
            if value["name"] == key:
                return value
        raise KeyError("no To Do list %s" % key)

    def new_task(self, tasks, body):
        now = graph_time(utc_now())
        task = {
            "id": self.graph_id("AAMkAGI2THVmAAA"),
            "title": "",
            "body": {"content": "", "contentType": "text"},
            "status": "notStarted",
            "importance": "normal",
            "createdDateTime": now,
            "lastModifiedDateTime": now,
            "checklistItems": [],
        }
        tasks[task["id"]] = task
        self.patch_task(task, body)
        return task

    def patch_task(self, task, body):
        for key in ("title", "status", "importance"):
            if key in body:
                task[key] = body[key]
        if "body" in body and isinstance(body["body"], dict):
            task["body"] = {
                "content": str(body["body"].get("content") or ""),
                "contentType": str(body["body"].get("contentType") or "text"),
            }
        if "dueDateTime" in body:
            due = due_to_utc(body["dueDateTime"])
            if due is None:
                task.pop("dueDateTime", None)
            else:
                task["dueDateTime"] = due
        if task["status"] == "completed":
            task.setdefault(
                "completedDateTime",
                {"dateTime": graph_time(utc_now())[:-1], "timeZone": "UTC"},
            )
        else:
            task.pop("completedDateTime", None)
        self.touch(task)

    def touch(self, task):
        task["lastModifiedDateTime"] = graph_time(utc_now())
        task["@odata.etag"] = 'W/"%s"' % secrets.token_hex(8)

    def new_step(self, task, body):
        step = {
            "id": str(uuid.uuid4()),
            "displayName": str(body.get("displayName") or ""),
            "isChecked": bool(body.get("isChecked")),
            "createdDateTime": graph_time(utc_now()),
        }
        task["checklistItems"].append(step)
        self.touch(task)
        return step

    def set_steps(self, task, steps):
        """The test changes the steps there: steps of the same text keep
        their id, as in the To Do app."""
        left = list(task["checklistItems"])
        result = []
        for wanted in steps:
            text = str(wanted["text"])
            same = next((s for s in left if s["displayName"] == text), None)
            if same is None:
                same = {
                    "id": str(uuid.uuid4()),
                    "displayName": text,
                    "createdDateTime": graph_time(utc_now()),
                }
            else:
                left.remove(same)
            same["isChecked"] = bool(wanted.get("done"))
            result.append(same)
        task["checklistItems"] = result
        self.touch(task)

    # --- what the test sees -------------------------------------------------

    def snapshot(self, zone_name):
        return {
            "calls": dict(self.calls),
            "bring": {
                "logins": list(self.bring_logins),
                "lists": [
                    {
                        "id": key,
                        "name": value["name"],
                        "items": [
                            {"name": name, "spec": item["spec"], "done": item["done"]}
                            for name, item in value["items"].items()
                        ],
                    }
                    for key, value in self.bring_lists.items()
                ],
            },
            "mstodo": {
                "flows": [
                    {
                        "clientId": f["clientId"],
                        "userCode": f["userCode"],
                        "approved": f["approved"],
                        "used": f["used"],
                    }
                    for f in self.flows.values()
                ],
                "lists": [
                    {
                        "id": key,
                        "name": value["name"],
                        "tasks": [self.task_view(t, zone_name) for t in value["tasks"].values()],
                    }
                    for key, value in self.ms_lists.items()
                ],
            },
        }

    @staticmethod
    def task_view(task, zone_name):
        due = task.get("dueDateTime")
        return {
            "id": task["id"],
            "title": task["title"],
            "note": task["body"]["content"],
            "done": task["status"] == "completed",
            "due": due,
            "dueDay": due_day(due, zone_name),
            "lastModified": task["lastModifiedDateTime"],
            "steps": [
                {"id": s["id"], "text": s["displayName"], "done": s["isChecked"]}
                for s in task["checklistItems"]
            ],
        }


FAKE = Fake()


class Answer(Exception):
    def __init__(self, status, body=None, content_type="application/json"):
        super().__init__(status)
        self.status = status
        self.body = body
        self.content_type = content_type


def form_of(raw):
    return {k: v[-1] for k, v in parse_qs(raw.decode("utf-8"), keep_blank_values=True).items()}


def json_of(raw):
    if not raw:
        return {}
    try:
        value = json.loads(raw.decode("utf-8"))
    except ValueError:
        raise Answer(400, {"error": "invalid json"})
    if not isinstance(value, dict):
        raise Answer(400, {"error": "expected an object"})
    return value


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FakeListServices/1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    # --- plumbing -------------------------------------------------------------

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().strip().split(b";")[0], 16)
                if size == 0:
                    self.rfile.readline()
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def send(self, status, body=None, content_type="application/json"):
        if body is None:
            data = b""
        elif isinstance(body, (bytes, bytearray)):
            data = bytes(body)
        elif isinstance(body, str):
            data = body.encode("utf-8")
        else:
            data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        if data:
            charset = "" if "charset" in content_type else "; charset=utf-8"
            self.send_header("Content-Type", content_type + charset)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data and self.command != "HEAD":
            self.wfile.write(data)

    def handle_any(self):
        url = urlsplit(self.path)
        parts = [unquote(p) for p in url.path.split("/") if p]
        query = {k: v[-1] for k, v in parse_qs(url.query).items()}
        raw = self.body()
        try:
            if not parts:
                raise Answer(404, {"error": "not found"})
            area, rest = parts[0], parts[1:]
            if area == "_test":
                result = self.control(rest, query, raw)
            elif area == "devicelogin":
                result = self.device_page(raw)
            elif area in ("bring", "login", "graph"):
                with FAKE.lock:
                    FAKE.calls[area] += 1
                    delay = FAKE.delay
                if delay:
                    time.sleep(delay)
                result = getattr(self, area)(rest, query, raw)
            else:
                raise Answer(404, {"error": "not found"})
            if isinstance(result, Answer):
                raise result
            self.send(200, result)
        except Answer as a:
            self.send(a.status, a.body, a.content_type)
        except KeyError as e:
            self.send(404, {"error": {"code": "ErrorItemNotFound", "message": str(e)}})
        except Exception as e:  # keep serving; the test reads the log
            sys.stderr.write("error: %r\n" % (e,))
            self.send(500, {"error": repr(e)})

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = handle_any

    def base_url(self):
        return "http://%s/" % (self.headers.get("Host") or "127.0.0.1")

    # --- Bring! ---------------------------------------------------------------

    def bring(self, parts, query, raw):
        if self.headers.get("X-BRING-API-KEY") != BRING_API_KEY:
            raise Answer(401, {"message": "no api key"})
        method = self.command
        with FAKE.lock:
            if parts == ["bringauth"] and method == "POST":
                form = form_of(raw)
                email = form.get("email", "").strip()
                password = form.get("password", "")
                if not email or not password or password == "falsch":
                    raise Answer(401, {"message": "wrong e-mail or password"})
                user = FAKE.bring_users.setdefault(email, str(uuid.uuid4()))
                FAKE.bring_logins.append(email)
                return self.bring_tokens_for(user, email)
            if parts == ["bringauth", "token"] and method == "POST":
                form = form_of(raw)
                user = FAKE.bring_refresh.get(form.get("refresh_token", ""))
                if form.get("grant_type") != "refresh_token" or user is None:
                    raise Answer(401, {"message": "invalid refresh token"})
                return self.bring_tokens_for(user, None)
            token = (self.headers.get("Authorization") or "").replace("Bearer ", "", 1)
            user = FAKE.bring_tokens.get(token)
            if user is None or self.headers.get("X-BRING-USER-UUID") != user:
                raise Answer(401, {"message": "not signed in"})
            if len(parts) == 3 and parts[0] == "bringusers" and parts[2] == "lists":
                if parts[1] != user:
                    raise Answer(403, {"message": "other user"})
                return {
                    "lists": [
                        {
                            "listUuid": key,
                            "name": value["name"],
                            "theme": "ch.publisheria.bring.theme.home",
                        }
                        for key, value in FAKE.bring_lists.items()
                    ]
                }
            if len(parts) == 2 and parts[0] == "bringlists" and method == "GET":
                items = FAKE.bring_lists[parts[1]]["items"]

                def entries(done):
                    return [
                        {
                            "uuid": item["uuid"],
                            "itemId": name,
                            "specification": item["spec"],
                            "attributes": [],
                        }
                        for name, item in items.items()
                        if item["done"] == done
                    ]

                return {
                    "uuid": parts[1],
                    "status": "REGISTERED",
                    "items": {"purchase": entries(False), "recently": entries(True)},
                }
            if (
                len(parts) == 3
                and parts[0] == "bringlists"
                and parts[2] == "items"
                and method == "PUT"
            ):
                items = FAKE.bring_lists[parts[1]]["items"]
                for change in json_of(raw).get("changes") or []:
                    name = str(change.get("itemId") or "").strip()
                    if not name:
                        raise Answer(400, {"message": "no itemId"})
                    operation = change.get("operation")
                    if operation == "REMOVE":
                        items.pop(name, None)
                    elif operation in ("TO_PURCHASE", "TO_RECENTLY"):
                        FAKE.bring_put(
                            items,
                            name,
                            str(change.get("spec") or ""),
                            operation == "TO_RECENTLY",
                        )
                    else:
                        raise Answer(400, {"message": "unknown operation"})
                return Answer(204)
        raise Answer(404, {"message": "unknown"})

    @staticmethod
    def bring_tokens_for(user, email):
        token, refresh = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
        FAKE.bring_tokens[token] = user
        FAKE.bring_refresh[refresh] = user
        answer = {
            "uuid": user,
            "publicUuid": user,
            "access_token": token,
            "refresh_token": refresh,
            "token_type": "Bearer",
            "expires_in": 604799,
        }
        if email is not None:
            answer["email"] = email
            answer["bringListUUID"] = next(iter(FAKE.bring_lists), "")
        return answer

    # --- Microsoft sign-in ---------------------------------------------------

    def login(self, parts, query, raw):
        form = form_of(raw)
        with FAKE.lock:
            if parts == ["devicecode"] and self.command == "POST":
                client = form.get("client_id", "")
                if not re.fullmatch(r"[0-9a-fA-F-]{36}", client):
                    raise Answer(400, {"error": "unauthorized_client"})
                if "Tasks.ReadWrite" not in form.get("scope", ""):
                    raise Answer(400, {"error": "invalid_scope"})
                device = secrets.token_urlsafe(32)
                alphabet = "BCDFGHJKLMNPQRSTVWXZ23456789"
                code = "".join(secrets.choice(alphabet) for _ in range(8))
                FAKE.flows[device] = {
                    "clientId": client,
                    "userCode": code,
                    "approved": False,
                    "used": False,
                }
                page = self.base_url() + "devicelogin"
                return {
                    "device_code": device,
                    "user_code": code,
                    "verification_uri": page,
                    "expires_in": 900,
                    "interval": 2,
                    "message": "To sign in, open %s and enter the code %s." % (page, code),
                }
            if parts == ["token"] and self.command == "POST":
                grant = form.get("grant_type", "")
                if grant == "urn:ietf:params:oauth:grant-type:device_code":
                    flow = FAKE.flows.get(form.get("device_code", ""))
                    if flow is None or flow["clientId"] != form.get("client_id"):
                        raise Answer(400, {"error": "invalid_grant"})
                    if flow["used"]:
                        raise Answer(400, {"error": "invalid_grant"})
                    if not flow["approved"]:
                        raise Answer(
                            400,
                            {
                                "error": "authorization_pending",
                                "error_description": "The user has not finished signing in.",
                            },
                        )
                    flow["used"] = True
                    return self.ms_tokens_for(flow["clientId"])
                if grant == "refresh_token":
                    client = FAKE.ms_refresh.get(form.get("refresh_token", ""))
                    if client is None or client != form.get("client_id"):
                        raise Answer(400, {"error": "invalid_grant"})
                    return self.ms_tokens_for(client)
                raise Answer(400, {"error": "unsupported_grant_type"})
        raise Answer(404, {"error": "not found"})

    @staticmethod
    def ms_tokens_for(client):
        token, refresh = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        FAKE.ms_tokens.add(token)
        FAKE.ms_refresh[refresh] = client
        return {
            "token_type": "Bearer",
            "scope": "Tasks.ReadWrite",
            "expires_in": 3600,
            "access_token": token,
            "refresh_token": refresh,
        }

    def device_page(self, raw):
        """Microsoft's page for the code; a form is enough here."""
        if self.command == "POST":
            code = re.sub(r"[\s-]", "", form_of(raw).get("code", "")).upper()
            with FAKE.lock:
                for flow in FAKE.flows.values():
                    if flow["userCode"] == code and not flow["used"]:
                        flow["approved"] = True
                        return Answer(200, "<p>Signed in.</p>", "text/html")
            raise Answer(400, "<p>Unknown code.</p>", "text/html")
        return Answer(
            200,
            '<form method="post"><input name="code"><button>Next</button></form>',
            "text/html",
        )

    # --- Microsoft Graph -----------------------------------------------------

    def graph(self, parts, query, raw):
        token = (self.headers.get("Authorization") or "").replace("Bearer ", "", 1)
        method = self.command
        with FAKE.lock:
            if token not in FAKE.ms_tokens:
                raise Answer(401, {"error": {"code": "InvalidAuthenticationToken"}})
            if parts[:3] != ["me", "todo", "lists"]:
                raise Answer(404, {"error": {"code": "BadRequest"}})
            rest = parts[3:]
            if not rest and method == "GET":
                return {
                    "value": [
                        {
                            "id": key,
                            "displayName": value["name"],
                            "isOwner": True,
                            "isShared": False,
                            "wellknownListName": value["wellknown"],
                        }
                        for key, value in FAKE.ms_lists.items()
                    ]
                }
            tasks = FAKE.ms_lists[rest[0]]["tasks"]
            if rest[1:] == ["tasks"] and method == "GET":
                return self.task_page(rest[0], tasks, query)
            if rest[1:] == ["tasks"] and method == "POST":
                return Answer(201, self.task_json(FAKE.new_task(tasks, json_of(raw)), False))
            if len(rest) == 3 and rest[1] == "tasks":
                task = tasks[rest[2]]
                if method == "GET":
                    return self.task_json(task, False)
                if method == "PATCH":
                    FAKE.patch_task(task, json_of(raw))
                    return self.task_json(task, False)
                if method == "DELETE":
                    del tasks[rest[2]]
                    return Answer(204)
            if len(rest) >= 4 and rest[1] == "tasks" and rest[3] == "checklistItems":
                task = tasks[rest[2]]
                if len(rest) == 4 and method == "GET":
                    return {"value": task["checklistItems"]}
                if len(rest) == 4 and method == "POST":
                    return Answer(201, FAKE.new_step(task, json_of(raw)))
                if len(rest) == 5:
                    step = next(
                        (s for s in task["checklistItems"] if s["id"] == rest[4]), None
                    )
                    if step is None:
                        raise KeyError("no step %s" % rest[4])
                    if method == "PATCH":
                        body = json_of(raw)
                        if "isChecked" in body:
                            step["isChecked"] = bool(body["isChecked"])
                        if "displayName" in body:
                            step["displayName"] = str(body["displayName"])
                        FAKE.touch(task)
                        return step
                    if method == "DELETE":
                        task["checklistItems"].remove(step)
                        FAKE.touch(task)
                        return Answer(204)
        raise Answer(404, {"error": {"code": "BadRequest"}})

    def task_page(self, list_id, tasks, query):
        top = min(int(query.get("$top") or 10), 100)
        skip = int(query.get("$skip") or 0)
        expand = query.get("$expand") == "checklistItems"
        everything = list(tasks.values())
        page = {"value": [self.task_json(t, expand) for t in everything[skip : skip + top]]}
        if skip + top < len(everything):
            params = "$top=%d&$skip=%d" % (top, skip + top)
            if expand:
                params += "&$expand=checklistItems"
            page["@odata.nextLink"] = "%sgraph/me/todo/lists/%s/tasks?%s" % (
                self.base_url(),
                quote(list_id, safe=""),
                params,
            )
        return page

    @staticmethod
    def task_json(task, expand):
        view = {k: v for k, v in task.items() if k != "checklistItems"}
        if expand:
            view["checklistItems"] = [dict(s) for s in task["checklistItems"]]
        return view

    # --- for the test ---------------------------------------------------------

    def control(self, parts, query, raw):
        body = json_of(raw)
        with FAKE.lock:
            what = "/".join(parts)
            if what == "state":
                return FAKE.snapshot(query.get("zone") or FAMILY_ZONE)
            if what == "reset":
                FAKE.reset()
                return {"ok": True}
            if what == "delay":
                FAKE.delay = float(body.get("seconds") or 0)
                return {"ok": True}
            if what == "bring/item":
                items = FAKE.bring_list(body["list"])["items"]
                FAKE.bring_put(
                    items,
                    str(body["name"]),
                    str(body.get("spec") or ""),
                    bool(body.get("done")),
                )
                return {"ok": True}
            if what == "bring/remove":
                FAKE.bring_list(body["list"])["items"].pop(str(body["name"]))
                return {"ok": True}
            if what == "mstodo/task":
                tasks = FAKE.ms_list(body["list"])["tasks"]
                task = FAKE.new_task(tasks, self.task_body(body))
                if body.get("steps"):
                    FAKE.set_steps(task, body["steps"])
                return Fake.task_view(task, FAMILY_ZONE)
            if what in ("mstodo/update", "mstodo/delete"):
                tasks = FAKE.ms_list(body["list"])["tasks"]
                matches = [
                    t
                    for t in tasks.values()
                    if t["id"] == body.get("id") or t["title"] == body.get("title")
                ]
                if len(matches) != 1:
                    raise Answer(400, {"error": "%d tasks match" % len(matches)})
                task = matches[0]
                if what == "mstodo/delete":
                    del tasks[task["id"]]
                    return {"ok": True}
                change = body.get("set") or {}
                FAKE.patch_task(task, self.task_body(change))
                if "steps" in change:
                    FAKE.set_steps(task, change["steps"])
                return Fake.task_view(task, FAMILY_ZONE)
        raise Answer(404, {"error": "unknown control %s" % "/".join(parts)})

    @staticmethod
    def task_body(change):
        """A change in the To Do app as Graph stores it: a due day is
        midnight in the member's zone."""
        body = {}
        if "title" in change:
            body["title"] = change["title"]
        if "note" in change:
            body["body"] = {"content": change["note"], "contentType": "text"}
        if "done" in change:
            body["status"] = "completed" if change["done"] else "notStarted"
        if "due" in change:
            body["dueDateTime"] = (
                None
                if change["due"] is None
                else {
                    "dateTime": "%sT00:00:00.0000000" % change["due"],
                    "timeZone": change.get("zone") or FAMILY_ZONE,
                }
            )
        return body


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print("fake list services on http://127.0.0.1:%d/" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
