# eviladmin — LLM Context

> Dieser File ist der vollständige Kontext für ein LLM das am eviladmin-Projekt arbeitet.
> Stand: 2026-09-01 | Architektur v7 + Demon-Armee
> Workspace: `/srv/bkg/workspace/bkg-projects/alpha/eviladmin/`
> **SQLite vollständig entfernt (2026-09-01). Einziger Datenspeicher: BKGDB.**
> Kanonische Dokumente: `BKG_LLM.md`, `EVILADMIN_LLM.md`, `wtf.md`, `SOUL_SPORES_v1.md`, `EVILADMIN_DEMON_ARMY_v1.md`

---

## Was ist eviladmin

eviladmin ist **kein normaler Peer und kein einzelner Agent**.
Es ist ein qualifizierter Netzwerk-Knoten mit einer eigenen operativen **Demon-Armee** —
die Hochrang-Schicht des BKG-Netzes.

Aktuell: native Zig-Plattform für **multi-tenant NVIDIA API-Gateway-Orchestrierung**.
Langfristig: autonomer regionaler Compute- und Algorithmus-Hub.

eviladmin importiert BKG-Module und nutzt BKGDB als Datenbank.
NVIDIA-spezifischer Code existiert ausschließlich im Provider-Adapter.

---

## Workspace

```
/srv/bkg/workspace/bkg-projects/alpha/eviladmin/
└── src/
    ├── core/            Platform-Lifecycle, Orchestrierung, Bootstrap, Graceful Shutdown
    ├── cluster/         Accounts, Credentials, Pools, Scheduler, Capacity Engine, Fairness
    ├── providers/
    │   └── nvidia/      NVIDIA NIM Adapter — einziger Ort mit NVIDIA-Wissen
    ├── models/          Virtuelle Modelle, physische Modelle, Model-Routing, Health
    ├── web/             Dashboard, SSR, SSE, WebSocket
    ├── api/             REST Endpunkte, Request-Lifecycle, Middleware-Chain
    ├── auth/            User, Sessions, RBAC — nutzt bkg-auth
    ├── vault/           Credential-Verschlüsselung — nutzt bkg-vault
    ├── metrics/         Health, Telemetrie, Logs, Tracing — nutzt bkg-metrics
    └── db/              BKGDB-Collections, Schema-Definitionen — nutzt bkg-db
```

Build: `cd bkg && zig build` — muss immer grün sein.
Zig Version: 0.16.0

---

## Rang und Aufstieg

```
Peer → Advanced Peer → Hub-Peer → eviladmin → Hero-Ebene
```

Aufstieg durch: messbare Verfügbarkeit, Reputation, Beiträge, korrekte Verifikation,
Capacity und nachweisbares Verhalten.

**Ein hoher Rang erzeugt niemals Immunität** (NO PERMANENT TRUST — wtf_v2).

---

## Drei Ebenen (unveränderlich)

```
BKG Framework        (Fundament — P2P, Ledger, DB, Guardian, Forge)
      │
      ▼
eviladmin Platform   (Multi-tenant Cluster / API Gateway + Demon-Armee)
      │
      ▼
NVIDIA Provider      (externer Adapter hinter Provider-Interface)
```

- **BKG kennt eviladmin nicht.**
- **eviladmin kennt NVIDIA nicht direkt — nur über das Provider-Interface.**
- **NVIDIA-Details gehören ausschließlich in `providers/nvidia/`.**

---

## Datenmodell — Identitätsregel (unveränderlich)

```
User
 └── Account                  (logische Provider-Identität)
      └── Credential           (verschlüsseltes Secret-Material)
           └── Provider         (nvidia | openai-compat | ...)
```

**1 API-Key = 1 Credential = 1 Account**

| Regel | Durchsetzung |
|-------|-------------|
| Ein API-Key kann nicht zwei Accounts repräsentieren | BKGDB unique constraint auf `credential.account_id` |
| Ein Account kann nicht zwei Credentials haben | BKGDB unique constraint auf `credential.account_id` |
| Kein Key darf doppelt registriert sein | BKGDB unique constraint auf `credential.secret_hash` |
| Ein User darf beliebig viele Accounts besitzen | keine Begrenzung auf User-Ebene |

---

## Credential-Status

```
active              normal, im Scheduler
pending_validation  neu registriert, nicht geprüft
cooldown            temporär pausiert (429/Rate-Limit)
quarantine          Key-Konflikt erkannt, außer Betrieb
invalid             Validation fehlgeschlagen (401)
revoked             explizit widerrufen
disabled            durch Admin deaktiviert
```

---

## Sicherheitsinvarianten (unveränderlich)

```
1. Ein Credential darf nur an die autorisierte aktive Session gebunden sein.
2. Ein unerwarteter zweiter Besitz-/Session-Kontext führt zur Quarantäne.
3. Credential-Sicherheit und Asset-Besitz sind strikt getrennt.
   Credentials ≠ Besitzrechte
4. User sind niemals Proofs.
5. Guardian-/Watcher-Prüfung ersetzt User-Vertrauen.
6. Kritische Claims benötigen unabhängige Evidence und Quorum.
7. Der Creator/Peer darf niemals seine eigene wirtschaftliche Belohnung allein bestätigen.
8. Eine aktive Identität darf nicht gleichzeitig ein widersprüchliches Traffic-Verhalten
   zeigen, das ihrer gebundenen Nutzung widerspricht.
```

---

## Key-Session-Binding

```
Account → Session → Key
  │           │
  │           └── Session-Identity (Ed25519 Keypair, kurzlebig)
  └── Peer-ID (P2P-Ebene)
```

**IP-Adresse wird nicht als Identität verwendet.**

---

## Killchain V2 — Signature Contradiction

Ein Key hat neben kryptografischer Identität ein fortlaufendes **Traffic-/Data-Signature-Profil**:

```
Peer, Session, Timing, Route, Modellklasse, Größenmuster,
Fehlerbild, Netzwerk-Merkmale, sichere Telemetrie
```

### Signature-States

```
STABLE        Identität passt zu Traffic — Key bleibt ACTIVE
DRIFTING      leichte Abweichung — Watcher erhöht Aufmerksamkeit
SUSPICIOUS    Identität passt nur teilweise — Key WATCHED, Guardian-Prüfung
CONTRADICTED  mehrere unabhängige Widersprüche bestätigt
COMPROMISED   gültige Identität, aber Traffic unvereinbar mit gebundener Nutzung
```

Ein einzelner Messwert reicht nicht für eine Sperre.
Mehrere unabhängige Widersprüche stufen den Zustand hoch.

### Killchain V2 Ablauf

```
COMPROMISED
  → SESSION_REVOKE
  → KEY_QUARANTINE
  → ROUTE_REMOVE          (Key aus Scheduler und Routing)
  → CAPABILITY_FREEZE     (noch nicht verbrauchte Compute-Capabilities eingefroren)
  → GUARDIAN_ALERT
  → LEDGER_EVENT          (KEY_COMPROMISED, unveränderlich)
```

### Konflikt-Eskalationskette (klassisch)

```
KEY_CONFLICT
  → KEY_QUARANTINE
  → SESSION_REVOKE
  → KEY AUS DEM SCHEDULER
  → SECURITY_EVENT (Security-Ledger, unveränderlich)
  → NEUE SESSION für legitimen Besitzer
```

### Second-Peer Challenge

```
LOCAL OBSERVATION
  → REMOTE WATCHER CHECK (andere Zone, unabhängig)
  → GUARDIAN DECISION
```

### False-Positive Protection

Netzwerkwechsel, Mobilität, Failover, NAT, legitime Lastspitzen dürfen **nicht** automatisch als Kompromittierung gelten.
Watcher bewertet Kontext, Zeitfenster und mehrere Signale gemeinsam.
Harte Entscheidungen brauchen definierte Evidenzschwelle oder Guardian-Quorum.

```
Bereits bestätigte Ledger-Einträge bleiben unverändert.
Nur aktive Sessions und noch nicht verbrauchte Capabilities werden eingefroren.
```

### Emergency Kill Chain

```
1. Key-Status → revoked
2. Alle TPS-Capabilities des Keys einfrieren
3. Alle Sessions schließen
4. Unveränderlicher Audit-Event: KEY_COMPROMISED
5. Security-Ledger-Eintrag
6. Optional: Ersatz-Key-Provisioning-Flow
```

---

## Kapazitäts-Modell

**CapacityOwner = Account**

```
Cluster theoretical = Σ Account.capacity   (alle Accounts)
Cluster available   = Σ Account.capacity   (nur healthy, status=active)
Cluster reserved    = Σ Account.capacity   (nur cooldown)
Cluster quarantined = Σ Account.capacity   (quarantined — außer Betrieb)
```

### Scheduler Score

```
score = health_weight    × health_score
      + capacity_weight  × available_capacity
      + load_weight      × (1 - current_load)
      + fairness_weight  × fairness_score
      + cooldown_weight  × (0 wenn cooldown/quarantine, 1 wenn aktiv)
```

Quarantined Keys werden **zusätzlich hart aus der Kandidatenliste gefiltert** — der Score kommt gar nicht erst zur Anwendung.

### Pool-Typen

| Typ | Zugang |
|-----|--------|
| `PUBLIC` | Alle berechtigten User nach Pool-Policy |
| `PRIVATE` | Nur Besitzer und explizit autorisierte Mitglieder |
| `INVITE` | Nur explizit eingeladene User |

Account gehört immer dem User. Pool hat nur Nutzungsberechtigung — kein Eigentum.

---

## Request Flow (vollständig)

```
Client
  → bkg-web       HTTP Parsing, Connection
  → api            Request ID, CORS, Logging
  → auth           JWT/Session prüfen, User laden
  → auth           Key-Session-Binding prüfen  ← Security Invariante
  → api Handler
  → cluster
      → Pool auswählen
      → User Quota prüfen
      → Capacity Engine (genug TPS?)
      → Scheduler (Account/Credential per Score, keine quarantined Keys)
      → Kapazität reservieren
  → providers/nvidia
      → NVIDIA NIM API Call
      → Streaming Response
  → Response zurück zum Client
  → Kapazität freigeben
  → Token-Verbrauch abgleichen
  → bkg-events Event Bus
      → bkg-metrics  (Latenz, Tokens, Fehler)
      → SSE          → Dashboard live
      → Audit Log    → BKGDB Immutable Ledger
      → Health Update

Guardian Flow (parallel, non-blocking):
  bkg-events
      → Guardian A: REQUEST_EXECUTED  (Verhalten/Signature-Analyse)
      → Guardian B: BENCHMARK_CLAIMED (Ökonomie)
      → bei Anomalie: GUARDIAN_FLAG → CHALLENGE → Remote-Guardians
      → Quorum bestätigt → Security-Ledger-Eintrag
```

---

## BKGDB Typed Collections (eviladmin)

```
eviladmin/src/db/
├── db.zig
├── schema.zig
└── collections/
    ├── users.zig
    ├── sessions.zig      ← inkl. Key-Session-Binding
    ├── credentials.zig
    ├── accounts.zig
    ├── pools.zig
    ├── usage_log.zig
    └── audit_log.zig
```

Beispiel:

```zig
pub const CredentialCollection = struct {
    txn: *bkgdb.Transaction,
    pub fn findById(self: *@This(), id: Uuid) !?Credential { ... }
    pub fn findByHash(self: *@This(), hash: [32]u8) !?Credential { ... }
    pub fn insert(self: *@This(), c: Credential) !void { ... }
    pub fn updateStatus(self: *@This(), id: Uuid, status: CredentialStatus) !void { ... }
    pub fn setQuarantine(self: *@This(), id: Uuid) !void { ... }
};
```

Kein SQL. Kein Schema-String. Alles Zig-Typen.

---

## API Endpunkte

```
POST /api/auth/register          GET    /api/pools
POST /api/auth/login             POST   /api/pools
POST /api/auth/logout            GET    /api/pools/{id}
POST /api/auth/refresh           PATCH  /api/pools/{id}
GET  /api/auth/me                DELETE /api/pools/{id}
                                 GET    /api/pools/{id}/members
GET    /api/keys                 POST   /api/pools/{id}/members
POST   /api/keys                 DELETE /api/pools/{id}/members/{uid}
POST   /api/keys/{id}/validate
POST   /api/keys/{id}/revoke     GET /api/models
                                 GET /api/models/{id}/health
GET /api/stats
GET /api/stats/usage             GET /api/stream

POST /v1/chat/completions        GET /health
POST /v1/completions             GET /ready
GET  /v1/models                  GET /metrics

GET   /api/admin/users           GET /api/admin/audit
PATCH /api/admin/users/{id}      GET /api/admin/security    ← Security-Ledger
GET   /api/admin/keys
POST  /api/admin/keys/{id}/approve
POST  /api/admin/keys/{id}/reject
POST  /api/admin/keys/{id}/quarantine
POST  /api/admin/keys/{id}/kill  ← Emergency Kill Chain
```

---

## Implementierungsphasen

| Phase | Inhalt | Status |
|-------|--------|--------|
| 0 | Build System, CI, Config-Template | [ ] |
| 1 | bkg-core, **bkg-db**: WAL, Page Store, MVCC, Merkle | [ ] |
| 2 | bkg-vault, bkg-auth, User, Sessions, **Key-Session-Binding** | [ ] |
| 3 | Credential-Verschlüsselung, Fingerprint, **Security-Ledger** | [ ] |
| 4 | Pools, Membership, PoolPolicy | [ ] |
| 5 | bkg-events, Capacity Engine, Scheduler, Rate Limiting, Fairness | [ ] |
| 6 | providers/nvidia, Streaming, Retry, Circuit Breaker | [ ] |
| 7 | Proxy API, Model Catalog, Model Health, Usage | [ ] |
| 8 | SSE, bkg-metrics Prometheus, Audit, Admin API | [ ] |
| 9 | Security Hardening: Key-Conflict, **Killchain V2**, Signature Model | [ ] |
| 10 | **bkg-guardian**: Guardian A/B, P2P-Kanal, Quorum | [ ] |
| 11 | **bkg-p2p**: Peer Join, Collateral, Zonen, Ledger-Sync | [ ] |
| 12 | **bkg-forge**: Algorithmus-Extraktion, Verifikation, Guardian-Schmiede | [ ] |
| 13 | Native Assets: SOUL NFT, LOST NFT, TPS-NFT, Algorithm-NFT | [ ] |
| 14 | Hero-Ebene, Evolution, Guardian-Genealogie, Forge-Epochen | [ ] |
| 15 | Docker, Kubernetes, Dokumentation | [ ] |
| 16 | Desktop Admin Client (optional) | [ ] |

---

## Qualitätsregeln

1. `zig build` muss immer grün sein
2. `zig build test` muss immer grün sein
3. Kein Secret in Logs — maximal `key=...a91f`
4. Jeder Request ist von Client bis Provider komplett tracebar
5. Capacity wird korrekt neu berechnet wenn ein Credential in Cooldown/Quarantine geht
6. Dashboard reagiert live ohne Page-Reload
7. Kein SQL, kein SQLite, kein PostgreSQL — ausschließlich BKGDB
8. Kein `TODO` das eine echte Implementierung versteckt
9. Kein `unreachable` das einen Fehlerfall versteckt
10. Jede Phase muss kompilieren und Tests bestehen bevor die nächste beginnt
11. Keine NVIDIA-Details außerhalb von `providers/nvidia/`
12. Kein BKG-Modul importiert eviladmin- oder NVIDIA-Code
13. **Key-Session-Binding muss in jedem Auth-Middleware-Test verifiziert werden**
14. **Security-Ledger-Einträge sind unveränderlich — kein Update, kein Delete**
15. **Kein Peer bestätigt allein seine eigene wirtschaftliche Belohnung**
16. **Guardian-Versionen sind signierte Artefakte mit vollständiger Herkunftskette**
17. **Keine NFT-Menge repräsentiert mehr Kapazität als durch Evidence gedeckt**

---

## Prometheus Metriken

```
─── eviladmin ───────────────────────────────────────────────────
eviladmin_requests_total          eviladmin_key_cooldowns
eviladmin_requests_failed_total   eviladmin_upstream_429_total
eviladmin_tokens_total            eviladmin_upstream_401_total
eviladmin_active_users            eviladmin_upstream_5xx_total
eviladmin_active_keys             eviladmin_request_latency
eviladmin_active_pools            eviladmin_key_capacity
eviladmin_key_quarantine_total    eviladmin_pool_capacity
eviladmin_security_incidents      eviladmin_user_quota_usage

─── Guardian / P2P ──────────────────────────────────────────────
bkg_guardian_events_total         bkg_guardian_flags_total
bkg_guardian_challenges_total     bkg_guardian_verdicts_total
bkg_quorum_decisions_total        bkg_collateral_frozen_total
bkg_guardian_a_version            bkg_guardian_b_version
bkg_peer_count                    bkg_watcher_count

─── Forge ───────────────────────────────────────────────────────
bkg_forge_candidates_total        bkg_forge_verified_total
bkg_forge_rejected_total          bkg_forge_epoch
bkg_algo_minted_total             bkg_xp_granted_total
```

Keine Labels mit unbounded Cardinality (keine User-IDs, keine Request-IDs als Labels).

---

## Konfigurations-Template (eviladmin.toml)

```toml
[server]
address = "127.0.0.1"
port    = 8080

[database]
data_dir = "./data"
checkpoint_interval_seconds = 60

[auth]
session_expiry_seconds = 86400
argon2_memory_kib      = 65536
argon2_iterations      = 3
argon2_parallelism     = 4
# EVILADMIN_MASTER_KEY=<32-byte-hex> — niemals in der Datei!

[capacity]
default_tps_per_account = 40

[scheduler]
health_weight    = 0.40
capacity_weight  = 0.25
load_weight      = 0.20
fairness_weight  = 0.10
cooldown_weight  = 0.05

[observability]
metrics_enabled = true
metrics_path    = "/metrics"
log_level       = "info"
log_format      = "json"

[bootstrap]
# Nur beim ersten Start — danach ignoriert
# admin_username = "admin"
# EVILADMIN_BOOTSTRAP_ADMIN_PASSWORD=<secret>
```

---

## Demon-Armee

> Spec: `EVILADMIN_DEMON_ARMY_v1.md`

### Was eine Demon-Armee ist

Demons sind spezialisierte, versionierte Agents für Ausführung, Routing, Analyse, Security,
Recovery, Compute-Orchestrierung und Forge-Aufgaben.

eviladmin bündelt diese Demons, besitzt aber **nicht deren Wahrheit**.
Watcher, Guardians, Quorum und Ledger bleiben die unabhängige Vertrauensschicht.

### Demon-Rollen (Basis, offen für Forge-Evolution)

| Demon | Aufgabe |
|-------|---------|
| **Routing Demon** | Request-Routing, Load-Balancing, Pool-Auswahl |
| **Security Demon** | Key-Conflict-Erkennung, Killchain-Trigger, Signature-Analyse |
| **Forge Demon** | Algorithmus-Kandidaten vorbereiten, Benchmarks liefern |
| **Recovery Demon** | Fallback-Flows, Credential-Erneuerung, Session-Repair |
| **Compute Demon** | TPS/Batch-Capacity-Verwaltung, Reservation, Freigabe |
| **Data Demon** | BKGDB-Operationen, Ledger-Writes, Collection-Queries |
| **Model Demon** | Model-Catalog, Health-Checks, Routing-Tabellen |
| **Trading Demon** | TPS/Capacity-NFT-Verwaltung, Asset-Transfers |
| **Scout Demon** | Watcher-Koordination, Zone-Beobachtung, Anomalie-Meldung |

### Demon-Identität (unveränderlich)

Jeder Demon besitzt:
```
Identität        eigene UUID + kryptografische Bindung
Version          Provenance + Parent-Versionen + verwendete Algorithmen
Capability       was er darf und was nicht
Guardian-Zuordnung  welcher Guardian ihn überwacht
Ressourcenlimits    CPU, Speicher, Netzwerk, Ledger-Writes
Kill-/Recovery-Regeln  wann er gestoppt, ersetzt oder zurückgestuft wird
```

### Demon-Lifecycle

```
Forge → Demon-Kandidat
     → Watcher: Verhalten prüfen
     → Guardian: Capability + Provenance bewerten
     → Quorum: Aktivierung entscheiden
     → eviladmin: Demon in operativen Pool übernehmen

Wenn überlegen → neue Version registrieren
Wenn fehlerhaft → zurückgestuft / eingefroren / ersetzt
Alte Version bleibt als historische Lineage erhalten
```

### Demon-Evolution

```
Demon v1 → bessere Algorithmen → Demon v2
Mehrere bewährte Demons → Composite-Capability (neue Identität)
Hero → verbessert Forge-Verfahren → bessere Demon-Generationen
```

### Kein-König-Invariante (unveränderlich)

```
Der eviladmin darf niemals sein:
  - alleinige Wahrheit
  - alleiniger Verifier
  - alleiniger Ledger-Schreiber
  - immune Instanz

Ein eviladmin kann:
  - von anderen Guardians beobachtet werden
  - von Watchern challenged werden
  - über Quorum zurückgestuft werden
  - bei nachgewiesenem Fehlverhalten isoliert werden
```

### Armee statt Monolith

```
Komplexer Auftrag
  → eviladmin zerlegt in kleine, überprüfbare Aufgaben
  → delegiert an spezialisierte Demons
  → Parallelität + Failure-Isolation + Rollback + gezielte Rotation

Ein kompromittierter Demon kompromittiert nicht automatisch den gesamten eviladmin.
```

### Endzustand eviladmin

```
Hub-Peer
  + Guardian-Pool
  + spezialisierte Demon-Armee
  + bewegliche Watcher
  + Forge-Zugang
  + vollständige kryptografische Lineage

Kann gleichzeitig:
  - große Peer-Zonen orchestrieren
  - Guardian-Pools hosten
  - Watcher-Rotation koordinieren
  - Compute-Kapazität bündeln
  - TPS/Batch-Capabilities verwalten
  - neue Algorithmen an die Forge liefern
  - Sicherheitsvorfälle isolieren und recovern
  - komplexe Aufgaben auf Demons aufteilen
  - Ergebnisse durch Watcher/Guardians prüfen lassen
```

### Verbindung SOUL / SPORE / Demon

```
eviladmin empfängt + verteilt signierte Capsule/Spore-Artefakte
SOUL bleibt an kanonische Identität gebunden
LOST bleibt Fragment einer SOUL-Lineage
Kein Demon darf eine SOUL eigenmächtig neu erschaffen
  oder ihre Herkunft verändern
```

### Ökonomie der Demons

```
eviladmin liefert echte Compute-Capacity
  → verifizierte Capacity- und TPS-Rechte entstehen
Demons bereiten ALGO-verdächtige Claims vor
  → Rewards erst nach unabhängiger Prüfung + Quorum
ALGO bleibt an wertvolle algorithmische Arbeit gekoppelt
BKG bleibt Settlement für autorisierte Nutzung
```

---

## Aktueller Stand

- Workspace: `/srv/bkg/workspace/bkg-projects/alpha/`
- Zig Version: 0.16.0
- `zig build`: grün
- BKG Framework: 11 Module angelegt (Stubs, Phase 1 läuft)
- eviladmin Platform: Verzeichnisstruktur angelegt
- Phase 0: in Arbeit
- `bkg-p2p`, `bkg-guardian`, `bkg-forge`: noch nicht angelegt (Phase 10–12)
- `ARCHITECTURE-V5.md` (Workspace-Root): Killchain V2 + Signature Model — noch in ARCHITECTURE.md einzuarbeiten
