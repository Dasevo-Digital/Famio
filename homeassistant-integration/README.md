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

Tipp: In Famio ein eigenes Mitglied „Home Assistant“ anlegen. Was es sehen
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

## Sicherheit

- Anmeldung wie eine App: Das Passwort wird nicht gespeichert, nur das
  Sitzungs-Token.
- Eigenes Zertifikat: Wie die Apps pinnt die Integration den Schlüssel des
  Servers (SHA-256 des öffentlichen Schlüssels). Erneuert der Server sein
  Zertifikat mit demselben Schlüssel, geht es ohne Rückfrage weiter; ein
  anderer Schlüssel wird abgelehnt.
- Mit gültigem Zertifikat (z. B. Let's Encrypt über Nginx Proxy Manager)
  prüft Home Assistant ganz normal.
