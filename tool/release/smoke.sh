#!/bin/sh
# Smoke test of a server update (needs Docker):
#   sh tool/release/smoke.sh <dir>   with <dir>/old/bundle and
# <dir>/new/bundle (unpacked server packages) and an empty <dir>/data.
# Account, guest and a family task survive the update; the new server
# answers, serves the web app and refuses a weak password.
S=$1
U=https://localhost:18766
up() { for i in $(seq 1 40); do curl -s localhost:18765/api/health >/dev/null && return; sleep 1; done; }
j() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
docker run -d --platform linux/amd64 --name famio-smoke -p 18765:8765 -p 18766:18766 -v "$S":/s debian:bookworm-slim sleep 600 >/dev/null
docker exec -d famio-smoke sh -c 'cd /s/old/bundle && echo $$ > /s/pid && FAMIO_DATA_DIR=/s/data FAMIO_TLS_PORT=18766 exec ./bin/server > /s/old.log 2>&1'
up
CODE=$(sed -n 's/.*Einrichtungscode für die App: \([A-Z0-9]*\).*/\1/p' "$S/old.log" | head -1)
ADMIN=$(curl -sk -X POST -H 'content-type: application/json' -d "{\"username\":\"admin\",\"displayName\":\"Admin\",\"password\":\"smoketest123\",\"setupCode\":\"$CODE\"}" $U/api/auth/setup | j "d.get('token','')")
curl -sk -X POST -H "authorization: Bearer $ADMIN" -H 'content-type: application/json' -d '{"username":"oma","displayName":"Oma","password":"smoketest123","role":"guest"}' $U/api/admin/users | j "'guest:', d.get('role')"
GUEST=$(curl -sk -X POST -H 'content-type: application/json' -d '{"username":"oma","password":"smoketest123","device":"smoke"}' $U/api/auth/login | j "d.get('token','')")
NOW=$(python3 -c "import time;print(int(time.time()*1000))")
curl -sk -X POST -H "authorization: Bearer $ADMIN" -H 'content-type: application/json' -d "{\"since\":0,\"changes\":[{\"collection\":\"tasks\",\"id\":\"muell\",\"data\":{\"title\":\"Muell\",\"done\":false},\"updatedAt\":$NOW}]}" $U/api/sync >/dev/null
echo "old: $(curl -s localhost:18765/api/health | cut -c1-45) admin=${#ADMIN} guest=${#GUEST}"
docker exec famio-smoke sh -c 'kill $(cat /s/pid)'
for i in $(seq 1 20); do curl -s localhost:18765/api/health >/dev/null || break; sleep 1; done
docker exec -d famio-smoke sh -c 'cd /s/new/bundle && echo $$ > /s/pid && FAMIO_DATA_DIR=/s/data FAMIO_TLS_PORT=18766 exec ./bin/server > /s/new.log 2>&1'
up
echo "new: $(curl -s localhost:18765/api/health | cut -c1-45)"
echo "web: $(curl -s localhost:18765/app/version.json)"
echo "index: $(curl -s localhost:18765/app/ | grep -o 'flutter_bootstrap.js?v=[^"]*')"
curl -sk -X POST -H "authorization: Bearer $GUEST" -H 'content-type: application/json' -d '{"since":0,"changes":[]}' $U/api/sync | j "'guest sees tasks:', [c['id'] for c in d['changes'] if c['collection']=='tasks' and not c.get('deleted')]"
curl -sk -X POST -H "authorization: Bearer $ADMIN" -H 'content-type: application/json' -d '{"since":0,"changes":[]}' $U/api/sync | j "'admin sees tasks:', [c['id'] for c in d['changes'] if c['collection']=='tasks' and not c.get('deleted')]"
curl -sk -X POST -H "authorization: Bearer $ADMIN" -H 'content-type: application/json' -d '{"username":"papa","password":"passwort1"}' $U/api/admin/users | j "'weak password:', d.get('error')"
grep -i -E "error|exception" "$S/new.log" | head -5
docker container rm -f famio-smoke >/dev/null
