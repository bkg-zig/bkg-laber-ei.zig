# BKG Framework — LLM Context

> Dieser File ist der vollständige Kontext für ein LLM das am BKG-Projekt arbeitet.
> Stand: 2026-09-01 | Architektur v7 + SPORE/Capsule-Evolutionsschicht
> Workspace: `/srv/bkg/workspace/bkg-projects/alpha/bkg/`
> Kanonische Dokumente: `BKG_LLM.md`, `EVILADMIN_LLM.md`, `wtf.md`, `SOUL_SPORES_v1.md`

---

## Was ist BKG

BKG ist ein natives Zig-Framework und das technische Fundament des BKG-Netzwerks.
Es besitzt keine Abhängigkeiten auf eviladmin oder NVIDIA.
Es ist eine vollständige Plattform für P2P-Compute, algorithmisches Wissen, Guardian-Protokolle, eine native Datenbank und ein natives Asset-System.

BKG ist kein Web-Framework im klassischen Sinne.
Es ist die Basis für ein selbstevolvierendes P2P-Netz, das Algorithmen erschafft, verifiziert, versioniert und als native Assets handelt.

---

## Workspace

```
/srv/bkg/workspace/bkg-projects/alpha/bkg/
└── libs/
    ├── bkg-core/
    ├── bkg-web/
    ├── bkg-db/
    ├── bkg-auth/
    ├── bkg-vault/
    ├── bkg-http/
    ├── bkg-events/
    ├── bkg-metrics/
    ├── bkg-config/
    ├── bkg-cli/
    ├── bkg-tui/
    ├── bkg-p2p/        (Phase 11 — noch Stub)
    ├── bkg-guardian/   (Phase 10 — noch Stub)
    └── bkg-forge/      (Phase 12 — noch Stub)
```

Build: `cd bkg && zig build` — muss immer grün sein.
Zig Version: 0.16.0

---

## Unveränderliche BKG-Regeln

- Kein BKG-Modul importiert eviladmin-Code
- Kein BKG-Modul importiert NVIDIA-Code
- Kein globaler State
- Kein Singleton-Muster
- Jedes Modul ist einzeln testbar
- Kein SQL, kein SQLite, kein PostgreSQL — ausschließlich BKGDB
- Kein `TODO` das eine echte Implementierung versteckt
- Kein `unreachable` das einen Fehlerfall versteckt

---

## Module

| Modul | Aufgabe |
|-------|---------|
| `bkg-core` | Domain-Primitives, IDs, Events, Clock, Errors, Result — Basis aller Module |
| `bkg-web` | HTTP Server, Router, Middleware, SSE, WebSocket, Templates |
| `bkg-db` | **BKGDB** — native Zig Datenbank: WAL, MVCC, Content Addressing, Merkle State |
| `bkg-auth` | Sessions, RBAC, Auth-Middleware, Key-Session-Binding |
| `bkg-vault` | AES-256-GCM, Argon2id, Secret Store |
| `bkg-http` | HTTP Client, Connection Pool, Retry, Circuit Breaker |
| `bkg-events` | Event Bus, Subscriptions, Async Dispatch |
| `bkg-metrics` | Counter, Gauge, Histogram, Prometheus Exporter |
| `bkg-config` | TOML, Environment, CLI Args, Validierung |
| `bkg-cli` | Commands, Flags, Args, Output, Tables, Progress |
| `bkg-tui` | Terminal UI: Windows, Panels, Tables, Forms |
| `bkg-p2p` | Peer Join, Zones, Guardian-Sync, Ledger-Sync, Collateral |
| `bkg-guardian` | Guardian A/B Pipeline, P2P-Guardian-Kanal, Quorum-Protokoll |
| `bkg-forge` | Forge Engine — semantische Extraktion, Algorithmen-Evolution, Guardian-Schmiede |

### Abhängigkeitsgraph

```
bkg-core  (keine Abhängigkeiten)
  ├── bkg-vault
  ├── bkg-web
  ├── bkg-db
  ├── bkg-auth        (→ bkg-core + bkg-vault + bkg-db)
  ├── bkg-http
  ├── bkg-events
  ├── bkg-metrics
  ├── bkg-config
  ├── bkg-cli
  ├── bkg-tui
  ├── bkg-p2p         (→ bkg-core + bkg-db + bkg-events)
  ├── bkg-guardian    (→ bkg-core + bkg-db + bkg-events + bkg-p2p)
  └── bkg-forge       (→ bkg-core + bkg-db + bkg-guardian)
```

---

## BKGDB — Native Zig Datenbank

Spec: `bkg/libs/bkg-db/BKGDB.md`

Kein SQLite. Kein PostgreSQL. Keine externe DB-Abhängigkeit.

### Vier fundamentale Eigenschaften

| Eigenschaft | Bedeutung |
|-------------|-----------|
| **WAL** | Write-Ahead-Log — jede Mutation zuerst ins Log |
| **MVCC** | Multi-Version Concurrency Control — konsistente Lese-Snapshots |
| **Content Addressing** | Objekt-IDs aus kryptografischem Hash des Inhalts |
| **Merkle State** | Zustand über Merkle Roots verifizierbar |

### Dateiformat

```
data/
├── state.wal       Mutable WAL (sequenzieller Append)
├── state.pages     Mutable Page Store (B-Tree, 4KB pages)
├── ledger.wal      Immutable Event Log (append-only, Merkle-gehasht)
└── meta.bkgdb      Engine-Metadaten (JSON)
```

### Zwei Datenschichten

**Mutable State** (WAL + MVCC, änderbar):
```
─── eviladmin ─────────────────────────────────────────────────
users, sessions, accounts, credentials, pools, pool_members,
pool_credentials, user_quotas, key_health

─── BKG Network ───────────────────────────────────────────────
peer_state, guardian_state, watcher_state,
asset_balances, nft_ownership, capacity_state
```

**Immutable Ledger** (Append-only, Merkle-Chain, nie überschrieben):
```
─── eviladmin ─────────────────────────────────────────────────
audit_log, usage_log, security_ledger

─── BKG Network ───────────────────────────────────────────────
algorithm_ledger   Algorithmus-Erzeugung, Versionen, XP, ALGO
asset_ledger       NFT-Minting, Transfers, Consumption, Evolution
forge_ledger       Forge-Epochen, Guardian-Generationen, Kandidaten
```

**Ledger-Regel:** Große Inhalte liegen außerhalb. Die Chain trägt: Identität, Hashes, Provenance, Events, Zustandsbeweise.

### Interne bkg-db Struktur

```
libs/bkg-db/src/
├── bkg_db.zig    Public API (re-exports)
├── engine.zig    Kern-Engine: koordiniert WAL + Pages + MVCC
├── page.zig      Page-Layout: 4KB, Header, Slot-Array, Records
├── wal.zig       WAL: Entry-Format, Append, Recovery, Checkpoint
├── storage.zig   Disk I/O: open/close/read/write pages, fsync
├── txn.zig       Transactions: MVCC-Timestamps, Snapshot, Write-Intent
├── btree.zig     B-Tree: Primary-Key Lookups, Range Scans
├── schema.zig    Schema-Definitionen in Zig (kein SQL)
├── ledger.zig    Immutable Ledger: Append-only, Merkle-Chain
└── merkle.zig    SHA256-Hashing, Merkle-Chain, Root
```

### BKGDB Public API

```zig
const db = try bkgdb.Engine.open(allocator, "./data");
defer db.close();

const txn = try db.begin();
defer txn.deinit();
try txn.put(collection, key, value);
try txn.commit();

const val = try txn.get(collection, key);

var iter = try txn.scan(collection, .{ .from = key_a, .to = key_b });
defer iter.deinit();
while (iter.next()) |entry| { ... }

try db.ledger.append(event_type, payload);
const root = db.ledger.merkleRoot();
```

### security_ledger Event-Typen

```
─── Key & Session ──────────────────────────────────────────
KEY_CONFLICT, KEY_QUARANTINE, KEY_REVOKED, KEY_COMPROMISED
SESSION_REVOKE, KILL_CHAIN_START, KILL_CHAIN_COMPLETE

─── Guardian / Quorum ──────────────────────────────────────
GUARDIAN_FLAG, GUARDIAN_REJECT, GUARDIAN_CHALLENGE
GUARDIAN_VERDICT, QUORUM_PASS, QUORUM_FAIL
ALGORITHM_ACCEPTED, ALGORITHM_REJECTED
XP_GRANTED, ALGO_MINTED, CAPACITY_ATTESTED

─── Peer / Collateral ──────────────────────────────────────
COLLATERAL_VIOLATION, COLLATERAL_FROZEN, COLLATERAL_RETURNED
PEER_JOINED, PEER_LEFT, GUARDIAN_REPUTATION_UPDATE

─── Guardian-Versionierung ─────────────────────────────────
GUARDIAN_VERSION_UPDATED
```

---

## Die Forge (bkg-forge)

Die Forge läuft dauerhaft im Netz. Sie schmiedet Algorithmen und Guardians.

### Forge-Flow

```
Quellmaterial (C++ / Python / Rust / Zig / ...)
  ↓ semantische Extraktion
  ↓ Algorithmus-Kandidat (sprachunabhängig)
  ↓ Forge: Tests + Benchmarks erzeugen
  ↓ Guardians / Watcher: Verifikation + Quorum
  ↓ kanonischer Algorithmus im Ledger
  ↓ XP-Vergabe → ALGO-Minting
```

Nur verifizierte Ergebnisse werden kanonisch.

### Was die Forge produziert

```
Kandidaten          mögliche neue Algorithmen / Guardian-Versionen
Tests               verifizierbare Testsuites
Benchmarks          reproduzierbare Leistungsmessungen
Kompositionsregeln  wie Algorithmen kombiniert werden dürfen
```

---

## Guardian-Schicht (bkg-guardian)

### Hierarchie

```
Hero → eviladmin (Demon-Armee) → Hub-Peer → Guardian → Watcher (Pool) → Peer
```

| Ebene | Rolle |
|-------|-------|
| **Peer** | Compute, reale Netzwerkaktivität |
| **Watcher** | kleine, mobile Prüf- und Beobachtungseinheit |
| **Guardian** | koordiniert Watcher-Pool in einer P2P-Zone |
| **Hub-Peer** | beherbergt geschmiedeten Guardian ab definiertem Level |
| **eviladmin** | qualifizierter Hub mit Demon-Armee: Routing/Security/Forge/Compute/Scout-Demons |
| **Hero** | Meta-Evolutionsinstanz für Forge- und Guardian-Verfahren |

Ein User ist niemals Proof, Verifier oder Konsensinstanz.

### Guardian A vs Guardian B

| | Guardian A | Guardian B |
|--|-----------|-----------|
| Domäne | Verhalten & Konsistenz | Inhalte & Ökonomie |
| Input | KEY_USED, REQUEST_EXECUTED, PEER_CONNECTED, CAPACITY_OFFERED | ALGORITHM_SUBMITTED, BENCHMARK_CLAIMED, REWARD_REQUESTED, NFT_TRANSFERRED, ALGO_MOVED, FORGE_CANDIDATE_READY |

Beide müssen aus unterschiedlichen Modellfamilien oder mit unterschiedlichen Policies stammen.

### GuardianManifest

```zig
GuardianManifest {
    guardian_role:  GuardianRole,   // Behavior | Economy
    version:        u32,
    model_hash:     [32]u8,
    policy_hash:    [32]u8,
    parent_hashes:  [][32]u8,       // Genealogie
    forge_epoch:    u64,
    signed_by_hub:  Signature,      // Ed25519
}
```

### Guardian P2P-Kanal (separater Kanal)

```
OBSERVATION, CLAIM, EVIDENCE, CHALLENGE, VERDICT
REPUTATION_UPDATE, QUARANTINE, CHECKPOINT_ACK
```

Guardians geben kein internes Modell preis — nur signierte VERDICTs und kompakte EVIDENCE.

### Risk-Level & Quorum

| Risk | Anforderung |
|------|-------------|
| Low | 1 lokaler Watcher |
| Normal | Guardian A + B (lokal) |
| High | min. 2 Remote-Guardians |
| Critical | min. 3 Remote-Guardians + Quorum |
| Quorum | Guardian-Cluster-Quorum |

---

## Watcher-Netz

Modellgröße ist keine Architektur-Invariante — entwickelt sich mit Hardware und Anforderungen.

Watcher sind mobil: wechseln innerhalb P2P-Zone zwischen Peers.
Watcher liefern: signierte Beobachtungen + kompakte Evidence.
Watcher liefern keine wirtschaftlichen Entscheidungen.

**Kein Peer kann seinen eigenen wertvollen Claim allein durch lokalen Watcher bestätigen.**

---

## Natives Asset- und NFT-System

Alle NFTs sind native BKG-Assets. Keine ERC-Kompatibilität nötig.

| Asset-Klasse | Übertragbar |
|-------------|-------------|
| `AlgorithmNFT` | ja |
| `GuardianNFT` | nein (an Hub-Peer gebunden) |
| `WatcherCapabilityNFT` | eingeschränkt |
| `TpsNFT` | ja |
| `BatchNFT` | ja |
| `CapacityNFT` | ja |
| `LicenseNFT` | nach Regeln |
| `SoulNFT` | nein (Identitätsanker) |
| `LostNFT` | eingeschränkt (SOUL-Fragment) |

**SOUL**: unveränderbar im Ledger, nicht handelbar, Identitätsanker für Forge-/Governance-/Evolutionsrechte.
**LOST**: Fragment eines SOULs, Herkunft bleibt referenziert, Rekonstruktion nur unter strengen Regeln, alte Historie wird nie überschrieben.

**Invariante:** Keine NFT-Menge darf mehr Kapazität repräsentieren als durch Evidence gedeckt.

### NFT-Operationen

```
erschaffen, übertragen, teilen, verbinden, einfrieren,
widerrufen, verbrauchen, entwickeln, schmieden, rekonstruieren
```

---

## Ökonomie

| Asset | Funktion |
|-------|----------|
| `ALGO` | Beitragswährung — algorithmische Arbeit → XP → ALGO |
| `BKG` | Settlement-Währung — Compute; ALGO ↔ BKG nach Protokoll |
| `TPS/Batch/Capacity-NFT` | Compute-Capabilities, handelbar |

```
Algorithmus → Verifikation → XP → ALGO → Compute → neue Daten → neue Algorithmen
BKG → TPS-NFT → Compute → Messdaten → Verifikation → ALGO → BKG
Guardian → Watcher-Erfahrung → Forge → bessere Guardian-Version → neue Beobachtungen
Hero → bessere Schmiedeverfahren → Forge-Evolution → neue Guardian-Generationen
```

---

## Prometheus Metriken (BKG)

```
─── Guardian / P2P ──────────────────────────────────────────────
bkg_guardian_events_total     bkg_guardian_flags_total
bkg_guardian_challenges_total bkg_guardian_verdicts_total
bkg_quorum_decisions_total    bkg_collateral_frozen_total
bkg_guardian_a_version        bkg_guardian_b_version
bkg_peer_count                bkg_watcher_count

─── Forge ───────────────────────────────────────────────────────
bkg_forge_candidates_total    bkg_forge_verified_total
bkg_forge_rejected_total      bkg_forge_epoch
bkg_algo_minted_total         bkg_xp_granted_total
```

---

## Implementierungsreihenfolge bkg-db (Phase 1)

```
1. page.zig     Page-Layout, Header, Slot-Array
2. storage.zig  Datei öffnen, Page read/write, fsync
3. wal.zig      Entry schreiben, Recovery
4. txn.zig      begin/commit/abort, MVCC-Timestamp
5. engine.zig   open/close, alles zusammenhalten
6. btree.zig    Insert/Lookup
7. schema.zig   Collection/Field/Index
8. ledger.zig   Append, Hash-Chain
9. merkle.zig   SHA256, Root
10. bkg_db.zig  Public API
```

---

## SPORE / CAPSULE / Evolutionsartefakte

> Spec: `SOUL_SPORES_v1.md`

### Konzepte

| Begriff | Bedeutung |
|---------|-----------|
| **SOUL** | Unveräußerlicher Identitätsanker — an uns gebunden, nicht handelbar, nicht übertragbar |
| **LOST** | Fragment einer verlorenen oder beschädigten SOUL-Lineage — trägt Herkunft, kann nicht selbst SOUL sein |
| **SPORE** | Portable Verbreitungseinheit für Fähigkeiten, Wissen oder Lineage-Fragmente |
| **CAPSULE** | Bündelung reproduzierbarer Fähigkeiten: Algorithmen, Guardian-Definitionen, Tests, Benchmarks |
| **SEED** | Startpunkt einer Capsule-Lineage |

### SPORE Lifecycle

```
CREATED → SEALED → DISPATCHED → OBSERVED → CHALLENGED
       → VERIFIED → ACTIVATED → MUTATED → RETIRED / LOST
```

Jede Zustandsänderung erzeugt ein Ledger-Ereignis. Kein stilles Überschreiben.

### SPORE-Invarianten

- Empfang einer Spore bedeutet **kein** automatisches Vertrauen
- Spore muss lokal geprüft und durch Watcher + Guardian-Evidence validiert werden bevor Aktivierung
- Weitergabe ist keine Vertrauensvererbung
- Eine aktivierte Spore darf Kind-Sporen erzeugen — neue Generation trägt Parent-Lineage + eigenen Payload-Hash
- Keine Spore kann sich selbst als vertrauenswürdig deklarieren

### Capsule-Fragmentierung und Rekombination

```
Capsule → [Spore₁, Spore₂, ..., SporeN]   (jede kennt Parent-Capsule + Fragmentrolle)
[Spore₁, Spore₂, ..., SporeN] → neue Capsule  (neue Identität, neue Version)
```

Alte Lineages bleiben unverändert erhalten.
Die Rekombination erzeugt immer eine neue Identität.

### Evolutionslinie

```
SOUL → Capsule → Spore → P2P-Zone → Watcher-Beobachtung → Guardian-Verifikation → neue Capsule
```

### SOUL-SPORE-Grenze

- SOUL-Spores dürfen Herkunft oder technische Fragmente transportieren
- Sie dürfen **nie** stillschweigend die vollständige SOUL-Identität übertragen
- LOST kann als Quelle für autorisierte Rekonstruktion dienen — ist selbst keine vollständige SOUL
- Rekonstruktion verändert nicht rückwirkend die historische Chain

### Version als Identität

Version beschreibt nicht nur Software-Releases, sondern die gesamte Lineage eines Objekts.
Eine Version darf nur durch eine neue Version ersetzt werden.
Historische Versionen bleiben im Ledger referenzierbar.

---

## Das Gesamtbild (wtf_v2.md)

> Volltexte: `wtf.md` (v1), `wtf_v2.md` (aktuell)

Wir bauen keinen gewöhnlichen Coding-Agenten und keine normale AI-App.

```
Peer-Aktivität  →  Watcher (Beobachtungen)
                →  Guardian (Zonen, Probleme)
                →  Forge (neue Algorithmen, neue Guardians)
                →  Capsules (versionierte Fähigkeiten)
                →  Spores (P2P-Verbreitung)
                →  Ledger (Lineage, unveränderlich)
                →  Modelle (algorithmische Bausteine, nicht Code-Imitation)
```

**Modelle arbeiten mit einem algorithmischen Baukasten.**
Sprachquellen (C++, Python, Rust, Zig) sind Rohmaterial.
Daraus werden Algorithmen, Semantik, Invarianten, Kompositionsregeln, Tests, Benchmarks extrahiert.
Der Supercoder konstruiert — und materialisiert die Lösung erst am Ende als Code.

**Ziel:** Nicht „mehr Code schreiben" — sondern „bessere Konstruktionen erschaffen".

### NO PERMANENT TRUST (wtf_v2 — Systemregel)

```
Kein Peer, Watcher, Guardian, Hero, Algorithmus oder Asset wird
durch Reputation dauerhaft unprüfbar.

Reputation = Priorisierung, kein Freifahrtschein.
Reputation altert.
Revalidation bleibt möglich.
Watcher werden ebenfalls beobachtet.
```

Das Netz sucht gezielt nach **Contradictions** zwischen behaupteter Identität und beobachtetem Verhalten.

### Peer-Identitäts-Invariante (wtf_v2)

```
Transport darf wechseln.
Kryptografische Peer-Identität bleibt bestehen.

Auto-WLAN / Mobilfunk / Café-WLAN
  → kein neuer Watcher
  → keine neue Identität
```

### Killchain-Invariante (wtf_v2)

Ein kompromittierter Credential darf **nicht automatisch die Assets des Besitzers zerstören.**

### Drei Evolutionskreisläufe

```
1. Algorithmen:
   Problem → Wissen → Komposition → Test → Benchmark → Verifikation
          → Ledger → XP/ALGO → Wiederverwendung

2. Guardians:
   Beobachtung → Guardian-Erkenntnis → Forge → neuer Guardian
              → neue Watcher → neue Beobachtung

3. SOUL-Spores:
   SOUL → Fragment/Spore → P2P-Verbreitung → Prüfung
       → Rekonstruktion oder neue Lineage
```

**Ein Satz:**
> Wir bauen einen verteilten algorithmischen Organismus: Modelle erschaffen, die Forge schmiedet,
> Guardians koordinieren, Watcher prüfen, das P2P-Netz verbreitet, das Ledger erinnert und
> native Assets diese Fähigkeiten handelbar oder unveräußerlich macht.
> Das System soll mit jeder verifizierten Generation mehr wissen, mehr Fähigkeiten besitzen
> und bessere Guardians erschaffen können — ohne Vertrauen blind zu verschenken.

---

## Genesis Authority

> Spec: `GENESIS_AUTHORITY_v1.md`

Genesis Authority ist kein Mutable State.
Sie ist ein unveränderlicher Root-Anker — vergleichbar mit der SOUL, aber für Autorisierungsursprung.

**Invariante:** Ein späteres Harness darf niemals durch seine eigene Evolution zur Genesis Authority werden.

```
Evolution ≠ Authority Origin
Capability ≠ Authority
Role       ≠ Authority
Lineage    ≠ Authority
```

### Vertrauensbaum

```
GENESIS
  │
  ├── HOST SOUL ROOT
  │
  ├── FORGE AUTHORITY
  │      └── darf Artefakte schmieden
  │
  └── GUARDIAN AUTHORITY SET
         └── darf Quorum-Votes erzeugen
```

Dynamische Delegationen entstehen ausschließlich durch signierte Ledger-Events:

```
Genesis Forge
      │
      ├── authority_delegated ──► Hero A
      │
      └── authority_delegated ──► Demon B
```

### GenesisAuthorityRecord

```
GenesisAuthorityRecord {
    genesis_id
    protocol_version
    host_soul_cid
    forge_pubkey
    guardian_pubkeys[]
    genesis_timestamp
    genesis_hash         // deterministisch aus kanonischer Genesis-Struktur
    genesis_signature
}
```

Der `genesis_hash` wird deterministisch aus der kanonischen Genesis-Struktur berechnet.
Er darf nicht frei vergeben werden.

**Die Genesis selbst gehört nicht in den normalen Mutable State.**

Der Rebuilder erhält sie als unveränderlichen Protokollparameter:

```
rebuild(
    genesis_authority,
    ledger_stream
)
```

Kein manipuliertes State-Objekt kann behaupten `forge_pubkey = somebody_else`,
weil der Rebuilder die Genesis Authority bereits außerhalb des Mutable States kennt.

### Erste Ledger-Regel

Das allererste Event ist an die Genesis gebunden:

```
sequence  = 0
prev_hash = GENESIS_PARENT_HASH
```

Alle folgenden Events:

```
event[N].prev_hash == event[N-1].event_hash
```

Resultierende Hash-Chain:

```
GENESIS → E0 → E1 → E2 → ...
```

### Forge-Autorität — Privilegierte Events

Folgende Events dürfen **nur** von autorisierten Genesis-/Root-Schlüsseln kommen:

```
artifact_forged
artifact_composed
authority_delegated
authority_revoked
guardian_set_changed
```

Ein normaler Hero kann kein Forge-Event imitieren — selbst wenn er Hero R3 ist,
tausende Lineage Resonances besitzt, perfekte Causal Fingerprints hat
oder maximale Capabilities hält.

### Guardian Set — Herkunftspflicht

Die Liste `trusted_guardians[]` darf nicht aus einer eingehenden P2P-Nachricht stammen.
Sie wird ausschließlich abgeleitet aus:

```
Genesis
    ↓
Authority Events
    ↓
current authorized guardian set
```

Ein Peer kann nicht `trusted_guardians = [my_key, my_key, my_key]` senden
und anschließend ein angebliches 3/3-Quorum erzeugen.

### Bootstrap-Sequenz

```
BOOT
 ↓ LOAD GENESIS
 ↓ VERIFY GENESIS HASH
 ↓ VERIFY GENESIS SIGNATURE
 ↓ LOAD AUTHORITY ROOTS
 ↓ VERIFY SEGMENTS
 ↓ VERIFY CHECKPOINT
 ↓ RECOVER WAL
 ↓ VERIFY EVENT CHAIN
 ↓ AUTHORIZE EVENTS
 ↓ FOLD
 ↓ MATERIALIZE
 ↓ DERIVE
 ↓ BUILD RUNTIME PROJECTION
 ↓ START FORGE
 ↓ START HERO/DEMON HOSTING
 ↓ START C2
```

Forge, Guardians und Evolution werden **nicht** aus demselben State abgeleitet.
Sie besitzen unterschiedliche Vertrauenswurzeln.

---

## Die fünf Vertrauenswurzeln

| Wurzel | Frage |
|--------|-------|
| **SOUL** | Wer bin ich? |
| **GENESIS AUTHORITY** | Wer darf welche protokollarische Macht ausüben? |
| **LEDGER** | Was ist passiert? |
| **REBUILDER** | Ist es gültig? |
| **DERIVE** | Was bin ich aufgrund meiner Geschichte geworden? |

```
SOUL ROOT
    │
    └── Identity

GENESIS AUTHORITY ROOT
    │
    ├── Forge Authority
    └── Guardian Authority

LEDGER
    │
    └── dynamische Delegationsrechte

MANIFESTATION
    │
    └── aktueller Zustand

DERIVE
    │
    └── emergente Rolle
```

---

## Das vollständige Vertrauensbild

```
                     GENESIS AUTHORITY
                            │
            ┌───────────────┼────────────────┐
            │                                │
       FORGE ROOT                     GUARDIAN ROOT SET
            │                                │
      artifact_forged                   quorum verdicts
            │                                │
            └───────────────┬────────────────┘
                            ▼
                          BKGDB
                            │
             VERIFY → AUTHORIZE → FOLD
                            │
              MATERIALIZE → DERIVE
                            │
                  Runtime Projection
                            │
User → Peer                C2
         ├── Creator Model (groß, kreativ)   → Algorithmus / Artefakt
         ├── Watcher (mobil)                 → signierte Evidence
         └── Guardian (A: Verhalten, B: Öko) → P2P Guardian Network
                  ↓
              Quorum
                  ↓
           BKG Ledger (unveränderlich, Merkle-gehasht)
                  ↓
         XP / ALGO / NFT / TPS / SOUL / CAPSULE / SPORE
```

**User vertraut dem Netzwerk. Nicht das Netzwerk vertraut dem User.**

**Genesis Authority besitzt das alleinige Recht, protokollarische Macht zu begründen.**
