# BKG-TTS Zig App

Dieses Verzeichnis im Repository-Root ist der festgelegte Ort der neuen BKG-TTS-Anwendung.

## Architekturgrenzen

- Produkt-App: Schicht `zig-app.bkg`.
- Framework-Abhängigkeit: `zig-body.bkg`, über die dokumentierte lokale Abhängigkeit und nur mit explizit benötigten Modulen.
- `banana.bkg`: BKG-Zig-Fork-Schicht; kein Ablageort für Produkt-App-Code.
- `zig.vanilla`: unveränderter Upstream-Zig-Referenzstand; keine BKG-Patches oder App-Änderungen.
- Verbindliche Reihenfolge: `zig.vanilla → banana.bkg → zig-body.bkg → zig-app.bkg`.

## Implementierungsstatus

Zielstruktur und Regeln sind dokumentiert. Funktionscode folgt nach Audit, bestätigtem Build und tatsächlichen unabhängigen Reviews. Keine Platzhalter als Implementierung ausgeben. Bestehende Copilot-TTS-Dateien unter `.bkgtts/` bleiben bis zur getesteten Migration unangetastet.

## Build und Tests

Build-Kommandos erst nach Prüfung der real vorhandenen Zig-Version, des Paketmanifests und der BKG-Framework-Abhängigkeiten festlegen. Keine ungeprüften Erfolgsmeldungen.
