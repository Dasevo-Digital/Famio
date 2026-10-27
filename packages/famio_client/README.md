# famio_client

Client-Kern der Famio-Apps in reinem Dart: Server-Anbindung, verschlüsselte
lokale Datenbank und Synchronisierung. Die Flutter-App baut darauf auf; weil
nichts davon Flutter braucht, laufen die Tests Ende-zu-Ende gegen einen
echten Famio-Server im selben Prozess.

## Inhalt

- **`FamioApiClient`:** HTTP-Zugriff auf den Server mit Zertifikats-Pinning,
  Anmeldung (Passwort, Zwei-Faktor, Passkey, SSO, Gerätekopplung), Dateien
  und WebSocket für Änderungsmeldungen.
- **`LocalStore`:** die Daten der Familie offline in SQLite, auf Geräten mit
  einem Schlüssel aus dem sicheren Speicher verschlüsselt.
- **`SyncEngine`:** gleicht lokale Änderungen mit dem Server ab, auch nach
  langer Offline-Zeit, und meldet den Apps, welche Bereiche sich geändert
  haben.
- **Dazu:** Dateicache, Erinnerungsplanung und die Texte des Clients.

## Verwendung

Das Paket wird nicht auf pub.dev veröffentlicht; die App bindet es per Pfad
ein (`path: ../packages/famio_client`). Es exportiert auch
`famio_shared`:

```dart
import 'package:famio_client/famio_client.dart';
```

## Prüfen

```sh
dart analyze --fatal-infos
dart test        # startet dafür den Server aus ../../server
```

## Lizenz

Wie das ganze Repository: [PolyForm Strict License 1.0.0](../../LICENSE).
Aufbau und Abläufe beschreibt die [README im Hauptverzeichnis](../../README.md).
