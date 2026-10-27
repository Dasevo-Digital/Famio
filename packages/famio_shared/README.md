# famio_shared

Gemeinsamer Kern von Famio-Server und -App, in reinem Dart (ohne Flutter).
Was hier steht, gilt auf beiden Seiten gleich.

## Inhalt

- **Sync-Protokoll:** `SyncRecord`, `SyncRequest`/`SyncResponse` und
  `Collections` mit den Lese- und Schreibrechten je Rolle (Erwachsene,
  Kinder, Gäste, Dienstkonten).
- **Datenmodelle** der Module unter `lib/src/models/` (Termine, Aufgaben,
  Einkauf, Abwesenheiten, Kinder, Medikamente usw.). Regeln, die App und
  Server gleich anwenden müssen, stehen beim Modell, etwa welche
  Abwesenheit bei Überschneidungen gilt (`absenceFor`).
- **Kataloge** unter `lib/src/catalog/`: Feiertage, Vorsorge- und
  Impftermine, Meilensteine, Wachstumskurven, Einkaufskategorien.
- **Querschnitt:** Server-Texte auf Englisch und Spanisch (`lib/src/i18n/`),
  Zertifikats-Pins (`tls_pin.dart`), Versionsvergleich und die Prüfung der
  Release-Signatur (`release_signature.dart`, Ed25519 über
  `SHA256SUMS.txt`).

## Verwendung

Das Paket wird nicht auf pub.dev veröffentlicht. Server, App und
`famio_client` binden es per Pfad ein:

```yaml
dependencies:
  famio_shared:
    path: ../packages/famio_shared
```

```dart
import 'package:famio_shared/famio_shared.dart';
```

## Prüfen

```sh
dart analyze --fatal-infos
dart test
```

`dart run tool/verify_release.dart <release-ordner>` prüft Prüfsummen und
Signatur eines Release-Ordners so, wie es die Apps vor einem Update tun.

## Lizenz

Wie das ganze Repository: [PolyForm Strict License 1.0.0](../../LICENSE).
Aufbau und Abläufe beschreibt die [README im Hauptverzeichnis](../../README.md).
