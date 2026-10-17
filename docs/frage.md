# BKG-TTS – offene Fragen zur Umsetzung

Dieses Dokument sammelt Entscheidungen, die vor der Umsetzung der BKG-TTS-Zielbeschreibung noch konkretisiert werden sollten. Die bereits festgelegten Produktziele sind Anforderungen und werden hier nicht erneut zur Abstimmung gestellt.

## Bereits festgelegte Vorgaben

- BKG-TTS wird als harness-unabhängige Sprachausgabe entwickelt; GitHub Copilot Chat ist ein Adapter und bleibt vollständig funktionsfähig.
- Die vorgesehenen Integrationen sind GitHub Copilot Chat, Claude Code, OpenAI Codex, OpenCode, Pi, OMP sowie BKG-eigene Agenten. Weitere Harnesses sollen über Adapter anschließbar sein.
- Es werden nur tatsächlich verfügbare Hook- und Streaming-Ereignisse verwendet. Fehlt echtes Streaming, wird ein klar benannter Fallback eingesetzt; Live-Ereignisse werden nicht vorgetäuscht.
- Die BKG-Schichtenfolge bleibt `zig.vanilla → banana.bkg → zig-body.bkg → zig-app.bkg`.
- Das deutsche Pocket-TTS-ONNX-INT4-Modell ist das bevorzugte Standardmodell, sofern Laufzeit, Lizenz und Zielplattform kompatibel sind. Die Engine-Abstraktion bleibt modellneutral.
- Stimmen sind pro Harness getrennt konfigurierbar. Harness-Konfigurationen und Hook-Dateien gehören ins Projekt und sollen sauber archiviert werden.
- Vorhandene Copilot-TTS-Funktionen und der VS-Code-Bedienweg dürfen nicht verloren gehen.

## 1. Umfang und Reihenfolge

1. **Was soll der erste nutzbare Meilenstein enthalten?**
- [ ] Gemeinsames Event-Modell und Engine-Schnittstelle, zunächst mit Copilot-Live-Adapter
- [ ] Event-Modell plus Copilot und ein weiterer Harness als vertikaler End-to-End-Pfad
- [ ] Alle genannten Harnesses mit jeweils dem bestverfügbaren echten Streaming- oder Hook-Pfad
- [ ] Zunächst ausschließlich Architektur- und Kompatibilitätsnachweis
Ergänzung / Prioritätsreihenfolge:

2. **Welche Plattformen müssen im ersten Meilenstein tatsächlich funktionieren?**
- [ ] Linux
- [ ] Windows
- [ ] macOS
- [ ] Remote-SSH/Container/WSL
Sind bestimmte Kombinationen aus Harness, Betriebssystem und lokalem/remote Extension Host zwingend?

3. **Was bedeutet „BKG-eigene Agenten“ für den ersten Adapter?**
- [ ] Ein dokumentiertes Event-Protokoll genügt zunächst
- [ ] Ein konkreter vorhandener BKG-Agent muss angebunden werden
Falls ein konkreter Agent gemeint ist: Repository, Startbefehl und derzeitige Event-Ausgabe:

## 2. Harness-Adapter und Ereignisverfügbarkeit

4. **Welche Harnesses sind für den ersten End-to-End-Meilenstein unverzichtbar?**
Gewünschte Reihenfolge, falls nicht alle gleichzeitig umgesetzt werden:

5. **Wie soll ein Harness ohne echtes Token-/Text-Streaming behandelt werden?**
- [ ] Hook am Ende der Antwort: ganze Antwort nach Abschluss sprechen
- [ ] Verfügbare Zwischenstatus-Ereignisse zusätzlich sprechen
- [ ] Integration als „nicht live“ kennzeichnen und standardmäßig deaktiviert lassen
Weitere Anforderungen:

6. **Wie sollen projektspezifische Hooks installiert und wieder entfernt werden?**
- [ ] Expliziter BKG-TTS-Befehl mit Vorschau und Bestätigung
- [ ] Manuelle Einrichtung mit generierten Dateien und Anleitungen
- [ ] Beides
Welche Konfigurationsänderungen müssen vor dem Schreiben einzeln angezeigt werden?

7. **Wie sollen Hooks und vorherige Harness-Konfigurationen archiviert werden?**
Vorgabe ist eine projektbezogene, nachvollziehbare Ablage. Bitte gewünschten relativen Ordner und Aufbewahrungs-/Bereinigungsregeln nennen:

## 3. Live-Streaming, Segmentierung und Sitzungen

8. **Wann ist ein Segment sprechfertig?**
- [ ] Satzzeichen und abgeschlossene Sätze bevorzugen
- [ ] Zusätzlich nach maximaler Wartezeit sprechen, auch ohne Satzzeichen
- [ ] Feste maximale Zeichen-/Wortzahl je Segment
Gewünschter Standard für Mindestlänge, Höchstlänge und maximale Wartezeit:

9. **Wie lange darf BKG-TTS auf einen Satzabschluss warten, bevor es ein sinnvolles Fragment spricht?**
Maximaler Zeitraum oder gewünschtes Verhalten:

10. **Was soll bei Abbruch, Fehler oder Harness-/Projektwechsel mit bereits erzeugtem Audio geschehen?**
- [ ] Aktuelles Segment beenden, Rest verwerfen
- [ ] Sofort stoppen und gesamte Queue des alten Kontexts verwerfen
- [ ] Fehler-/Abbruchmeldung priorisiert sprechen
Weitere Regeln:

11. **Wie sollen wiederholte oder nach einer Wiederverbindung erneut gelieferte Events erkannt werden?**
Vorgeschlagene Identität ist Harness + Projekt + Antwort + Segment-ID/Sequenznummer. Ist diese Regel ausreichend? Welche Aufbewahrungsdauer soll die Deduplizierung haben?

12. **Welche Kontextgrenze gilt für Wiedergabe und Verlauf?**
- [ ] Pro Projekt und Harness
- [ ] Zusätzlich pro Konversation/Sitzung
- [ ] Andere Grenze
Gewünschte Aufbewahrungsdauer und Verhalten beim Schließen eines Projekts:

## 4. Sprechregeln und Code

13. **Welche Inhaltsarten sollen nach einer Neuinstallation standardmäßig aktiviert sein?**
Für jede Kategorie gewünschter Standard: Prosa, Code, Zwischenmeldungen, Tool-Ausgaben, Fehler, Zusammenfassungen.

14. **Was soll „Zusammenfassung“ bei langen Antworten bedeuten?**
- [ ] Nur eine vom Harness gelieferte Zusammenfassung verwenden
- [ ] Eine vorhandene lokale Zusammenfassungsfunktion verwenden
- [ ] Vorläufig nicht sprechen, wenn keine Zusammenfassung bereitsteht
Maximale Länge oder gewünschte Dauer:

15. **Welche Code-Standards gelten je Modus?**
Der Entwurf sieht „Aus“, „Zusammenfassung“ und „Vollständig“ vor. Soll die Sprachausgabe bei „Zusammenfassung“ Code selbst zusammenfassen oder nur eine vorhandene Erklärung vorlesen? Welche Programmiersprachen sollen initial auswählbar sein?

16. **Wie soll der optionale Modus für Syntaxzeichen funktionieren?**
- [ ] Syntaxzeichen nur auf ausdrücklichen Wunsch ansagen
- [ ] Pro Programmiersprache konfigurierbare Aussprache verwenden
Benötigte Zeichen und gewünschte gesprochene Namen:

17. **Welche Geheimnisse müssen vor jeder Ausgabe zwingend redigiert werden?**
Vorgeschlagen sind bekannte Credential-Muster wie API-Schlüssel, Tokens, Passwörter und private Schlüssel. Gibt es zusätzliche organisationsspezifische Muster oder lokale Ausschlusslisten? Sollen redigierte Stellen als „geheimnis entfernt“ angekündigt oder still ausgelassen werden?

18. **Wie sollen Tool-Ausgaben behandelt werden?**
- [ ] Vollständig nach den Inhaltsregeln sprechen
- [ ] Standardmäßig zusammenfassen/begrenzen
- [ ] Nur Fehler und ausgewählte Tools sprechen
Ausnahmen, maximale Länge sowie gewünschte Tool-Auswahl:

## 5. Wiedergabe und Steuerung

19. **Was soll Pause/Fortsetzen genau mit dem laufenden Segment tun?**
- [ ] Audiowiedergabe pausieren und an derselben Position fortsetzen
- [ ] Aktuelles Segment neu beginnen
- [ ] Nur weitere Queue-Ausgabe anhalten
Das Verhalten hängt von Audio-Backend und Plattform ab; welche Unterschiede sind akzeptabel?

20. **Welche Priorität soll bei gleichzeitig eintreffenden Inhalten gelten?**
Gewünschte Reihenfolge für Fehler, Statusmeldungen, Prosa, Code und Tool-Ausgaben:

21. **Darf eine wichtige Meldung die laufende Wiedergabe unterbrechen?**
- [ ] Nie
- [ ] Nur Fehler
- [ ] Fehler und ausgewählte Statusmeldungen
Falls ja: laufendes Segment abbrechen oder zunächst beenden?

22. **Welche Queue-Aktionen müssen sowohl im Panel als auch per API verfügbar sein?**
- [ ] Pause
- [ ] Fortsetzen
- [ ] Aktuelles Segment überspringen
- [ ] Queue leeren
- [ ] Sofort stoppen
Zusätzliche Aktionen:

## 6. Dashboard und VS-Code-Panel

23. **Welche Elemente sollen in der ersten UI-Version zwingend sichtbar sein?**
Der Entwurf listet Projekt, Harness, Modell-/Verbindungsstatus, aktuellen Text, Segment, Queue, Inhaltsregeln, Stimme, Tempo, Lautstärke und Wiedergabesteuerung. Bitte optionale Elemente oder gewünschte Reihenfolge nennen:

24. **Wo sollen die getrennten Stimmen pro Harness gepflegt werden?**
- [ ] Im Panel, mit Harness-Auswahl
- [ ] In VS-Code-Einstellungen plus Panel-Kurzweg
- [ ] In Projektkonfiguration und Panel-Kurzweg
Soll eine Projektstimme die globale Stimme überschreiben?

25. **Welche Barrierefreiheitsanforderungen sind für die Abnahme verbindlich?**
Gewünschte Tastaturbedienung, Fokusreihenfolge, Screenreader-Ansagen und Mindestanforderungen:

26. **Was bedeutet „API-Key-Verwaltung für Administratoren“ in diesem Produkt?**
- [ ] Schlüssel für externe KI-/TTS-Anbieter
- [ ] Schlüssel für zugreifende Harness-Clients
- [ ] Beides
Wer ist Administrator, und wie wird dessen Berechtigung vergeben?

## 7. API, Sicherheit und Betrieb

27. **Welche Clients dürfen die API im ersten Meilenstein aufrufen?**
- [ ] Nur lokale Prozesse auf demselben Rechner
- [ ] Remote-Harnesses im vertrauenswürdigen LAN
- [ ] Andere
Bei Netzwerkzugriff muss Authentifizierung und Berechtigungsprüfung vor dem Öffnen eines nicht-lokalen Listeners fertig sein. Gewünschter Betriebsmodus:

28. **Welche der im Entwurf genannten API-Routen sind für den ersten Meilenstein Pflicht?**
- [ ] Bereitschaft/Einstellungen
- [ ] Wiedergabesteuerung
- [ ] Harness-Status
- [ ] Admin-Schlüssel auflisten/anlegen/widerrufen
Pro Route: benötigte Rollen, erlaubte Aktionen und gewünschte Fehlermeldungen:

29. **Wie sollen API-Schlüssel erzeugt, angezeigt und widerrufen werden?**
Vorgabe: nur gehashte Schlüssel dauerhaft speichern und Schlüssel niemals protokollieren. Soll der Klartext einmalig beim Erstellen angezeigt werden? Welche Rollen und Ablaufzeiten werden benötigt?

30. **Welche Speichergrenzen gelten für Event-Deduplizierung, Queue, Antwortverlauf und Diagnosedaten?**
Gewünschte Größen-/Zeitlimits und Regeln für Datenlöschung:

31. **Welche Status- und Fehlerdaten dürfen angezeigt oder gespeichert werden?**
Bitte festlegen, ob Texte/Tool-Ausgaben im Diagnoseverlauf gespeichert werden dürfen, wie lange und ob Nutzer sie exportieren/löschen können.

## 8. TTS-Engine und native Runtime

32. **Welche Betriebssysteme und CPU-Architekturen muss das bevorzugte Pocket-TTS-ONNX-INT4-Modell unterstützen, bevor es Standard wird?**
Bitte Mindesthardware und zulässige Download-/Speichergröße nennen:

33. **Welche Sprach- und Stimmenauswahl soll bei der ersten Veröffentlichung gelten?**
Der verlinkte deutsche Modell-Snapshot enthält mehrere Stimmenbeispiele. Welche davon sollen auswählbar sein, und welche Stimme ist je Harness die Voreinstellung?

34. **Ist ein externer Runtime-Prozess zulässig, wenn keine geeignete native ONNX- oder Audio-Integration in BKG vorhanden ist?**
- [ ] Nein, nur vorhandene/neu zu entwickelnde native BKG-Schnittstellen
- [ ] Ja, als klar abgegrenzter austauschbarer Engine-Worker
- [ ] Nur nach einem Laufzeit-Prototyp und dokumentierter Entscheidung
Bevorzugte Grenze und betriebliche Einschränkungen:

35. **Welche Engine-Funktionen müssen im ersten gemeinsamen Interface enthalten sein?**
- [ ] Synthese einzelner Segmente
- [ ] Streaming-Ausgabe
- [ ] Stimmenliste
- [ ] Abbruch
- [ ] Sprach-/Stimmenmetadaten
- [ ] Modellstatus
Weitere erforderliche Fähigkeiten:

36. **Wie sollen Modell- und Runtime-Dateien verwaltet werden?**
- [ ] Expliziter Download mit Fortschritt und Zustimmung
- [ ] Installationsassistent nach manueller Initialisierung
Gewünschter Speicherort, Offline-Verhalten und Update-/Rollback-Regeln:

## 9. BKG-Integration und Migration

37. **Welche Anwendungsschicht soll den neuen Server-Endpunkt bereitstellen?**
Im Workspace sind BKG-Bibliotheken für HTTP, Authentifizierung, Events und WebSockets vorhanden; der dokumentierte BKG-CLI-Einstiegspunkt fehlt jedoch in diesem Snapshot.
- [ ] Zunächst vorhandene Bibliotheken ohne CLI-Abhängigkeit integrieren
- [ ] Fehlenden Einstiegspunkt als separate Voraussetzung wiederherstellen
- [ ] Erst nach Prüfung des vollständigen BKG-Anwendungswegs entscheiden
Gewünschter BKG-Server-/Build-Einstiegspunkt:

38. **Welche Schicht ist zuständig für ONNX-Runtime, Audioausgabe und Plattformintegration?**
Vorgabe ist die eingefrorene BKG-Schichtenfolge. Bitte benennen, falls bereits feststeht, welche Schicht den jeweiligen nativen Adapter besitzen soll; andernfalls soll dies durch einen technischen Nachweis entschieden werden:

39. **Wie sollen bestehende Copilot-TTS-Einstellungen und Hook-Dateien migriert werden?**
- [ ] Bestehende Einstellungen automatisch übernehmen, Original archivieren
- [ ] Importvorschau und ausdrückliche Bestätigung
- [ ] Manuelle Migration
Was muss bei Rückkehr auf die alte Version wiederherstellbar sein?

40. **Welcher Produktname soll in Befehlen, Einstellungen, Dateien und Marketplace-Metadaten gelten?**
„BKG-TTS“ ist der gewünschte Rebrand. Sollen bestehende `copilot-tts.*`-IDs aus Kompatibilitätsgründen dauerhaft bestehen bleiben, Aliasnamen erhalten oder später migriert werden?

## 10. Abnahme und Veröffentlichung

41. **Welche messbare Latenz gilt als „live“?**
Gewünschtes Maximum zwischen Empfang eines vollständigen, sprechbaren Segments und Beginn der Audioausgabe:

42. **Welche Tests müssen für jeden Adapter verpflichtend sein?**
- [ ] Echtes Harness-End-to-End
- [ ] Reproduzierbare Fixture-Aufzeichnung
- [ ] Fehlende/verspätete/duplizierte Events
- [ ] Abbruch/Wiederverbindung
Mindestanforderung, wenn ein Harness in CI nicht installiert werden kann:

43. **Welche Abnahmetests sind für Datenschutz und Geheimnisse zwingend?**
Gewünschte Testfälle für Redigierung, Logs, API-Schlüssel, Archivdateien und Datenlöschung:

44. **Welche Veröffentlichungsgrenze gilt für unvollständige Integrationen?**
- [ ] Nur als experimentell markierte Adapter ausliefern
- [ ] Adapter erst nach bestandenem End-to-End-Test sichtbar machen
- [ ] Andere Regel
Benötigte Dokumentation und Freigabekriterien:

## Antwortvorlage

Antworten können direkt unter der jeweiligen Frage ergänzt werden. Nicht benötigte Punkte bitte mit „nicht im ersten Meilenstein“ markieren. Für Entscheidungen, die erst nach einem technischen Prototyp möglich sind, „Nachweis erforderlich“ notieren und den geforderten Nachweis benennen.
