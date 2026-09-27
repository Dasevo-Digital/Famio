#!/bin/sh
# Installs the Famio Linux bundle for the current user:
#   ./install.sh            (run inside the extracted release folder)
set -e
here=$(cd "$(dirname "$0")" && pwd)
dest="$HOME/.local/opt/famio"
mkdir -p "$dest" "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons"
cp -r "$here/bundle/." "$dest/"
ln -sf "$dest/famio" "$HOME/.local/bin/famio"
cp -r "$here/icons/." "$HOME/.local/share/icons/"
sed "s|^Exec=.*|Exec=$dest/famio|" "$here/de.status403.famio.desktop" \
  > "$HOME/.local/share/applications/de.status403.famio.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" || true
echo "Famio installiert. Start über das Anwendungsmenü oder: famio"
