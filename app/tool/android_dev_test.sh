#!/bin/sh
# Runs an integration test as "Famio Dev" (flavor dev, id
# de.status403.famio.dev) on an Android device, next to the family's Famio:
#
#   tool/android_dev_test.sh <device> <test file> [--dart-define=…]…
#
# Checks afterwards that the family's Famio (de.status403.famio) is still
# installed.
set -eu
DEVICE="$1"; TARGET="$2"; shift 2
cd "$(dirname "$0")/.."
ADB="${ADB:-adb}"
installed() {
  "$ADB" -s "$DEVICE" shell pm list packages de.status403.famio |
    tr -d '\r' | grep -x 'package:de.status403.famio' || true
}
before=$(installed)
# A dark screen stops the app from drawing and the test would wait
# forever: keep it on while plugged in (if the device allows it), then
# restore the owner's setting.
stay=$("$ADB" -s "$DEVICE" shell settings get global stay_on_while_plugged_in | tr -d '\r')
if [ "$stay" != "7" ] &&
  "$ADB" -s "$DEVICE" shell settings put global stay_on_while_plugged_in 7 2>/dev/null; then
  trap '"$ADB" -s "$DEVICE" shell settings put global stay_on_while_plugged_in "${stay:-0}"' EXIT
fi
status=0
flutter drive --profile --flavor dev -d "$DEVICE" \
  --driver test_driver/integration_test.dart --target "$TARGET" \
  --dart-define=FAMIO_ENV=dev "$@" || status=$?
if [ -n "$before" ] && [ -z "$(installed)" ]; then
  echo "ALARM: Famio (de.status403.famio) ist nicht mehr installiert!" >&2
  exit 2
fi
exit $status
