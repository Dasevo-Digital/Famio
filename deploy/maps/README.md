# Eigene Karten mit Martin und PMTiles/MBTiles

**Optional.** Ohne eigenen Kartenserver lädt Famio die Karte von
OpenStreetMap; für die meisten Familien reicht das. Famio kann den
öffentlichen OSM-Kachelserver durch eine eigene HTTPS-XYZ-URL
ersetzen, etwa damit Kartenabrufe (IP-Adresse und sichtbarer Ausschnitt)
im eigenen Netz bleiben. Martin ist dafür als **optionaler Compose-Profile-Service** direkt
in die Docker-Installation integriert. Er startet weder beim normalen
`docker compose up -d` noch durch die Famio-App. Die Kartenarchive bleiben auf
dem eigenen Rechner; Martin erkennt neue oder ersetzte Dateien automatisch.

## Start

1. Rechtlich zulässige `*.pmtiles` oder `*.mbtiles` nach `map-tiles/` im
   Famio-Docker-Ordner legen.
   Die Datei ist bewusst nicht Bestandteil dieses Repositories.
2. Im Repository `docker compose --profile maps up -d` ausführen. Der
   Martin-Container hört dann nur auf `127.0.0.1:3000`.
3. Im bestehenden HTTPS-Reverse-Proxy einen ausschließlich internen Host oder
   Pfad auf `127.0.0.1:3000` weiterleiten. Nicht direkt an Port 3000 ins
   Internet veröffentlichen.
4. Im Martin-Katalog (`https://karten.example.org/catalog`) die Quellen und
   ihre TileJSON-Adresse prüfen. In Famio unter **Server-Verwaltung →
   Einstellungen → Eigener Martin-Server** die genaue XYZ-URL einer
   Rasterquelle eintragen, beispielsweise
   `https://karten.example.org/tiles/basemap/{z}/{x}/{y}`.

Für die Vorlage unter `deploy/npm/` ist der gleiche Service verfügbar:
`cd deploy/npm && docker compose --profile maps up -d`. Martin teilt dort das
NPM-Netz und wird im Proxy als `martin:3000` eingetragen. Nicht beide Compose-
Vorlagen gleichzeitig verwenden, weil sie denselben Container-Namen nutzen.

Martin liefert Vektor-, Raster- und TileJSON-Quellen, zeichnet aber selbst
keine Kartenbilder. Famio zeigt **Rasterkacheln** (PNG, JPEG oder WebP) über
`flutter_map` an. Das Archiv muss deshalb Rasterkacheln enthalten; ein
Vektor-Archiv (MVT, etwa ein Protomaps-Auszug) ergibt in Famio eine leere
Karte. Rasterarchive sind groß: für ein ganzes Land bis zur Straßenebene
Hunderte GB, für die eigene Region deutlich weniger. Eine spätere Umstellung
der App auf Vektor-Darstellung (MapLibre-Styles) käme ohne Wechsel des
Kartenbetriebs aus, weil Martin dieselben Archive und Style-Endpunkte
weiterliefert.

## Betrieb und Datenschutz

- Für das Karten-Subdomain ein gültiges HTTPS-Zertifikat verwenden. Famio
  akzeptiert absichtlich keine HTTP-Kacheladresse.
- Die Karten-URL enthält keine Familien- oder Standortdaten. Dennoch verrät
  jede Kachelanfrage ungefähr den sichtbaren Kartenausschnitt; ein eigener
  Martin-Server hält diese Information im eigenen Netz.
- Archivquellen und Styles haben eigene Lizenzen. Attribution im Style und in
  der App darf nicht entfernt werden.
- Martin `1.16.1` ist bewusst mit seinem OCI-Digest festgesetzt. Updates zuerst
  in einer Testumgebung prüfen und Version/Digest anschließend kontrolliert
  anheben. Für einen separaten Proxmox-LXC hinter NPM folgt
  [LXC-NPM.md](LXC-NPM.md) einer vollständig geprüften Installation.
