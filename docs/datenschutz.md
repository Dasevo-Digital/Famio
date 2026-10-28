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
- Einzelne gelöschte Aufgaben, Termine, Notizen und Dokumente werden mit ihren
  Anhängen bis zu 30 Tage im serverseitigen Papierkorb aufbewahrt. Mitglieder
  sehen nur Löschstände, die sie nach ihren aktuellen Rechten noch sehen dürfen;
  die Wiederherstellung benötigt außerdem Schreibrechte. Nach Ablauf sind sie
  nicht mehr abrufbar und werden bei der regelmäßigen Bereinigung entfernt.
  Ein vollständiges administratives Löschen der Familiendaten leert auch den
  Papierkorb. Löschmarkierungen für den Geräteabgleich, Konfliktkopien und
  Sicherungen sind davon getrennt.
- Bei ausdrücklich angeforderter Bestätigung einer Zuständigkeit werden die
  Rückmeldung, die zuständige Person und der Bezug zur konkreten Aufgabe oder
  Fahrt gespeichert. Sie sind nur für die berechtigten Betrachter des
  zugehörigen Eintrags sichtbar. Erinnerungen an offene Zusagen sind optional
  und folgen den vorhandenen Push- und Ruhezeiteinstellungen.
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
ableiten. Die Web-App schickt dabei zusätzlich die Adresse des Famio-Servers
(ohne Pfad) als Referer mit, weil OpenStreetMap Browser-Anfragen ohne Referer
ablehnt. Ein eigener Kartenserver hält diesen Abruf im eigenen Betrieb.

**Schriften der Web-App.** Emojis und Schriftzeichen anderer Sprachen lädt die
Web-App vom eigenen Famio-Server, nicht von Google. Für chinesische,
japanische und koreanische Zeichen holt der Server die passende Schriftdatei
einmal bei Google Fonts und hält sie danach selbst vor; Google sieht dabei
nur die Adresse des Servers, nicht die der Familie.

**Open-Meteo.** Wetter ist pro Gerät opt-in. Übertragen werden auf 0,01 Grad
gerundete Koordinaten des gewählten Orts sowie die technisch notwendige
IP-Adresse.

**Text- und Barcode-Erkennung (Android).** Termine aus Fotos und der
Barcode-Scanner werten die Bilder auf dem Handy aus; Bilder verlassen das
Handy dafür nicht. Im kleinen Paket für 64-Bit-Handys kommen die
Erkennungsmodelle von den Google-Play-Diensten, die sie beim ersten Gebrauch
einmal herunterladen; dabei sieht Google die Anfrage des Handys wie bei jedem
anderen Download aus Google Play. Wer das nicht möchte, schaltet unter
Einstellungen → „Erkennung ohne Google Play“ das Paket mit eingebauten
Modellen ein. Der Dokumentenscanner kommt immer von den Google-Play-Diensten.

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

**Versionsprüfung.** Nur wenn ein Administrator in der Server-Verwaltung „Nach
neuer Version suchen“ antippt, fragt seine App die öffentliche Release-Liste
des Projekts bei GitHub ab. Dabei werden keine Famio-Daten übertragen; GitHub
sieht die IP-Adresse des Geräts. Wird zusätzlich die Updateverteilung über den
Famio-Server ausdrücklich aktiviert, ruft der Server die Release-Liste und die
zugehörigen Installationsdateien bei GitHub ab. Unvollständige Downloads werden
im Hintergrund erneut versucht. Dabei sehen GitHub und seine Downloadserver die
IP-Adresse des Famio-Servers; Famio-Inhalte werden nicht übertragen. Ohne diese
Aktivierung führt der Server diese Abfragen nicht durch.

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
