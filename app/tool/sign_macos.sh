#!/bin/sh
# Signs the macOS app with a stable local identity instead of ad hoc.
#
# Prefers an "Apple Development" certificate (free Apple ID in Xcode): with
# its team ID, "Immer erlauben" in the Keychain holds across updates. The
# local certificate keeps the app's identity too, but without a team ID the
# Keychain ties "Immer erlauben" to the exact build and asks once per update
# (see SecureVault).
#
# Usage: tool/sign_macos.sh [path/to/Famio.app] [identity]
set -eu
APP="${1:-build/macos/Build/Products/Release/Famio.app}"
DEV_IDENTITY="$(security find-identity -v -p codesigning |
  sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
IDENTITY="${2:-${DEV_IDENTITY:-Famio Local Signing}}"
ENTITLEMENTS="$(dirname "$0")/../macos/Runner/Release.entitlements"

if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Signier-Identität „$IDENTITY“ fehlt im Schlüsselbund." >&2
  exit 1
fi

# Inside out: frameworks and libraries first, then the app with entitlements.
find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) |
  while read -r item; do
    codesign --force --sign "$IDENTITY" --timestamp=none "$item"
  done
codesign --force --sign "$IDENTITY" --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
