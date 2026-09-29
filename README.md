# Famio

Familien-Organizer mit eigenem Sync-Server. Die App läuft auf Android, iOS,
macOS, Windows und Linux sowie im Browser (`<server>/app/`) und in der
Seitenleiste von Home Assistant; der Server läuft als Home-Assistant-Add-on
oder eigenständig (Docker, Proxmox-LXC).

| Modul | Stand |
|---|---|
| Start-Übersicht (Familien-Dashboard) | ✅ |
| Aufgaben (fällig, zuständig, Erinnerung) | ✅ |
| Einkaufslisten | ✅ |
| Kalender mit Wiederholungen, Erinnerungen, Google/Apple-Abos | ✅ |
| CalDAV: Kalender-Apps bearbeiten Famio-Termine; Abgleich mit Google, iCloud & Co. | ✅ |
| Standort: Familienkarte, Orte mit Benachrichtigung, 7-Tage-Verlauf | ✅ (Teilen: Android, iOS) |
| Familienchat + Einzelchats mit Fotos und Dateien | ✅ |
| Dokumente mit Sichtbarkeit pro Dokument und Ablauf-Erinnerung | ✅ |
| Kinder: Meilensteine, U1–J2 und STIKO-Impfungen abhaken, Erinnerungen, WHO-Wachstumskurven | ✅ |
| Baby-Protokoll: Stillen, Fläschchen, Schlaf, Windeln, Fieber, Medikamente mit Timern und Diagrammen | ✅ |
| Notfall-Seite pro Kind (offline) und Familienkontakte | ✅ |
| Geburtstage (Mitglieder, Kinder, Kontakte) im Kalender mit Erinnerung | ✅ |
| Wetter & Kleidungstipps pro Kind (Open-Meteo, opt-in) | ✅ |
| Schwangerschaft: SSW, Termine, Checklisten, Wehen-Timer | ✅ |
| Essen: Rezepte (Import von Webseiten), Wochenplan, Zutaten auf die Einkaufsliste | ✅ |
| Finanzen: Haushaltsbuch mit Limits, nur für ausgewählte Mitglieder | ✅ |
| Stundenplan pro Schulkind | ✅ |
| Ämter mit Punkten und Rotation, Belohnungen, Taschengeld-Konto | ✅ |
| Routinen für Kinder (Morgen/Abend-Checklisten mit Bildern) | ✅ |
| Rollen: Erwachsen, Kind, Gast (Großeltern/Babysitter mit eingeschränkter Sicht) | ✅ |
| Eigene Push-Benachrichtigungen ohne ntfy/Google (Android auch bei geschlossener App), alternativ über ntfy | ✅ |
| Wandanzeige fürs Küchen-Tablet | ✅ |
| Kommentare an Terminen, Umfragen im Chat, Listen-Vorlagen (Packlisten) | ✅ |
| Vorrat mit Barcode-Scanner (Open Food Facts) und MHD-Erinnerung | ✅ (Scanner: Android, iOS, macOS) |
| Medikamentenplan mit Erinnerung und Vorrat | ✅ |
| Widget für den Startbildschirm | ✅ Android (iOS: braucht bezahlten Apple-Entwickler-Account) |
| Web-App im Browser und in der Home-Assistant-Seitenleiste (Add-on als Server oder nur als Client) | ✅ |
| Multi-Device-Sync, offlinefähig, Rechte pro Datensatz | ✅ |

## Aufbau

```
packages/famio_shared   Datenmodelle + Sync-Protokoll (reines Dart, Server & App)
packages/famio_client   API-Client, lokale SQLite-DB, Sync-Engine (reines Dart)
server/                 Sync-Server (shelf, SQLite, WebSocket)
app/                    Flutter-App
homeassistant-addon/    Home-Assistant-Add-on (config.yaml, DOCS.md)
Dockerfile              Server-Image (standalone und Add-on)
```

### Sync

Alle Daten sind generische Datensätze (`SyncRecord`: Sammlung, ID, JSON-Daten,
Zeitstempel, Lösch-Markierung). Neue Module brauchen deshalb keine neuen
Server-Endpunkte, nur einen Eintrag in `Collections` und ein Modell.

1. Jede Änderung landet sofort in der lokalen SQLite-DB der App (offline nutzbar)
   und wird als „dirty“ markiert.
2. `POST /api/sync` schickt lokale Änderungen und holt alles seit der letzten
   bekannten Server-Revision – in einem Aufruf, seitenweise.
3. Konflikte: pro Datensatz gewinnt die spätere Änderung (last-writer-wins).
   Die App korrigiert ihre Uhr mit der Serverzeit; der Server kappt Zeitstempel
   aus der Zukunft.
4. Über eine WebSocket-Verbindung (`/api/ws`) erfahren die anderen Geräte
   sofort von neuen Revisionen; zusätzlich wird jede Minute synchronisiert.

Kennt ein älterer Server eine Sammlung noch nicht, überspringt er sie und
meldet sie zurück; die App behält diese Änderungen lokal, bis der Server
aktualisiert ist. App und Server lassen sich so unabhängig aktualisieren.

Einkaufs-Artikel sind eigene Datensätze, damit zwei Personen gleichzeitig
verschiedene Artikel abhaken können, ohne sich zu überschreiben.

### Kalender und Erinnerungen

Serien werden nicht als Einzeltermine gespeichert, sondern als Regel
(`Recurrence`) plus Ausnahmen und erst beim Anzeigen in lokaler Zeit
aufgelöst – ein wöchentlicher Termin um 19:00 bleibt auch nach der
Zeitumstellung um 19:00. „Nur diesen Termin ändern“ trägt eine Ausnahme in die
Serie ein und legt einen Einzeltermin an.

Erinnerungen plant jedes Gerät selbst für die nächsten 14 Tage (Termine, an
denen man teilnimmt, und eigene bzw. nicht zugewiesene Aufgaben):

| Plattform | Verhalten |
|---|---|
| Android, macOS, Windows | System-Benachrichtigung, auch bei geschlossener App |
| Linux | nur solange die App läuft (kein geplantes Anzeigen unter Linux) |

### Google Kalender, Apple Kalender & Co.

Der Abgleich läuft über ICS-Abo-Links, ohne Passwörter oder Google-Cloud-Projekt:

- **Famio → andere Kalender:** Jedes Mitglied erzeugt in der App
  (Kalender → ⇄) private Links unter `/ical/<token>.ics` – mit allen Terminen
  oder nur den eigenen. Serien werden als `RRULE` mit `TZID` exportiert.
  Apple Kalender lädt den Link vom Gerät aus, wenn das Abo lokal liegt (Mac:
  Ort „Auf meinem Mac“; iPhone: Einstellungen → Kalender) – das klappt im
  Heimnetz. **Google Kalender und iCloud-Abos laden von fremden Servern**,
  dafür muss Famio per HTTPS aus dem Internet erreichbar sein und
  `FAMIO_PUBLIC_URL` gesetzt werden (sonst: „Anfrage fehlgeschlagen“).
- **Andere Kalender → Famio:** ICS-Adressen (Google „Privatadresse im
  iCal-Format“, iCloud „Öffentlicher Kalender“, Schul-/Vereinskalender)
  werden als Abo gespeichert. Der Server ruft sie alle 30 Minuten ab (mit
  ETag), löst Serien inkl. `BYDAY`, `EXDATE` und verschobener Einzeltermine
  für −90 bis +400 Tage auf und verteilt sie als schreibgeschützte Datensätze
  (`external_events`) über den normalen Sync.
- **Wer sieht verbundene Kalender?** Abos und CalDAV-/Google-Verbindungen
  gehören dem Mitglied, das sie angelegt hat; nur es kann sie ändern oder
  entfernen. Es teilt sie mit der ganzen Familie, ausgewählten Mitgliedern
  oder niemandem (`sharedWith`). Admins können im **Kalender-Profil** eines
  Mitglieds (Server-Verwaltung → Mitglied → Kalender) geteilte Kalender
  ausblenden (`GET/PUT /api/admin/users/<id>/calendars`). Der Server setzt
  daraus `visibleTo` der importierten Termine; ausgeblendete Termine gelangen
  nie auf die Geräte des Mitglieds. Abos von vor 0.12 gehören der Familie.

### CalDAV (Zwei-Wege)

- **Kalender-Apps → Famio (CalDAV-Server):** Unter `/dav/` (Discovery über
  `/.well-known/caldav`) sieht jedes Mitglied einen Kalender „Famio“ mit den
  Terminen, die es sehen darf. Apple Kalender (Mac, iPhone), Thunderbird und
  DAVx⁵ können Termine anlegen, ändern und löschen; unterstützt werden
  PROPFIND, `calendar-query`, `calendar-multiget` und `sync-collection`.
  Anmeldung mit Benutzername und einem **App-Passwort pro Gerät**
  (Einstellungen → Kalender verbinden); das Famio-Passwort funktioniert dort
  bewusst nicht. Vertrauliche Termine sieht eine Kalender-App nur, wenn es
  beim App-Passwort erlaubt wurde. Teilnehmer und Sichtbarkeit aus Famio
  bleiben beim Bearbeiten erhalten.
  Für Mac, iPhone und iPad erstellt die App ein **Profil**
  („Apple-Gerät einrichten“) mit eigenem App-Passwort und der
  Zertifizierungsstelle des Servers: Apple Kalender sendet Passwörter nur
  über HTTPS und verlangt ein Zertifikat, das den Hostnamen nennt und
  höchstens 825 Tage gilt. Der Server erneuert sein Zertifikat deshalb
  selbst (gleicher Schlüssel) und nimmt die im Profil verwendete Adresse
  auf; weitere Namen über `FAMIO_TLS_NAMES`.
- **Famio ↔ iCloud, Nextcloud & Co. (CalDAV-Client):** Der Server gleicht
  alle 15 Minuten und nach jeder Änderung mit einem Kalender dort ab (ETag,
  CTag). Famio-Termine gehen hin (ohne vertrauliche), Termine von dort
  kommen in Famio an und sind dort bearbeitbar; haben beide Seiten geändert,
  gewinnt die neuere Änderung. Termine, die Famio nicht exakt abbilden kann
  (z. B. „jeden 2. Dienstag“, einzeln verschobene Serientermine), erscheinen
  schreibgeschützt, damit beim Zurückschreiben nichts verloren geht. Das
  Passwort (bei iCloud ein app-spezifisches) liegt nur verschlüsselt auf dem
  Server.
- **Google Kalender** spricht CalDAV nur mit OAuth. Dafür legt man einmalig
  in der Google Cloud Console ein eigenes Projekt mit OAuth-Client vom Typ
  „Desktop-App“ an (Google Calendar API und CalDAV API aktivieren,
  Veröffentlichungsstatus „In Produktion“). Die App meldet sich damit im
  Browser an (PKCE, Rücksprung auf `127.0.0.1`), der Server tauscht den Code
  gegen ein Refresh-Token und erneuert das Zugriffstoken selbst. Termine,
  die Google unter eigener Adresse ablegt, erkennt Famio an ihrer UID.

### Standort

Die Android-App teilt den Standort über einen Vordergrund-Dienst (sichtbare
Benachrichtigung), auch bei geschlossener App und nach einem Neustart; er
nutzt den stromsparenden Fused-Provider (bei ausgeschalteter
Netzwerk-Ortung GPS). Unter iOS übernimmt das Core Location im Hintergrund
(blaue Standortanzeige); nach dem Schließen startet iOS die App bei
größeren Ortswechseln selbst wieder. iPhones melden nur bei Bewegung, daher
gilt ein iPhone erst nach 12 Stunden Stille als „keine Verbindung“. Beide
melden sich mit einem eigenen Token, das nur Positionen melden kann. Der Server hält die letzte Position pro Mitglied als
Datensatz (`member_locations`), erkennt Ankunft und Verlassen von Orten
(`places`, mit Toleranz gegen GPS-Sprünge) und schreibt Hinweise
(`location_alerts`) für die Mitglieder, die sie abonniert haben. Positionen
werden nach **7 Tagen gelöscht**; den Verlauf sehen nur Eltern
(Administratoren) und das Mitglied selbst.

Pausieren und Beenden – auch Abmelden auf einem teilenden Handy – geht nur
mit dem **Eltern-Code** (Einstellungen → Server-Verwaltung → Einstellungen).
Technisch verhindern lässt sich das Abschalten auf einem Handy nicht (App
deinstallieren, Berechtigung entziehen); Famio zeigt den Eltern aber an,
wenn ein Handy keine Positionen mehr schickt, die Berechtigung fehlt oder
GPS aus ist. Kartenkacheln kommen von OpenStreetMap oder von einem eigenen
Kachelserver (Server-Verwaltung → Einstellungen → Kartenserver).

### Rollen

Neben der Admin-Rolle hat jedes Mitglied eine Rolle, die der Server bei
jedem Sync durchsetzt:

- **Erwachsen:** alles, was für das Mitglied sichtbar ist.
- **Kind:** darf Ämter, Belohnungen, Routinen und Taschengeld nicht
  verwalten; erledigte Ämter und Belohnungswünsche sind Anfragen, die ein
  Erwachsener bestätigt.
- **Gast:** bekommt nur Kalender, Termin-Kommentare, Chat, Einkauf,
  Aufgaben, Essen, Kontakte, Ämter und Vorrat; schreiben darf er nur Chat,
  Einkaufsartikel, Aufgaben, Kommentare und Umfrage-Stimmen. Standort und
  Kalender-Verbindungen sind für Gäste gesperrt.

### Push-Benachrichtigungen

**Direkt über Famio (ohne ntfy, ohne Google):** Der Server legt jede
Benachrichtigung drei Tage lang für die betroffenen Mitglieder ab
(`notices`-Tabelle in der verschlüsselten Datenbank). Geräte holen sie mit
`GET /api/notifications?after=<id>&wait=<s>`; der Server hält die Anfrage
offen (höchstens 300 s), bis etwas Neues kommt (Long-Polling).

- Android: Ein Vordergrund-Dienst (`NotifyService`, Typ `remoteMessaging`)
  holt sie mit einem eigenen Token, das nur Benachrichtigungen lesen kann
  (`POST /api/notifications/device-token`) – auch bei geschlossener App und
  nach einem Neustart. Der Sperrbildschirm zeigt nur den kurzen Hinweis.
- macOS, Windows, Linux: Die laufende App fragt ebenso ab und zeigt Neues,
  wenn sie nicht im Vordergrund ist (standardmäßig an).
- iPhone: Ohne Apples Push-Dienst (kostenpflichtiges Entwicklerkonto) nur bei
  offener App – dort bleibt ntfy der Weg.

Pro Gerät lässt sich einstellen, ob Namen und Texte angezeigt werden.

**Alternativ über ntfy:** Jedes Mitglied kann in den Einstellungen Geräte mit einem ntfy-Thema
eintragen (`https://ntfy.sh/<geheimer-name>` oder ein eigener ntfy-Server,
optional mit Token). Der Server meldet dort neue Nachrichten, zugewiesene
Aufgaben, Termin-Kommentare, Ämter-Anfragen und Ortsmeldungen. Ohne
„Details“ enthält die Meldung nur einen Hinweis wie „Neue Nachricht“ –
Namen und Inhalte verlassen den Server dann nicht.

### Sichtbarkeit und Dateien

Datensätze können ein Feld `visibleTo` (Mitglieds-IDs) tragen. Der Server
liefert sie nur an diese Mitglieder aus, lehnt Schreibzugriffe anderer
stillschweigend ab und schickt Mitgliedern, denen die Sicht entzogen wird,
eine Löschmarke. Einzelchats und private Dokumente nutzen das. Dateien
(`POST /api/files`) darf laden, wer sie hochgeladen hat oder einen sichtbaren
Datensatz sieht, der sie referenziert – so schützt die Sichtbarkeit eines
Dokuments auch seine Datei. Vorschaubilder erzeugt der Server; unbenutzte
Uploads werden nach 24 Stunden gelöscht.

### Anmeldung

Eigene Konten mit Passwort (PBKDF2) und Session-Token. Beim ersten Start legt
die App das Admin-Konto an. Im Home-Assistant-Add-on werden HA-Benutzer, die
Famio über die Seitenleiste (Ingress) öffnen, automatisch angelegt und können
dort ein Passwort für die App setzen. Die Ingress-Header werden nur von der
Supervisor-Adresse `172.30.32.2` akzeptiert.

**Zwei-Faktor-Anmeldung (TOTP):** Unter Einstellungen → Anmeldung & Sicherheit
richtet jedes Mitglied eine Authenticator-App ein (QR-Code, RFC 6238, 30 s,
6 Stellen) und bekommt 10 Wiederherstellungscodes, die je einmal gelten. Ein
Code gilt nur einmal (auch nicht innerhalb seiner 30 Sekunden erneut),
Fehlversuche werden wie Passwörter gedrosselt. Ausschalten braucht Passwort und
Code. In der Server-Verwaltung lässt sich die Zwei-Faktor-Anmeldung **für
Administratoren oder alle** verlangen: Betroffene sehen dann nur die
Einrichtung bzw. eine Code-Abfrage, bis sie erledigt ist. Administratoren können
sie für ein Mitglied zurücksetzen (Handy verloren). CalDAV-App-Passwörter und
die Standort-Tokens der Handys sind davon nicht betroffen. Die
Home-Assistant-Integration fragt den Code bei der Einrichtung einmal ab und
bleibt dann angemeldet.

**Single Sign-On (OpenID Connect):** Server-Verwaltung → Einstellungen →
Single Sign-On: Anbieter-Adresse (Issuer), Client-ID und -Secret eintragen,
beim Anbieter die angezeigte Weiterleitungs-Adresse
(`https://<öffentliche Adresse>/api/auth/sso/callback`) registrieren. Geht mit
Authentik, Keycloak, Authelia, Zitadel, Google, Microsoft Entra u. a.; braucht
die öffentliche Adresse. Mitglieder verknüpfen ihr Konto einmal unter
Anmeldung & Sicherheit (oder, wenn eingeschaltet, über gleiche Benutzernamen)
und melden sich dann mit „Mit … anmelden“ an: Die App öffnet den Browser und
wartet, bis die Anmeldung dort fertig ist – ohne App-Links, auf allen
Plattformen. Famio ist vertraulicher Client (Code-Austausch mit Secret und
PKCE, `state`, `nonce`; Aussteller, Empfänger und Ablauf des ID-Tokens werden
geprüft). Eine SSO-Anmeldung erfüllt auch die Zwei-Faktor-Pflicht – die
übernimmt dann der Anbieter.

### Sicherheit und Datenschutz

Famio speichert auch Gesundheitsdaten (Vorsorge, Impfungen, Wachstum,
Dokumente). Umgesetzt ist:

| Bereich | Schutz |
|---|---|
| Transport | HTTPS ist auch im Heimnetz Standard (Port 8766 mit eigener Zertifizierungsstelle); die App pinnt nach Bestätigung des Fingerabdrucks den Schlüssel des Servers; Klartext-API aus dem Netz ist standardmäßig gesperrt (`FAMIO_REQUIRE_TLS`); HSTS hinter dem Proxy; Token nur im `Authorization`-Header |
| Anmeldung | PBKDF2-SHA256 mit 310 000 Runden (im eigenen Isolate), Drosselung bei Fehlversuchen, Einrichtungscode für den ersten Admin auch im Heimnetz; optional Zwei-Faktor (TOTP, auf Wunsch Pflicht) und Single Sign-On per OpenID Connect |
| Sitzungen | Nur gehasht gespeichert, Ablauf nach 90 Tagen Inaktivität, Geräte einzeln abmeldbar, Passwortänderung meldet andere Geräte ab |
| Zugriff | Sichtbarkeit pro Datensatz serverseitig (`visibleTo`), gilt auch für Admins und Dateien; Kinderdaten (inkl. Protokoll, Notfalldaten, Schwangerschaft) nur für Sorgeberechtigte; Wetter nur nach Zustimmung mit gerundeten Koordinaten |
| Browser | Uploads nie als HTML/SVG ausgeliefert (`attachment`, CSP `sandbox`), CSRF-Schutz über `application/json`, `nosniff`, `no-store` |
| Server | Datenbank und Dateien verschlüsselt (SQLite3MultipleCiphers, ChaCha20-Poly1305), Schlüssel getrennt von den Daten (`FAMIO_KEY_FILE`); nur für den Famio-Benutzer lesbar (umask 077), redigiertes Request-Log, Audit-Log, Größenlimits |
| Betrieb | Docker read-only ohne Capabilities; systemd-Sandbox (`systemd-analyze security`: 3.0 OK) |
| Geräte | Lokale Datenbank und Dateicache verschlüsselt, Schlüssel und Anmeldung im Schlüsselbund des Systems (Keychain, Android Keystore, Windows DPAPI, KWallet/GNOME); beim Abmelden gelöscht; Android ohne Cloud-Backup, Sperrbildschirm ohne Inhalt |
| Kalender-Abos | Termine lassen sich als *vertraulich* markieren (nie im Abo, nie bei iCloud & Co.); Abos auf Wunsch nur als „Belegt“ ohne Details |
| CalDAV | Eigenes App-Passwort pro Kalender-App (80 Bit, einzeln widerrufbar, Drosselung), Passwörter für iCloud & Co. nur verschlüsselt auf dem Server |
| Standort | Nur nach Einschalten auf dem eigenen Handy, dauerhaft sichtbare Benachrichtigung; Token des Handys kann nur Positionen melden; Verlauf 7 Tage, nur für Eltern und die Person selbst; Pausieren nur mit Eltern-Code |

Bewusst offen bzw. Aufgabe des Betriebs:

- **Schlüssel sichern:** Ohne `famio.key` sind Datenbank und Dateien
  nicht lesbar – die Datei getrennt von den Daten sichern (z. B. im
  Passwortmanager). Fehlt sie, startet der Server bewusst nicht, statt
  leer neu anzufangen. Im Home-Assistant-Add-on liegt sie in `/data`;
  dort die Backups mit Passwort verschlüsseln (HA-Standard).
- **Unverschlüsseltes HTTP** (Port 8765) dient nur Loopback, Healthcheck und
  vertrauenswürdigen HTTPS-Proxys. Die API lehnt Klartext aus dem Netz
  standardmäßig ab. Nur für eine befristete Migration alter Clients kann
  `FAMIO_REQUIRE_TLS=false` gesetzt werden.
- **Kalender-Feeds** sind geheime Links; wer den Link hat, sieht die
  Termine. Google/Apple speichern die abonnierten Termine – vertrauliche
  Termine sind nie enthalten.
- **Geöffnete Dokumente:** Zum Anzeigen in einer anderen App (PDF-Viewer)
  entsteht kurz eine unverschlüsselte Kopie im Temp-Ordner; sie wird beim
  nächsten Start gelöscht.
- **Kartenkacheln** lädt die App standardmäßig von OpenStreetMap; die
  OSM-Server sehen dabei IP-Adresse und Kartenausschnitt, nicht aber, wer
  wo ist. Mit eigenem Kachelserver bleibt auch das im Haus.
- **Administratoren** können Passwörter zurücksetzen und sich so Zugang
  verschaffen – das steht im Audit-Log (`docker logs famio | grep audit`).

### Server-Verwaltung

Administratoren verwalten den Server aus jeder angemeldeten App heraus
(Einstellungen → Server-Verwaltung, API unter `/api/admin/…`):

- **Benutzer:** anlegen, Name/Benutzername/Farbe ändern, Admin-Rolle vergeben
  (mindestens ein Admin bleibt immer), Passwort zurücksetzen (meldet die
  Geräte des Mitglieds ab), einzelne Geräte oder alle abmelden, entfernen.
- **Einstellungen:** öffentliche Adresse, Zeitzone und maximale Dateigröße
  gelten sofort und überschreiben die Umgebungsvariablen bzw. Add-on-Optionen;
  ein leeres Feld stellt den Standard wieder her. `FAMIO_TRUST_PROXY` und die
  Home-Assistant-Anmeldung bleiben bewusst nur auf dem Host änderbar.
- **Zurücksetzen** (unten in den Einstellungen):
  - *Einstellungen auf Standard* entfernt alle in der App gesetzten Werte;
    Daten, Mitglieder und Eltern-Code bleiben.
  - *Alle Daten löschen* entfernt Termine, Chats, Listen, Aufgaben, Ämter,
    Dokumente, Fotos, Kinder- und Gesundheitsdaten, Standorte, verbundene
    Kalender (die fremden Kalender bei iCloud & Co. bleiben unberührt) und
    Kalender-Links – auf dem Server und beim nächsten Abgleich auf allen
    Geräten, auch was dort offline geändert wurde. Konten, Einstellungen und
    Zertifikat bleiben; auf Wunsch werden auch alle anderen Mitglieder
    entfernt. Braucht das eigene Passwort und die Eingabe „LÖSCHEN“, steht im
    Audit-Log und lässt sich nicht rückgängig machen – vorher den
    Datenordner sichern.
- **Status:** Version, Laufzeit, Datenbank- und Dateigröße, Einträge,
  angemeldete und gerade verbundene Geräte.

Jedes Mitglied kann außerdem sein Profil (Name, Farbe) ändern und unter
„Meine Geräte“ sehen, wo es angemeldet ist.

App-Icons für alle Plattformen erzeugt `python3 app/tool/make_icons.py`.

## Entwicklung

```sh
# Server lokal (Port 8765, Daten in server/data)
cd server && dart run bin/server.dart

# App
cd app && flutter run -d macos     # oder windows, linux, <android-gerät>

# Tests
(cd packages/famio_shared && dart test)
(cd packages/famio_client && dart test)   # Ende-zu-Ende gegen echten Server
(cd server && dart test)
(cd app && flutter test)
```

In der App als Server-Adresse z. B. `localhost` eintragen (Port 8765 wird
ergänzt). Vom Android-Emulator aus ist der Rechner unter `10.0.2.2` erreichbar.

### Produktiv- und Entwicklungsumgebung auf einem Mac

| | Produktiv | Entwicklung |
|---|---|---|
| App | „Famio“ (`de.status403.famio`) | „Famio Dev“ (`de.status403.famio.dev`, DEV-Band im Icon und in der App) |
| Installation | `app/tool/mac_install.sh prod [version]` – nur aus einem freigegebenen Release-Ordner | `app/tool/mac_install.sh dev` – baut die Arbeitskopie |
| Server | Docker-Image mit fester Version, Ports 8765/8766 | aus dem Repository gebaut (`docker compose up -d --build`), Ports 8775/8776 |

Beide Apps haben getrennte Daten, Schlüsselbund-Einträge und Server. Auf Android
gibt es dieselbe Trennung als Build-Variante: `flutter build apk --flavor prod`
(Famio) bzw. `--flavor dev` („Famio Dev“, `de.status403.famio.dev`); Tests
auf einem Gerät mit echter Famio nur über `app/tool/android_dev_test.sh`.
Release-APKs werden mit einem eigenen Schlüssel signiert, wenn
`~/Famio/keys/android/key.properties` (oder `FAMIO_SIGNING`) existiert. Der
Build-Ordner heißt `build.noindex` (mit `build` als Verweis), damit Spotlight
nur die beiden installierten Apps findet. Ende-zu-Ende-Tests laufen in der
Dev-Variante, z. B.:

```sh
FLUTTER_XCODE_FAMIO_APP_NAME="Famio Dev" \
FLUTTER_XCODE_FAMIO_BUNDLE_ID=de.status403.famio.dev \
FLUTTER_XCODE_FAMIO_APP_ICON=AppIconDev \
flutter drive --profile -d macos --driver test_driver/integration_test.dart \
  --target integration_test/admin_flow_test.dart --dart-define=FAMIO_ENV=dev \
  --dart-define=FAMIO_URL=localhost:8775 --dart-define=FAMIO_PASSWORD=…
```

## Betrieb

| Variante | Anleitung |
|---|---|
| Docker (NAS, Server) | `docker compose up -d` im Repository, Daten in `./data` |
| Docker hinter **Nginx Proxy Manager** | [deploy/npm/README.md](deploy/npm/README.md) |
| **Proxmox-LXC** (empfohlen: Debian 13), auch Umzug von Docker | [deploy/lxc/README.md](deploy/lxc/README.md) – `proxmox-create.sh` |
| Home-Assistant-**Add-on** (Seitenleiste; als Server oder als Client eines vorhandenen Servers) | [homeassistant-addon/famio/DOCS.md](homeassistant-addon/famio/DOCS.md) – lokal: `homeassistant-addon/local/` |
| Home-Assistant-**Integration** (Client: Kalender, To-dos, Sensoren, Standorte) | [homeassistant-integration/README.md](homeassistant-integration/README.md) |
| **LXC** (Proxmox) ohne Docker, systemd | [deploy/lxc/README.md](deploy/lxc/README.md) |

| Variable | Bedeutung |
|---|---|
| `TZ` / `FAMIO_TIMEZONE` | Zeitzone der Familie (Standard `Europe/Berlin`) |
| `FAMIO_PUBLIC_URL` | Öffentliche HTTPS-Adresse (für Google/iCloud-Kalenderabos) |
| `FAMIO_TRUST_PROXY` | Client-IP aus `X-Forwarded-For` (nur hinter Reverse-Proxy) |
| `FAMIO_MAX_UPLOAD_MB` | Maximale Dateigröße (Standard 100) |
| `FAMIO_MAX_STORAGE_MB` | Gesamtes Upload-Speicherbudget der Familie in MB (Standard 5120) |
| `FAMIO_ALLOW_PRIVATE_CALENDAR_HOSTS` | Private/HTTP-ICS- und CalDAV-Ziele erlauben (Standard `false`; nur für bewusst lokal betriebene Kalender) |
| `FAMIO_PORT`, `FAMIO_DATA_DIR` | Port (8765) und Datenverzeichnis |
| `FAMIO_REQUIRE_TLS` | Klartext-API aus dem Netz sperren (Standard `true`; `false` nur befristet für alte Clients) |
| `FAMIO_TLS_NAMES` | Zusätzliche Hostnamen/IP-Adressen für das HTTPS-Zertifikat (Port 8766), z. B. `192.168.1.5,famio.fritz.box` |
| `FAMIO_WEB_DIR` | Ordner der Web-App (Standard: `web/` neben `bin/` im Server-Paket) |

**Web-App:** Jeder Server liefert die App unter `/app/` aus (gebaut mit
`app/tool/build_web.sh`, landet in `server/web` und damit in allen
Server-Paketen). Im Browser gilt die normale Anmeldung inkl. Zwei-Faktor; die
Sitzung bleibt nur im geöffneten Tab (nichts im Browser gespeichert). In der
Home-Assistant-Seitenleiste meldet das Add-on an: als Server über den
Home-Assistant-Benutzer, als Client (`mode: client`) mit dem Famio-Konto,
dessen Sitzung das Add-on je Home-Assistant-Benutzer aufbewahrt.

Beim ersten Start ohne Konto schreibt der Server einen **Einrichtungscode**
ins Log. Er wird bei jeder Ersteinrichtung verlangt, auch direkt im Heimnetz,
damit kein anderes Gerät den frisch gestarteten Server übernehmen kann.

Prüfen einer Installation (arm64/amd64, Docker, LXC, hinter NPM):

```sh
cd packages/famio_client
dart run tool/smoke_test.dart <server-url> <benutzer> <passwort> [ics-url]
```

Server-Binaries für LXC baut `.github/workflows/server-release.yml` bei jedem
Tag `v*`; Docker-Images für das Add-on `.github/workflows/server-image.yml`.
Vorher den Platzhalter `YOUR_GITHUB_USER` ersetzen.
