#!/usr/bin/env bash
# Moves the Home Assistant add-on to a released version: only once the
# GitHub release has the files the add-on's Dockerfile fetches (the server
# packages, SHA256SUMS.txt and its signature). Home Assistant offers the
# update as soon as homeassistant-addon/famio/config.yaml carries the new
# version on main; before the release is there its build fails (2.0.33).
#
#   bash tool/addon_release.sh 2.0.34    then commit and push the change
set -euo pipefail
V=${1:?Aufruf: bash tool/addon_release.sh <version>}
cd "$(git rev-parse --show-toplevel)"
CONFIG=homeassistant-addon/famio/config.yaml
python3 - "$V" <<'EOF'
import json, sys, time, urllib.request
v = sys.argv[1]
need = {f'famio-server-{v}-linux-x64.tar.gz', f'famio-server-{v}-linux-arm64.tar.gz',
        'SHA256SUMS.txt', 'SHA256SUMS.txt.sig'}
url = f'https://api.github.com/repos/Dasevo-Digital/Famio/releases/tags/v{v}'
for attempt in range(5):
    try:
        r = json.load(urllib.request.urlopen(urllib.request.Request(
            url, headers={'Accept': 'application/vnd.github+json'}), timeout=60))
        break
    except urllib.error.HTTPError as e:
        sys.exit(f'GitHub-Release v{v}: {e.code} – erst sync.py abwarten')
    except OSError as e:
        print(f'GitHub nicht erreichbar ({e}), neuer Versuch …', file=sys.stderr)
        time.sleep(15)
else:
    sys.exit('GitHub nicht erreichbar')
if r.get('draft'):
    sys.exit(f'GitHub-Release v{v} ist noch ein Entwurf')
have = {a['name'] for a in r['assets'] if a.get('state') == 'uploaded'}
missing = sorted(need - have)
if missing:
    sys.exit(f'GitHub-Release v{v}: es fehlt {", ".join(missing)}')
print(f'GitHub-Release v{v}: Server-Pakete und Signatur vorhanden')
EOF
sed -i.bak -E "s/^version: \"[^\"]+\"/version: \"$V\"/" "$CONFIG" && rm -f "$CONFIG.bak"
dart tool/check_versions.dart
echo "$CONFIG: $V – jetzt committen und pushen (Home Assistant bietet das Update dann an)"
