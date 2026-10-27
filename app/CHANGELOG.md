# Was ist neu in Famio?

Je Version das Wichtigste in wenigen Zeilen. Die App zeigt den Abschnitt
ihrer Version nach einem Update einmal an; die ausführlichen Release-Texte
stehen bei den Releases.

## 2.0.19 – Stabiler im Hintergrund

- Ein übersehener Fehler in einem Hintergrundauftrag beendet den Server
  nicht mehr; er wird protokolliert, Famio läuft weiter.
- iPhone und iPad erscheinen in der Geräteliste mit ihrem Modell statt als
  „localhost“.

## 2.0.18 – Geschenkideen, Leihgaben und Schulranzen

- Geschenkideen: Auf der Wunschliste eines anderen notiert ihr Ideen für
  Geburtstag oder Weihnachten; die Person selbst sieht sie nie.
- Verliehen & geliehen (Einstellungen): wer was von euch hat und ihr von
  wem, mit Erinnerung am Rückgabetag.
- Schulranzen-Check: Im Stundenplan je Fach eintragen, was mit muss; am
  Vorabend erinnert Famio an Fächer und Sachen für morgen.
- Dokumente werden auch über ihren Inhalt gefunden: Beim Hinzufügen liest
  das Gerät den Text eines PDFs oder Fotos.
- Eine Vertretung sieht während der Abwesenheit auch die Aufgaben, die nur
  einige sehen dürfen.
- iPhone (vom Mac installiert): Famio sagt rechtzeitig, wann es neu
  installiert werden muss.

## 2.0.17 – Eingang, Vertretungen und Gerät koppeln

- Der Familien-Eingang auf der Startseite sammelt, was noch keinen Platz hat
  (Texte, Links, Dateien, auch über „Teilen an Famio“); später wird daraus
  eine Aufgabe, ein Termin, eine Notiz, ein Dokument oder ein Einkauf.
- Abwesenheiten mit Vertretung: Wer verreist ist, dessen Ämter und Aufgaben
  übernimmt für die Zeit eine andere Person (Ämter → Abwesenheiten).
- Ein neues Gerät meldet sich per QR-Code von einem angemeldeten Gerät aus
  an, ohne Passwort (dort Einstellungen → QR-Symbol „Neues Gerät koppeln“, auf dem
  neuen „Vorhandenes Konto koppeln“).
- Große Datenexporte laufen zuverlässiger, und Bring!/Microsoft To Do
  bleiben nicht mehr hängen.

## 2.0.16 – Keine doppelten Einträge mehr

- Wird etwas erneut eingetragen, das abgehakt noch auf der Liste steht,
  kommt der abgehakte Eintrag zurück; steht es noch offen drauf, sagt
  Famio das, statt es doppelt einzutragen.
- Mit Bring! verbundene Listen bekommen keine doppelten Einträge mehr;
  vorhandene werden beim Abgleich zusammengeführt.

## 2.0.15 – Private Einkaufslisten und Darstellung

- Bei jeder Einkaufsliste lässt sich einstellen, wer sie sieht (Menü der
  Liste → „Wer sieht die Liste?“). Ihre Einträge sieht dann auch sonst
  niemand.
- Hell, dunkel oder wie das System: unter Einstellungen → Dieses Gerät →
  Darstellung.

## 2.0.14 – Fotos in voller Qualität, verlässlicherer Standort

- Der Bildbetrachter zeigt erst eine Vorschau und dann das Original in
  voller Schärfe, auch beim Zoomen.
- Fotos aus PhotoVault kommen im Betrachter und auf der Wandanzeige in
  voller Größe statt als kleine Miniatur.
- Meldet sich ein Handy einen Tag lang nicht, sagt „Wo ist wer?“ das
  deutlich; nach zwei Tagen bekommen die Erwachsenen einen Hinweis.
- Wer weit weg ist, verlässt „Zuhause“ jetzt auch, wenn das Handy nur
  ungenaue Positionen schickt.

## 2.0.13 – Fotos in Famio ansehen

- Ein Tipp auf ein Foto öffnet es in Famio statt als Download oder in
  einer anderen App: zum Weiterwischen, mit Zoom und den Pfeiltasten. Der
  Knopf oben rechts lädt das Original wie bisher herunter.
- Ist die Bibliothek des verbundenen PhotoVault-Kontos leer, sagt die
  Einstellung das jetzt und rät zum Konto, dem die Fotos gehören.

## 2.0.12 – Zufällige Fotos auf der Wandanzeige

- Die Wandanzeige zeigt auf Wunsch zufällige Fotos aus dem ganzen
  PhotoVault-Zeitstrahl, alle drei Stunden 100 neue (Server-Verwaltung →
  Einstellungen → PhotoVault → Fotos für die Wandanzeige).
- Die Diashow übernimmt neue Fotos sofort, statt bei der alten Auswahl zu
  bleiben.
- Die Beschreibung von Famio in HACS zeigt wieder Bilder und Links.

## 2.0.11 – PhotoVault, Stammartikel und Erinnerungen

- PhotoVault lässt sich anbinden (Server-Verwaltung → Einstellungen):
  Fotos des Tages in „Heute vor einem Jahr“, ein Album auf der Wandanzeige,
  Chat-Fotos als Beiträge an einen PhotoVault-Link und Geburtstage aus dem
  Stammbaum, sofern sie noch nirgends stehen.
- „Heute vor einem Jahr“ auf der Startseite zeigt Meilensteine, Ausflüge und
  Fotos vom selben Tag früherer Jahre.
- Die Einkaufsliste schlägt vor, was ihr oft kauft. Stammartikel mit
  Rhythmus kommen von selbst wieder auf die Liste. Die Liste lässt sich als
  Text teilen.
- Den Kassenbon fotografieren, und der Betrag steht im Haushaltsbuch.
- Home-Assistant-Automationen schicken Nachrichten in den Familien-Chat oder
  an einzelne Personen.
- Die Web-App kann ihre Daten verschlüsselt im Browser behalten und startet
  dann schneller (Einstellungen → Dieses Gerät).

## 2.0.10 – Android startet wieder

- Auf Android blieb Famio 2.0.8 und 2.0.9 nach dem Start weiß. Das ist
  behoben. Wer eine dieser Versionen hat, installiert 2.0.10 einmal von
  Hand, weil die App das Update selbst nicht mehr anbieten konnte.
- Home Assistant zeigt das Famio-Symbol bei der Integration und im
  Add-on-Store.

## 2.0.9 – Wochenplan, Verträge und Sparziele

- Der Kalender druckt einen Wochenplan für den Kühlschrank (Drucker-Symbol):
  Termine, Essen, Ämter und Tonnen, eine Zeile je Tag.
- „Woche vorschlagen“ im Essensplan füllt die freien Tage aus euren
  Lieblingsrezepten, ohne Wiederholung der letzten zwei Wochen und mit dem,
  was der Vorrat hergibt. Nach dem Einkauf trägt „Bezahlt? Betrag ins
  Haushaltsbuch“ den Betrag als Ausgabe ein.
- Fristen kennen Verträge und Abos: Famio erinnert vor dem letzten
  Kündigungstag, auf Wunsch steht der Monatsbetrag im Haushaltsbuch.
- Kinder legen im Taschengeld-Konto Sparziele an und sehen, wann es reicht.
- Für Termine an Familienorten erinnert Famio, wann man losfahren muss
  (Einstellungen → Push-Benachrichtigungen).
- Erwachsene können eigene Notfall-Infos hinterlegen (Einstellungen → Meine
  Notfall-Infos); beim SOS-Alarm sehen die anderen Erwachsenen sie.
- Kalender-Apps behalten Farbe und Reihenfolge der Famio-Kalender.

## 2.0.8 – Urlaub, freie Termine und Web-App mit Mitteilungen

- Urlaubsmodus: Unter Ämter → Urlaub einen Zeitraum eintragen. Dann sind
  Ämter und Routinen nicht fällig, niemand wird an die Mülltonnen erinnert,
  und auf Wunsch fällt auch das Taschengeld aus.
- „Wann haben alle Zeit?“ im Kalender schlägt freie Zeiten der nächsten zwei
  Wochen vor. Ein Tipp legt den Termin an.
- „Bin unterwegs“ unter Wo ist wer?: Ziel wählen, die Familie erfährt die
  ungefähre Ankunft.
- Gibt es eine neue App-Version, bekommen Mitglieder mit älteren Android-,
  Windows- und Linux-Geräten einmal Bescheid.
- Die Web-App lädt schneller, kann Mitteilungen anzeigen, auch ohne offenen
  Tab (Einstellungen → Push-Benachrichtigungen), und meldet auf Wunsch mit
  einem Passkey an (Anmeldung & Sicherheit). Rezepte lassen sich jetzt auch
  dort importieren.
- Auf dem Computer lassen sich Dateien ins Famio-Fenster ziehen: als Aufgabe,
  Dokument oder in den Chat, Kalenderdateien in den Import.

## 2.0.7 – Kochmodus und Teilen an Famio

- Rezepte haben einen Kochmodus: Schritt für Schritt, der Bildschirm bleibt
  an, Zeiten im Text starten per Tipp einen Timer.
- Auf Android lassen sich Text, Links, Fotos und Dateien aus anderen Apps an
  Famio teilen: auf die Einkaufsliste, als Aufgabe, Notiz oder Dokument oder
  in den Chat.
- Auf Wunsch kommt jeden Morgen ein Tagesüberblick mit Terminen, Aufgaben,
  Abfall und Wetter (Einstellungen → Push-Benachrichtigungen).
- Orte lassen sich als Geschäft markieren: Wer dort ankommt, bekommt die
  offenen Einkäufe.
- Leicht zu erratende Passwörter werden abgelehnt; die Zwei-Faktor-Pflicht
  gibt es auch für alle Erwachsenen.
- Das Android-Update für 64-Bit-Handys ist rund 32 MB groß; Termine aus
  Fotos und der Barcode-Scanner laden ihre Erkennung dann einmal über
  Google Play.
- Rund um die Zeitumstellung am 25. Oktober rutscht nichts mehr auf den Vor-
  oder Folgetag.

## 2.0.6 – Dokumente scannen

- In jeder Dateiauswahl gibt es „Dokument scannen“: Die Seiten werden auf
  dem Handy zu einem PDF, etwa für Dokumente oder Aufgaben.
- Meldet sich jemand auf einem weiteren Gerät mit deinem Konto an,
  bekommen deine anderen Geräte eine Mitteilung.
- Der Aufgaben-Editor ist kürzer. Checkliste, Dateien und „Wer darf es
  sehen?“ liegen hinter einem Knopf.
- Die Web-App lädt keine Schriften mehr von Google.
- Updates über den Server sind auf 64-Bit-Android-Handys etwa 40 % kleiner.
- Ämter, Taschengeld-Zahltage und das Alter in Monaten stimmen auch rund
  um die Zeitumstellung.

## 2.0.5 – Schönere Android-Widgets

- „Famio heute“ zeigt oben Logo und Datum und jede Zeile in der Farbe
  ihres Bereichs, bei dunklem Handy im dunklen Design.
- Der Notruf-Knopf hat einen Verlauf und passt in jede Zellengröße.

## 2.0.4 – Dateien an Aufgaben

- An Aufgaben lassen sich neben Fotos auch PDFs und andere Dateien
  hängen, etwa ein Formular oder eine Anleitung.
- In „Wo ist wer?“ können Erwachsene Mitglieder ohne Handy ausblenden,
  für die ganze Familie. Unter „Ausgeblendet“ kommen sie zurück.
- Nach einem Update lädt die Web-App sofort die neue Version.

## 2.0.3 – Aufgaben für mehrere

- Eine Aufgabe kann mehreren Personen gehören. Jede bekommt die
  Erinnerung und findet die Aufgabe unter „Meine“.
- Unter „Wer darf es sehen?“ lässt sich eine Aufgabe auf dich oder
  ausgewählte Personen beschränken. Wer sich kümmert, sieht sie immer.
- Gäste sehen nur noch Aufgaben, die ihnen zugewiesen oder für sie
  freigegeben sind.
- Die Karte in der Web-App lädt wieder.

## 2.0.2 – Tipps und Einrichtung

- Beim ersten Besuch eines Bereichs erklärt ein kurzer Tipp, was dort
  leicht übersehen wird. „Keine Tipps mehr“ schaltet sie ab, die
  Einstellungen wieder ein.
- In der Einrichtungsliste lassen sich einzelne Punkte ignorieren und
  wieder anzeigen.
- Die Server-Verwaltung zeigt bei Single Sign-On, PaperBuddy und
  App-Updates, was eingerichtet ist, und bietet dann „Ändern“ an.
- Logo und Seitenleiste sind bei großem Fenster auch auf Bildschirmen ohne
  Retina-Auflösung scharf, etwa über Remote-Desktop.
- Die Server-Überwachung meldet jetzt auch, wenn eine Sicherung ausbleibt.

## 2.0.1 – Fotos an Aufgaben

- Ein neues Kind sehen jetzt alle Erwachsenen. Wer ein Kind nicht sieht,
  bekommt einen Hinweis, statt es ein zweites Mal anzulegen.
- An Aufgaben lassen sich Fotos anhängen, aus der Kamera oder der Galerie.
- Im Protokoll eines Kindes lassen sich Tag, Woche oder Monat ansehen und
  zurückblättern, mit Durchschnitt pro Tag.
- Ist die App älter als der Server, sagt sie es auf der Startseite. Die
  Verwaltung sieht die Version jedes Geräts.

## 2.0.0 – Updates vom eigenen Server

- Neue Versionen für Android, Windows und Linux kommen jetzt über den
  Famio-Server: Ein Hinweis auf der Startseite lädt, prüft und installiert
  sie. Die Verwaltung schaltet das unter „App-Updates über den Server“ ein.
- Kalenderdateien (.ics) übernehmen: unter „Termine erkennen“ oder direkt
  mit „Öffnen mit Famio“ aus Mail und Dateien, auf allen Geräten. Serien
  bleiben Serien, ein zweiter Import aktualisiert statt zu verdoppeln.
- Eine kurze Tour zeigt die wichtigsten Bereiche. Sie wird einmal auf der
  Startseite angeboten und steht jederzeit unter Einstellungen.
- Unter Windows und Linux läuft Famio nur noch einmal; ein zweiter Start
  holt das offene Fenster nach vorn.
- Die Home-Assistant-Integration lässt sich über HACS installieren.
- Die Einrichtungsliste erkennt die öffentliche Adresse auch hinter
  Routern ohne Hairpin-NAT und zählt bei Benachrichtigungen nur Mitglieder
  mit der App.
- Das Logo oben links ist auch bei großem Fenster scharf.

## 1.0.16 – Entwicklung bis ins Erwachsenenalter

- Bei den Kindern erklären Entwicklungsphasen, was gerade passiert: vom
  Sehen und Hören des Neugeborenen über die Trotzphase bis zur Pubertät.
- Viele neue Meilensteine bis ins Erwachsenenalter, etwa Fontanellen,
  Zähne, Denken und Pubertät – passend zum Geschlecht im Profil des Kindes.

## 1.0.15 – Besser lesbare Farben

- Schrift, Knöpfe und Abzeichen in den Farben der Bereiche sind jetzt auch
  ohne „Hoher Kontrast“ gut lesbar. Symbole und Kacheln bleiben bunt.
- Die Initialen auf farbigen Personenkreisen sind weiß oder dunkel, je
  nachdem, was besser zu lesen ist.

## 1.0.14 – Termine in drei Sprachen erkennen

- „Termine erkennen“ liest jetzt auch englische und spanische Datums- und
  Zeitangaben, etwa „October 16 at 7 pm“ oder „16 de octubre a las 19:00“.
- Vorgeschlagene Titel kommen ohne Wochentage und Füllwörter.

## 1.0.13 – Mehr Verbindungen

- Unterpunkte von Aufgaben erscheinen in Apple Erinnerungen als
  Unteraufgaben und in Microsoft To Do als Schritte.
- Fehlbestände aus PreppSuite auf die Einkaufsliste übernehmen
  (Einkaufsliste → ⋮).
- Kontoauszug ins Haushaltsbuch importieren (CSV oder CAMT, nur auf dem
  Gerät gelesen).
- Nährwerte pro Portion für Rezepte über Open Food Facts.
- Dokumente aus PaperBuddy mit ihren Fristen bei den Dokumenten.
- Jahresrückblick mit Zahlen, Meilensteinen, Reisen und Fotos, auch als
  PDF.
- Home Assistant: Sensoren für Ämter, nächste Abfuhr und Countdown.

## 1.0.12 – Englisch und Spanisch

- Famio gibt es jetzt auch auf Englisch und Spanisch. Die App folgt der
  Sprache des Geräts; unter Einstellungen → Sprache lässt sie sich
  festlegen.
- Benachrichtigungen kommen in der Sprache des jeweiligen Handys.
- Nach einem Update zeigt die App einmal, was neu ist; unter Einstellungen
  → „Was ist neu?“ jederzeit.
- Android: Widget „Famio Notruf“ für den Startbildschirm.
- Für Admins zeigt die Startseite eine Checkliste, bis die Einrichtung
  abgeschlossen ist.
- Größere Tippflächen, bessere Bedienung mit großer Schrift und mit dem
  Bildschirmleser.

## 1.0.11 – Sicherer abgleichen

- Ändern zwei von euch dasselbe, ohne die Änderung des anderen zu sehen,
  geht nichts mehr still verloren: Die Startseite zeigt „Eine Änderung hat
  sich überschnitten“, ihr vergleicht und entscheidet.
- Der Server prüft jede nächtliche Sicherung, ob sie sich wiederherstellen
  lässt (Server-Verwaltung → Status → „Sicherung prüfen“).
- Der Docker-Server läuft ohne root-Rechte.

## 1.0.10 – Vorfreude und Ordnung

- Countdown: Termine markieren, die Startseite zählt die Tage („12 Tage bis
  Ostsee“).
- Wochenvorschau sonntags um 18 Uhr mit Terminen, Fahrten und Geburtstagen.
- Abfallkalender: wer wann welche Tonne rausstellt, mit Erinnerung am
  Vorabend.
- Packlisten an Reisen, je Person, mit Erinnerung vor der Abreise.
- Fristen und Wartung: TÜV, Heizung, Tierarzt – rechtzeitig erinnert.
- Meilensteine passend zum Alter; Fotos und Dokumente belegen höchstens
  500 MB auf dem Gerät.

## 1.0.9 – Wünsche und Fahrten

- Wunschzettel für Geburtstag und Weihnachten; wer was besorgt, sieht der
  Beschenkte nicht.
- Im Termin festlegen, wer bringt und wer abholt – mit eigener Erinnerung.
- Termine aus PDFs erkennen, etwa aus einem Elternbrief.
- Notruf und Check-in auch in Home Assistant.

## 1.0.8 – Notfallknopf

- Notfallknopf für Kinder: lauter Alarm bei den Eltern mit Standort, Anruf,
  Sirene und SMS ohne Internet.
- Handy eines Kindes klingeln lassen, Check-in „Bin angekommen“, Warnung
  bei schwachem Akku.
- Ruhezeiten für Benachrichtigungen, Einladungen per QR-Code.
- Einkauf nach Gängen sortiert, Feiertage und Schulferien im Kalender,
  Pinnwand, Checklisten in Aufgaben und Termine aus Fotos.

## 1.0.7

- Beim Abgleich mit Bring! und anderen Listen-Apps tauchen erledigte
  Einträge nicht mehr wieder auf.

## 1.0.6

- Die Leiste „Rückgängig“ verschwindet wieder von selbst.
- Der Bring!-Abgleich versteht mehr Antworten der Bring!-Schnittstelle.

## 1.0.5 – Andere Apps

- Aufgaben und Einkaufslisten in Apple Erinnerungen, Bring! und Microsoft
  To Do.
- Wiederkehrende Aufgaben, Suche über alles, „Rückgängig“ beim Löschen und
  „Meine Daten exportieren“.
