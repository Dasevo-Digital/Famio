# Famio mit Nginx Proxy Manager

Mit HTTPS von außen erreichbar funktionieren die Apps auch unterwegs, und
Google Kalender und iCloud können die Famio-Kalender abonnieren.

## 1. Famio starten

| Betrieb | Ziel für NPM | `FAMIO_TRUST_PROXY` |
|---|---|---|
| Docker im selben Netz wie NPM ([docker-compose.yml](docker-compose.yml)) | `famio` : `8765` | `true` |
| LXC ([../lxc/README.md](../lxc/README.md)) | `<LXC-IP>` : `8765` | wie oben |
| Home-Assistant-Add-on | `<HA-IP>` : `8765` | – |

`FAMIO_PUBLIC_URL` auf die spätere Adresse setzen, z. B.
`https://famio.example.de/`.

## 2. Proxy Host in NPM anlegen

**Details**

- Domain Names: `famio.example.de`
- Scheme: `http`, Forward Hostname/IP und Port: siehe Tabelle oben
- **Websockets Support: an** (sonst keine Live-Aktualisierung)
- Block Common Exploits: an

**SSL**

- Let's Encrypt-Zertifikat anfordern
- Force SSL, HTTP/2 Support und HSTS: an

**Advanced** (Uploads bis zur Famio-Grenze erlauben):

```nginx
client_max_body_size 100m;
proxy_read_timeout 1h;
proxy_send_timeout 1h;
```

Kalender-Apps (CalDAV unter `/dav/` und `/.well-known/caldav`) laufen über
denselben Proxy Host; NPM reicht die WebDAV-Methoden (PROPFIND, REPORT)
unverändert durch. Serveradresse in Apple Kalender oder DAVx⁵:
`https://famio.example.de/dav/`.

## 3. Ersteinrichtung

Famio verlangt für das allererste Konto immer einen
**Einrichtungscode**, damit niemand einen frisch veröffentlichten Server
übernehmen kann:

```sh
docker logs famio        # bzw. journalctl -u famio im LXC
```

Das gilt ebenso bei der Einrichtung direkt im Heimnetz.

## 4. Prüfen

```sh
curl https://famio.example.de/api/health          # Version, 200
curl -I http://famio.example.de/                  # 301 auf https (Force SSL)
curl https://famio.example.de/ | grep url         # zeigt https://famio.example.de
```

## Optionale eigene Karten (Martin)

Die Compose-Vorlage enthält Martin als deaktiviertes Profil für PMTiles und
MBTiles. Kartenarchive in `deploy/npm/map-tiles/` ablegen und starten:

```sh
docker compose --profile maps up -d
```

In NPM einen zusätzlichen HTTPS-Proxy-Host (z. B. `karten.example.de`) auf
`martin`, Port `3000`, anlegen. Danach in Famio unter **Server-Verwaltung →
Einstellungen → Eigener Martin-Server** die XYZ-Adresse eintragen, zum Beispiel
`https://karten.example.de/tiles/basemap/{z}/{x}/{y}`. Martin wird nicht von
der App gestartet und bekommt keine Famio-Daten oder Zugangsdaten.

Die Startseite (`/`) zeigt die Adresse, die in die Apps gehört. Die Apps
dann überall auf `https://famio.example.de` umstellen (Einstellungen →
„Server-Adresse ändern“) – so funktionieren Abgleich und Standort auch
unterwegs.

## LXC: Port 8765 nur für NPM

Mit `FAMIO_TRUST_PROXY=true` darf Port 8765 nur von NPM erreichbar sein.
Im Container z. B. mit nftables (`/etc/nftables.conf`, dann
`systemctl enable --now nftables`):

```nft
flush ruleset
table inet famio {
  chain input {
    type filter hook input priority filter; policy accept;
    tcp dport 8765 ip saddr { 127.0.0.1, <NPM-IP> } accept
    tcp dport 8765 ip6 saddr ::1 accept
    tcp dport 8765 drop
  }
}
```

Dazu in `/etc/famio/famio.env`: `FAMIO_TRUST_PROXY=true`,
`FAMIO_REQUIRE_TLS=true` und `FAMIO_PUBLIC_URL=https://famio.example.de/`,
dann `systemctl restart famio`. Port 8766 (Famios eigenes HTTPS) bleibt fürs
Heimnetz offen.

## Sicherheit

- Anmeldungen werden nach 5 Fehlversuchen gedrosselt (pro Client-IP und
  Benutzer, bis zu 1 Stunde). Nach 20 Fehlversuchen von verschiedenen
  Adressen ist das Konto gesperrt – außer für Adressen, von denen aus sich
  jemand in den letzten 30 Tagen erfolgreich angemeldet hat, damit ein
  Fremder niemanden aussperren kann. Hinter NPM braucht es dafür
  `FAMIO_TRUST_PROXY=true`, sonst sähe Famio nur die IP von NPM.
- `FAMIO_TRUST_PROXY` nur setzen, wenn Port 8765 **nicht** direkt erreichbar
  ist – sonst könnten Clients ihre Adresse fälschen.
- Famio nimmt den letzten Eintrag aus `X-Forwarded-For`, also die Adresse,
  die NPM selbst angehängt hat; was der Client mitschickt, zählt nicht.
  Steht vor NPM noch ein weiterer Proxy (z. B. Cloudflare), sieht Famio
  dessen Adresse statt der des Geräts.
- Private Dokumente, Einzelchats und deren Dateien liefert der Server nur an
  berechtigte Mitglieder aus.
- `FAMIO_REQUIRE_TLS=true` (in der Vorlage gesetzt): Unverschlüsselte
  Anfragen aus dem Netz werden abgelehnt; erlaubt sind nur NPM (HTTPS) und
  Famios eigenes HTTPS auf Port 8766. NPM setzt `X-Forwarded-Proto` selbst.
- Der Schlüssel in `./keys/famio.key` verschlüsselt Datenbank und Dateien –
  getrennt von `./data` sichern!
