#!/bin/sh
# Builds the folder of the locally installable Famio add-on:
#
#   sh make_local_addon.sh <version> <server-x64.tar.gz> <server-arm64.tar.gz> <out>
#
# <out>/famio then goes to the "addons" share of Home Assistant (Samba or
# SSH add-on): /addons/famio.
set -eu
V="$1"; X64="$2"; ARM64="$3"; OUT="$4"
HERE=$(cd "$(dirname "$0")" && pwd)
ADDON="$HERE/../famio"
rm -rf "$OUT/famio" && mkdir -p "$OUT/famio"
# Without "image:" Home Assistant builds the add-on from the Dockerfile.
grep -v '^image:\|^# Prebuilt by\|^# has no sources' "$ADDON/config.yaml" |
  sed "s/^version: .*/version: \"$V\"/" > "$OUT/famio/config.yaml"
cp "$ADDON/DOCS.md" "$ADDON/CHANGELOG.md" "$HERE/Dockerfile" "$OUT/famio/"
[ -f "$ADDON/icon.png" ] && cp "$ADDON/icon.png" "$OUT/famio/" || true
[ -f "$ADDON/logo.png" ] && cp "$ADDON/logo.png" "$OUT/famio/" || true
cp "$X64" "$OUT/famio/famio-server-amd64.tar.gz"
cp "$ARM64" "$OUT/famio/famio-server-aarch64.tar.gz"
echo "Add-on folder: $OUT/famio"
