# Changelog

## 0.17.1 – Kleidung für die Nacht, ruhigere Startseite

- **Wetter & Kleidung: für die Nacht.** Ab 17 Uhr zeigt die Kachel, worin die
  Kinder schlafen (Schlafanzug, Schlafsack mit TOG-Wert, Decke) – nach der
  Tiefsttemperatur der Nacht. Die Details zeigen Tag und Nacht.
- **Startseite:** Kacheln einer Reihe sind gleich hoch, keine Lücken mehr;
  die Seitenleiste reicht über die ganze Höhe.

## 0.17.0 – Bereiche ein- und ausblenden

- **Nicht genutzte Bereiche ausblenden**, z. B. Finanzen, Essen oder Ämter:
  - Server-Verwaltung → Einstellungen → „Bereiche“.
  - Gilt für die ganze Familie und alle Apps: Menü, Startseite und
    Wandanzeige.
  - Die Daten bleiben erhalten und sind nach dem Einschalten wieder da.
  - Start und Einstellungen bleiben immer.
- iOS: Famio-Symbol statt des Flutter-Standardsymbols.

## 0.16.0 – Eigene Benachrichtigungen, stärkerer Kontrast

- **Benachrichtigungen direkt über Famio**, ohne ntfy und ohne Google:
  - Einstellungen → Benachrichtigungen → „Direkt über Famio“.
  - Android: Auch bei geschlossener App und nach einem Neustart. Die App
    hält dafür eine Verbindung zu deinem Server; Android zeigt dazu dezent
    „Famio ist bereit“ an.
  - Mac, Windows, Linux: Solange Famio läuft.
  - Pro Gerät „Inhalte anzeigen“ an oder aus; der Android-Sperrbildschirm
    zeigt nie Inhalte.
  - ntfy bleibt als Alternative, etwa fürs iPhone.
- **Hoher Kontrast verstärkt:** Text jetzt mindestens 7:1 (WCAG AAA), dazu
  sichtbare Ränder um Karten, Reiter und Knöpfe.
- Server: Ein Termin für ein nicht mehr vorhandenes Mitglied kann den Sync
  nicht mehr stören.

## 0.15.2 – Hoher Kontrast

- **Neuer Schalter „Hoher Kontrast“** unter Einstellungen → Dieses Gerät:
  - Kräftigere Bereichsfarben und dunklere Schrift statt Pastell; jeder
    Text erreicht mindestens 4,5:1 (WCAG AA).
  - Im Dunkelmodus werden die Farben aufgehellt, die Schrift auf farbigen
    Flächen wird dunkel.
  - Die Einstellung gilt pro Gerät.
  - Ist „Kontrast erhöhen“ im Betriebssystem an (iOS, macOS), ist er
    automatisch aktiv.
- Ohne Schalter bleibt der Pastell-Look unverändert.

## 0.15.1 – Feinschliff: Akku, Sicherheit, Bedienbarkeit

- **Weniger Akku und Datenverkehr:**
  - Solange die Live-Verbindung steht, gleicht die App nur noch alle
    10 Minuten zur Sicherheit ab statt jede Minute.
  - Beim Öffnen der App wird sofort abgeglichen.
  - Das Baby-Protokoll baut bei laufendem Schlaf- oder Still-Timer nur
    noch die Stoppuhr sekündlich neu auf.
  - Vorschaubilder werden nicht mehr bei jedem Neuaufbau erneut geladen
    und dekodiert.
- **Server:**
  - Weniger Schreibzugriffe: Sitzungen werden höchstens einmal pro Minute
    aktualisiert, SQLite läuft mit `synchronous=NORMAL`.
  - Große Anfragen brauchen ein Achtel des Speichers.
  - Kein `X-Powered-By` mehr.
  - Strengere Content-Security-Policy für die Startseite (Skript per
    Hash) und die SSO-Seiten, dazu eine Permissions-Policy.
  - Fehlermeldungen verraten keine Server-Interna mehr.
- **Bedienbarkeit:**
  - Grauer Nebentext mit ausreichendem Kontrast (WCAG AA).
  - Runde Knöpfe und Abhak-Kreise mit mindestens 48 × 48 Tippfläche.
  - Abhak-Kreise nennen dem Screenreader, was abgehakt wird.
  - Untertitel dürfen zweizeilig sein, z. B. das Geburtsdatum.

## 0.15.0 – Zwei-Faktor & Single Sign-On

- **Zwei-Faktor-Anmeldung:** Einstellungen → Anmeldung & Sicherheit:
  Authenticator-App per QR-Code einrichten, 10 Wiederherstellungscodes. Beim
  Anmelden fragt Famio dann nach dem Code.
- **Pflicht per Server-Verwaltung** für Administratoren oder alle; Admins
  können die Zwei-Faktor-Anmeldung eines Mitglieds zurücksetzen.
- **Single Sign-On (OpenID Connect):** Anmelden mit Authentik, Keycloak,
  Authelia, Google, Microsoft & Co. – „Mit … anmelden“ auf dem
  Anmeldebildschirm, Konto einmal in den Einstellungen verknüpfen.
- Home-Assistant-Integration: klare Meldung bei Konten mit Zwei-Faktor.

## 0.14.3

- Startseite des Servers: zeigt hinter einem Reverse-Proxy (z. B. Nginx Proxy
  Manager) bzw. mit gesetzter öffentlicher Adresse die richtige
  https-Adresse statt „http://…:8765“; ohne Proxy den HTTPS-Port 8766.

## 0.14.2

- Einstellungen → „Über Famio“ zeigt die Version der App und des Servers.

## 0.14.1

- Passwortfelder: Rechtsklick (bzw. langes Drücken) bietet „Einfügen“,
  z. B. aus dem Passwortmanager. Kopieren bleibt gesperrt.

## 0.14.0 – Zurücksetzen

- **Server-Verwaltung → Einstellungen → Zurücksetzen:**
  - *Einstellungen auf Standard:* öffentliche Adresse, Zeitzone,
    Dateigröße und Kartenserver wieder aus der Server-Konfiguration.
  - *Alle Daten löschen:* alle Inhalte der Familie auf dem Server und allen
    Geräten, auf Wunsch auch alle anderen Mitglieder. Mit Passwort und
    Bestätigung „LÖSCHEN“; verbundene Kalender bei iCloud & Co. bleiben
    unberührt.

## 0.13.0 – Ämter, Routinen, Push und mehr

- **Ämter & Punkte:** Haushaltsaufgaben mit Emoji und Punkten – täglich, an
  bestimmten Wochentagen, wöchentlich oder einmalig; auf Wunsch reihum
  („heute ist Lena dran“). Kinder haken ab, Erwachsene bestätigen.
- **Belohnungen & Taschengeld:** Punkte gegen Belohnungen eintauschen
  (Kinder wünschen, Eltern bestätigen); Taschengeld-Konto mit wöchentlicher
  automatischer Buchung, Ausgaben, Geschenken und Punkte-Umtausch.
- **Routinen für Kinder:** Morgen- und Abend-Checklisten mit großen Bildern,
  Erinnerung und Punkten fürs Fertigwerden.
- **Rollen:** Erwachsen, Kind oder **Gast** (Großeltern, Babysitter): Gäste
  sehen nur Kalender, Chat, Einkauf, Aufgaben, Essen und Kontakte – keine
  Dokumente, Gesundheitsdaten, Finanzen oder Standorte. Der Server setzt das
  durch.
- **Push-Benachrichtigungen über ntfy:** Nachrichten, zugewiesene Aufgaben,
  Termin-Kommentare, Ämter-Anfragen und Ortsmeldungen auch bei
  geschlossener App. Ohne „Details“ verlässt nur „Neue Nachricht“ o. Ä. den
  Server.
- **Wandanzeige** fürs Küchen-Tablet: Uhr, Termine, Wetter, Ämter zum
  Abhaken, Einkauf und Essen – bleibt an, optional beim Start.
- **Kommentare an Terminen** und **Umfragen im Chat**.
- **Vorlagen für Listen:** Packlisten (Urlaub, Kita, Kliniktasche …) oder
  eigene Listen als Vorlage speichern; „Alle Haken entfernen“.
- **Vorrat mit Barcode-Scanner:** Kühlschrank, Tiefkühler, Vorratsschrank;
  Produktnamen aus Open Food Facts, Mindesthaltbarkeit mit Erinnerung,
  Knappes mit einem Tipp auf die Einkaufsliste.
- **Medikamente:** Einnahmeplan mit Erinnerungen, Abhaken, Vorrat und
  Nachkauf-Warnung; nur für ausgewählte Mitglieder sichtbar. Famio schlägt
  keine Dosierungen vor.
- Home Assistant: neuer Sensor „Punkte“.
- „Mehr“-Menü auf dem Handy kompakter (alle Bereiche passen).

## 0.12.1 – Sicherheit und Feinschliff

- **Anmeldeschutz verschärft:** Fehlversuche zählen jetzt auch pro Adresse
  über alle Benutzernamen und pro Benutzer über alle Adressen. Eine Flut
  ausgedachter Namen kann bestehende Sperren nicht mehr aufheben.
- **Android:** Eigener Signaturschlüssel statt des Debug-Schlüssels
  (einmalig: alte App deinstallieren, neue installieren, neu anmelden).
- **Finanzen:** Symbole je Kategorie; Kategorien ohne Limit zeigen ihren
  Anteil an den Ausgaben.
- Große Bildschirme: Listen und Einstellungen bleiben lesbar schmal.
- Logo in der App wie das App-Symbol (Haus mit Herz).

## 0.12.0 – Eigene Kalender teilen, Kalender-Profile

- **Eigene Kalender teilen:** Wer einen Kalender verbindet (Google, iCloud,
  CalDAV oder ein ICS-Abo), bestimmt, wer die Termine sieht: die ganze
  Familie, ausgewählte Mitglieder oder nur man selbst – jederzeit änderbar.
  Nur wer den Kalender verbunden hat, kann ihn ändern oder entfernen.
- **Kalender-Profil pro Mitglied:** In der Server-Verwaltung legen Admins
  fest, welche geteilten Kalender ein Mitglied sieht (z. B. den
  Dienstplan nicht bei den Kindern). Ausgeblendete Termine gelangen gar
  nicht erst auf dessen Geräte.
- Behoben: Das Verbinden eines Google-Kalenders scheiterte, weil die App
  die Google-Anmeldung nicht an den Server weitergab.
- Bestehende Abos gehören weiter der ganzen Familie; bisherige
  „nur für mich“-Verbindungen bleiben privat.
- **Home-Assistant-Integration** (neu): Kalender, Aufgaben und
  Einkaufslisten als To-do-Listen, Sensoren und Standorte der Familie –
  verbindet sich mit jedem Famio-Server (LXC, Docker, Add-on).
- **Proxmox:** `proxmox-create.sh` legt einen Debian-Container mit Famio an
  und übernimmt auf Wunsch Daten und Schlüssel eines bestehenden Servers.
- **Server-Adresse ändern** (Einstellungen): nach einem Umzug des Servers
  ohne neue Anmeldung weiterarbeiten.
- Passwörter lassen sich beim Eingeben kurz anzeigen (Auge-Symbol).
- Neu im Server: `GET /api/calendar/occurrences` (Termine eines Zeitraums,
  Serien aufgelöst).

## 0.11.0 – Essen, Finanzen, Stundenplan und Widget

- **Essen:** Familienrezepte (selbst geschrieben oder von Chefkoch & Co.
  per Adresse übernommen), Portionsrechner, Wochenplan; Zutaten eines
  Rezepts oder der ganzen Woche mit einem Tipp auf die Einkaufsliste –
  gleiche Zutaten werden zusammengerechnet.
- **Finanzen:** Haushaltsbuch mit Einnahmen, Ausgaben, monatlichen Buchungen
  (Miete, Gehalt), Limits pro Kategorie; sichtbar nur für ausgewählte
  Mitglieder (serverseitig).
- **Stundenplan** pro Schulkind; die Startseite zeigt „Schule bis …“.
- **Android-Widget „Famio heute“:** Termine, Essen, Aufgaben, Einkauf.
- Startseite: Kacheln für Essen und Finanzen; Seitenleiste passt auf
  niedrige Bildschirme.

## 0.10.0 – Geburtstage, Wetter und Schwangerschaft

- **Geburtstage** von Familienmitgliedern (Profil), Kindern und Kontakten
  im Kalender, auf der Startseite und als Erinnerung (Vorabend und am Tag).
- **Wetter & Kleidung:** was die Kinder heute anziehen sollten – nach
  gefühlter Temperatur, Alter, Regen, Wind und UV. Wetter von Open-Meteo,
  nur nach Zustimmung pro Gerät; übertragen werden nur die auf ~1 km
  gerundeten Koordinaten des Orts „Zuhause“.
- **Schwangerschaft:** SSW und Größenvergleich, Termine nach
  Mutterschafts-Richtlinien und STIKO (Ultraschall, Zuckertest,
  Keuchhusten-Impfung …), Checklisten (Kliniktasche, Erstausstattung, nach
  der Geburt), Wehen-Timer mit 5-1-1-Hinweis, „Baby ist da!“ legt das Kind
  an. Nur für ausgewählte Mitglieder sichtbar.
- Kontakte: neue Arten Hebamme und Klinik.

## 0.9.0 – Baby-Protokoll, Notfall und Kontakte

- **Protokoll pro Kind:** Stillen (links/rechts mit Timer), Fläschchen,
  Beikost, Abpumpen, Schlaf (Timer), Windel, Temperatur, Medikament,
  Symptom, Baden – mit Tagessummen, 7-Tage-Diagramm, „zuletzt …“ und
  Erinnerung an die nächste Mahlzeit. Beide Eltern sehen alles sofort.
- **Fieber und Medikamente:** vorsichtige Hinweise je nach Alter (116 117,
  112), Mindestabstand zwischen Gaben mit Erinnerung; keine Dosierungen.
- **Vorsorge und Impfungen abhaken** direkt in Zeitstrahl, Kinderkarte und
  Liste („heute“, anderes Datum, „Datum unbekannt“), frühere gesammelt
  nachtragen, Messwerte bei der U eintragen, Foto vom U-Heft/Impfpass,
  Erinnerung zum Terminvereinbaren 4 Wochen vorher.
- **WHO-Wachstumskurven** (3./50./97. Perzentile, 0–24 Monate) für Größe,
  Gewicht und Kopfumfang.
- **Notfall-Seite pro Kind** (offline): 112, 116 117, Giftnotruf, 5 W-Fragen,
  Allergien, Vorerkrankungen, Gewicht, letzte Medikamente, Kinderarzt.
- **Kontakte:** Kinderarzt, Kita, Schule, Babysitter & Co. mit Anruf-Knopf.

## 0.8.1 – Apple Kalender per Profil

- „Apple-Gerät einrichten“ erstellt ein Profil für Mac, iPhone und iPad
  (CalDAV mit eigenem App-Passwort und dem Zertifikat des Servers).
- Eigenes HTTPS-Zertifikat nach Apples Regeln: kleine Zertifizierungsstelle,
  Hostnamen im Zertifikat, automatische Erneuerung mit gleichem Schlüssel.
  Die Apps prüfen jetzt den Schlüssel – **nach dem Update einmal den neuen
  Fingerabdruck bestätigen** (Hinweis oben in der App).
- `FAMIO_TLS_NAMES` für zusätzliche Hostnamen/IP-Adressen.

## 0.8.0 – Google Kalender und iPhone

- Google Kalender in beide Richtungen: eigener Google-Zugang (OAuth-Client
  „Desktop-App“), Anmeldung im Browser; der Server erneuert den Zugang selbst.
- iOS-App: alle Funktionen, Standort teilen auch im Hintergrund.
- Eigener Kartenserver statt OpenStreetMap einstellbar.
- Dialoge passen auf kleine Handys mit offener Tastatur; der Schlüsselbund
  wird nach einem Neustart nicht mehr übergangen (iOS/Android).

## 0.7.0 – CalDAV und Standort

- Kalender-Apps direkt verbinden (CalDAV-Server unter `/dav/`): Apple
  Kalender auf Mac und iPhone, Thunderbird oder DAVx⁵ auf Android zeigen
  die Famio-Termine und können sie bearbeiten. Anmeldung mit eigenem
  App-Passwort pro Gerät (Einstellungen → Kalender verbinden).
- Zwei-Wege-Abgleich mit iCloud, Nextcloud, mailbox.org, Posteo und
  anderen CalDAV-Kalendern; vertrauliche Termine werden nie übertragen.
  Termine, die Famio nicht genau abbilden kann, erscheinen schreibgeschützt.
- Wiederholungen an mehreren Wochentagen (z. B. Di + Do).
- Standort: Familienkarte, Orte mit Benachrichtigung bei Ankunft und
  Verlassen, Verlauf der letzten 7 Tage (danach automatisch gelöscht),
  „Wo ist wer?“ auf der Startseite. Geteilt wird mit der Android-App im
  Hintergrund; pausieren oder beenden nur mit dem Eltern-Code
  (Einstellungen → Server).

## 0.6.0 – Verschlüsselung

- Datenbank und Dateien werden verschlüsselt gespeichert (ChaCha20-Poly1305);
  vorhandene Daten werden beim ersten Start automatisch umgestellt.
  Schlüssel: `FAMIO_KEY_FILE` – getrennt von den Daten sichern!
- HTTPS im Heimnetz auf Port 8766 mit eigenem Zertifikat; die Apps prüfen
  den Fingerabdruck einmalig und merken sich das Zertifikat.
  `FAMIO_REQUIRE_TLS=true` sperrt unverschlüsseltes HTTP aus dem Netz.
- Apps: Anmeldung und Schlüssel im Schlüsselbund des Systems, lokale
  Datenbank und Dateicache verschlüsselt; „Jetzt verschlüsseln“ in den
  Einstellungen stellt bestehende Verbindungen auf HTTPS um.
- Kalender: Termine als „vertraulich“ markieren (nie in Abos), Abos auf
  Wunsch nur als „Belegt“.

## 0.5.1 – Sicherheitsupdate

Server und Apps bitte gemeinsam aktualisieren.

- Kinder: Entwicklung, Vorsorge, Impfungen und Fotos sehen nur die
  eingetragenen Sorgeberechtigten (serverseitig durchgesetzt).
- Hochgeladene Dateien können im Browser keinen Code mehr ausführen
  (Schutz vor Stored XSS, v. a. hinter Home Assistant Ingress).
- Schutz vor CSRF: JSON-Anfragen nur noch mit `application/json`.
- Anmelde-Token nur noch im Authorization-Header (auch beim WebSocket),
  nicht mehr in URLs und damit nicht in Proxy-Logs.
- Server-Log ohne Kalender-Tokens und Dateinamen; Audit-Log für
  Admin-Aktionen.
- Sitzungen laufen nach 90 Tagen Inaktivität ab; eigene Passwortänderung
  meldet alle anderen Geräte ab; Raten des aktuellen Passworts gedrosselt.
- Passwort-Hashing stärker (310 000 Runden) und ohne den Server zu
  blockieren; bestehende Passwörter werden beim Login umgestellt.
- Sicherheits-Header (nosniff, no-store, HSTS hinter HTTPS-Proxy),
  Größenlimit für Anfragen, Schutz vor Bild-„Dekompressionsbomben“.
- Daten auf dem Server nur für den Famio-Benutzer lesbar (umask 077);
  gehärtete Docker- und systemd-Konfiguration.
- Apps: unverschlüsselte Verbindungen über das Internet werden abgelehnt,
  Verbindungsstatus in den Einstellungen; Android ohne Cloud-Backup der
  Familiendaten, Sperrbildschirm ohne Erinnerungsinhalt.

## 0.5.0

- Server-Verwaltung in jeder App (für Administratoren): Mitglieder anlegen,
  bearbeiten, zu Admins machen, Passwort zurücksetzen, Geräte abmelden.
- Servereinstellungen zur Laufzeit ändern: öffentliche Adresse, Zeitzone,
  maximale Dateigröße (überschreiben die Add-on-Optionen/Umgebungsvariablen).
- Status-Übersicht: Speicherbedarf, Einträge, angemeldete Geräte.
- Eigenes Profil (Name, Farbe) und „Meine Geräte“ für alle Mitglieder.
- Neue App-Icons für macOS, Windows, Linux und Android (inkl. Themed Icon).

## 0.4.0

- Neues Design: kinderfreundlich in Pastellfarben, eigene Schrift und Icons.
- Start-Übersicht mit Terminen, Aufgaben, Einkauf, Chat, Kindern, Dokumenten.
- Familienchat und private Einzelchats mit Fotos und Dateien.
- Dokumente mit Sichtbarkeit pro Dokument und Erinnerung vor dem Ablauf.
- Kinder: Entwicklungs-Zeitstrahl mit Meilensteinen, U-Untersuchungen,
  STIKO-Impfungen, Erinnerungen mit Fotos und Wachstumskurven.
- Sicherheit für den Betrieb im Internet: Schutz vor Passwort-Raten,
  Einrichtungscode, serverseitige Zugriffsrechte pro Datensatz.

## 0.3.0

- Google Kalender, Apple Kalender & Outlook: private Abo-Links für die
  Famio-Termine (alle oder nur die eigenen, jederzeit widerrufbar).
- Externe Kalender (Google, iCloud, Schule, Verein …) per ICS-Adresse in
  Famio einblenden; der Server aktualisiert sie alle 30 Minuten.
- Zeitzone über `TZ`/`FAMIO_TIMEZONE`, öffentliche Adresse für Google über
  `FAMIO_PUBLIC_URL`.
- Docker-Image kleiner (Distroless, ~60 MB) und mit Healthcheck.

## 0.2.0

- Familienkalender: Termine mit Teilnehmern, ganztägig oder mit Uhrzeit,
  Wiederholungen (täglich bis jährlich, mit Enddatum und Ausnahmen).
- Erinnerungen für Termine und Aufgaben als Benachrichtigung auf den Geräten.
- Neuere Apps mit unbekannten Modulen blockieren den Sync nicht mehr.

## 0.1.0

- Erste Version: Aufgaben, Einkaufslisten, Familienmitglieder, Sync.
