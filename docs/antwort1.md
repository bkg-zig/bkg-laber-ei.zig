# BKG-TTS – offene Fragen: verbindliche Umsetzungsentscheidungen

**Status:** Vorgabe für Planung und Implementierung  
**Produktname:** BKG-TTS  
**Architekturprinzip:** Eine gemeinsame Engine, getrennte Harness-Adapter, eigene Profile je Projekt und Harness.

Bereits festgelegte Produktanforderungen bleiben verbindlich. Entscheidungen, die einen technischen Prototyp erfordern, werden nicht vorweggenommen.

## 1. Umfang und Reihenfolge

### 1. Was enthält der erste nutzbare Meilenstein?

**Entscheidung:** Gemeinsames Event-Modell, Engine-Schnittstelle und zwei vollständige End-to-End-Pfade: GitHub Copilot Chat und Claude Code.

Priorität:
1. Bestehende Copilot-TTS-Funktionen erhalten.
2. Event-Modell und Live-Wiedergabe implementieren.
3. Claude Code als zweiten Harness integrieren.
4. Projekt- und Harness-Profile einschließlich eigener Stimmen implementieren.
5. Dashboard, VS-Code-Panel und sichere API bereitstellen.
6. Weitere Harnesses schrittweise ergänzen.

Alle vorgesehenen Harnesses werden von Anfang an in der Architektur berücksichtigt. Nicht fertig getestete Adapter werden nicht als vollständig funktionsfähig ausgegeben.

### 2. Welche Plattformen sind erforderlich?

**Entscheidung:** Linux zuerst, danach Windows und macOS. Remote-SSH, Container und WSL werden als wichtige Betriebsformen berücksichtigt.

Zuerst muss die Kombination aus Linux, VS-Code-Extension-Host, Copilot und Claude Code funktionieren. Audioausgabe und Audio-Weiterleitung müssen dort getestet werden, wo sie tatsächlich stattfinden. Ein Remote-Extension-Host darf nicht stillschweigend voraussetzen, dass der entfernte Rechner eine Soundkarte oder einen erreichbaren Audioplayer besitzt.

### 3. Was bedeutet „BKG-eigene Agenten“?

**Entscheidung:** Ein dokumentiertes Event-Protokoll ist die erste Voraussetzung. Danach wird ein konkreter vorhandener BKG-Agent angebunden.

Repository, Startbefehl und Ereignisformat werden vor der Implementierung aus dem tatsächlichen Projektbestand ermittelt. Keine erfundenen Endpunkte und keine simulierten Live-Ereignisse.

## 2. Harness-Adapter und Ereignisverfügbarkeit

### 4. Reihenfolge der Harnesses

1. GitHub Copilot Chat
2. Claude Code
3. OpenAI Codex
4. OpenCode
5. Pi
6. OMP
7. BKG-eigene Agenten

Weitere Adapter müssen über dasselbe dokumentierte Event-Modell anschließbar sein. Die Reihenfolge kann nach einem technischen Kompatibilitätsnachweis angepasst werden.

### 5. Harness ohne echtes Streaming

**Entscheidung:** Tatsächlich verfügbare Zwischenstatus-Ereignisse dürfen gesprochen werden. Die vollständige Antwort wird bei Bedarf nach Abschluss ausgegeben. Nicht-live-fähige Adapter werden eindeutig als solche gekennzeichnet.

Kein erfundenes Token-Streaming. Ein Adapter ohne Live-Text erhält standardmäßig den Modus „Antwort nach Abschluss“.

### 6. Hooks installieren und entfernen

**Entscheidung:** Beides. Ein expliziter BKG-TTS-Befehl bietet Vorschau und Bestätigung; zusätzlich werden manuelle Einrichtung und generierte Dateien dokumentiert.

Vor jeder Änderung werden Zielpfad, bestehender Inhalt, geplante Änderung, Sicherungspfad und Rücknahmeaktion angezeigt. Überschreiben fremder Konfigurationen ohne ausdrückliche Bestätigung ist verboten.

### 7. Archivierung von Hooks und Konfigurationen

**Entscheidung:** Projektbezogen unter `.bkg-tts/`.

Vorgesehene Struktur:

- `.bkg-tts/config/` – Projektprofile und Harness-Zuordnungen
- `.bkg-tts/hooks/` – BKG-TTS-eigene Hook-Dateien
- `.bkg-tts/archive/` – gesicherte vorherige Konfigurationen
- `.bkg-tts/manifest.json` – Version, Herkunft, Zeitstempel und Prüfsummen

Vorhandene fremde Dateien werden vor Änderungen gesichert. Bereinigungen erfolgen nur nach expliziter Regel, niemals automatisch durch pauschales Löschen. Schlüssel, Passwörter und andere Geheimnisse dürfen nicht archiviert werden.

## 3. Live-Streaming, Segmentierung und Sitzungen

### 8. Wann ist ein Segment sprechfertig?

**Entscheidung:** Satzgrenzen bevorzugen, aber nicht unbegrenzt auf Satzzeichen warten.

Vorläufige Startwerte, die messbar getestet werden:
- Mindestlänge: ungefähr 20 Zeichen
- Zielsegment: ungefähr 120 Zeichen
- Maximale Segmentlänge: ungefähr 240 Zeichen
- Maximale Wartezeit auf ein sinnvolles Fragment: 700 Millisekunden

Diese Werte sind konfigurierbare Startwerte, keine garantierten optimalen Modellgrenzen. Codeblöcke und unvollständige Markdown-Strukturen müssen beim Segmentieren berücksichtigt werden.

### 9. Maximale Wartezeit

**Entscheidung:** Standardmäßig 700 Millisekunden nach dem letzten neuen Text, sofern ein sinnvolles Fragment vorliegt. Bei laufender Generierung werden Segmente fortlaufend verarbeitet. Sehr kurze Fragmente werden nach Möglichkeit zusammengeführt.

### 10. Abbruch, Fehler und Kontextwechsel

**Entscheidung:** Bei Projekt- oder Harness-Wechsel wird die Wiedergabe des alten Kontexts sofort gestoppt und dessen Queue verworfen. Bei einem Abbruch werden nicht abgespielte Segmente verworfen.

Eine Fehler- oder Abbruchmeldung wird nur gesprochen, wenn die jeweilige Kategorie aktiviert ist. Alte Inhalte dürfen nicht versehentlich in das neue Projekt hineinsprechen.

### 11. Deduplizierung

**Entscheidung:** Identität aus Harness-ID, Projekt-ID, Sitzungs-ID, Antwort-ID und Segment-ID beziehungsweise Sequenznummer.

Wiederverbindungen dürfen bereits verarbeitete Segmente nicht erneut einreihen. Vorläufige Aufbewahrung der Deduplizierungsdaten: 24 Stunden oder bis zum Ende der begrenzten Sitzungshistorie. Die Implementierung muss Speicherverbrauch und Bereinigung begrenzen.

### 12. Kontextgrenze

**Entscheidung:** Projekt, Harness und Konversation beziehungsweise Sitzung bilden gemeinsam die Kontextgrenze.

Beim Schließen eines Projekts werden Wiedergabe und Queue geleert. Ein persistenter Textverlauf wird standardmäßig nicht gespeichert. Diagnosedaten werden getrennt behandelt und dürfen keine vollständigen Antworten oder Geheimnisse enthalten.

## 4. Sprechregeln und Code

### 13. Standardwerte nach Neuinstallation

- Prosa: aktiviert
- Code: Zusammenfassungsmodus
- Zwischenmeldungen: aktiviert, auf relevante Statusänderungen begrenzt
- Tool-Ausgaben: begrenzt und standardmäßig zusammengefasst
- Fehler: aktiviert
- Zusammenfassungen: aktiviert, sofern eine echte Zusammenfassung vorhanden ist

Alle Einstellungen sind global, je Harness und je Projekt konfigurierbar. Eine lokale Projektregel hat Vorrang vor der Harness-Regel, diese wiederum vor der globalen Einstellung.

### 14. Zusammenfassung langer Antworten

**Entscheidung:** Zuerst eine echte Zusammenfassung des Harness verwenden, falls vorhanden. Andernfalls eine nachweislich vorhandene lokale Zusammenfassungsfunktion verwenden. Keine Zusammenfassung vortäuschen, wenn keine solche Funktion verfügbar ist.

Vorläufige Zielgröße: 2 bis 5 Sätze. Ohne verfügbare Zusammenfassung wird nach den normalen Inhaltsregeln gesprochen.

### 15. Code-Modi

**Entscheidung:** Drei Modi:
- Aus: Code wird übersprungen.
- Zusammenfassung: vorhandene Erklärung wird bevorzugt; andernfalls darf eine lokale Zusammenfassung nur über eine explizite, implementierte Funktion erzeugt werden.
- Vollständig: Code wird unter Berücksichtigung der Sprachregeln vorgelesen.

Initial auswählbare Sprachen: Zig, Rust, TypeScript, JavaScript, Shell, JSON, YAML, Python und Markdown. Weitere Sprachen werden über erweiterbare Sprachprofile ergänzt.

### 16. Syntaxzeichen

**Entscheidung:** Syntaxzeichen nur auf ausdrücklichen Wunsch ansagen. Die Aussprache ist pro Sprache konfigurierbar.

Der Standard liest Code möglichst sprachlich verständlich vor, statt jedes Semikolon und jede Klammer anzusagen. Ein optionaler Modus kann beispielsweise Klammern, Operatoren, Punkte, Schrägstriche und Unterstriche benennen.

### 17. Geheimnisse und Redigierung

**Entscheidung:** Vor jeder Synthese werden bekannte Credential-Muster, API-Schlüssel, Zugriffstokens, Passwörter, private Schlüssel und vergleichbare Geheimnisse redigiert.

Zusätzliche projektspezifische Muster und Ausschlusslisten werden unterstützt. Redigierte Inhalte werden standardmäßig still ausgelassen. Optional kann eine kurze Ansage „Geheimnis entfernt“ aktiviert werden.

Redigierung muss vor Queue, Synthese, Diagnoseprotokoll und Export erfolgen. Sie ersetzt keine Zugriffskontrolle und darf nicht als vollständige Erkennung unbekannter Geheimnisse dargestellt werden.

### 18. Tool-Ausgaben

**Entscheidung:** Standardmäßig begrenzen und zusammenfassen. Vollständige Ausgabe nur für ausgewählte Tools und nach expliziter Aktivierung.

Fehler werden bevorzugt gesprochen. Lange Terminalausgaben, Rohdaten, Binärinhalte, große JSON-Antworten und wiederholte Statusmeldungen werden nicht vollständig vorgelesen. Maximallänge und erlaubte Tools sind pro Harness und Projekt konfigurierbar.

## 5. Wiedergabe und Steuerung

### 19. Pause und Fortsetzen

**Entscheidung:** Pause soll möglichst an derselben Audioposition fortsetzen. Falls das konkrete Audio-Backend diese Fähigkeit nicht bietet, wird das Segment kontrolliert neu begonnen. Das Verhalten muss pro Backend dokumentiert sein.

### 20. Prioritäten

Reihenfolge:
1. Kritische Fehler und Sicherheitsmeldungen
2. Aktivierte wichtige Statusmeldungen
3. Normale Prosa
4. Tool-Ausgaben
5. Code

Die Reihenfolge ist konfigurierbar. Einträge gleicher Priorität werden grundsätzlich in Empfangsreihenfolge verarbeitet.

### 21. Unterbrechungen

**Entscheidung:** Nur Fehler und ausdrücklich als wichtig markierte Statusmeldungen dürfen unterbrechen.

Ein laufendes Segment wird bei einer kritischen Meldung abgebrochen. Die bisherige Queue bleibt nur erhalten, wenn der Kontext unverändert und die Fortsetzung sinnvoll ist. Bei Projekt- oder Harness-Wechsel wird sie verworfen.

### 22. Queue-Aktionen

Alle folgenden Aktionen sind sowohl im Panel als auch über die geschützte API verfügbar:
- Pause
- Fortsetzen
- Aktuelles Segment überspringen
- Queue leeren
- Sofort stoppen

Zusätzlich werden Queue-Länge, aktuelles Segment und Wiedergabestatus angezeigt.

## 6. Dashboard und VS-Code-Panel

### 23. Pflichtinhalte der ersten UI-Version

Reihenfolge:
1. Aktuelles Projekt und aktiver Harness
2. Verbindungs-, Engine- und Modellstatus
3. Aktuelle Sprachausgabe und Queue
4. Stimme und Sprechtempo
5. Schalter für Prosa, Code, Zwischenmeldungen, Tools und Fehler
6. Wiedergabesteuerung
7. Harness- und Projektprofile
8. Diagnoseinformationen und API-Key-Verwaltung für berechtigte Administratoren

Das Panel wird in VS Code integriert. Kein separates schwebendes Fenster als primärer Bedienweg.

### 24. Stimmen pro Harness

**Entscheidung:** Profile werden im Panel mit Harness-Auswahl gepflegt; die wichtigsten Einstellungen sind zusätzlich über VS-Code-Einstellungen zugänglich. Projektprofile liegen in der Projektkonfiguration.

**Ja, eine Projektstimme überschreibt die globale Stimme.** Die Priorität lautet: Projekt-Harness-Profil → globales Harness-Profil → globale Standardeinstellung.

Die Stimme wird erst nach einem Hörtest als Standard festgelegt. Eine Modellstimme und eine NVIDIA-Stimme sind unterschiedliche Engine-Profile und dürfen nicht als identische Stimmen behandelt werden.

### 25. Barrierefreiheit

**Verbindliche Anforderungen:**
- vollständige Tastaturbedienung
- sichtbarer und nachvollziehbarer Fokus
- sinnvolle Fokusreihenfolge
- Screenreader-Beschriftungen und Statusansagen
- keine alleinige Information über Farbe
- keine ungefragten, mehrfach wiederholten Ansagen
- bedienbare Pause-, Stopp- und Überspringen-Funktionen
- zugängliche Fehlermeldungen und Verbindungsstatus

Abnahme erfolgt mit tatsächlicher Tastatur- und Screenreader-Nutzung, nicht nur durch Sichtprüfung.

### 26. Bedeutung der API-Key-Verwaltung

**Entscheidung:** Primär Schlüssel für zugreifende Harness-Clients. Anbieter-Schlüssel sind davon getrennte Zugangsdaten und werden nur verwaltet, wenn eine konkrete Engine sie benötigt.

Administratoren dürfen Schlüssel anlegen, Berechtigungen vergeben, Metadaten einsehen und Schlüssel widerrufen. Die Admin-Berechtigung wird über eine explizite lokale Admin-Einrichtung beziehungsweise einen bereits gesicherten Administrationszugang vergeben. Ein gewöhnlicher Harness-Schlüssel darf keine Adminrechte erhalten.

## 7. API, Sicherheit und Betrieb

### 27. API-Zugriff

**Entscheidung:** Zunächst lokale Prozesse auf demselben Rechner.

Standardmäßig nur an `127.0.0.1` binden. Remote-Zugriff ist eine gesondert aktivierte Betriebsart und darf erst nach implementierter Authentifizierung, Autorisierung und Transportabsicherung verfügbar werden.

### 28. Pflicht-API-Routen

Erste Version:
- Bereitschaft und Engine-Status
- Einstellungen lesen und ändern
- Harness-Status
- Wiedergabe steuern
- API-Schlüssel erstellen, auflisten und widerrufen

Jede Route erhält eine explizite Berechtigungsprüfung. Nicht authentifizierte Anfragen werden abgewiesen. Fehlermeldungen enthalten keine Schlüssel, internen Geheimnisse oder vollständigen privaten Inhalte.

### 29. API-Schlüssel

**Entscheidung:** Kryptografisch zufällige Schlüssel mit eindeutiger ID, Name, Berechtigungen, Erstellungsdatum und optionalem Ablaufdatum.

Der Klartext wird bei der Erstellung genau einmal angezeigt. Dauerhaft gespeichert wird ausschließlich ein sicherer Schlüssel-Hash. Schlüssel werden weder protokolliert noch in Projektdateien, Quellcode oder Client-Logs geschrieben.

Widerruf muss sofort wirksam werden. Rollen und Berechtigungen folgen dem Prinzip der minimal erforderlichen Rechte.

### 30. Speichergrenzen

**Vorläufige Startgrenzen:**
- Queue: maximal 100 Segmente je Sitzung
- Deduplizierung: maximal 24 Stunden
- Diagnoseereignisse: maximal 7 Tage
- Vollständiger Antwort- und Tool-Ausgabeverlauf: standardmäßig nicht persistent
- Größenlimits: für Event-Nutzdaten und API-Anfragen verbindlich festlegen und testen

Bei Überschreitung wird kontrolliert verworfen oder abgewiesen. Es gibt keine unbegrenzten Warteschlangen und kein stilles dauerhaftes Mitschneiden.

### 31. Diagnose und Datenschutz

Standardmäßig dürfen Status, Zeitstempel, Harness-ID, Projektkennung, Latenz, Segmentanzahl und Fehlerkategorien gespeichert werden. Vollständige Antworttexte und Tool-Ausgaben bleiben ausgeschlossen.

Nutzer erhalten eine nachvollziehbare Möglichkeit, Diagnosedaten einzusehen, zu exportieren und zu löschen. Geheimnisse werden vor Protokollierung redigiert. Diagnoseaufbewahrung ist konfigurierbar und standardmäßig auf sieben Tage begrenzt.

## 8. TTS-Engine und native Runtime

### 32. Plattform- und Hardwareanforderungen

**Entscheidung:** Linux x86-64 ist die erste Zielplattform. ARM64, Windows und macOS werden nachgewiesen, bevor sie als unterstützt gelten.

Pocket-TTS ONNX INT4 wird erst dann Standard, wenn Modell, Runtime, Lizenz, Speicherbedarf, Synthesequalität und Latenz tatsächlich geprüft wurden. Der ungefähr 106 MB große Modellbestand ist ein Richtwert für die Modellartefakte, kein vollständiger Speicherbedarf der Laufzeit.

Mindesthardware und RAM-Grenzen werden nach reproduzierbaren Tests festgelegt, nicht erfunden.

### 33. Stimmenauswahl

**Entscheidung:** Die Stimmenliste wird aus den tatsächlich verfügbaren Modellartefakten und der jeweiligen Engine abgeleitet.

Für die bevorzugte NVIDIA-Ausgabe bleibt `nvidia:DE-DE.Mia` die Standardstimme, wenn diese Engine verfügbar ist. Für Pocket-TTS werden mehrere Stimmen nach Hörtest angeboten. `charles` ist wegen der gewünschten weiblichen Stimmen kein Standardprofil.

Jeder Harness erhält ein eigenes Profil. Die anfängliche Zuordnung darf dieselbe Stimme verwenden, bleibt aber unabhängig änderbar. Unbekannte Stimmen-IDs werden als ungültig gemeldet und nicht stillschweigend ersetzt.

### 34. Externer Runtime-Prozess

**Entscheidung:** Nur nach einem Laufzeit-Prototyp und dokumentierter Architekturentscheidung.

Native BKG-Integration bleibt das Ziel. Falls keine geeignete native ONNX- oder Audio-Integration existiert, darf ein austauschbarer Worker nur nach einem nachgewiesenen technischen Bedarf eingesetzt werden. Prozessgrenze, Protokoll, Fehlerbehandlung, Berechtigungen und Ressourcenverbrauch müssen dokumentiert sein.

Kein Python- oder Node-Prozess wird stillschweigend zum verpflichtenden Kern des BKG-Zig-Frameworks gemacht.

### 35. Engine-Schnittstelle

Pflichtfunktionen:
- Synthese einzelner Segmente
- Abbruch
- Stimmenliste
- Sprach- und Stimmenmetadaten
- Modell- und Engine-Status
- Fehlerstatus
- konfigurierbare Sprechparameter

Streaming-Synthese wird als eigene Fähigkeit ausgewiesen. Eine Engine, die nur fertige Segmente synthetisieren kann, darf nicht als Audio-Streaming-Engine ausgegeben werden.

### 36. Modell- und Runtime-Dateien

**Entscheidung:** Expliziter Download mit Fortschritt und Zustimmung.

Modelldateien werden in einem dokumentierten BKG-TTS-Datenverzeichnis gespeichert, getrennt vom Quellcode und den Projekt-Hooks. Der konkrete plattformgerechte Pfad wird bei der Implementierung festgelegt.

Offline-Nutzung bereits installierter Modelle muss möglich sein. Downloads prüfen Integrität und Version. Updates dürfen die letzte funktionierende Version erst ersetzen, wenn die neue Version erfolgreich geprüft wurde. Rollback und Entfernung sind dokumentiert.

## 9. BKG-Integration und Migration

### 37. Anwendungsschicht

**Entscheidung:** Zuerst den vollständigen BKG-Anwendungsweg prüfen. Bestehende Bibliotheken werden nur dann ohne CLI-Abhängigkeit integriert, wenn dies dem tatsächlichen Framework-Vertrag entspricht.

Der fehlende oder unklare CLI-Einstiegspunkt wird als technische Voraussetzung dokumentiert und gegebenenfalls separat wiederhergestellt. Kein zweiter, ungeprüfter Einstiegspunkt wird erfunden.

### 38. Schichtzuständigkeit

Die eingefrorene Reihenfolge bleibt unverändert:

`zig.vanilla → banana.bkg → zig-body.bkg → zig-app.bkg`

- `zig.vanilla`: Upstream-Referenz, nicht für BKG-spezifische Änderungen verändern.
- `banana.bkg`: BKG-eigene Zig-Version und dort erforderliche Fork-Anpassungen.
- `zig-body.bkg`: gemeinsam nutzbare Framework-Funktionen und passende native Schnittstellen.
- `zig-app.bkg`: BKG-TTS-Anwendung, Konfiguration und Anwendungskomposition.

Die genaue Zuordnung von ONNX-Runtime, Audioausgabe und plattformspezifischen Adaptern erfordert einen technischen Nachweis. Keine Schicht wird umgangen.

### 39. Migration bestehender Copilot-TTS-Konfigurationen

**Entscheidung:** Importvorschau und ausdrückliche Bestätigung.

Bestehende Einstellungen und Hooks werden erkannt, angezeigt, gesichert und erst nach Bestätigung migriert. Die ursprünglichen Dateien bleiben archiviert und können wiederhergestellt werden.

Ein Rollback muss die vorherigen Einstellungen, Hook-Inhalte und den bisherigen Copilot-Bedienweg wiederherstellen können. Nicht zuordenbare Einstellungen werden nicht stillschweigend verworfen.

### 40. Produktname und Kompatibilität

**Entscheidung:** BKG-TTS ist der neue Produktname in UI, Dokumentation, Befehlen und neuen Metadaten.

Bestehende `copilot-tts.*`-Einstellungen und Befehle werden während einer Übergangsphase über kompatible Aliasnamen unterstützt, soweit technisch möglich. Eine Umbenennung darf keine vorhandene Installation unbrauchbar machen. Die endgültige Marketplace-ID wird erst nach Prüfung der bestehenden Extension-Metadaten festgelegt.

## 10. Abnahme und Veröffentlichung

### 41. Messbare Live-Latenz

**Ziel:** Beginn der Wiedergabe innerhalb von 1 Sekunde nach Eingang eines vollständigen, sprechfertigen Segments, sofern Engine und Audioausgabe bereit sind.

Die Messung trennt Ereignisverarbeitung, Segmentierung, Synthese und Audiostart. Latenzen werden unter reproduzierbaren Bedingungen getestet. Der Zielwert ist kein Versprechen, bevor der Prototyp ihn erreicht.

### 42. Adaptertests

Jeder Adapter benötigt:
- reproduzierbare Fixture-Aufzeichnungen
- Tests auf fehlende, verspätete und duplizierte Events
- Abbruch- und Wiederverbindungstests
- Kontextwechseltests
- Tests der Inhaltsregeln
- mindestens einen echten End-to-End-Test vor stabiler Freigabe

Wenn ein Harness in CI nicht installiert werden kann, werden Fixture-Tests verpflichtend und ein dokumentierter manueller End-to-End-Test ist vor der Freigabe erforderlich.

### 43. Datenschutz- und Sicherheitstests

Verbindlich:
- bekannte API-Schlüssel und Tokens werden vor Synthese redigiert
- Geheimnisse erscheinen nicht in Logs, Queue-Diagnosen oder Exporten
- Klartext-API-Schlüssel werden nur einmal angezeigt
- widerrufene Schlüssel verlieren ihre Berechtigung
- unberechtigte Admin-Anfragen werden abgewiesen
- Hook-Archive enthalten keine Zugangsdaten
- Projektwechsel gibt keine vorherigen Inhalte erneut aus
- Löschfunktionen entfernen die jeweils vorgesehenen persistenten Daten
- ungültige und übergroße Events werden sicher behandelt

### 44. Veröffentlichung unvollständiger Integrationen

**Entscheidung:** Experimentelle Adapter dürfen sichtbar sein, müssen aber eindeutig als experimentell und gegebenenfalls nicht-live gekennzeichnet werden. Ein Adapter wird erst nach bestandenem End-to-End-Test als stabil markiert.

Für jede Integration sind Fähigkeiten, verfügbare Events, Fallback-Verhalten, bekannte Einschränkungen und Testnachweise dokumentiert. Nicht unterstützte Funktionen werden nicht als vorhanden beworben.

## Verbindliche Profilstruktur für Stimmen und Projekte

Die Konfiguration folgt dieser Priorität:

1. Projektprofil für den konkreten Harness
2. Globales Profil des Harness
3. Globale BKG-TTS-Standardeinstellung

Jedes Profil kann folgende Werte separat setzen:
- Engine und Stimme
- Sprechtempo
- Prosa ein/aus
- Code-Modus
- Syntaxzeichen
- Zwischenmeldungen
- Tool-Ausgaben
- Fehleransagen
- Zusammenfassungen
- Wiedergabeprioritäten

Beispiel für logische Profile, nicht als bereits vorhandene Dateien zu verstehen:

- `copilot`
- `claude`
- `codex`
- `opencode`
- `pi`
- `omp`
- `bkg-agent`

Alle Profile dürfen zunächst dieselbe Standardstimme nutzen. Änderungen an einem Profil verändern keine anderen Harness-Profile. Eine Projektstimme überschreibt ausschließlich das entsprechende Harness-Profil in diesem Projekt.

## Umsetzungsregel

Vor jeder Implementierung werden das vorhandene Repository, die BKG-Schichten, der bisherige Copilot-TTS-Code und die tatsächlichen Harness-Schnittstellen geprüft. Danach folgen getrennte, überprüfbare Meilensteine mit Tests und nachvollziehbaren Änderungen.

Technische Unsicherheiten werden als Nachweisaufgaben geführt. Bestehende Funktionalität wird nicht entfernt, kein Streaming vorgetäuscht, keine fremde Konfiguration ungefragt überschrieben und nichts ohne tatsächlichen Test als fertig erklärt.
Hier ist der BKG-TTS-Umsetzungsplan als aufeinander aufbauende Milestones. Jeder Milestone erhält einen eigenen Branch und einen Squash-PR. Erst nach bestandenen Tests geht es weiter. Die vorhandenen Copilot-TTS-Funktionen bleiben während der gesamten Umsetzung erhalten.

## M0

Bestandsaufnahme und Kompatibilitätsnachweis

Grundlage

- Vorhandene Copilot-TTS-Funktionen, Extension und Hooks erfassen.
- BKG-Zig-Schichten und Build-Einstiegspunkte prüfen.
- Tatsächliche Streaming- und Hook-Fähigkeiten aller sieben Harnesses untersuchen.
- ONNX-Runtime, Audioausgabe und Plattformkompatibilität prototypisch prüfen.
- Risiken, Abhängigkeiten und Testergebnisse dokumentieren.

Abnahme: Technischer Bericht mit verifizierten Fähigkeiten und konkretem Implementierungsplan. Keine erfundenen Schnittstellen.

## M1

Gemeinsames Event-Modell und Engine-Schnittstelle

- Einheitliches Event-Modell für Harness, Projekt, Sitzung, Antwort und Segment.
- Engine-Schnittstelle mit Synthese, Stimmen, Abbruch und Status.
- Geordnete Queue, Deduplizierung und Kontexttrennung.
- Einheitliche Fehler- und Fallback-Regeln.

Abnahme: Automatisierte Tests für Reihenfolge, Duplikate, Fehler und Abbruch.

## M2

Live-TTS für Copilot und Claude Code

- Bestehenden Copilot-Bedienweg erhalten.
- Claude Code als zweiten End-to-End-Adapter anbinden.
- Verfügbare Ereignisse während der Generierung verarbeiten.
- Satzorientierte Segmentierung mit konfigurierbarem Zeitlimit.
- Stoppen, Abbruch und Projektwechsel zuverlässig behandeln.

Abnahme: Beide Harnesses werden mit echten Ereignissen getestet. Live-Fähigkeit und Fallbacks sind klar ausgewiesen.

## M3

Projektprofile, Harness-Stimmen und Sprechregeln

- Unabhängige Stimmenprofile für Copilot, Claude, Codex, OpenCode, Pi, OMP und BKG-Agenten.
- Konfigurationspriorität: Projekt-Harness → globaler Harness → globale Vorgabe.
- Prosa, Code, Zwischenmeldungen, Tool-Ausgaben und Fehler separat schaltbar.
- Code-Modi: Aus, Zusammenfassung und Vollständig.
- Geheimnisse vor Synthese und Diagnose redigieren.

Abnahme: Änderungen an einem Profil beeinflussen keine anderen Profile. Projektwechsel übernimmt die richtigen Regeln.

## M4

VS-Code-Panel und Wiedergabesteuerung

- Integriertes Panel statt separatem schwebendem Fenster.
- Aktives Projekt, Harness, Stimme, Engine und Queue anzeigen.
- Pause, Fortsetzen, Überspringen, Queue leeren und Sofortstopp.
- Tastatur- und Screenreader-Unterstützung.
- Projektprofile über das Panel verwalten.

Abnahme: Die zentralen Funktionen sind ohne Maus bedienbar und Statusänderungen werden zugänglich angesagt.

## M5

API, Admin-Dashboard und Schlüsselverwaltung

- Lokale API mit Bereitschaft, Einstellungen, Harness-Status und Wiedergabesteuerung.
- API-Schlüssel mit Berechtigungen, Ablaufdatum und sofortigem Widerruf.
- Klartextschlüssel nur bei Erstellung anzeigen, dauerhaft nur Hash speichern.
- Nicht-lokalen Netzwerkzugriff erst nach abgesicherter Authentifizierung erlauben.
- Status und Diagnosedaten begrenzt und datenschutzbewusst speichern.

Abnahme: Rollen-, Authentifizierungs-, Widerrufs- und Datenschutztests bestanden.

## M6

TTS-Runtime und Pocket-TTS-Integration

- Pocket-TTS ONNX INT4 als bevorzugtes Modell technisch validieren.
- Stimmenvergleich und Auswahl durchführen.
- Native BKG-Integration prüfen.
- Falls erforderlich, einen externen Engine-Worker nur nach dokumentiertem Prototyp zulassen.
- Modell-Download, Integritätsprüfung, Offline-Betrieb und Rollback umsetzen.

Abnahme: Reproduzierbarer Synthesetest und dokumentierte Latenz-, Ressourcen- und Plattformmessungen.

## M7

Weitere Harnesses und BKG-Agenten

- OpenAI Codex
- OpenCode
- Pi
- OMP
- BKG-Agenten
- Dokumentierter Adaptervertrag für künftige Harnesses

Abnahme: Jeder Adapter besitzt reproduzierbare Fixture-Tests und einen echten End-to-End-Nachweis vor stabiler Freigabe. Adapter ohne echtes Streaming werden entsprechend gekennzeichnet.

## M8

Migration, Plattformtests und Veröffentlichung

- Bestehende Copilot-Konfigurationen mit Vorschau importieren.
- Originale archivieren und Rollback ermöglichen.
- Linux stabilisieren, danach Windows, macOS und Remote-Szenarien prüfen.
- Barrierefreiheit, Geheimnisschutz, Latenz und Wiederverbindung testen.
- BKG-TTS als Produktname einführen und notwendige Kompatibilitätsaliasse erhalten.

Abnahme: Dokumentierte Freigabekriterien erfüllt; unvollständige Adapter bleiben experimentell.

## Globale Regeln für alle Milestones

- Architektur: `zig.vanilla → banana.bkg → zig-body.bkg → zig-app.bkg`. Keine Schicht überspringen.
- Stimmen: Pro Projekt und Harness getrennt; `nvidia:DE-DE.Mia` als bevorzugte NVIDIA-Stimme. Pocket-TTS-Stimmen erst nach Hörtest auswählen.
- Live-Ziel: Angestrebter Audiostart innerhalb einer Sekunde nach Eingang eines sprechfertigen Segments, durch Messungen zu bestätigen.
- Sicherheit: Keine Geheimnisse in Logs, Hook-Archiven oder Projektkonfigurationen. Adminrechte strikt trennen.
- Entwicklung: Ein Milestone = ein Branch = ein Squash-PR. Kein Push ohne ausdrückliche Freigabe.
- Qualität: Keine Platzhalterimplementierungen, kein vorgetäuschtes Streaming und keine Freigabe ohne passende Tests.

Wichtig für die Reihenfolge: M0 muss zuerst zeigen, welche Runtime- und Audioarchitektur tatsächlich funktioniert. M1 bis M5 bauen den gemeinsamen Produktkern. M6 kann parallel vorbereitet werden, darf aber die eingefrorene BKG-Schichtenfolge nicht umgehen. Weitere Harnesses werden über den gemeinsamen Vertrag ergänzt, statt sieben separate TTS-Systeme zu bauen.