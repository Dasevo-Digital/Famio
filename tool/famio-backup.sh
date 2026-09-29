#!/bin/sh
# Create or verify an authenticated, encrypted Famio backup with age.
#
# Run create only while the Famio service/container is stopped. A SQLite WAL
# backup copied during writes is not an atomic family snapshot.
set -eu

usage() {
  cat <<'EOF'
Usage:
  tool/famio-backup.sh create --stopped --data-dir DIR --key-file FILE \
    --recipient age1... --output FILE.tar.age
  tool/famio-backup.sh restore --identity FILE.txt --input FILE.tar.age \
    --output EMPTY-DIRECTORY

The output contains data/ and key/famio.key. It is encrypted and authenticated
with age. Restore deliberately extracts into a new directory; replacing a
running server's data is a separate, explicit administrator action.
EOF
  exit "${1:-0}"
}

command -v age >/dev/null 2>&1 || {
  echo 'age fehlt. Installieren: brew install age bzw. apt install age' >&2
  exit 69
}
command -v tar >/dev/null 2>&1 || {
  echo 'tar fehlt.' >&2
  exit 69
}
if command -v sha256sum >/dev/null 2>&1; then
  checksum='sha256sum'
else
  command -v shasum >/dev/null 2>&1 || {
    echo 'sha256sum oder shasum fehlt.' >&2
    exit 69
  }
  checksum='shasum -a 256'
fi

mode="${1:-}"
[ -n "$mode" ] || usage 64
shift

data_dir=''
key_file=''
recipient=''
output=''
input=''
identity=''
stopped=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stopped) stopped=1 ;;
    --data-dir) shift; data_dir="${1:-}" ;;
    --key-file) shift; key_file="${1:-}" ;;
    --recipient) shift; recipient="${1:-}" ;;
    --output) shift; output="${1:-}" ;;
    --input) shift; input="${1:-}" ;;
    --identity) shift; identity="${1:-}" ;;
    -h|--help) usage ;;
    *) echo "Unbekannte Option: $1" >&2; usage 64 ;;
  esac
  shift
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/famio-backup.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

case "$mode" in
  create)
    [ "$stopped" -eq 1 ] || {
      echo 'Abbruch: Famio zuerst stoppen und dann --stopped angeben.' >&2
      exit 64
    }
    [ -d "$data_dir" ] && [ -f "$key_file" ] || {
      echo 'data-dir oder key-file fehlt.' >&2
      exit 66
    }
    [ -n "$recipient" ] && [ -n "$output" ] || usage 64
    [ ! -e "$output" ] || {
      echo "Ausgabe existiert bereits: $output" >&2
      exit 73
    }
    mkdir -p "$tmp/famio-backup/data" "$tmp/famio-backup/key"
    cp -RP "$data_dir/." "$tmp/famio-backup/data/"
    cp -P "$key_file" "$tmp/famio-backup/key/famio.key"
    (
      cd "$tmp/famio-backup"
      find data key -type f -exec $checksum {} \; | LC_ALL=C sort > manifest.sha256
    )
    tar -C "$tmp" -cf - famio-backup | age -r "$recipient" -o "$output"
    chmod 600 "$output" 2>/dev/null || true
    echo "Sicherung erstellt: $output"
    echo 'Zum Prüfen oder Wiederherstellen den privaten age-Schlüssel sicher aufbewahren.'
    ;;
  restore)
    [ -n "$identity" ] && [ -f "$identity" ] && [ -f "$input" ] && [ -n "$output" ] || usage 64
    [ ! -e "$output" ] || {
      echo "Ziel muss neu und leer sein: $output" >&2
      exit 73
    }
    age -d -i "$identity" -o "$tmp/archive.tar" "$input"
    # Reject archives that could escape their extraction root. They are
    # normally created by this script, but backup media must be treated as
    # untrusted before extraction.
    tar -tf "$tmp/archive.tar" > "$tmp/entries"
    while IFS= read -r entry; do
      case "$entry" in
        famio-backup|famio-backup/*) ;;
        *) echo "Ungültiger Archivpfad: $entry" >&2; exit 1 ;;
      esac
    done < "$tmp/entries"
    mkdir "$output"
    tar -C "$tmp" -xf "$tmp/archive.tar"
    (
      cd "$tmp/famio-backup"
      $checksum -c manifest.sha256
    )
    mv "$tmp/famio-backup/data" "$output/data"
    mv "$tmp/famio-backup/key" "$output/key"
    echo "Sicherung geprüft und entpackt: $output"
    echo 'Erst den Famio-Dienst stoppen, dann data/ und key/famio.key gezielt übernehmen und den Dienst wieder starten.'
    ;;
  *) usage 64 ;;
esac
