# Datenschutzinformationen für Famio

Stand: 14. November 2026

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

Datenbank und Dateien des Servers sind verschlüsselt, ebenso seine nächtlichen
Sicherungen. Das Audit-Log schreibt der Server in das Protokoll des Systems
(etwa das Journal), dort gilt dessen Aufbewahrung. Die Geräte halten eine
ebenfalls verschlüsselte lokale Datenbank und einen Dateicache für den
Offlinebetrieb. Ihr Schlüssel bleibt im Schlüsselbund des Geräts; auf iPhone
und iPad sind beide von der Gerätesicherung ausgenommen. Unter Linux ohne
Schlüsselbund liegt der Schlüssel nach Zustimmung in den App-Einstellungen.

Unverschlüsselt auf dem Gerät bleiben:

- eine Kopie eines Dokuments, das jemand in einer anderen App öffnet; sie wird
  nach spätestens einer Stunde beim nächsten Aufräumen entfernt;
- Fotos und Dateien, die Kamera, Dateiauswahl und Scanner für Famio ablegen,
  bis das Betriebssystem den Zwischenspeicher der App leert;
- zwischengespeicherte Kartenkacheln, auf dem iPhone die Orte der Familie für
  Ortsmeldungen und die Koordinaten des Wetterorts;
- Texte angezeigter Mitteilungen, wenn „Inhalte anzeigen“ eingeschaltet ist;
  bei Erinnerungen an Medikamente und Kinder nennen sie Namen.

Gesundheitsdaten (Medikamente, Kinderdaten mit Notfallangaben und Protokoll,
Schwangerschaften und Dokumente der Kategorie Gesundheit) erhalten nur
Erwachsene und ausdrücklich ausgewählte Personen. Fotos an Einträgen des
Kinder-Protokolls, etwa von einem Ausschlag, folgen denselben Regeln. Dienstkonten, etwa für Home Assistant oder eine
Wandanzeige, erhalten sie nie, Kinderkonten nur, wenn sie ausgewählt sind.
Vertrauliche Termine sehen Gäste und Kinderkonten nur, wenn sie beteiligt sind;
Dienstkonten erfahren nur die belegte Zeit. Mitteilungen nennen sie ohne Titel.
Administratoren können Konten und Passwörter verwalten und dadurch technisch
Zugang zu Familiendaten erlangen; entsprechende Vorgänge erscheinen im
Audit-Log. Sie können außerdem den Standortverlauf jedes Mitglieds abrufen und
die Daten der ganzen Familie exportieren (siehe unten). Wer Famio über die
Seitenleiste von Home Assistant zum ersten Mal öffnet, ist zunächst Gast, bis
ein Administrator die Rolle festlegt.

## Aufbewahrung und Löschung

- Sitzungen laufen nach 90 Tagen Inaktivität ab und können je Gerät widerrufen
  werden.
- Ist der Bereich Standort in der Server-Verwaltung ausgeblendet, nimmt der
  Server keine Positionen an, und die Telefone pausieren das Teilen.
- Der Standortverlauf ist auf 1 bis 365 Tage einstellbar; Standard sind sieben
  Tage. Die zuletzt gemeldete Position bleibt gespeichert, bis eine neue kommt,
  das Teilen pausiert oder das Konto gelöscht wird.
- Der Server sichert seine Datenbank jede Nacht verschlüsselt und behält sieben
  tägliche und vier wöchentliche Sicherungen. Gelöschte Einträge und ältere
  Positionen sind darin noch bis zu etwa fünf Wochen enthalten.
- Konfliktkopien, die beim gleichzeitigen Bearbeiten auf zwei Geräten
  entstehen, enthalten die vollständige ältere Fassung, auch von
  Gesundheitsdaten. Sie sehen nur die beiden Beteiligten, und sie werden nach
  60 Tagen entfernt. Löschmarkierungen für den Geräteabgleich ohne Inhalt
  bleiben 180 Tage, zugestellte Hinweise der eigenen Push-Verbindung drei
  Tage.
- Beim Abmelden werden lokale Datenbank, Cache und Anmeldedaten des Geräts
  gelöscht.
- Administratoren können die Familiendaten serverseitig löschen. Diese
  Löschung wird beim nächsten Abgleich auf die Geräte übertragen. Verbindungen
  zu Listen-Apps, Paperless-ngx und PhotoVault werden vorher getrennt, damit
  deren Einträge nicht zurückkommen.
- Erwachsene und Gäste können ihr Konto in der App selbst löschen;
  Kinderkonten entfernt ein Erwachsener in der Server-Verwaltung.
- Wird ein Konto gelöscht, entfernt der Server dessen Notfallangaben und alle
  Einträge, die nur diese Person sehen konnte, etwa private Notizen, Dokumente
  samt Dateien und Gesundheitsdaten; auch aus dem Papierkorb.
  Daten von Kindern bleiben als Daten der Familie erhalten; war die Person ihre
  einzige Sorgeberechtigte, sehen sie danach alle Erwachsenen. Vorhandene
  Sicherungen enthalten die gelöschten Daten bis zu ihrem Ablauf weiter.
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
ableiten. Weil die Familienkarte den Positionen der Mitglieder folgt und die
Karte eines Notrufs nah heranzoomt, verrät das ungefähr, wo sich jemand
aufhält. Die Web-App schickt dabei zusätzlich die Adresse des Famio-Servers
(ohne Pfad) als Referer mit, weil OpenStreetMap Browser-Anfragen ohne Referer
ablehnt. Ein eigener Kartenserver hält diesen Abruf im eigenen Betrieb.

**Schriften der Web-App.** Emojis und Schriftzeichen anderer Sprachen lädt die
Web-App vom eigenen Famio-Server, nicht von Google. Für chinesische,
japanische und koreanische Zeichen holt der Server die passende Schriftdatei
einmal bei Google Fonts und hält sie danach selbst vor; Google sieht dabei
nur die Adresse des Servers, nicht die der Familie.

**Open-Meteo.** Wetter ist pro Gerät opt-in. Übertragen werden auf 0,01 Grad
gerundete Koordinaten des Orts „Zuhause“ (ohne ihn des ersten Orts) sowie die
technisch notwendige IP-Adresse. Der Anbieter kann Anfragen nach seinen eigenen
Regeln protokollieren.

**Text- und Barcode-Erkennung (Android).** Termine aus Fotos und der
Barcode-Scanner werten die Bilder auf dem Handy aus; Bilder verlassen das
Handy dafür nicht. Ein Foto oder Scan eines Termins kommt nur als Anhang auf
den eigenen Famio-Server, wenn beim Übernehmen „Original an den Terminen
speichern“ eingeschaltet bleibt. Im kleinen Paket für 64-Bit-Handys kommen die
Erkennungsmodelle von den Google-Play-Diensten, die sie beim ersten Gebrauch
einmal herunterladen; dabei sieht Google die Anfrage des Handys wie bei jedem
anderen Download aus Google Play. Unter Einstellungen → „Erkennung ohne Google
Play“ gibt es ein Paket mit eingebauten Modellen. Laut Google sendet ML Kit
aber auch mit eingebauten Modellen Diagnose- und Nutzungsdaten an Google:
Gerät, App-Version, Leistungswerte und eine Kennung der Installation, nicht
die Bilder oder erkannten Texte. Der Dokumentenscanner kommt immer von den
Google-Play-Diensten. Auf iPhone und iPad erkennt Apples Vision Text und
Barcodes auf dem Gerät, ohne etwas zu senden.

**SMS beim Notruf (Android).** Ist „SMS ohne Internet“ eingeschaltet und das
Handy ohne Verbindung, geht der Notruf mit Name und Position als SMS über den
Mobilfunkanbieter an die gewählten Nummern.

**Open Food Facts.** Eine Barcode-Suche im Vorrat überträgt den gescannten
Barcode, die Suche nach Nährwerten (nach einmaliger Zustimmung je Gerät) die
Suchbegriffe, jeweils mit der technisch notwendigen IP-Adresse, an
`world.openfoodfacts.org`.

**Rezept-Import.** Wer ein Rezept von einer Webseite übernimmt, ruft diese Seite
auf: die App direkt, die Web-App über den Famio-Server. Das Foto des Rezepts holt
immer der Server und speichert es wie einen Upload. Der Anbieter der Seite sieht
dabei die IP-Adresse von Gerät oder Server, sonst nichts.

**ntfy.** Nur nach Einrichtung. Der eingestellte ntfy-Server erhält das
geheime Thema, die IP-Adresse und mindestens einen knappen Hinweis; auch dieser
nennt bei manchen Mitteilungen einen Namen („SOS von …“, „… kommt“). Wenn
„Details“ aktiviert ist, wird die eigentliche Benachrichtigung übertragen, etwa
Ankünfte an Orten, Fahrtziele mit Ankunftszeit oder Chat-Texte. Der öffentliche
Dienst ntfy.sh hält Nachrichten laut eigener Datenschutzerklärung bis zu zwölf
Stunden vor und stellt sie auf Handys über Google (FCM) beziehungsweise Apple
zu. Auf dem iPhone ist ntfy ohne Apple Push der einzige Weg für Mitteilungen im
Hintergrund, auch für Notrufe. Ein eigener ntfy-Server hält das im eigenen
Betrieb.

**Web Push.** Im Browser erhält der Push-Dienst des Browsers (Google, Mozilla,
Apple oder Microsoft) die verschlüsselte Mitteilung, ihre Dringlichkeit und die
öffentliche Adresse des Famio-Servers; den Inhalt kann er nicht lesen.

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

**Paperless-ngx und PhotoVault.** Nur wenn ein Administrator sie verbindet.
Der Famio-Server holt dann mit dem hinterlegten Zugang Dokumente samt Dateien
aus Paperless-ngx (auch solche der Kategorie Gesundheit) beziehungsweise Fotos
und Geburtstage aus PhotoVault und zeigt sie den gewählten Mitgliedern. An
PhotoVault gibt Famio außerdem die Fotos des Familien-Chats mit Name des
Absenders und Zeitpunkt weiter, wenn das eingestellt ist.

**Home Assistant.** Ein Dienstkonto für Home Assistant erhält Positionen,
Termine (vertrauliche nur als belegte Zeit), Aufgaben, Listen, Finanzen und den
Familien-Chat, aber keine Gesundheitsdaten, Dokumente und keinen Eingang. Home
Assistant speichert diese Werte in seinem eigenen Verlauf (Recorder) nach
seinen Einstellungen; Famio kann sie dort nicht löschen. Im Modus „client“
speichert das Add-on die Sitzungen der Seitenleiste unverschlüsselt in seinem
Datenordner, der zu den Sicherungen von Home Assistant gehört.

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
erwachsener Administrator kann in der Server-Verwaltung die Daten der ganzen
Familie exportieren, etwa für einen Umzug auf einen anderen Server. Dieser
Export ist eine vollständige Sicherung: Er enthält auch private Einträge,
Direktnachrichten und Gesundheitsdaten anderer Mitglieder sowie letzte
Positionen und Notrufe, aber keine Standortverläufe. Er steht im Audit-Log,
und die anderen Erwachsenen bekommen eine Mitteilung. Beide Exporte sind nicht
verschlüsselt. Die Datei wird auf
dem Server nur kurz für den Download angelegt und danach gelöscht. Für
Berichtigung und Löschung sowie weitere Auskünfte wenden sich Mitglieder an den
Betreiber ihres Famio-Servers. Das Famio-Projekt besitzt keinen Zugriff auf
eine selbst gehostete Installation und kann deren Inhalte weder lesen noch
löschen.
