#!/bin/bash
# Creates a Proxmox LXC container with the Famio server – run on the Proxmox
# host as root, next to the release files:
#
#   bash proxmox-create.sh --server famio-server-0.12.0-linux-x64.tar.gz
#
# Moving an existing Famio server into the container (same data, key and
# certificate – the apps only need the new address, see LIESMICH):
#
#   bash proxmox-create.sh --server famio-server-0.12.0-linux-x64.tar.gz \
#     --import-data famio-data.tar.gz --key famio.key
#
# Options (defaults in brackets):
#   --ctid N            container id [next free id]
#   --hostname NAME     [famio]
#   --ip CIDR|dhcp      e.g. 192.168.1.50/24 [dhcp]
#   --gw ADDRESS        gateway, needed with a fixed --ip
#   --bridge NAME       [vmbr0]
#   --vlan ID           VLAN tag of the network interface
#   --storage NAME      storage for the container disk [local-lvm]
#   --template-storage NAME  storage for OS templates [local]
#   --disk GB           [8]      --memory MB [512]      --cores N [1]
#   --tls-names LIST    extra names for the HTTPS certificate, e.g.
#                       famio.home.arpa (the container's IP is added)
#   --public-url URL    public HTTPS address behind a reverse proxy
#
# The container: Debian 13 (Debian 12 if 13 is unavailable), unprivileged,
# starts on boot, automatic security updates, Famio as systemd service with
# data in /var/lib/famio and the key in /etc/famio/famio.key.
set -euo pipefail

CTID=""
HOSTNAME_="famio"
IP="dhcp"
GW=""
BRIDGE="vmbr0"
VLAN=""
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
DISK=8
MEMORY=512
CORES=1
SERVER=""
IMPORT_DATA=""
IMPORT_KEY=""
TLS_NAMES=""
PUBLIC_URL=""

die() { echo "Fehler: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --hostname) HOSTNAME_="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --gw) GW="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --vlan) VLAN="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --server) SERVER="$2"; shift 2 ;;
    --import-data) IMPORT_DATA="$2"; shift 2 ;;
    --key) IMPORT_KEY="$2"; shift 2 ;;
    --tls-names) TLS_NAMES="$2"; shift 2 ;;
    --public-url) PUBLIC_URL="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "Unbekannte Option: $1 (siehe --help)" ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || die "Bitte als root auf dem Proxmox-Host ausführen."
command -v pct >/dev/null && command -v pveam >/dev/null ||
  die "pct/pveam fehlen – läuft das Skript auf dem Proxmox-Host?"

# The server package matching the host (the container shares its CPU).
case "$(uname -m)" in
  x86_64) ARCH=x64 ;;
  aarch64) ARCH=arm64 ;;
  *) die "Nicht unterstützte Architektur: $(uname -m)" ;;
esac
if [ -z "$SERVER" ]; then
  SERVER=$(ls "$HERE"/famio-server-*-linux-$ARCH.tar.gz "$HERE"/../../famio-server-*-linux-$ARCH.tar.gz 2>/dev/null | sort -V | tail -n 1 || true)
fi
[ -n "$SERVER" ] && [ -f "$SERVER" ] ||
  die "Server-Paket fehlt: --server famio-server-<version>-linux-$ARCH.tar.gz"
case "$SERVER" in *"-linux-$ARCH.tar.gz") ;; *) die "$SERVER passt nicht zu diesem Host ($ARCH)." ;; esac
for f in install.sh famio.service famio.env; do
  [ -f "$HERE/$f" ] || die "$f fehlt neben diesem Skript."
done
if [ -n "$IMPORT_DATA" ] || [ -n "$IMPORT_KEY" ]; then
  [ -n "$IMPORT_DATA" ] && [ -n "$IMPORT_KEY" ] ||
    die "Für den Umzug beides angeben: --import-data und --key"
  [ -f "$IMPORT_DATA" ] || die "Nicht gefunden: $IMPORT_DATA"
  [ -f "$IMPORT_KEY" ] || die "Nicht gefunden: $IMPORT_KEY"
fi
if [ "$IP" != "dhcp" ]; then
  case "$IP" in */*) ;; *) die "--ip braucht die Netzmaske, z. B. 192.168.1.50/24" ;; esac
  [ -n "$GW" ] || die "Mit fester --ip bitte auch --gw angeben."
fi

[ -n "$CTID" ] || CTID=$(pvesh get /cluster/nextid)
pct status "$CTID" >/dev/null 2>&1 && die "Container $CTID existiert bereits."

step "Vorlage: Debian"
pveam update >/dev/null || echo "Hinweis: Vorlagenliste konnte nicht aktualisiert werden."
TEMPLATE=""
for release in 13 12; do
  TEMPLATE=$(pveam available --section system 2>/dev/null |
    awk '{print $2}' | grep -E "^debian-$release-standard_.*_(amd64|arm64)\.tar\.(zst|gz|xz)$" |
    sort -V | tail -n 1 || true)
  [ -n "$TEMPLATE" ] && break
done
[ -n "$TEMPLATE" ] || die "Keine Debian-Vorlage gefunden (pveam available)."
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  echo "Lade $TEMPLATE …"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi
echo "$TEMPLATE"

step "Container $CTID ($HOSTNAME_) anlegen"
NET="name=eth0,bridge=$BRIDGE,ip=$IP"
[ -n "$GW" ] && NET="$NET,gw=$GW"
[ -n "$VLAN" ] && NET="$NET,tag=$VLAN"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME_" \
  --description "Famio – Familien-Organizer (Server). Daten: /var/lib/famio, Schlüssel: /etc/famio/famio.key" \
  --tags famio \
  --ostype debian \
  --unprivileged 1 \
  --features nesting=1 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap 256 \
  --rootfs "$STORAGE:$DISK" \
  --net0 "$NET" \
  --onboot 1 \
  --timezone host
pct start "$CTID"

step "Warten auf Netzwerk"
for _ in $(seq 1 60); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  sleep 2
done
pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null ||
  die "Container $CTID hat kein Internet (Bridge/VLAN/Gateway prüfen)."

step "System aktualisieren, automatische Sicherheitsupdates"
pct exec "$CTID" -- bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y -qq full-upgrade >/dev/null
  apt-get -y -qq install ca-certificates unattended-upgrades >/dev/null
  echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
  dpkg-reconfigure -f noninteractive unattended-upgrades
'

step "Famio installieren"
pct exec "$CTID" -- mkdir -p /root/famio-install
pct push "$CTID" "$SERVER" "/root/famio-install/$(basename "$SERVER")"
for f in install.sh famio.service famio.env; do
  pct push "$CTID" "$HERE/$f" "/root/famio-install/$f"
done
ARGS="/root/famio-install/$(basename "$SERVER")"
if [ -n "$IMPORT_DATA" ]; then
  pct push "$CTID" "$IMPORT_DATA" /root/famio-install/famio-data.tar.gz
  pct push "$CTID" "$IMPORT_KEY" /root/famio-install/famio.key --perms 0400
  ARGS="$ARGS --import-data /root/famio-install/famio-data.tar.gz --key /root/famio-install/famio.key"
fi
# Settings before the first start.
pct exec "$CTID" -- install -d -m 0755 /etc/famio
pct exec "$CTID" -- install -m 0644 /root/famio-install/famio.env /etc/famio/famio.env
ADDRESS=$(pct exec "$CTID" -- bash -c "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n 1")
NAMES="$ADDRESS,$HOSTNAME_${TLS_NAMES:+,$TLS_NAMES}"
pct exec "$CTID" -- bash -c "echo 'FAMIO_TLS_NAMES=$NAMES' >> /etc/famio/famio.env"
if [ -n "$PUBLIC_URL" ]; then
  pct exec "$CTID" -- bash -c "echo 'FAMIO_PUBLIC_URL=$PUBLIC_URL' >> /etc/famio/famio.env"
fi
pct exec "$CTID" -- bash -c "cd /root/famio-install && sh install.sh $ARGS"
# The copies of data and key are no longer needed in the container.
pct exec "$CTID" -- rm -rf /root/famio-install

step "Fertig"
FINGERPRINT=$(pct exec "$CTID" -- bash -c "journalctl -u famio --no-pager | grep -o '[0-9A-F]\{2\}\(:[0-9A-F]\{2\}\)\{31\}' | tail -n 1" || true)
SETUP=$(pct exec "$CTID" -- bash -c "journalctl -u famio --no-pager | grep -o 'Einrichtungscode für die App: [A-Z0-9]*' | tail -n 1" || true)
cat <<EOF
Container:   $CTID ($HOSTNAME_), Debian, IP $ADDRESS
Famio:       https://$ADDRESS:8766   (Apps im Heimnetz; http auf 8765)
Fingerabdruck: ${FINGERPRINT:-siehe: pct exec $CTID -- journalctl -u famio}
${SETUP:+$SETUP}

Wichtig: Den Schlüssel /etc/famio/famio.key getrennt sichern, z. B.
  pct pull $CTID /etc/famio/famio.key /root/famio.key.backup
Backups: Proxmox-Backup des Containers (vzdump) – der Schlüssel liegt im
Container, das Backup daher verschlüsselt ablegen (PBS mit Verschlüsselung).
Updates: neues Server-Paket in den Container kopieren und dort
  sh install.sh famio-server-<version>-linux-$ARCH.tar.gz
EOF
