# Was ist neu in Famio?

Je Version das Wichtigste in wenigen Zeilen. Die App zeigt den Abschnitt
ihrer Version nach einem Update einmal an; die ausführlichen Release-Texte
stehen bei den Releases.

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
