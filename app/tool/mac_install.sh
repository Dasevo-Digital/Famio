#!/bin/sh
# Installs Famio on this Mac in one of two environments:
#
#   tool/mac_install.sh dev             builds "Famio Dev" from the working
#                                       copy (own bundle id, icon, data and
#                                       server on port 8776) and installs it
#   tool/mac_install.sh prod [version]  installs "Famio" only from a released
#                                       build in ~/Desktop/Famio-Release-v…
#                                       (default: the newest release)
#
# Both land in /Applications; build products stay out of Spotlight
# (build → build.noindex), so Spotlight shows exactly these two apps.
set -eu
cd "$(dirname "$0")/.."

# Spotlight skips folders named *.noindex.
if [ -d build ] && [ ! -L build ]; then
  rm -rf build.noindex
  mv build build.noindex
fi
mkdir -p build.noindex
[ -L build ] || ln -s build.noindex build

case "${1:-}" in
dev)
  FLUTTER_XCODE_FAMIO_APP_NAME="Famio Dev" \
  FLUTTER_XCODE_FAMIO_BUNDLE_ID=de.status403.famio.dev \
  FLUTTER_XCODE_FAMIO_APP_ICON=AppIconDev \
    flutter build macos --release --dart-define=FAMIO_ENV=dev
  APP="build/macos/Build/Products/Release/Famio Dev.app"
  tool/sign_macos.sh "$APP"
  rm -rf "/Applications/Famio Dev.app"
  ditto "$APP" "/Applications/Famio Dev.app"
  echo "Installiert: /Applications/Famio Dev.app"
  ;;
prod)
  if [ -n "${2:-}" ]; then
    DIR="$HOME/Desktop/Famio-Release-v$2"
  else
    DIR="$(ls -d "$HOME"/Desktop/Famio-Release-v* 2>/dev/null | sort -V | tail -n 1)"
  fi
  ZIP="$(ls "$DIR"/macOS/Famio-*-macOS.zip 2>/dev/null | head -n 1)"
  if [ -z "$ZIP" ]; then
    echo "Keine freigegebene macOS-Version gefunden (${DIR:-~/Desktop/Famio-Release-v…})." >&2
    exit 1
  fi
  TMP="$(mktemp -d)"
  ditto -x -k "$ZIP" "$TMP"
  codesign --verify --deep --strict "$TMP/Famio.app"
  rm -rf /Applications/Famio.app
  ditto "$TMP/Famio.app" /Applications/Famio.app
  rm -rf "$TMP"
  echo "Installiert: /Applications/Famio.app aus $ZIP"
  ;;
*)
  echo "Aufruf: tool/mac_install.sh dev | prod [version]" >&2
  exit 1
  ;;
esac
