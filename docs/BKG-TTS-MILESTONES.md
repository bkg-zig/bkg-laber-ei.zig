# BKG-TTS: Umsetzungsplan und verbindliche Arbeitsregeln

Status: Planung und Audit zuerst; Umsetzung fortlaufend bis alle Milestones abgeschlossen oder nachweislich blockiert sind.

## Verbindliche Regeln

1. **Nur Pull Requests:** Niemals direkt auf `main` schreiben. Jeder Milestone erhält einen eigenen Branch und einen eigenen PR. Änderungen an demselben Pfad werden sequenziell vorgenommen.
2. **Keine künstlichen Pausen zwischen Milestones:** Nach Abschluss, Tests und Review eines Milestones wird unmittelbar mit dem nächsten begonnen. Nicht bei jedem Milestone auf eine neue Chat-Bestätigung warten. Nur echte Blockaden, fehlende Berechtigungen, nicht verfügbare Infrastruktur oder eine Sicherheitsentscheidung, die nicht sicher automatisiert werden kann, unterbrechen die Arbeit.
3. **PR-Lebenszyklus:** Ein PR darf automatisch geschlossen werden, wenn nach Prüfung kein Feature, kein notwendiger Fix und keine relevante Dokumentationsänderung übrig bleibt oder sein Diff ausschließlich unbeabsichtigten Code-/Feature-Drift enthält. Vor dem Schließen Diff und Status dokumentieren. Ein PR mit gültigen Änderungen wird nicht allein wegen fehlender CI oder aus Zeitgründen geschlossen. Merge nur bei erfüllten Akzeptanzkriterien und grünen erforderlichen Checks; keine automatische Umgehung von Branch-Schutz oder Reviews.
4. **Zwei unabhängige Reviews vor Implementierung:** Review A prüft Framework-Schichten, Build, Paketmanifest und vorhandene Bibliotheken. Review B prüft TTS-Architektur, Harness-Events, Datenschutz, API-Sicherheit und Erhalt bestehender Funktionen. Ergebnisse samt Datei-/Zeilenbelegen in `docs/` festhalten. Keine Reviews als erfolgt ausgeben, solange sie nicht tatsächlich vorliegen.
5. **Zig und Framework zuerst:** Backend und Kernlogik in Zig, ausschließlich innerhalb der vorhandenen BKG-Schichten. TypeScript nur dort, wo die VS-Code-Extension-API es erfordert. Kein paralleles Ersatz-Framework, keine Vendor-Code-Kopie, keine Platzhalter, keine Fake-Events und keine README-only-Milestones.
6. **Vanilla und Banana strikt trennen:** Reihenfolge `zig.vanilla → banana.bkg → zig-body.bkg → zig-app.bkg`. `zig.vanilla` ist unveränderter Upstream-Zig-Referenzstand. Niemals BKG-Code, App-Code, Workarounds oder eigene Patches dort eintragen. `banana.bkg` ist die eigenständige BKG-Zig-Fork-Schicht; nur BKG-spezifische Compiler-/Sprachänderungen gehören dorthin. Allgemeine Framework-APIs und Bibliotheken gehören in `zig-body.bkg`; Produktkomposition und TTS-App gehören in `zig-app.bkg`. Abhängigkeiten zeigen nur von einer Schicht auf die darunterliegende. Keine Rückwärtsabhängigkeiten, keine Umgehung der BKG-API durch Upstream-Interna. Vor jeder Änderung die kanonischen Regeln unter `/srv/bkg/playground/zig-docs-bkg` und die verbindlichen Repository-Dokumente prüfen. Bei Konflikten oder fehlenden Regeln erst dokumentieren und klären, nicht stillschweigend entscheiden. Vanilla-Updates dürfen BKG-Patches nicht überschreiben; Banana-Änderungen müssen gegen die festgelegte Vanilla-Basis nachvollziehbar sein. Jeder PR nennt betroffene Schicht und Begründung.
7. **Bestehende Funktion erhalten:** Das bestehende `.bkgtts/`-Verhalten, die Copilot-Extension, bestehende Hooks und Konfigurationen zuerst inventarisieren. Migration schrittweise, mit Rückweg und ohne stilles Entfernen funktionierender Funktionen.
8. **Echte Ergebnisse:** Builds, Tests, CI und Plattformabdeckung nur als erfolgreich melden, wenn tatsächlich ausgeführt. Nicht getestete Harnesses/Plattformen ausdrücklich kennzeichnen.
9. **Sicherheit:** API zunächst nur an `127.0.0.1` binden. Schlüssel nur einmal im Klartext ausgeben, ausschließlich Hashes speichern, Schlüssel nie protokollieren, Widerruf sofort wirksam machen. Geheimnisse vor Synthese, Persistenz und Diagnoseausgaben redigieren.
10. **Keine ungefragten Pushes auf `main`:** Branches und PRs sind erlaubt; kein direkter Main-Push. PR-Merge folgt den Regeln des Repositories und den Checks.

## Verbindlicher App-Ort

Die neue App liegt im Repository-Root unter `bkg-tts.zig/`. Dieses Verzeichnis ist Produktcode der `zig-app.bkg`-Schicht. Es bindet `zig-body.bkg` nur über die dokumentierte lokale Framework-Abhängigkeit und ausschließlich benötigte Module ein. App-Code gehört weder nach `zig.vanilla` noch nach `banana.bkg` oder in Framework-Quellordner. Bestehende `.bkgtts/`-Dateien bleiben während Audit und Migration erhalten und werden nicht als Zielordner für die neue Zig-App verwendet. TypeScript bleibt auf die notwendige VS-Code-Extension-Grenze beschränkt; Kernlogik, Events, Auth/API und Orchestrierung sind Zig.

## Zielbild

BKG-TTS ist eine harness-unabhängige Sprach-Ausgabe mit einem gemeinsamen Event-Modell, konfigurierbaren Sprach-/Filterprofilen, einer Engine-Abstraktion und einer integrierten, barrierearmen VS-Code-Seitenleiste. Sie unterstützt echte Live-Ereignisse, wenn ein Harness sie bereitstellt. Adapter ohne echte Live-Events müssen ihren Fallback sichtbar als nicht-live deklarieren. Es werden keine künstlichen Streaming-Events erzeugt.

Unterstützte Harness-Ziele: GitHub Copilot Chat, Claude Code, OpenAI Codex, OpenCode, Pi, OMP und BKG-Agenten. Jeder Adapter erhält eine dokumentierte Fähigkeitsmatrix und Integrationstests.

## Milestones

### M0 — Audit und zwei Reviews
- [ ] Vollständigen Repository- und `.bkgtts/`-Bestand erfassen.
- [ ] Kanonische Vanilla-/Banana-Regeln und Layer-Verträge aus dem verbindlichen Regelwerk prüfen.
- [ ] Root-Ziel `bkg-tts.zig/` als App-Schicht bestätigen, ohne Code in Vanilla, Banana oder Framework-Quellordner abzulegen.
- [ ] BKG-Framework-Module und Schichtgrenzen verifizieren.
- [ ] `build.zig.zon`-Pfade und CLI-Einstieg mit einem echten Build prüfen; Manifest nicht anhand der README beurteilen.
- [ ] Review A: Framework, Build, Paketpfade und Wiederverwendung.
- [ ] Review B: TTS, Harness-Live-Events, Sicherheit, Migration und Accessibility.
- [ ] Befunde mit konkreten Pfaden und reproduzierbaren Prüfungen unter `docs/` dokumentieren.
- [ ] Root-Verzeichnis `bkg-tts.zig/` für die neue App anlegen; bestehende `.bkgtts/`-Funktionen nicht verschieben oder löschen.
- Akzeptanz: Beide Reviews sind tatsächlich abgeschlossen; Ausgangs-Buildstatus und bestehende Funktionen sind dokumentiert.

### M1 — Gemeinsamer Ereigniskern
- [ ] Einheitliches Event-Modell mit Harness, Projekt, Sitzung, Event-ID, Typ, Zeitstempel, Live-Fähigkeit und Datenschutzklasse.
- [ ] Deduplizierung, geordnete Queue, begrenzter Rückstau, Abbruch und Fehlerzustände.
- [ ] Trennung von User-/Assistant-Prosa, Code, Zwischenstatus, Tool-Ausgabe, Fehlern und Zusammenfassung.
- [ ] Engine-Schnittstelle und überprüfbare Tests mit deterministischen Fixtures.
- Akzeptanz: Reale Eventdaten bleiben unterscheidbar; keine erfundenen Live-Ereignisse; Queue ist begrenzt und testbar.

### M2 — Erste Live-End-to-End-Adapter
- [ ] Copilot-Integration und bestehende VS-Code-TTS-Funktionen erhalten.
- [ ] Claude-Code-Adapter mit nachgewiesenen tatsächlichen Ereignisquellen.
- [ ] Segmentierung, Unterbrechung, Stop/Resume und Fehlerbehandlung.
- [ ] End-to-End-Tests von echtem Adapter-Event bis zum Audio-Engine-Aufruf.
- Akzeptanz: Beide Integrationen funktionieren ohne Fake-Streaming; Fähigkeit und Latenz sind gemessen und dokumentiert.

### M3 — Profile, Stimmen und Datenschutz
- [ ] Priorität: Projektprofil > Harness-Profil > globale Defaults.
- [ ] Eigene Stimme und Regeln pro Projekt und Harness.
- [ ] Kategorien separat schaltbar: Prosa, Code, Zwischenmeldungen, Tool-Ausgaben, Fehler, Zusammenfassungen.
- [ ] Code-Modi: aus, Zusammenfassung, vollständig; Zeichensetzung optional vorlesen.
- [ ] Geheimnis-Redaktion vor TTS und vor Diagnose-/Logausgabe.
- Akzeptanz: Profilauflösung, Regelkombination, Redaktion und Überschreiben vollständig getestet.

### M4 — Integrierte VS-Code-Oberfläche
- [ ] TTS-Panel innerhalb der IDE, kein schwebendes Fenster.
- [ ] Tastaturbedienung und Screenreader-Labels, Statusmeldungen und Fokusführung.
- [ ] Wiedergabe, Pause, Abbruch, Warteschlange, Stimme, Lautstärke und Profile.
- [ ] Nur das aktive IDE-Projekt bzw. explizit freigegebene Projekte sprechen.
- Akzeptanz: Accessibility-Prüfliste und Bedienungstests; vorhandene Copilot-Bedienung bleibt erhalten.

### M5 — Zig-API und Admin
- [ ] Vorhandene BKG-HTTP-, Auth-, Event- und WebSocket-Bibliotheken verwenden, sofern der Audit ihre Eignung bestätigt.
- [ ] API anfangs ausschließlich an `127.0.0.1`.
- [ ] Admin-Ansicht zum Erstellen, Anzeigen von Metadaten und Widerrufen von API-Schlüsseln.
- [ ] Schlüsselmaterial nur einmal zeigen; gehashte Speicherung, sichere Vergleiche, sofortiger Widerruf, keine Schlüssel in Logs.
- [ ] Authentifizierungs-, Berechtigungs- und Missbrauchstests.
- Akzeptanz: Kein anonymer Fernzugriff, keine Klartext-Schlüsselspeicherung, Widerruf durch Integrationstest nachgewiesen.

### M6 — TTS-Engine und Pocket-TTS-Prototyp
- [ ] Engine-Adapter und Modell-Lifecycle implementieren, unabhängig vom Harness.
- [ ] Pocket-TTS ONNX INT4 als bevorzugten Kandidaten auf tatsächliche Kompatibilität prüfen.
- [ ] Modellintegrität, Downloadstatus, Abbruch, Speicherbedarf, Fehler und Rollback behandeln.
- [ ] NVIDIA-Engine und Stimme `nvidia:DE-DE.Mia` als getrennte, explizit konfigurierte Option erhalten.
- [ ] Qualität, Latenz, CPU-/Speicherbedarf und Plattformunterstützung messen.
- Akzeptanz: Nur nachgewiesene Modelle/Plattformen als unterstützt markieren; kein Modell als kompatibel deklarieren, bevor es real läuft.

### M7 — Weitere Harness-Adapter
- [ ] OpenAI Codex.
- [ ] OpenCode.
- [ ] Pi.
- [ ] OMP.
- [ ] BKG-Agenten.
- [ ] Für jeden Adapter: echte Eventquelle, Fähigkeitsmatrix, Auth-/Datenschutzprüfung, Integrations- und Fehlerfalltests.
- Akzeptanz: Jeder Adapter besteht die gemeinsame Vertragstestsuite oder ist ausdrücklich als experimentell/nicht-live markiert.

### M8 — Migration, Plattformen und Release
- [ ] Bestehende Hooks und Konfigurationen mit Migrations- und Rollback-Anleitung übernehmen.
- [ ] Linux zuerst; Windows, macOS und Remote-Entwicklung nach realen Tests freigeben.
- [ ] Barrierefreiheit, Sicherheitsgrenzen, Queue-Verhalten und Fehlerwiederherstellung prüfen.
- [ ] Installations-, Upgrade-, Deinstallations- und Wiederherstellungstests.
- [ ] Dokumentation, bekannte Einschränkungen und Release-Kriterien aktualisieren.
- Akzeptanz: Alle Pflichtprüfungen bestanden, offene Einschränkungen explizit, keine unbeabsichtigten Feature- oder Code-Drifts.

## Durchgängige CI- und Review-Gates

Jeder Milestone-PR enthält:
- Ziel und begrenzten Umfang;
- konkrete Akzeptanzkriterien;
- tatsächliche Build-/Testbefehle und Ergebnisse;
- geänderte Framework-Schicht(en) und Begründung;
- Sicherheits- und Accessibility-Auswirkungen;
- Nachweis, dass vorhandene Funktionen nicht unbeabsichtigt entfernt wurden;
- Review-Ergebnis und offene Einschränkungen.

Ein grüner CI-Lauf allein beweist nicht die Funktionalität. Relevante End-to-End-Tests müssen die behauptete Funktion abdecken. Bei fehlender Infrastruktur wird der PR als blockiert markiert, statt Ergebnisse zu erfinden.

## Fortschrittsprotokoll

| Milestone | Status | Branch/PR | Build/Test | Review / Hinweise |
|---|---|---|---|---|
| M0 | offen | eigener PR erforderlich | Audit erforderlich | Vanilla/Banana-Grenzen und Root-App-Pfad verbindlich; zwei unabhängige Reviews ausstehend |
| M1 | offen | noch nicht erstellt | nicht ausgeführt | abhängig von M0 |
| M2 | offen | noch nicht erstellt | nicht ausgeführt | abhängig von M1 |
| M3 | offen | noch nicht erstellt | nicht ausgeführt | abhängig von M1 |
| M4 | offen | noch nicht erstellt | nicht ausgeführt | abhängig von M2 und M3 |
| M5 | offen | noch nicht erstellt | nicht ausgeführt | abhängig von M0 und M1 |
| M6 | offen | noch nicht erstellt | nicht ausgeführt | abhängig von M1 |
| M7 | offen | noch nicht erstellt | nicht ausgeführt | abhängig von M1 bis M3 |
| M8 | offen | noch nicht erstellt | nicht ausgeführt | abhängig von allen Pflichtmilestones |

Dieses Dokument ist der Arbeitsvertrag für die Umsetzung. Fortschritt darf nur nach überprüfbaren Ergebnissen eingetragen werden. Zwischen Milestones wird ohne unnötige Wartepausen weitergearbeitet; reale Blockaden werden mit Ursache, Auswirkung und nächstem konkreten Schritt dokumentiert.
