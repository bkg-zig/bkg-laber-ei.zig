# Verbindliche BKG-Zig-Regeln: Quellenverzeichnis und Layer-Vertrag

Status: Der kanonische Pfad wurde vom Projektverantwortlichen vorgegeben. Der Inhalt des lokalen Regelverzeichnisses wurde in dieser GitHub-Sitzung nicht direkt gelesen; daher ist dieses Dokument ein verbindlicher Verweis und eine Zusammenfassung bereits ausdrücklich mitgeteilter Regeln, kein behaupteter Vollabzug der lokalen Dokumentation.

## Autoritative Quelle

Absoluter Pfad auf dem BKG-System:

`/srv/bkg/playground/zig-docs-bkg`

Dieses Verzeichnis ist vor jeder Änderung an Zig, Banana, Framework oder App zu prüfen. Alle relevanten Vanilla-/Banana-Regeln, Layer-Verträge, Build-Regeln und Architekturentscheidungen dort sowie die verbindlichen Dokumente der jeweiligen Repositories sind zu berücksichtigen.

**Zugriffshinweis:** Der absolute Pfad ist auf dem BKG-System erreichbar, aber nicht automatisch über GitHub erreichbar. In dieser Sitzung ist der lokale Inhalt nicht verfügbar. Es darf nicht behauptet werden, dass die Dateien gelesen oder vollständig auditiert wurden. Wenn ein Arbeitsrechner oder Remote-Tool den Pfad nicht erreichen kann, muss die Blockade ausdrücklich festgehalten und der Inhalt über einen autorisierten Zugriff bereitgestellt werden, bevor Regeln geraten oder ergänzt werden.

## Unveränderliche Layer-Reihenfolge

`zig.vanilla → banana.bkg → zig-body.bkg → zig-app.bkg`

### 1. `zig.vanilla`

- Unveränderter Upstream-Zig-Referenzstand.
- Keine BKG-spezifischen Patches, Workarounds, Framework-Funktionen oder Produkt-App-Änderungen.
- Upstream-Aktualisierungen dürfen keine BKG-Änderungen überschreiben, da BKG-spezifische Änderungen hier nicht abgelegt werden dürfen.

### 2. `banana.bkg`

- Eigenständige BKG-Zig-Fork-Schicht auf einer nachvollziehbar festgelegten Vanilla-Basis.
- Nur BKG-spezifische Compiler- oder Sprachänderungen gehören hierher.
- Keine TTS-Produktlogik und keine gewöhnlichen Framework- oder App-Funktionen.

### 3. `zig-body.bkg`

- Gemeinsames BKG-Framework und wiederverwendbare Bibliotheken.
- Allgemeine APIs und Framework-Funktionalität gehören in diese Schicht, nicht in Vanilla oder Banana.
- Vorhandene Module sind zu prüfen und wiederzuverwenden, sofern ihre Eignung durch Audit und Tests belegt ist.

### 4. `zig-app.bkg`

- Produktanwendungen und deren Komposition.
- Die neue BKG-TTS-Anwendung liegt im Repository-Root unter `bkg-tts.zig/` und gehört zur App-Schicht.
- Die App bindet `zig-body.bkg` über die dokumentierte lokale Framework-Abhängigkeit ein und verwendet nur benötigte Module.

## Abhängigkeitsregeln

- Abhängigkeiten dürfen nur in Richtung der darunterliegenden Schicht zeigen.
- Keine Rückwärtsabhängigkeiten, keine Layer-Umgehung und kein Zugriff auf Upstream-Interna als Ersatz für die dokumentierte BKG-API.
- Produktcode gehört nicht in Compiler-/Framework-Quellordner.
- TypeScript ist ausschließlich dort zulässig, wo die VS-Code-Extension-API es erfordert; der BKG-Kern bleibt native Zig-Implementierung.
- Vendor-Repositories sind Referenzen, kein Ort zum unkritischen Kopieren von Code.

## Pflichtprüfung vor jeder Änderung

1. `/srv/bkg/playground/zig-docs-bkg` und die einschlägigen Repository-Regeln tatsächlich lesen, sofern der Zugriff verfügbar ist.
2. Betroffene Schicht und erlaubte Abhängigkeitsrichtung bestimmen.
3. Prüfen, ob die Funktion bereits in `zig-body.bkg` vorhanden ist und ob sie nachweislich geeignet ist.
4. Vanilla-Basis und Banana-spezifische Deltas nachvollziehbar halten.
5. Build, Tests und betroffene Verträge tatsächlich ausführen; Ergebnisse nicht erfinden.
6. Im PR betroffene Schicht, Begründung, Prüfungen und offene Blockaden dokumentieren.
7. Änderungen nur über einen eigenen Branch und PR; niemals direkt auf `main`.

Wenn die autoritativen lokalen Dokumente nicht erreichbar sind oder eine Regel unklar ist, darf diese Zusammenfassung nicht als Ersatz für das vollständige Regelwerk ausgegeben werden. Die Unklarheit ist vor einer möglicherweise betroffenen Implementierung zu dokumentieren und zu klären.
