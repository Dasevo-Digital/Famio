#!/bin/sh
# Puts one of the server's automatic backups back in place.
#
#   tool/famio-restore-backup.sh [--force] <backup-folder> <data-dir>
#
# Run only while the Famio service/container is stopped. The current
# databases are moved aside (data-dir/before-restore-<time>/), never deleted
# right away; of these folders the three newest are kept. The key file stays
# as it is: the backups are encrypted with it.
#
# A backup whose last check failed (check.json) is only restored after a
# confirmation on the terminal, or with --force.
set -eu
# The databases hold the family's data: new files for the owner only.
umask 077

usage() {
  echo 'Aufruf: tool/famio-restore-backup.sh [--force] <Sicherungsordner> <Datenverzeichnis>' >&2
  echo 'Beispiel: tool/famio-restore-backup.sh /var/lib/famio/backups/famio-20261006-030000 /var/lib/famio' >&2
  echo '--force: auch eine Sicherung einspielen, deren Prüfung fehlgeschlagen ist' >&2
  exit 64
}

FORCE=0
if [ "${1:-}" = --force ]; then
  FORCE=1
  shift
fi
[ $# -eq 2 ] || usage
BACKUP="$1"
DATA="$2"
# Folders set aside by earlier restores that stay.
KEEP_ASIDE=3
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

# The server's last check of this backup (compact JSON, see BackupCheck).
CHECK="$BACKUP/check.json"
if [ -f "$CHECK" ] && grep -q '"ok":false' "$CHECK"; then
  problems=$(sed -n 's/.*"problems":\[\([^]]*\)\].*/\1/p' "$CHECK" |
    sed 's/","/; /g; s/^"//; s/"$//')
  {
    echo 'ACHTUNG: Die letzte Prüfung dieser Sicherung ist fehlgeschlagen.'
    [ -n "$problems" ] && echo "Gemeldet: $problems"
    echo 'Wiederhergestellt wird nur, was darin intakt ist; es kann Daten fehlen.'
  } >&2
  if [ "$FORCE" != 1 ]; then
    if [ -t 0 ]; then
      printf 'Trotzdem einspielen? Dann „ja“ eingeben: ' >&2
      read -r answer || answer=
      [ "$answer" = ja ] || {
        echo 'Abgebrochen, nichts geändert.' >&2
        exit 65
      }
    else
      echo 'Abgebrochen, nichts geändert. Mit --force trotzdem einspielen.' >&2
      exit 65
    fi
  fi
fi

stamp=$(date +%Y%m%d-%H%M%S)
ASIDE="$DATA/before-restore-$stamp"
n=0
# Never into the folder of an earlier restore in the same second.
until mkdir "$ASIDE" 2>/dev/null; do
  n=$((n + 1))
  [ "$n" -le 99 ] || {
    echo "Kann keinen Ordner für die bisherigen Datenbanken anlegen: $ASIDE" >&2
    exit 73
  }
  ASIDE="$DATA/before-restore-$stamp-$n"
done
MOVE="famio.db famio.db-wal famio.db-shm"
[ "$WITH_FILES" = 1 ] && MOVE="$MOVE files.db files.db-wal files.db-shm"
for f in $MOVE; do
  if [ -e "$DATA/$f" ]; then mv "$DATA/$f" "$ASIDE/"; fi
done
cp "$BACKUP/famio.db" "$DATA/"
if [ "$WITH_FILES" = 1 ]; then cp "$BACKUP/files.db" "$DATA/"; fi
# Same owner as the data directory (e.g. the famio service user).
owner=$(stat -c '%u:%g' "$DATA" 2>/dev/null || stat -f '%u:%g' "$DATA")
for f in famio.db files.db; do
  [ -e "$DATA/$f" ] || continue
  if ! chown "$owner" "$DATA/$f" 2>/dev/null; then
    echo "Hinweis: Besitzer von $DATA/$f nicht geändert ($owner). Famio muss die Datei lesen können." >&2
  fi
  chmod 600 "$DATA/$f" || {
    echo "Konnte die Rechte von $DATA/$f nicht auf 600 setzen." >&2
    exit 1
  }
done
[ "$WITH_FILES" = 1 ] ||
  echo 'Diese Sicherung enthält keine Dateien: Dokumente und Fotos bleiben auf dem heutigen Stand.'
echo "Wiederhergestellt aus $BACKUP."
echo "Die vorherigen Datenbanken liegen in $ASIDE."

# Only the newest folders of earlier restores stay (names sort by time).
old=$(find "$DATA" -mindepth 1 -maxdepth 1 -type d -name 'before-restore-*' |
  LC_ALL=C sort | awk -v keep="$KEEP_ASIDE" '{ line[NR] = $0 }
    END { for (i = 1; i <= NR - keep; i++) print line[i] }')
if [ -n "$old" ]; then
  echo "$old" | while IFS= read -r dir; do
    [ "$dir" = "$ASIDE" ] && continue
    rm -rf "$dir"
    echo "Entfernt (ältere beiseitegelegte Datenbanken): $dir"
  done
fi
echo 'Jetzt Famio wieder starten, z. B. systemctl start famio'
