# BKG Laber EI

Dieses Workspace enthält zwei getrennte Zig-Projekte unter `framework.bkg/`:

- **Body:** [BKG Framework](framework.bkg/zig-body.bkg-main/README.md) mit Bibliotheken, Build-Konfiguration und Architektur-/Moduldokumentation.
- **Soul:** `zig-soul.bkg-banana.bkg`, ein separates Zig-Projekt.

## Handoff: Body

- Voraussetzung laut Paketmanifest: Zig **0.16.0 oder neuer**.
- Zig 0.16.0 ist benutzerlokal installiert und über `PATH` erreichbar.
- `zig build test` besteht.
- `zig build` scheitert, weil `build.zig` `utils/bkg/main.zig` referenziert, diese Datei aber weder im entpackten Verzeichnis noch im ZIP enthalten ist.

Tests im Body-Verzeichnis erneut ausführen:

```sh
cd framework.bkg/zig-body.bkg-main
zig build test
```

Nach Wiederherstellung des CLI-Einstiegspunkts zusätzlich `zig build` ausführen.

Details zum Modulbestand, zu offenen Punkten und zur Dokumentation stehen in der [Body-README](framework.bkg/zig-body.bkg-main/README.md).
