# BKG-TTS Zig App

Dieses Verzeichnis im Repository-Root ist der festgelegte Ort der neuen BKG-TTS-Anwendung.

## Architekturgrenzen

- App-Schicht: `zig-app.bkg`; dieses Verzeichnis enthält die Produkt-App.
- Framework-Abhängigkeit: `zig-body.bkg` ausschließlich über die dokumentierte lokale Abhängigkeit und benötigte Module.
- `banana.bkg` bleibt die BKG-Zig-Fork-Schicht und wird nicht als Ablage für App-Code verwendet.
- `zig.vanilla` bleibt unveränderter Upstream-Zig-Referenzstand. Hier werden keine BKG-Änderungen eingetragen.
- Schichtenreihenfolge: `zig.vanilla → banana.bkg → zig-body.bkg → zig-app.bkg`.

## Implementierungsstatus

Dies ist zunächst die dokumentierte Zielstruktur. App-Quellcode wird erst nach dem Framework-/Build-Audit und den zwei tatsächlichen Reviews ergänzt. Keine Platzhalter als funktionsfähige Implementierung ausgeben. Bestehende Copilot-TTS-Dateien unter `.bkgtts/` bleiben bis zur getesteten Migration unangetastet.

## Build und Tests

Build-Kommandos werden erst nach Prüfung der tatsächlich vorhandenen Zig-Version, des Paketmanifests und der BKG-Framework-Abhängigkeiten festgeschrieben. Keine ungeprüften Befehle oder Erfolgsmeldungen.
