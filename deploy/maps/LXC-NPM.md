# Martin im eigenen Proxmox-LXC hinter Nginx Proxy Manager

Diese Anleitung betreibt Martin getrennt von Famio: keine Famio-Daten,
keine Zugangsdaten und ein eigener unprivilegierter Linux-Dienst. Nginx Proxy
Manager (NPM) ist der einzige öffentlich sichtbare Einstieg. Sie ist für
Debian 12/13 auf x86_64 oder arm64 und Martin **1.16.1** ausgelegt.

## 1. LXC anlegen und Netzwerk festlegen

Einen unprivilegierten Debian-LXC mit mindestens 1 vCPU, 512 MiB RAM und
genügend Plattenplatz für die Kartenarchive anlegen. Dem Container eine feste
LAN-IP geben, etwa `192.168.1.60`. Notiere auch die IP des vorhandenen
NPM-Containers, etwa `192.168.1.20`.

Der Dienst wird nur an die LXC-LAN-IP gebunden. Eine Firewall lässt anschließend
ausschließlich NPM auf Port 3000 zu. Dadurch kann kein Gerät im Heimnetz Martin
oder dessen Katalog direkt aufrufen.

## 2. Martin binär und prüfbar installieren

Im Martin-LXC als `root` ausführen. Die Hashes stammen aus dem offiziellen
Release `martin-v1.16.1`; bei einem Update müssen Version, URL und Hash gemeinsam
aus dem offiziellen Release ersetzt werden.

```sh
apt-get update
apt-get install -y ca-certificates curl tar
install -d -m 0755 /opt/martin /etc/martin /var/lib/martin/tiles
useradd --system --home /var/lib/martin --shell /usr/sbin/nologin martin
chown -R martin:martin /var/lib/martin

case "$(uname -m)" in
  x86_64)
    asset=martin-x86_64-unknown-linux-gnu.tar.gz
    hash=cd37c6d55914ba118628d38d7f8204bdb385c75a2ff1839bf26b263ea4f302c1
    ;;
  aarch64|arm64)
    asset=martin-aarch64-unknown-linux-gnu.tar.gz
    hash=cc55ec4f1faf070bdfbcc654decac4a31477d70563680a684dd67a8ab8f66805
    ;;
  *) echo "Nicht unterstützte Architektur: $(uname -m)" >&2; exit 1 ;;
esac

curl -fL --proto '=https' --tlsv1.2 \
  "https://github.com/maplibre/martin/releases/download/martin-v1.16.1/$asset" \
  -o "/tmp/$asset"
printf '%s  %s\n' "$hash" "/tmp/$asset" | sha256sum -c -
tar -xzf "/tmp/$asset" -C /opt/martin martin
chmod 0755 /opt/martin/martin
/opt/martin/martin --version
rm -f "/tmp/$asset"
```

## 3. Kacheln und Systemdienst konfigurieren

Kopiere die Famio-Vorlagen `martin-lxc.yaml` und `martin.service` in den LXC. Die
Listen-Adresse muss die LXC-IP sein - im Beispiel unten `192.168.1.60`.

```sh
cp /pfad/zu/Famio/deploy/maps/martin-lxc.yaml /etc/martin/martin.yaml
cp /pfad/zu/Famio/deploy/maps/martin.service /etc/systemd/system/martin.service
sed -i 's/^listen_addresses:.*/listen_addresses: 192.168.1.60:3000/' /etc/martin/martin.yaml
chown martin:martin /etc/martin/martin.yaml
chmod 0640 /etc/martin/martin.yaml

# Nur rechtmäßig bezogene Archive; Famio- oder personenbezogene Daten gehören
# niemals in dieses Verzeichnis.
install -o martin -g martin -m 0640 /pfad/basemap.pmtiles /var/lib/martin/tiles/
systemctl daemon-reload
systemctl enable --now martin
systemctl status martin --no-pager
curl -fsS http://192.168.1.60:3000/catalog
```

Die Standard-Binary erzeugt keine serverseitig gerenderten Kartenbilder; für
Famios XYZ-/PMTiles-/MBTiles-Betrieb ist das nicht nötig. Martin erkennt neu
abgelegte oder ersetzte Archive im Verzeichnis selbst.

## 4. LXC-Firewall auf NPM beschränken

Mit NPM auf `192.168.1.20` nur dessen Verbindung zulassen. Ergänze die echten
IP-Adressen und aktiviere die Firewall, bevor die NPM-Regel getestet wird:

```nft
table inet martin {
  chain input {
    type filter hook input priority filter; policy accept;
    tcp dport 3000 ip saddr 192.168.1.20 accept
    tcp dport 3000 drop
  }
}
```

Speichere sie in `/etc/nftables.conf` und aktiviere `systemctl enable --now
nftables`. Wenn NPM und Martin **im selben** LXC laufen, statt der LAN-IP
`127.0.0.1:3000` in `martin.yaml` verwenden und in NPM auf `127.0.0.1:3000`
weiterleiten.

## 5. NPM-Proxy Host und Famio einrichten

In NPM einen separaten Proxy Host anlegen, z. B. `karten.example.de`:

- Forward scheme: `http`
- Forward host/IP: `192.168.1.60`
- Forward port: `3000`
- Websockets: aus (Martin benötigt sie nicht)
- SSL: Let's Encrypt, **Force SSL**, HTTP/2 und HSTS einschalten.

NPM muss den LXC auf Port 3000 erreichen können. Kein Router-Portforward auf
3000 und keine zusätzliche NPM-Zugangsliste für die Tile-URL einrichten: die
Famio-Apps laden Kacheln selbst und können keine NPM-Anmeldung senden.

Prüfen:

```sh
curl -fsS https://karten.example.de/catalog
```

In Famio anschließend **Server-Verwaltung → Einstellungen → Eigener
Martin-Server** wählen und eine URL aus Martins Katalog einsetzen, etwa
`https://karten.example.de/tiles/basemap/{z}/{x}/{y}`. Die konkrete
Quellenbezeichnung steht im Katalog und hängt vom Dateinamen ab. Die URL muss
HTTPS verwenden; nach dem Speichern synchronisieren sich alle Famio-Apps.

## Betrieb

- `journalctl -u martin -f` zeigt Start- und Quellfehler.
- `systemctl restart martin` genügt nach Konfigurationsänderungen.
- Vor Martin-Updates erst Release-Hash und `/catalog` in einer Testinstanz
  prüfen; dann Binary atomar ersetzen und Dienst neu starten.
- PMTiles/MBTiles und zugehörige Kartenattributionen unterliegen ihrer
  jeweiligen Lizenz.
