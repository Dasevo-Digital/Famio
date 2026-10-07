# Famio für Home Assistant (Integration)

Verbindet Home Assistant mit einem Famio-Server – egal ob er im
Proxmox-Container, in Docker oder als Famio-Add-on läuft – und zeigt, was ein
Famio-Mitglied sieht:

| Entität | Inhalt |
|---|---|
| Kalender | Alle Termine inkl. Serien und geteilter Kalender (Google, iCloud, Abos). Termine anlegen und löschen (keine Serien). Vertrauliche Termine nur als „Belegt“. |
| To-do „Aufgaben“ | Aufgaben: anlegen, abhaken, Fälligkeit, Notiz |
| To-do „Einkauf <Liste>“ | Jede Einkaufsliste: Artikel hinzufügen, abhaken (Menge als Beschreibung) |
| Sensoren „Offene Aufgaben“, „Meine Aufgaben“, „Einkauf offen“ | Anzahl, Titel als Attribute |
| Sensor „Nächster Termin“ | Beginn des nächsten Termins, Titel/Ort als Attribute |
| Tracker je Mitglied | Standort der Mitglieder, die ihn in Famio teilen (Akku, Famio-Ort, Pause) |
| **Gerät je Mitglied** („Famio Lena“, ab 0.20.0) | To-do „Aufgaben“ (die dem Mitglied zugewiesenen; neue werden ihm zugewiesen), Kalender (seine Termine), Sensoren „Offene Aufgaben“ (mit Überfälligen), „Nächster Termin“, „Punkte“ |

Änderungen kommen live über die WebSocket-Verbindung des Servers an (ohne
Verbindung alle 5 Minuten).

## Installation

1. Den Ordner `custom_components/famio` nach `/config/custom_components/famio`
   kopieren (z. B. mit dem Samba- oder „Studio Code Server“-Add-on).
2. Home Assistant neu starten.
3. Einstellungen → Geräte & Dienste → Integration hinzufügen → **Famio**.
4. Server-Adresse (z. B. `192.168.1.50` – dann HTTPS auf Port 8766 – oder
   `https://famio.example.de`), Benutzername und Passwort eingeben.
5. Beim eigenen Zertifikat des Servers den angezeigten Fingerabdruck mit dem
   Server-Log vergleichen (`journalctl -u famio` im Container bzw.
   `docker logs famio`) und bestätigen.

Tipp: In Famio ein eigenes Mitglied „Home Assistant“ mit der Rolle
**Dienstkonto** anlegen (ab 0.19.0) – es erscheint dann nicht in Chats,
Standorten und Auswahllisten der Familie. Was es sehen
darf, steuern Sichtbarkeit und Kalender-Profil (Server-Verwaltung → Mitglied
→ Kalender) – Home Assistant bekommt nur diese Daten. Die Sitzung erscheint in
Famio unter den Geräten als „Home Assistant“ und lässt sich dort beenden;
dann fragt Home Assistant nach dem Passwort.

**Zwei-Faktor-Anmeldung:** Nutzt das Mitglied einen zweiten Faktor (oder ist er
in der Server-Verwaltung Pflicht), fragt die Einrichtung nach dem Passwort
einmal den 6-stelligen Code aus der Authenticator-App ab (ein
Wiederherstellungscode geht auch). Danach bleibt Home Assistant angemeldet;
einen neuen Code braucht es erst, wenn die Sitzung in Famio beendet wird.
Ist der zweite Faktor Pflicht, aber noch nicht eingerichtet: einmal in einer
Famio-App mit diesem Mitglied anmelden und ihn dort einrichten.

## Familien-Dashboard

Die Aktion **Famio: Dashboard erstellen** (`famio.dashboard`) baut aus den
Entitäten ein fertiges Dashboard: Familienkalender, je Person nächster
Termin, offene Aufgaben (bei Kindern Punkte) und Aufgabenliste, die
Einkaufslisten und eine Karte der geteilten Standorte.

1. Entwicklerwerkzeuge → Aktionen → „Famio: Dashboard erstellen“ →
   **Aktion ausführen**; die Antwort enthält unter `yaml` das Dashboard.
2. Einstellungen → Dashboards → Dashboard hinzufügen → „Neues Dashboard von
   Grund auf“ → öffnen → ✏️ → ⋮ → **Raw-Konfigurationseditor** → den Inhalt
   von `yaml` einfügen → Speichern.

Was das Dashboard zeigt, bestimmt das verbundene Famio-Konto: Nur für
bestimmte Personen freigegebene Einträge bleiben verborgen.

## Notruf und Check-in in Automationen

Drückt jemand in Famio den Notfallknopf, feuert die Integration das Ereignis
`famio_sos` (Daten: `member`, `member_id`, `state` = `active`/`coming`/
`resolved`, `latitude`, `longitude`, `coming`), und je Person ist der
Binärsensor „Notruf (SOS)“ an, bis der Notfall beendet ist. Ein Check-in
(„Bin angekommen“, „Alles ok“ …) feuert `famio_checkin` (`member`, `text`,
`place`). Beispiel: bei einem Notruf alle Lichter rot blinken lassen.

```yaml
automation:
  - alias: Famio-Notruf
    triggers:
      - trigger: event
        event_type: famio_sos
        event_data:
          state: active
    actions:
      - action: light.turn_on
        target:
          area_id: wohnzimmer
        data:
          color_name: red
          flash: long
      - action: notify.notify
        data:
          message: "SOS von {{ trigger.event.data.member }}!"
```

Ereignisse kommen nur für frische Notrufe und Check-ins (höchstens 30 Minuten
alt), nicht für alte Einträge beim ersten Abgleich.

## Dienstkonto und Schreibrechte

Am besten verbindet sich Home Assistant mit einem eigenen Mitglied mit der
Rolle **Dienstkonto** (Famio → Server-Verwaltung → Mitglied → Rolle). Es
taucht dann nicht in Chats, Standorten und Auswahllisten der Familie auf.
Unter „Darf ändern“ lässt sich einschränken, was Home Assistant ändern darf –
der Server setzt das durch, die Entitäten passen sich an:

| Einstellung | Home Assistant darf |
|---|---|
| Lesen und ändern | alles wie ein Erwachsener |
| Abhaken und Einkauf | Aufgaben abhaken, Einkaufslisten führen – keine Termine, keine neuen Aufgaben |
| Nur lesen | nichts ändern (am sichersten) |

Nach einer Änderung die Integration neu laden (⋮ → Neu laden).

## Sicherheit

- Anmeldung wie eine App: Das Passwort wird nicht gespeichert, nur das
  Sitzungs-Token.
- Eigenes Zertifikat: Wie die Apps pinnt die Integration den Schlüssel des
  Servers (SHA-256 des öffentlichen Schlüssels). Erneuert der Server sein
  Zertifikat mit demselben Schlüssel, geht es ohne Rückfrage weiter; ein
  anderer Schlüssel wird abgelehnt.
- Mit gültigem Zertifikat (z. B. Let's Encrypt über Nginx Proxy Manager)
  prüft Home Assistant ganz normal.
