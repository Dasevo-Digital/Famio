# Datenschutzinformationen für Famio

Stand: 30. September 2026 · Famio 1.0.0

## Verantwortlichkeit

Famio ist selbst gehostete Software. Es gibt keinen zentralen Famio-Dienst und
kein vom Projekt betriebenes Benutzerkonto. Verantwortlich für den konkreten
Betrieb, die angelegten Konten und die darin gespeicherten Daten ist die
Person oder Organisation, die den jeweiligen Famio-Server betreibt. Sie muss
den Mitgliedern eine erreichbare Kontaktstelle und, soweit erforderlich,
weitere rechtliche Pflichtinformationen mitteilen.

## Verarbeitete Daten

Je nach Nutzung speichert Famio insbesondere Konten und Sitzungen,
Familienbeziehungen, Kalender, Aufgaben, Listen, Nachrichten, Dokumente,
Fotos, Vorräte, Finanzangaben, Kinder- und Gesundheitsdaten sowie genaue
Standortverläufe. Der Server speichert außerdem ein Audit-Log über
sicherheitsrelevante Verwaltungsvorgänge. Welche Kategorien tatsächlich
verarbeitet werden, entscheidet die Familie beziehungsweise der Betreiber.

Serverdaten und Dateien sind verschlüsselt. Die Geräte halten eine ebenfalls
verschlüsselte lokale Datenbank und einen Dateicache für den Offlinebetrieb.
Administratoren können Konten und Passwörter verwalten und dadurch technisch
Zugang zu Familiendaten erlangen; entsprechende Vorgänge erscheinen im
Audit-Log.

## Aufbewahrung und Löschung

- Sitzungen laufen nach 90 Tagen Inaktivität ab und können je Gerät widerrufen
  werden.
- Der Standortverlauf ist auf 1 bis 365 Tage einstellbar; Standard sind sieben
  Tage.
- Beim Abmelden werden lokale Datenbank, Cache und Anmeldedaten des Geräts
  gelöscht.
- Administratoren können die Familiendaten serverseitig löschen. Diese
  Löschung wird beim nächsten Abgleich auf die Geräte übertragen.
- Sicherungen und Kopien in externen Kalender-, Cloud- oder Push-Diensten
  müssen beim jeweiligen Betreiber gesondert gelöscht werden.

## Netzwerkverbindungen und Empfänger

**Eigener Famio-Server.** App und Browser übertragen die zur Synchronisation
benötigten Familien-, Konto- und Gerätedaten an den vom Betreiber bestimmten
Server. HTTPS ist Standard. Ein öffentlicher Reverse-Proxy oder Hostinganbieter
kann technisch Verbindungsdaten verarbeiten.

**OpenStreetMap oder eigener Kartenserver.** Beim Öffnen der Karte werden
Kacheln für den betrachteten Ausschnitt geladen. Der Kartenanbieter erhält die
IP-Adresse und Kachelkoordinaten; daraus lässt sich der betrachtete Bereich
ableiten. Ein eigener Kartenserver hält diesen Abruf im eigenen Betrieb.

**Open-Meteo.** Wetter ist pro Gerät opt-in. Übertragen werden auf 0,01 Grad
gerundete Koordinaten des gewählten Orts sowie die technisch notwendige
IP-Adresse.

**Open Food Facts.** Eine Barcode-Suche überträgt den gescannten Barcode und
die technisch notwendige IP-Adresse an `world.openfoodfacts.org`.

**ntfy.** Nur nach Einrichtung. Der eingestellte ntfy-Server erhält das
geheime Thema, die IP-Adresse und mindestens einen knappen Hinweis. Wenn
„Details“ aktiviert ist, kann die eigentliche Benachrichtigung einschließlich
Namen oder Inhaltsauszügen übertragen werden.

**Kalenderdienste.** ICS-Abos, CalDAV und Google Calendar werden nur nach
Einrichtung verwendet. Dabei verlassen Termine beziehungsweise Zugangsdaten
den Famio-Server im für die Funktion erforderlichen Umfang. Als vertraulich
markierte Famio-Termine werden nicht in Kalenderabos veröffentlicht.

**Bring! und Microsoft To Do.** Nur wenn ein Mitglied sein Konto verbindet
und Listen zuordnet. Dann überträgt der Famio-Server die Einträge der
zugeordneten Listen (bei Aufgaben Titel, Notiz, Fälligkeit und Erledigt-
Status; bei Einkaufslisten Artikel, Menge und Abgehakt-Status) an Bring!
(Bring! Labs AG, Schweiz) beziehungsweise Microsoft (Microsoft Graph) und
holt Änderungen von dort ab. Gespeichert werden nur Anmelde-Token, nicht
das Passwort. Die Anbindung an Bring! nutzt eine nicht offiziell
dokumentierte Schnittstelle. Eine Familie kann die Funktion in der
Server-Verwaltung ganz abschalten; das Trennen eines Kontos löscht die
Token und Zuordnungen auf dem Famio-Server.

**OpenID Connect.** Bei aktivierter Anmeldung über einen Identitätsanbieter
werden Browser, Famio-Server und der konfigurierte Anbieter miteinander
verbunden. Der Anbieter verarbeitet die zur Anmeldung erforderlichen Konto-
und Verbindungsdaten.

**Eigene Push-Verbindung.** Famios direkte Push-Variante hält eine Verbindung
zwischen Gerät und eigenem Famio-Server und verwendet keinen fremden
Pushanbieter. Auf iOS ist Hintergrundzustellung ohne Apple Push eingeschränkt.

## Keine projektseitige Telemetrie

Famio enthält keine projektseitige Nutzungsanalyse, Werbung oder automatische
Absturzübermittlung. Vom Betreiber ergänzte Reverse-Proxys, Kalender-, Karten-,
Push- oder Identitätsdienste können eigene Protokolle führen.

## Export, Auskunft und Berichtigung

Jedes Mitglied kann unter Einstellungen → „Meine Daten exportieren“ selbst eine
ZIP-Datei mit allen Daten erstellen, die es in Famio sehen kann, einschließlich
seiner Dateien und seines Standortverlaufs (Passwort-Bestätigung). Ein
Administrator kann in der Server-Verwaltung die Daten der ganzen Familie
exportieren; Standortverläufe sind darin nicht enthalten. Die Datei wird auf
dem Server nur kurz für den Download angelegt und danach gelöscht. Für
Berichtigung und Löschung sowie weitere Auskünfte wenden sich Mitglieder an den
Betreiber ihres Famio-Servers. Das Famio-Projekt besitzt keinen Zugriff auf
eine selbst gehostete Installation und kann deren Inhalte weder lesen noch
löschen.
