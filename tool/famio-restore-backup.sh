#!/bin/sh
# Puts one of the server's automatic backups back in place.
#
#   tool/famio-restore-backup.sh <backup-folder> <data-dir>
#
# Run only while the Famio service/container is stopped. The current
# databases are moved aside (data-dir/before-restore-<time>/), never deleted.
# The key file stays as it is: the backups are encrypted with it.
set -eu

usage() {
  echo 'Aufruf: tool/famio-restore-backup.sh <Sicherungsordner> <Datenverzeichnis>' >&2
  echo 'Beispiel: tool/famio-restore-backup.sh /var/lib/famio/backups/famio-20261006-030000 /var/lib/famio' >&2
  exit 64
}

[ $# -eq 2 ] || usage
BACKUP="$1"
DATA="$2"
[ -f "$BACKUP/famio.db" ] && [ -f "$BACKUP/files.db" ] || {
  echo "Keine Famio-Sicherung: $BACKUP (famio.db und files.db fehlen)" >&2
  exit 66
}
[ -d "$DATA" ] || {
  echo "Datenverzeichnis fehlt: $DATA" >&2
  exit 66
}
if command -v pgrep >/dev/null 2>&1 && pgrep -f '/opt/famio/bin/server' >/dev/null 2>&1; then
  echo 'Famio läuft noch. Erst stoppen, z. B. systemctl stop famio' >&2
  exit 75
fi

ASIDE="$DATA/before-restore-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ASIDE"
for f in famio.db famio.db-wal famio.db-shm files.db files.db-wal files.db-shm; do
  [ -e "$DATA/$f" ] && mv "$DATA/$f" "$ASIDE/"
done
cp "$BACKUP/famio.db" "$BACKUP/files.db" "$DATA/"
# Same owner as the data directory (e.g. the famio service user).
owner=$(stat -c '%u:%g' "$DATA" 2>/dev/null || stat -f '%u:%g' "$DATA")
chown "$owner" "$DATA/famio.db" "$DATA/files.db" 2>/dev/null || true
chmod 600 "$DATA/famio.db" "$DATA/files.db"
echo "Wiederhergestellt aus $BACKUP."
echo "Die vorherigen Datenbanken liegen in $ASIDE."
echo 'Jetzt Famio wieder starten, z. B. systemctl start famio'
