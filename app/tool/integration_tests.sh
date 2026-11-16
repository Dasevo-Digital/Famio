#!/usr/bin/env bash
# Runs the integration tests that need no phone, each against its own
# throwaway server (two-factor and "delete all data" change the server):
#
#   tool/integration_tests.sh <linux|macos> [integration_test/<file>]…
#
# Without files it runs the five flows listed below. The acceptance tests of
# reviewed features (integration_test/review_*_test.dart, one test per
# board card, about 20 minutes on macOS) run only when named.
# The app runs as "Famio E2E"
# (FAMIO_ENV=e2e; on macOS de.status403.famio.e2e) with its own data and
# keychain entry and starts signed out; the family's Famio and "Famio Dev"
# stay untouched.
# On Linux it needs a display and a keyring (CI: xvfb-run and
# gnome-keyring in a dbus session).
# FAMIO_E2E_ARGS goes to `flutter test` as it is, e.g.
# FAMIO_E2E_ARGS='--plain-name KIN-012' to run single tests of a file.
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

# FAMIO_E2E_SLOT=<n> runs beside other runs: bundle id, data and keychain
# entry of their own (each slot needs its own copy of the repo, as the build
# folder is shared otherwise).
SLOT=${FAMIO_E2E_SLOT:-}
TEST_ID=de.status403.famio.e2e$SLOT
if [ "$DEVICE" = macos ]; then
  export FLUTTER_XCODE_FAMIO_APP_NAME="Famio E2E${SLOT:+ $SLOT}"
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

# A throwaway key pair for tests that need a server with another certificate
# (catalog_gru_b_test.dart); made for each run, never kept in the repository.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc \
  -keyout "$WORK/other.key" -out "$WORK/other.crt" -days 2 -subj /CN=localhost \
  >/dev/null 2>&1
OTHER_CERT=$(base64 < "$WORK/other.crt" | tr -d '\n')
OTHER_KEY=$(base64 < "$WORK/other.key" | tr -d '\n')
failed=()

for test in "${TESTS[@]}"; do
  echo "== $test"
  data=$(mktemp -d "$WORK/data.XXXXXX")
  port=$(free_port)
  tls_port=$(free_port)
  log=$data.log
  # A test file may want its server set up otherwise, in a line like
  #   // e2e-server: FAMIO_BACKUP_DIR=off FAMIO_TLS_PORT=0
  # Only FAMIO_ variables; data folder and port stay the script's.
  server_env=()
  for assignment in $(sed -n 's|^// e2e-server:||p' "$test"); do
    if [[ ! $assignment =~ ^FAMIO_[A-Z_]+=[A-Za-z0-9._:/-]*$ ]] ||
      [[ $assignment =~ ^FAMIO_(DATA_DIR|PORT)= ]]; then
      echo "Ungültige Servereinstellung in $test: $assignment" >&2
      exit 1
    fi
    server_env+=("$assignment")
  done
  [ ${#server_env[@]} -eq 0 ] || echo "== Server mit ${server_env[*]}"
  env FAMIO_TLS_PORT="$tls_port" FAMIO_TIMEZONE=Europe/Berlin \
    ${server_env[@]+"${server_env[@]}"} \
    FAMIO_DATA_DIR="$data" FAMIO_PORT="$port" "$SERVER_BIN" >"$log" 2>&1 &
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
    --dart-define=FAMIO_E2E_TLS_PORT="$tls_port" \
    --dart-define=FAMIO_USER=admin \
    --dart-define=FAMIO_PASSWORD="$PASSWORD" \
    --dart-define=FAMIO_ALLOW_WIPE=yes \
    --dart-define=FAMIO_E2E_SLOT="$SLOT" \
    --dart-define=FAMIO_OTHER_CERT="$OTHER_CERT" \
    --dart-define=FAMIO_OTHER_KEY="$OTHER_KEY" \
    ${FAMIO_E2E_ARGS:+$FAMIO_E2E_ARGS}; then
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
