# Famio

Famio ist der Familien-Organizer für Home Assistant. Das Add-on ist der
Server, mit dem sich die Famio-Apps (Android, macOS, Windows, Linux)
synchronisieren.

## Einrichtung

1. Add-on starten und in der Seitenleiste **Famio** öffnen. Du wirst mit
   deinem Home-Assistant-Benutzer automatisch angemeldet; der erste Benutzer
   wird Administrator.
2. Dort ein Passwort für die App festlegen.
3. In der App die angezeigte Server-Adresse (z. B.
   `http://homeassistant.local:8765`) eintragen und mit Benutzername und
   Passwort anmelden.

Weitere Familienmitglieder öffnen Famio einfach ebenfalls über die
Seitenleiste, oder ein Administrator legt sie in der App unter
*Einstellungen → Familie* an.

## Optionen

- `ingress_auth` – Home-Assistant-Benutzer über die Seitenleiste automatisch
  anmelden (Standard: an).

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
Add-on-Protokoll vergleichen). Port 8765 ist unverschlüsselt. Für den Zugriff außerhalb des
Heimnetzes einen Reverse-Proxy mit HTTPS (z. B. das NGINX- oder
Cloudflared-Add-on) oder ein VPN verwenden – Port 8765 nicht ungeschützt ins
Internet freigeben.

## Kalender-Apps und Standort

- **CalDAV:** Apple Kalender, Thunderbird oder DAVx⁵ verbinden sich direkt
  mit Port 8766 (`https://<Home-Assistant-IP>:8766/dav/`) oder über den
  Reverse-Proxy – nicht über die Seitenleiste. App-Passwörter gibt es in
  der App unter Einstellungen → Kalender verbinden; für Mac und iPhone
  erstellt „Apple-Gerät einrichten“ ein fertiges Profil.
- **Standort:** Geteilt wird mit der Android-App. Den Eltern-Code zum
  Pausieren legt ein Administrator in der App unter Einstellungen →
  Server-Verwaltung fest.

