# BKG Zig – Architektur und Verzeichnisstruktur

## Gesamtstruktur

```
/srv/bkg/playground/
│
├── zig-soul.bkg/                        ← Zig-Sprachbasis
│   ├── zig.vanilla/
│   │   ├── docgen/                      ← Zig Dokumentationsgenerator
│   │   ├── release-cutter/              ← Release-Tooling
│   │   ├── zig-bootstrap/               ← Bootstrap-Compiler
│   │   └── zig.zig/                     ← Upstream ziglang/zig (read-only Referenz)
│   │       └── .git/ → origin: github.com/ziglang/zig
│   └── banana.bkg/
│       └── zig.bkg/                     ← BKG Zig-Fork (alle BKG-Patches)
│           └── .git/ → origin: github.com/bkg-zig/zig.bkg.git
│               branches: master (= upstream), banana (= BKG-Patches)
│
├── zig-body.bkg/                        ← Framework-Bibliotheken
│   ├── build.zig                        ← Framework-Build (exportiert alle Module)
│   ├── build.zig.zon                    ← name=bkg, version=0.1.0, keine ext. Deps
│   └── libs/
│       ├── bkg-core/                    ← Fehler, IDs, Clock – Foundation
│       ├── bkg-db/                      ← Durable KV, WAL, B-Tree, Ledger, Crypto
│       ├── bkg-vault/                   ← AES-256-GCM, Argon2id, Secret Store
│       ├── bkg-auth/                    ← Argon2, Sessions, JWT HS256, RBAC
│       ├── bkg-web/                     ← HTTP Server, Router, WS, SSE, Templates
│       ├── bkg-http/                    ← HTTP Client (Stub – Phase 2)
│       ├── bkg-config/                  ← ENV-Konfiguration
│       ├── bkg-cli/                     ← CLI Argument-Parser
│       ├── bkg-events/                  ← Event-Bus (Stub – Phase 2)
│       ├── bkg-metrics/                 ← Metriken (Stub – Phase 2)
│       ├── bkg-tui/                     ← Terminal-UI (Stub – Phase 2)
│       └── bkg-model/                   ← Model-Layer (Artifact, Lineage, Evolution)
│
├── zig-app.bkg/                         ← Alle BKG-Anwendungen
│   ├── bkg-flocker.zig/                 ← Docker-Management-UI (aktiv in Entwicklung)
│   │   ├── build.zig                    ← deps: bkg-core, bkg-web, bkg-auth, bkg-config, bkg-cli
│   │   ├── build.zig.zon                ← path-Abhängigkeit auf ../../zig-body.bkg
│   │   └── src/
│   │       ├── config.zig               ← ✅ vorhanden
│   │       ├── main.zig                 ← ❌ fehlt noch
│   │       ├── docker/                  ← ❌ fehlt noch (Unix-Socket HTTP-Client)
│   │       │   └── client.zig
│   │       ├── api/                     ← ❌ fehlt noch (REST-Routen)
│   │       │   └── handlers.zig
│   │       └── ws/                      ← ❌ fehlt noch (WebSocket Terminal-Exec)
│   │           └── handshake.zig
│   ├── bkg-eviladmin.zig/               ← Admin-Backend (eigenes Git-Repo)
│   │   └── .git/
│   └── bkg-forgekb.zig/                 ← Knowledge-Base / LLM-App
│
└── zig-docs-bkg/                        ← Diese Dokumentation
    └── .git/                            ← eigenes Repo
```

## Abhängigkeits-Graph (bkg-flocker)

```
bkg-flocker
    ├── bkg-core    (Pflicht – Domain Primitives)
    ├── bkg-web     (Pflicht – HTTP + WebSocket)
    ├── bkg-auth    (Pflicht – Bearer, Sessions)
    ├── bkg-config  (Pflicht – ENV-Konfiguration)
    └── bkg-cli     (Pflicht – CLI Argument-Parser)

    NICHT eingebunden (nicht benötigt):
    ├── bkg-db      (kein eigenes KV-Store in bkg-flocker)
    ├── bkg-vault   (keine Secret-Encryption direkt)
    ├── bkg-http    (Stub, Docker-Socket direkt via std.net)
    ├── bkg-events  (Stub)
    ├── bkg-metrics (Stub)
    ├── bkg-tui     (Stub)
    └── bkg-model   (nicht benötigt)
```

## Framework-Einbindung in Apps

**Regel:** Jede App bindet **ausschließlich die benötigten Libs** per
`path`-Referenz ein – niemals das Framework als Ganzes, keinen Hash-Lock.

```zig
// build.zig.zon einer App:
.dependencies = .{
    .bkg = .{ .path = "../../zig-body.bkg" },
},

// build.zig einer App:
const fw = b.dependency("bkg", .{ .target = target, .optimize = optimize });
const bkg_core = fw.module("bkg-core");
const bkg_web  = fw.module("bkg-web");
// nur was wirklich gebraucht wird
```

Stand: 2026-09-02
