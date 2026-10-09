#!/bin/sh
# Signs the macOS app inside out: frameworks and libraries first, then the
# app with macos/Runner/Release.entitlements (no get-task-allow).
#
# Published builds are signed ad hoc (--adhoc). A certificate would put its
# name (with the developer's e-mail address) and team ID into every
# download; ad hoc replaces every signature in the bundle, including the one
# from a local Signing.xcconfig.
#
# Builds for this Mac (tool/mac_install.sh) keep a stable local identity.
# It prefers an "Apple Development" certificate (free Apple ID in Xcode):
# with its team ID, "Immer erlauben" in the Keychain holds across updates.
# The local certificate keeps the app's identity too, but without a team ID
# the Keychain ties "Immer erlauben" to the exact build and asks once per
# update (see SecureVault).
#
# Usage: tool/sign_macos.sh --adhoc [path/to/Famio.app]
#        tool/sign_macos.sh [path/to/Famio.app] [identity]
set -eu
ADHOC=0
if [ "${1:-}" = --adhoc ]; then
  ADHOC=1
  shift
fi
APP="${1:-build/macos/Build/Products/Release/Famio.app}"
ENTITLEMENTS="$(dirname "$0")/../macos/Runner/Release.entitlements"

if [ $ADHOC -eq 1 ]; then
  IDENTITY=-
  # A provisioning profile would carry the certificate and device IDs along.
  rm -f "$APP/Contents/embedded.provisionprofile"
else
  DEV_IDENTITY="$(security find-identity -v -p codesigning |
    sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
  IDENTITY="${2:-${DEV_IDENTITY:-Famio Local Signing}}"
  if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "Signier-Identität „$IDENTITY“ fehlt im Schlüsselbund." >&2
    exit 1
  fi
fi

find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) |
  while read -r item; do
    codesign --force --sign "$IDENTITY" --timestamp=none "$item"
  done
codesign --force --sign "$IDENTITY" --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

if [ $ADHOC -eq 1 ]; then
  # Every binary must be ad hoc: one left with a certificate would still
  # name its owner.
  find "$APP" -type f | while read -r file; do
    file -b "$file" | grep -q Mach-O || continue
    if ! codesign -dv "$file" 2>&1 | grep -qx 'Signature=adhoc'; then
      echo "Nicht ad hoc signiert: $file" >&2
      exit 1
    fi
  done
  if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q get-task-allow; then
    echo "get-task-allow in der Signatur von $APP." >&2
    exit 1
  fi
  echo "Ad hoc signiert: $APP"
else
  codesign -d -r- "$APP" 2>&1 | grep designated
fi
