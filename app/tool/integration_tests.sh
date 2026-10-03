#!/usr/bin/env bash
# Runs the integration tests that need no phone, each against its own
# throwaway server (two-factor and "delete all data" change the server):
#
#   tool/integration_tests.sh <linux|macos> [integration_test/<file>]…
#
# Without files it runs all of them. The app runs as "Famio E2E"
# (FAMIO_ENV=e2e; on macOS de.status403.famio.e2e) with its own data and
# keychain entry and starts signed out; the family's Famio and "Famio Dev"
# stay untouched.
# On Linux it needs a display and a keyring (CI: xvfb-run and
# gnome-keyring in a dbus session).
set -euo pipefail

DEVICE="${1:?usage: tool/integration_tests.sh <linux|macos> [test]…}"
shift
cd "$(dirname "$0")/.."
APP_DIR=$PWD
SERVER_DIR=$APP_DIR/../server

TESTS=("$@")
if [ ${#TESTS[@]} -eq 0 ]; then
  TESTS=(
    integration_test/admin_flow_test.dart
    integration_test/features_flow_test.dart
    integration_test/move_server_test.dart
    integration_test/two_factor_flow_test.dart
    integration_test/reset_flow_test.dart
  )
fi

TEST_ID=de.status403.famio.e2e
if [ "$DEVICE" = macos ]; then
  export FLUTTER_XCODE_FAMIO_APP_NAME="Famio E2E"
  export FLUTTER_XCODE_FAMIO_BUNDLE_ID=$TEST_ID
  export FLUTTER_XCODE_FAMIO_APP_ICON=AppIconDev
fi

WORK=$(mktemp -d)
SERVER_PID=
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
  # Built app bundles would show up in Spotlight and Launchpad.
  if [ "$DEVICE" = macos ]; then
    find "$APP_DIR/build/macos" -name '*.app' -type d -prune \
      -exec rm -rf {} + 2>/dev/null || true
  fi
}
trap cleanup EXIT

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}

echo "== Server bauen"
(cd "$SERVER_DIR" && dart pub get >/dev/null && dart build cli -t bin/server.dart -o "$WORK/server" >/dev/null)
SERVER_BIN=$(find "$WORK/server" -type f -name server -perm -u+x | head -1)
[ -x "$SERVER_BIN" ] || { echo "Server-Binary nicht gefunden" >&2; exit 1; }

PASSWORD="ci-$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
failed=()

for test in "${TESTS[@]}"; do
  echo "== $test"
  data=$(mktemp -d "$WORK/data.XXXXXX")
  port=$(free_port)
  tls_port=$(free_port)
  log=$data.log
  FAMIO_DATA_DIR=$data FAMIO_PORT=$port FAMIO_TLS_PORT=$tls_port \
    FAMIO_TIMEZONE=Europe/Berlin "$SERVER_BIN" >"$log" 2>&1 &
  SERVER_PID=$!

  for _ in $(seq 1 60); do
    curl -fs "http://localhost:$port/api/health" >/dev/null && break
    sleep 0.5
  done
  code=$(sed -n 's/.*Einrichtungscode für die App: \([A-Z0-9]*\).*/\1/p' "$log")
  body=$(python3 -c 'import json,sys; print(json.dumps({"username":"admin","displayName":"Admin","password":sys.argv[1],"setupCode":sys.argv[2]}))' "$PASSWORD" "$code")
  if ! curl -fs -X POST -H 'content-type: application/json' \
    -d "$body" "http://localhost:$port/api/auth/setup" >/dev/null; then
    echo "Einrichtung des Testservers fehlgeschlagen:" >&2
    cat "$log" >&2
    exit 1
  fi

  if flutter test "$test" -d "$DEVICE" \
    --dart-define=FAMIO_ENV=e2e \
    --dart-define=FAMIO_FRESH_START=true \
    --dart-define=FAMIO_URL="http://localhost:$port" \
    --dart-define=FAMIO_NEW_URL="https://localhost:$tls_port" \
    --dart-define=FAMIO_USER=admin \
    --dart-define=FAMIO_PASSWORD="$PASSWORD" \
    --dart-define=FAMIO_ALLOW_WIPE=yes; then
    echo "== OK: $test"
  else
    echo "== FEHLER: $test" >&2
    tail -40 "$log" >&2
    failed+=("$test")
  fi
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "Fehlgeschlagen: ${failed[*]}" >&2
  exit 1
fi
echo "Alle ${#TESTS[@]} Integrationstests bestanden."
