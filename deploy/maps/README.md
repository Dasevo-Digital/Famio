# Eigene Karten mit Martin und PMTiles/MBTiles

Famio kann den öffentlichen OSM-Kachelserver durch eine eigene HTTPS-XYZ-URL
ersetzen. Martin ist dafür als **optionaler Compose-Profile-Service** direkt
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

Martin liefert Vektor-, Raster- und TileJSON-Quellen. Famio nutzt heute die
kompatible XYZ-Ausgabe von `flutter_map`; die PMTiles/MBTiles- und
Reverse-Proxy-Grenze ist damit bereits produktiv. Die spätere UI-Umstellung
auf MapLibre-Vector-Styles kann ohne erneuten Wechsel des Kartenbetriebs
erfolgen, weil Martin dieselben Archive und Style-Endpunkte weiterliefert.

## Betrieb und Datenschutz

- Für das Karten-Subdomain ein gültiges HTTPS-Zertifikat verwenden. Famio
  akzeptiert absichtlich keine HTTP-Kacheladresse.
- Die Karten-URL enthält keine Familien- oder Standortdaten. Dennoch verrät
  jede Kachelanfrage ungefähr den sichtbaren Kartenausschnitt; ein eigener
  Martin-Server hält diese Information im eigenen Netz.
- Archivquellen und Styles haben eigene Lizenzen. Attribution im Style und in
  der App darf nicht entfernt werden.
- Martin `1.16.1` ist bewusst festgesetzt. Updates zuerst in einer Testumgebung
  prüfen und Version/Hash anschließend kontrolliert anheben.
