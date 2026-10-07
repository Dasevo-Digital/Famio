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
[ -f "$BACKUP/famio.db" ] || {
  echo "Keine Famio-Sicherung: $BACKUP (famio.db fehlt)" >&2
  exit 66
}
# Older backups keep no files.db (documents and photos are only in the
# newest ones): then the current files stay in place.
WITH_FILES=0
[ -f "$BACKUP/files.db" ] && WITH_FILES=1
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
MOVE="famio.db famio.db-wal famio.db-shm"
[ "$WITH_FILES" = 1 ] && MOVE="$MOVE files.db files.db-wal files.db-shm"
for f in $MOVE; do
  [ -e "$DATA/$f" ] && mv "$DATA/$f" "$ASIDE/"
done
cp "$BACKUP/famio.db" "$DATA/"
[ "$WITH_FILES" = 1 ] && cp "$BACKUP/files.db" "$DATA/"
# Same owner as the data directory (e.g. the famio service user).
owner=$(stat -c '%u:%g' "$DATA" 2>/dev/null || stat -f '%u:%g' "$DATA")
for f in famio.db files.db; do
  chown "$owner" "$DATA/$f" 2>/dev/null || true
  chmod 600 "$DATA/$f" 2>/dev/null || true
done
[ "$WITH_FILES" = 1 ] ||
  echo 'Diese Sicherung enthält keine Dateien: Dokumente und Fotos bleiben auf dem heutigen Stand.'
echo "Wiederhergestellt aus $BACKUP."
echo "Die vorherigen Datenbanken liegen in $ASIDE."
echo 'Jetzt Famio wieder starten, z. B. systemctl start famio'
