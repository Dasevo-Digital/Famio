# Famio im LXC-Container (Proxmox)

Ohne Docker: Famio läuft als systemd-Dienst direkt im Container. Empfohlenes
System: **Debian 13 „Trixie“** (Standard-Vorlage von Proxmox, schlank,
Sicherheitsupdates bis 2030; Debian 12 geht auch). Ressourcen: 1 CPU,
512 MB RAM, 8 GB Speicher reichen für eine Familie mit Fotos und Dokumenten.

## Container mit einem Befehl anlegen (auf dem Proxmox-Host)

Den Release-Ordner `Server/` (Server-Paket + `deploy/lxc/`) auf den
Proxmox-Host kopieren, z. B. `scp -r Server root@proxmox:/root/famio`, dann
dort als root:

```sh
cd /root/famio/deploy/lxc
bash proxmox-create.sh --server ../../famio-server-0.12.0-linux-x64.tar.gz \
  --ip 192.168.1.50/24 --gw 192.168.1.1
```

Das Skript lädt die Debian-Vorlage, legt einen unprivilegierten Container
an (startet mit dem Host, automatische Sicherheitsupdates), installiert
Famio und zeigt am Ende Adresse und Zertifikat-Fingerabdruck. Weitere
Optionen: `--ctid`, `--hostname`, `--storage`, `--bridge`, `--vlan`,
`--disk`, `--memory`, `--tls-names famio.home.arpa`, `--public-url` (für
Nginx Proxy Manager) – siehe `bash proxmox-create.sh --help`. Ohne `--ip`
bekommt der Container seine Adresse per DHCP (dann im Router fest zuweisen).

## Umzug eines bestehenden Servers (Docker → LXC)

Daten, Schlüssel und HTTPS-Zertifikat ziehen mit – alle Anmeldungen bleiben
gültig und der Fingerabdruck bleibt gleich.

1. Alten Server anhalten und Daten einpacken, z. B. bei Docker:
   ```sh
   cd ~/Famio/prod && docker compose stop
   tar --no-xattrs -czf famio-data.tar.gz -C data .
   cp keys/famio.key famio.key
   ```
2. Beide Dateien auf den Proxmox-Host kopieren und dort:
   ```sh
   bash proxmox-create.sh --server ../../famio-server-0.12.0-linux-x64.tar.gz \
     --ip 192.168.1.50/24 --gw 192.168.1.1 \
     --import-data /root/famio-data.tar.gz --key /root/famio.key
   ```
3. In jeder App: Einstellungen → „Server-Adresse ändern“ → neue Adresse. Man
   bleibt angemeldet. Apple-Kalender-Profil neu erzeugen („Apple-Gerät
   einrichten“), Home-Assistant-Integration neu einrichten.
4. Wenn alles läuft: alten Server entfernen, `famio-data.tar.gz` und die
   Kopie von `famio.key` sicher löschen.

## Installation in einem vorhandenen Container

```sh
sh install.sh famio-server-<version>-linux-x64.tar.gz
# Umzug: zusätzlich --import-data famio-data.tar.gz --key famio.key
```

Bei einer URL ist der SHA-256-Wert aus der zum Release gehörenden
`SHA256SUMS.txt` Pflicht, damit ein Transport- oder Downloadfehler nicht
installiert wird:

```sh
sh install.sh --url https://gitea.example/famio-server-linux-x64.tar.gz \
  --sha256 <Wert-aus-SHA256SUMS.txt>
```

(Auf ARM, z. B. Raspberry Pi: `famio-server-<version>-linux-arm64.tar.gz`.)
Einstellungen in `/etc/famio/famio.env` (öffentliche Adresse für Nginx Proxy
Manager, Zeitzone), dann `systemctl restart famio`. Einrichtungscode für das
erste Konto: `journalctl -u famio`.

Updates: dasselbe `install.sh` mit der neuen Version erneut ausführen – Daten
(`/var/lib/famio`) und Einstellungen bleiben erhalten, die vorige Version liegt
in `/opt/famio.old`.

## Backup

Die Daten liegen verschlüsselt in `/var/lib/famio` (`famio.db`, `files.db`,
HTTPS-Zertifikat). Der Schlüssel liegt getrennt in `/etc/famio/famio.key`:
**diese Datei zusätzlich und getrennt sichern** (z. B. im Passwortmanager) –
ohne sie ist ein Backup nicht lesbar, und mit ihr zusammen im selben Backup
wäre die Verschlüsselung wirkungslos. Für ein konsistentes Backup den Dienst
kurz stoppen (`systemctl stop famio`) oder Proxmox-Snapshots verwenden.

Beim Update von 0.5 auf 0.6 legt `install.sh` den Schlüssel an; der Server
verschlüsselt die vorhandenen Daten beim ersten Start automatisch.

HTTPS im Heimnetz: Port 8766 (eigenes Zertifikat, die Apps fragen beim ersten
Verbinden nach dem Fingerabdruck – er steht in `journalctl -u famio`).

Reverse Proxy: siehe [../npm/README.md](../npm/README.md).
Eigene Karten als separater LXC: siehe [../maps/LXC-NPM.md](../maps/LXC-NPM.md).
