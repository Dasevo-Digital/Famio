# Famio mit Nginx Proxy Manager

Mit HTTPS von außen erreichbar funktionieren die Apps auch unterwegs, und
Google Kalender und iCloud können die Famio-Kalender abonnieren.

## 1. Famio starten

| Betrieb | Ziel für NPM | `FAMIO_TRUST_PROXY` |
|---|---|---|
| Docker im selben Netz wie NPM ([docker-compose.yml](docker-compose.yml)) | `famio` : `8765` | `true` |
| Docker mit veröffentlichtem Port (Standard-`docker-compose.yml`) | `<Host-IP>` : `8765` | nur wenn Port 8765 sonst nicht erreichbar ist |
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

Über den Proxy verlangt Famio für das allererste Konto einen
**Einrichtungscode**, damit niemand einen frisch veröffentlichten Server
übernehmen kann:

```sh
docker logs famio        # bzw. journalctl -u famio im LXC
```

Im Heimnetz direkt auf Port 8765 ist kein Code nötig.

## 4. Prüfen

```sh
curl https://famio.example.de/api/health          # Version, 200
curl -I http://famio.example.de/                  # 301 auf https (Force SSL)
curl https://famio.example.de/ | grep url         # zeigt https://famio.example.de
```

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
  Benutzer, bis zu 1 Stunde). Hinter NPM braucht es dafür
  `FAMIO_TRUST_PROXY=true`, sonst sähe Famio nur die IP von NPM.
- `FAMIO_TRUST_PROXY` nur setzen, wenn Port 8765 **nicht** direkt erreichbar
  ist – sonst könnten Clients ihre Adresse fälschen.
- Private Dokumente, Einzelchats und deren Dateien liefert der Server nur an
  berechtigte Mitglieder aus.
- `FAMIO_REQUIRE_TLS=true` (in der Vorlage gesetzt): Unverschlüsselte
  Anfragen aus dem Netz werden abgelehnt; erlaubt sind nur NPM (HTTPS) und
  Famios eigenes HTTPS auf Port 8766. NPM setzt `X-Forwarded-Proto` selbst.
- Der Schlüssel in `./keys/famio.key` verschlüsselt Datenbank und Dateien –
  getrennt von `./data` sichern!
