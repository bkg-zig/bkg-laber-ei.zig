# BKG Zig – Verbindliche Regeln und Konventionen

## §1 Dokumentation

- **Jede** Entscheidung, Konvention, Architekturwahl oder Erkenntnis wird
  **sofort** in `/srv/bkg/playground/zig-docs-bkg/` dokumentiert.
- Kein Schritt gilt als abgeschlossen ohne entsprechenden Doku-Eintrag.
- Rückwirkend gilt diese Regel für alles, was in dieser Session entschieden wurde.

## §2 Verzeichnisstruktur

| Pfad | Zweck | Regel |
|---|---|---|
| `zig-soul.bkg/zig.vanilla/zig.zig/` | Upstream ziglang/zig | **Read-only** – niemals direkt ändern |
| `zig-soul.bkg/banana.bkg/zig.bkg/` | BKG Zig-Fork | Nur auf Branch `banana` ändern |
| `zig-body.bkg/` | Framework-Bibliotheken | **Keine Apps**, nur `libs/` |
| `zig-app.bkg/` | BKG-Anwendungen | **Keine Libs**, nur Executables |
| `zig-docs-bkg/` | Diese Dokumentation | Immer aktuell halten |

## §3 Framework (`zig-body.bkg`)

- Das Framework enthält **ausschließlich** `libs/` – keine `apps/`, keine `utils/`.
- Apps gehören unter `zig-app.bkg/`, nicht ins Framework.
- Jede Lib ist eigenständig und hat keine zirkulären Abhängigkeiten.
- Stub-Libs (Phase-2) sind als solche markiert (`// Phase 1+: Implementierung ausstehend`).
- **Frozen modules** (dürfen nicht verändert werden ohne explizite Freigabe):
  - `libs/bkg-db/src/crypto/envelope.zig`
  - `libs/bkg-db/src/crypto/keyring.zig`
  - `libs/bkg-db/src/storage/wal_encrypted.zig`
  - BKG Model Layer (`libs/bkg-model/src/`)

## §4 App-Abhängigkeiten

- Jede App bindet **nur die wirklich benötigten Libs** ein – nie das Framework als Ganzes.
- Abhängigkeit immer als **`path`-Referenz** auf `../../zig-body.bkg` – kein `zig fetch`, kein Hash-Lock, kein Tar-Archiv.
- `zig-pkg/`-Verzeichnisse mit alten Hash-Locks sind zu entfernen.

```zig
// RICHTIG:
.dependencies = .{
    .bkg = .{ .path = "../../zig-body.bkg" },
},

// FALSCH:
.dependencies = .{
    .bkg = .{ .url = "file:///tmp/...", .hash = "bkg-0.1.0-..." },
},
```

## §5 Benennung

| Bereich | Muster | Beispiel |
|---|---|---|
| App-Verzeichnis | `bkg-<name>.zig` | `bkg-flocker.zig` |
| Framework-Verzeichnis | `zig-body.bkg` | (unveränderlich) |
| Fork-Verzeichnis | `zig-soul.bkg` | (unveränderlich) |
| Lib-Modul | `bkg-<bereich>` | `bkg-web`, `bkg-db` |
| Binary-Name | `bkg-<name>` | `bkg-flocker` |

## §6 Git

- `zig-docs-bkg/` ist ein eigenes Git-Repo mit sinnvollen Commit-Messages.
- Jede Änderung an der Doku wird **sofort** committed.
- Der BKG Zig-Fork (`banana.bkg/zig.bkg`) hat Branch `master` (= upstream) und `banana` (= BKG-Patches).
- Eigene Patches **niemals** auf `master` – ausschließlich auf `banana`.

## §7 Zig-Version

- Minimum: Zig **0.16.0**
- Compiler: System-Zig (`zig 0.16.0`) bis der Fork (`zig.bkg`) gebaut wird
- Alle `build.zig.zon` müssen `minimum_zig_version = "0.16.0"` enthalten

## §8 Kein externer Paketmanager

- Kein `zig fetch` für interne Abhängigkeiten
- Kein npm, kein cargo, kein pip – reines Zig-Ökosystem
- Externe Abhängigkeiten: nur über `path` oder lokalen Hash-Lock für echte externe Libs

Stand: 2026-09-02
