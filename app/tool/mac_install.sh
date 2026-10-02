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

# Replaces the app in /Applications. A running copy is quit first: it would
# otherwise load libraries from the new files next to the old ones already
# in memory and crash (seen with sqlite3mc). Started again afterwards.
replace_app() { # <source .app> <target .app>
  was_running=0
  if pgrep -f "$2/Contents/MacOS/" >/dev/null 2>&1; then
    was_running=1
    echo "Beende laufendes $(basename "$2") …"
    osascript -e "tell application \"$2\" to quit" >/dev/null 2>&1 || true
    i=0
    while pgrep -f "$2/Contents/MacOS/" >/dev/null 2>&1; do
      i=$((i + 1))
      if [ $i -gt 30 ]; then
        echo "$(basename "$2") läuft noch – bitte beenden und erneut aufrufen." >&2
        exit 1
      fi
      sleep 1
    done
  fi
  rm -rf "$2"
  ditto "$1" "$2"
  [ $was_running -eq 0 ] || open "$2"
}

case "${1:-}" in
dev)
  FLUTTER_XCODE_FAMIO_APP_NAME="Famio Dev" \
  FLUTTER_XCODE_FAMIO_BUNDLE_ID=de.status403.famio.dev \
  FLUTTER_XCODE_FAMIO_APP_ICON=AppIconDev \
    flutter build macos --release --dart-define=FAMIO_ENV=dev
  APP="build/macos/Build/Products/Release/Famio Dev.app"
  tool/sign_macos.sh "$APP"
  replace_app "$APP" "/Applications/Famio Dev.app"
  echo "Installiert: /Applications/Famio Dev.app"
  ;;
prod)
  # Release folders are called Famio-Release-v<version>-Upload (flat);
  # older ones had no suffix and a macOS subfolder.
  if [ -n "${2:-}" ]; then
    DIR="$(ls -d "$HOME/Desktop/Famio-Release-v$2-Upload" \
      "$HOME/Desktop/Famio-Release-v$2" 2>/dev/null | head -n 1)"
  else
    DIR="$(ls -d "$HOME"/Desktop/Famio-Release-v* 2>/dev/null | sort -V | tail -n 1)"
  fi
  ZIP="$(ls "$DIR"/Famio-*-macOS.zip "$DIR"/macOS/Famio-*-macOS.zip 2>/dev/null | head -n 1)"
  if [ -z "$ZIP" ]; then
    echo "Keine freigegebene macOS-Version gefunden (${DIR:-~/Desktop/Famio-Release-v…})." >&2
    exit 1
  fi
  TMP="$(mktemp -d)"
  ditto -x -k "$ZIP" "$TMP"
  codesign --verify --deep --strict "$TMP/Famio.app"
  replace_app "$TMP/Famio.app" /Applications/Famio.app
  rm -rf "$TMP"
  echo "Installiert: /Applications/Famio.app aus $ZIP"
  ;;
*)
  echo "Aufruf: tool/mac_install.sh dev | prod [version]" >&2
  exit 1
  ;;
esac
