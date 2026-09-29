# Famio

Famio ist der Familien-Organizer für Home Assistant. In der Seitenleiste
läuft die ganze Famio-App – Startseite, Kalender, Aufgaben, Einkauf, Chat,
Kinder, Wandanzeige und mehr.

Das Add-on hat zwei Betriebsarten (Option `mode`):

- **server** (Standard): Das Add-on *ist* der Famio-Server. Die Daten liegen
  in Home Assistant, die Famio-Apps (Android, iPhone, macOS, Windows, Linux)
  synchronisieren sich mit ihm.
- **client**: Euer Famio-Server läuft schon woanders (z. B. Proxmox, Docker,
  NAS). Das Add-on zeigt nur die Seitenleiste und verbindet sich mit ihm.

## Betriebsart „client“

1. Optionen: `mode: client`, `server_url` = Adresse eures Famio-Servers,
   z. B. `https://famio.example.de`. Für einen Server im Heimnetz mit
   eigenem Zertifikat (Port 8766) zusätzlich `server_fingerprint` aus dem
   Server-Log eintragen.
2. Add-on starten, in der Seitenleiste **Famio** öffnen.
3. Einmal mit dem eigenen Famio-Konto anmelden (bei Zwei-Faktor-Anmeldung
   mit Code). Jeder Home-Assistant-Benutzer meldet sich mit seinem eigenen
   Famio-Konto an; das Add-on merkt sich die Anmeldung – im Browser wird
   nichts gespeichert.
4. Die Sitzung steht in Famio unter *Meine Geräte* als „Home Assistant
   (Name)“ und lässt sich dort beenden; *Einstellungen → Abmelden* in der
   Seitenleiste geht auch.

## Betriebsart „server“: Einrichtung

1. Add-on starten und in der Seitenleiste **Famio** öffnen. Du wirst mit
   deinem Home-Assistant-Benutzer automatisch angemeldet; der erste Benutzer
   wird Administrator.
2. Für die Apps: in der Seitenleiste *Einstellungen → Famio-Apps verbinden*
   – dort ein Passwort festlegen.
3. In der App die angezeigte Server-Adresse (z. B.
   `http://homeassistant.local:8765`) eintragen und mit Benutzername und
   Passwort anmelden.

Weitere Familienmitglieder öffnen Famio einfach ebenfalls über die
Seitenleiste, oder ein Administrator legt sie in der App unter
*Einstellungen → Familie* an.

## Optionen

- `mode` – `server` oder `client` (siehe oben).
- `ingress_auth` – nur `server`: Home-Assistant-Benutzer über die
  Seitenleiste automatisch anmelden (Standard: an).
- `server_url`, `server_fingerprint` – nur `client`: euer Famio-Server.

## Zugriff von unterwegs (Nginx Proxy Manager)

Mit dem Add-on „Nginx Proxy Manager“ einen Proxy Host auf
`<Home-Assistant-IP>:8765` anlegen, **Websockets Support** einschalten und ein
Let's-Encrypt-Zertifikat anfordern. Details: `deploy/npm/README.md` im
Repository.

## Verschlüsselung

Datenbank und Dateien sind verschlüsselt. Der Schlüssel liegt im Add-on unter
`/data/famio.key` und ist damit Teil der Home-Assistant-Backups – diese
deshalb mit Passwort verschlüsseln (Standard in Home Assistant).

## Hinweise zum Zugriff

Die Apps sprechen den Server im Heimnetz verschlüsselt über Port 8766 an
(eigenes Zertifikat; beim ersten Verbinden den Fingerabdruck aus dem
Add-on-Protokoll vergleichen). Port 8765 dient dem Home-Assistant-Ingress;
direkte unverschlüsselte API-Anfragen aus dem Netz werden abgelehnt. Für den
Zugriff außerhalb des Heimnetzes einen Reverse-Proxy mit HTTPS (z. B. das
NGINX- oder Cloudflared-Add-on) oder ein VPN verwenden.

## Kalender-Apps und Standort

- **CalDAV:** Apple Kalender, Thunderbird oder DAVx⁵ verbinden sich direkt
  mit Port 8766 (`https://<Home-Assistant-IP>:8766/dav/`) oder über den
  Reverse-Proxy – nicht über die Seitenleiste. App-Passwörter gibt es in
  der App unter Einstellungen → Kalender verbinden; für Mac und iPhone
  erstellt „Apple-Gerät einrichten“ ein fertiges Profil.
- **Standort:** Geteilt wird mit der Android-App. Den Eltern-Code zum
  Pausieren legt ein Administrator in der App unter Einstellungen →
  Server-Verwaltung fest.
