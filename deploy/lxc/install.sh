#!/bin/sh
# Installs or updates the Famio server on Debian/Ubuntu (e.g. a Proxmox LXC).
#
#   sh install.sh famio-server-linux-x64.tar.gz
#   sh install.sh --url https://gitea.status403.de/superkuh/Famio/releases/download/vX.Y.Z/famio-server-linux-x64.tar.gz \
#     --sha256 <value-from-SHA256SUMS.txt>
#
# Moving an existing server here (Docker, another container):
#   sh install.sh famio-server-linux-x64.tar.gz \
#     --import-data famio-data.tar.gz --key famio.key
#
# Layout: binary in /opt/famio, data in /var/lib/famio, settings in
# /etc/famio/famio.env, systemd unit "famio". Data and settings survive updates.
set -eu

SRC=""
EXPECTED_SHA256=""
NO_SYSTEMD=0
IMPORT_DATA=""
IMPORT_KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --url) SRC="$2"; shift 2 ;;
    --sha256) EXPECTED_SHA256="$2"; shift 2 ;;
    --no-systemd) NO_SYSTEMD=1; shift ;;  # for containers without systemd
    # Contents of the old data directory (famio.db, files.db, tls-*.pem …).
    --import-data) IMPORT_DATA="$2"; shift 2 ;;
    # The old server's key file; without it the imported data is unreadable.
    --key) IMPORT_KEY="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) SRC="$1"; shift ;;
  esac
done
[ -n "$SRC" ] || { echo "Usage: $0 <tarball|--url URL> [--sha256 HEX]" >&2; exit 64; }
[ "$(id -u)" -eq 0 ] || { echo "Please run as root." >&2; exit 1; }
if [ -n "$IMPORT_DATA" ] && [ -z "$IMPORT_KEY" ]; then
  echo "--import-data needs the old server's key: --key famio.key" >&2
  exit 64
fi
for f in "$IMPORT_DATA" "$IMPORT_KEY"; do
  [ -z "$f" ] || [ -f "$f" ] || { echo "Not found: $f" >&2; exit 66; }
done
# Checked before anything changes (the running server keeps running).
if [ -n "$IMPORT_DATA" ] && [ -f /var/lib/famio/famio.db ]; then
  echo "/var/lib/famio already holds a Famio database – not overwriting it." >&2
  exit 1
fi
HERE=$(cd "$(dirname "$0")" && pwd)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
case "$SRC" in
  http://*|https://*)
    [ -n "$EXPECTED_SHA256" ] || {
      echo "Remote release needs --sha256 from SHA256SUMS.txt." >&2
      exit 64
    }
    command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates; }
    curl -fsSL "$SRC" -o "$TMP/famio.tar.gz" ;;
  *) cp "$SRC" "$TMP/famio.tar.gz" ;;
esac
[ -z "$EXPECTED_SHA256" ] || {
  printf '%s  %s\n' "$EXPECTED_SHA256" "$TMP/famio.tar.gz" | sha256sum -c -
}
tar -xzf "$TMP/famio.tar.gz" -C "$TMP"
[ -x "$TMP/bundle/bin/server" ] || { echo "Archive does not contain bundle/bin/server" >&2; exit 1; }

id famio >/dev/null 2>&1 || useradd --system --home /var/lib/famio --shell /usr/sbin/nologin famio
install -d -o famio -g famio -m 0700 /var/lib/famio
# Data from older versions may be group/world readable.
chmod -R go-rwx /var/lib/famio
install -d -m 0755 /etc/famio
[ -f /etc/famio/famio.env ] || install -m 0644 "$HERE/famio.env" /etc/famio/famio.env
# Encryption key for database and files: outside the data directory, so
# backups of /var/lib/famio alone are useless. Back it up separately!
if [ -n "$IMPORT_KEY" ]; then
  if [ -f /etc/famio/famio.key ] && ! cmp -s "$IMPORT_KEY" /etc/famio/famio.key; then
    echo "/etc/famio/famio.key exists and differs from $IMPORT_KEY – not replacing it." >&2
    exit 1
  fi
  install -m 0400 "$IMPORT_KEY" /etc/famio/famio.key
elif [ ! -f /etc/famio/famio.key ]; then
  (umask 077; od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > /etc/famio/famio.key; echo >> /etc/famio/famio.key)
fi
chown famio:famio /etc/famio/famio.key
chmod 0400 /etc/famio/famio.key
grep -q '^FAMIO_KEY_FILE=' /etc/famio/famio.env || echo 'FAMIO_KEY_FILE=/etc/famio/famio.key' >> /etc/famio/famio.env

[ "$NO_SYSTEMD" -eq 1 ] || systemctl stop famio 2>/dev/null || true
if [ -n "$IMPORT_DATA" ]; then
  tar -xzf "$IMPORT_DATA" -C /var/lib/famio --no-same-owner --warning=no-unknown-keyword
  [ -f /var/lib/famio/famio.db ] || { echo "$IMPORT_DATA holds no famio.db" >&2; exit 1; }
  chown -R famio:famio /var/lib/famio
  chmod -R go-rwx /var/lib/famio
  echo "Imported data from $IMPORT_DATA."
fi
rm -rf /opt/famio.new && mkdir -p /opt/famio.new
cp -R "$TMP/bundle/." /opt/famio.new/
rm -rf /opt/famio.old && [ -d /opt/famio ] && mv /opt/famio /opt/famio.old || true
mv /opt/famio.new /opt/famio

if [ "$NO_SYSTEMD" -eq 1 ]; then
  echo "Installed to /opt/famio (systemd skipped)."
  exit 0
fi
install -m 0644 "$HERE/famio.service" /etc/systemd/system/famio.service
systemctl daemon-reload
systemctl enable --now famio
sleep 2
if /opt/famio/bin/server --healthcheck --port "$(. /etc/famio/famio.env; echo "${FAMIO_PORT:-8765}")"; then
  echo "Famio is running. First start? The setup code is in: journalctl -u famio"
else
  echo "Famio did not start – see: journalctl -u famio" >&2
  exit 1
fi
