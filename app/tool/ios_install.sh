#!/bin/sh
# Installs a built Famio on iPhones and starts it once on each.
#
#   app/tool/ios_install.sh <path/to/Runner.app> <device id>...
#
# Why the start: iOS wakes an app for location events (the moving fence,
# significant changes) only once it has run since it was installed. Without
# it, location sharing stays silent until somebody opens Famio on that
# phone – in October 2026 a family phone reported nothing for three days
# after its weekly reinstall. The phone must be unlocked for the start.
set -eu

if [ $# -lt 2 ]; then
  echo "Aufruf: $0 <Runner.app> <Geräte-ID>..." >&2
  exit 2
fi
app=$1
shift
plist="$app/Info.plist"
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")

status=0
for device in "$@"; do
  if ! xcrun devicectl device install app --device "$device" "$app" \
    > /dev/null 2>&1; then
    echo "$device: nicht installiert (gesperrt oder nicht erreichbar?)"
    status=1
    continue
  fi
  if ! xcrun devicectl device info apps --device "$device" \
    --bundle-id "$bundle" 2> /dev/null | grep -q " $version "; then
    echo "$device: installiert, aber $version nicht gefunden"
    status=1
    continue
  fi
  if xcrun devicectl device process launch --device "$device" "$bundle" \
    > /dev/null 2>&1; then
    echo "$device: $version installiert und gestartet"
  else
    echo "$device: $version installiert, Start fehlgeschlagen (gesperrt?)" \
      "– Famio dort einmal öffnen, sonst bleibt der Standort stumm"
    status=1
  fi
done
exit $status
