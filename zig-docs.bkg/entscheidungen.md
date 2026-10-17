# BKG Zig – Architekturentscheidungen (ADR)

Format: Datum · Entscheidung · Begründung · Konsequenzen

---

## ADR-001 · 2026-09-02 · Zig statt Rust für bkg-dock Relaunch

**Entscheidung:** Das Docker-Management-UI (`bkg-dockgott`) wird nicht in Rust+Dioxus,
sondern in **Zig** als `bkg-flocker.zig` neu implementiert.

**Begründung:**
- BKG hat bereits ein eigenes Zig-Framework (`zig-body.bkg`) und einen Zig-Fork (`banana.bkg/zig.bkg`)
- Das Framework soll auf seine erste echte Probe gestellt werden
- Rust+Dioxus würde eine komplett andere Toolchain einführen
- Zig erlaubt direktere Kontrolle über Speicher und System-Calls (Unix-Socket, etc.)
- Ein Zig-Projekt ist ein vorzeigbares Referenzprojekt für das Framework

**Konsequenzen:**
- `bkg-web/websocket.zig` muss implementiert werden (war Stub)
- Docker-API-Anbindung direkt über `std.net.connectUnixSocket` ohne externe Deps
- Kein npm, kein node_modules

---

## ADR-002 · 2026-09-02 · Framework nicht als Ganzes importieren

**Entscheidung:** Apps binden **nur die benötigten Libs** einzeln ein, nicht das
gesamte Framework.

**Begründung:**
- Klare Abhängigkeitsdeklaration – jeder sieht was eine App wirklich braucht
- Kein versehentliches Einbinden von nicht benötigtem Code
- Bessere Compile-Zeiten
- Framework kann wachsen ohne alle Apps zu beeinflussen

**Konsequenzen:**
- `build.zig` jeder App muss explizit `fw.module("bkg-xyz")` aufrufen
- `build.zig.zon` nutzt `path`-Referenz auf `../../zig-body.bkg`

---

## ADR-003 · 2026-09-02 · Kein zig fetch, kein Hash-Lock für interne Deps

**Entscheidung:** Interne Framework-Abhängigkeiten werden über **`path`-Referenzen**
eingebunden, nicht über `zig fetch --save` mit Hash-Lock und Tar-Archiv.

**Begründung:**
- Hash-Lock an `/tmp/`-Pfaden ist nicht reproduzierbar
- `path`-Referenzen sind sofort nachvollziehbar und für jeden Entwickler transparent
- Keine Build-Infrastruktur (kein Paketserver) nötig
- Änderungen am Framework sind sofort in allen Apps sichtbar

**Konsequenzen:**
- `zig-pkg/`-Verzeichnisse mit alten Hash-Locks müssen entfernt werden
- Alle `build.zig.zon` mit `file://`-URLs werden auf `path`-Referenzen umgestellt

---

## ADR-004 · 2026-09-02 · BKG Zig-Fork Branch-Strategie

**Entscheidung:** Der Fork `banana.bkg/zig.bkg` hat zwei Branches:
- `master` = identisch mit upstream ziglang/zig (read-only, nur sync)
- `banana` = alle BKG-eigenen Patches

**Begründung:**
- Klare Trennung zwischen upstream-Stand und BKG-Erweiterungen
- `git rebase master` hält `banana` immer sauber auf neuestem upstream
- `master` kann jederzeit als Referenz für Vanilla-Zig-Verhalten genutzt werden
- Branch-Name `banana` = Erkennungszeichen des BKG-Forks

**Konsequenzen:**
- Alle BKG-Patches werden mit Prefix `bkg:` committed
- `master` darf niemals direkt verändert werden

---

## ADR-005 · 2026-09-02 · Apps-Verzeichnis `zig-app.bkg`, nicht im Framework

**Entscheidung:** Alle ausführbaren Anwendungen liegen unter `zig-app.bkg/`,
nicht im Framework-Verzeichnis `zig-body.bkg/`.

**Begründung:**
- Framework enthält ausschließlich wiederverwendbare Bibliotheken
- Klare Trennung: `libs/` = Bibliotheken, `zig-app.bkg/` = Binaries
- Jede App ist ein eigenständiges Zig-Projekt mit eigener `build.zig`
- Verhindert versehentliche Abhängigkeiten vom Framework auf Apps

**Konsequenzen:**
- `utils/bkg/`-Verzeichnis wurde aus Framework entfernt (war Referenz-App)
- Referenz-App (`bkg`) lebt jetzt in `zig-body.bkg/` direkt unter `apps/` – **nein**,
  sie wurde aus dem Framework komplett herausgelöst

---

## ADR-006 · 2026-09-02 · `zig-docs-bkg` als verbindliche Dokumentationsquelle

**Entscheidung:** `/srv/bkg/playground/zig-docs-bkg/` ist die **einzige autoritative
Quelle** für Regeln, Entscheidungen und Konventionen. Kein Schritt ohne Doku.

**Begründung:**
- Wissen geht sonst im Chat-Verlauf verloren
- Neue Sessions können direkt hier einlesen
- Jede Entscheidung ist nachvollziehbar und begründet

**Konsequenzen:**
- `zig-docs-bkg/` wird als eigenes Git-Repo geführt
- Jede Änderung wird sofort committed
- Diese Datei (`entscheidungen.md`) wird bei jeder neuen ADR ergänzt

Stand: 2026-09-02
