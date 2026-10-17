# Genesis Authority — Specification v1

> Status: **Baseline** — 2026-09-01
> Scope: BKG Host Protocol — Single-Host Variant
> Referenziert von: `BKG_LLM.md`, `ARCHITECTURE-V5.md`

---

## 1. Zweck

Genesis Authority definiert den unveränderlichen Ursprung aller protokollarischen Macht
im BKG-Host-System. Sie ist kein Mutable State, kein Ledger-Event und kein Runtime-Zustand.

Sie existiert **vor** dem ersten Ledger-Event und **außerhalb** des Rebuilder-Zustands.

---

## 2. Kernprinzip

```
Evolution   ≠ Authority Origin
Capability  ≠ Authority
Role        ≠ Authority
Lineage     ≠ Authority
```

Kein Harness — unabhängig von Rang, Lineage Resonances oder Capabilities —
kann durch eigene Evolution zur Genesis Authority aufsteigen.

Autorität entsteht **ausschließlich** durch:
1. Das unveränderliche Genesis Record selbst (Forge Root, Guardian Root Set), oder
2. Signierte `authority_delegated`-Events, die von Genesis-autorisierten Schlüsseln
   stammen und im Ledger verankert sind.

---

## 3. GenesisAuthorityRecord

Das einzige kanonische Objekt, das Genesis Authority materialisiert.

```
GenesisAuthorityRecord {
    genesis_id          // global eindeutiger Bezeichner dieser Genesis-Instanz
    protocol_version    // BKG Protocol Version (u32, LE)
    host_soul_cid       // CID der Host-SOUL — unveränderlich ab Genesis
    forge_pubkey        // Ed25519-Pubkey der Forge Authority (32 Bytes)
    guardian_pubkeys[]  // Ed25519-Pubkeys des initialen Guardian Root Sets
    genesis_timestamp   // Unix-Timestamp der Erstellung (u64, LE)
    genesis_hash        // SHA256 der kanonischen Genesis-Struktur (s. §3.1)
    genesis_signature   // Ed25519-Signatur über genesis_hash
}
```

### 3.1 Kanonische Hash-Berechnung

`genesis_hash` wird deterministisch berechnet. Er darf nie frei vergeben werden.

```
genesis_hash = SHA256(
    protocol_version_le4     ||
    host_soul_cid            ||
    forge_pubkey             ||
    guardian_count_le2       ||
    guardian_pubkeys[0..N]   ||
    genesis_timestamp_le8
)
```

Felder werden **immer in dieser Reihenfolge** gehasht. Reihenfolge-Änderungen
erzeugen einen anderen genesis_hash und werden als Protokollversion-Bruch behandelt.

### 3.2 Signatur

```
genesis_signature = Ed25519.sign(forge_privkey, genesis_hash)
```

Die Signatur bindet den Forge-Schlüsselinhaber an den vollständigen Genesis-Inhalt.

---

## 4. Vertrauensbaum

```
GENESIS
  │
  ├── HOST SOUL ROOT
  │      └── Identität des Hosts — unveränderlich
  │
  ├── FORGE AUTHORITY
  │      └── darf privilegierte Ledger-Events ausstellen
  │
  └── GUARDIAN AUTHORITY SET
         └── darf Quorum-Votes erzeugen
```

### 4.1 Privilegierte Ledger-Events

Folgende Events dürfen **ausschließlich** von einem Genesis-autorisierten Schlüssel
(Forge Root oder per `authority_delegated` abgeleiteter Schlüssel) signiert werden:

| Event | Beschreibung |
|-------|-------------|
| `artifact_forged` | Neues Artefakt erzeugen |
| `artifact_composed` | Artefakte zusammensetzen |
| `authority_delegated` | Autorität an Hero/Demon delegieren |
| `authority_revoked` | Delegierte Autorität entziehen |
| `guardian_set_changed` | Guardian Root Set ändern |

Ein normaler Hero kann kein solches Event imitieren — selbst wenn er:
- Hero R3 ist,
- tausende Lineage Resonances besitzt,
- perfekte Causal Fingerprints hat, oder
- maximale Capabilities hält.

### 4.2 Dynamische Delegationen

Dynamische Delegationen entstehen ausschließlich durch signierte Ledger-Events:

```
Genesis Forge
      │
      ├── authority_delegated ──► Hero A
      │
      └── authority_delegated ──► Demon B
```

Die Delegation ist ledger-gebunden: Sie existiert ab dem Event-Hash ihres
`authority_delegated`-Events und endet mit dem zugehörigen `authority_revoked`-Event.

---

## 5. Genesis Record als Protokollparameter

Die Genesis gehört **nicht** in den normalen Mutable State.

Der Rebuilder erhält sie als unveränderlichen Parameter außerhalb des Ledger-Streams:

```
rebuild(
    genesis_authority: GenesisAuthorityRecord,
    ledger_stream:     []const LedgerEventEnvelope,
) → RebuildResult
```

**Sicherheitsgarantie:** Kein manipuliertes State-Objekt kann behaupten,
`forge_pubkey = somebody_else`, weil der Rebuilder die Genesis Authority bereits
vor der Ledger-Verarbeitung kennt und extern verifiziert hat.

---

## 6. Erste Ledger-Regel (Genesis Binding)

Das allererste Event muss an die Genesis gebunden sein:

```
event[0].sequence  = 0
event[0].prev_hash = GENESIS_PARENT_HASH  // = ZERO_HASH ([32]u8{0})
```

Alle folgenden Events:

```
event[N].prev_hash == event[N-1].event_hash
```

Resultierende Hash-Chain:

```
GENESIS
   ↓
E0 (sequence=0, prev=ZERO_HASH)
   ↓
E1 (sequence=1, prev=E0.event_hash)
   ↓
E2 (sequence=2, prev=E1.event_hash)
   ↓
...
```

---

## 7. Guardian Set — Herkunftspflicht

Die Liste `trusted_guardians[]` wird **ausschließlich** aus der Ledger-Kette abgeleitet:

```
Genesis.guardian_pubkeys[]
    ↓
guardian_set_changed Events (chronologisch)
    ↓
aktuelles authorized guardian set
```

Sie darf **niemals** aus einer eingehenden P2P-Nachricht stammen.

**Angriffs-Invariante:** Ein Peer kann nicht senden:
```
trusted_guardians = [my_key, my_key, my_key]
```
und anschließend ein angebliches 3/3-Quorum erzeugen, weil der Host das
Guardian Set ausschließlich aus dem verifizierten Ledger ableitet.

---

## 8. Bootstrap-Sequenz

Der vollständige Boot-Pfad unter Genesis Authority:

```
BOOT
 ↓
LOAD GENESIS
 ↓
VERIFY GENESIS HASH          // genesis_hash == SHA256(kanonische Felder)
 ↓
VERIFY GENESIS SIGNATURE     // Ed25519.verify(forge_pubkey, genesis_hash, genesis_signature)
 ↓
LOAD AUTHORITY ROOTS         // forge_pubkey + guardian_pubkeys[] aus Genesis extrahieren
 ↓
VERIFY SEGMENTS              // Segment-Merkle-Roots prüfen
 ↓
VERIFY CHECKPOINT            // letzter Checkpoint-Hash prüfen
 ↓
RECOVER WAL                  // WAL-Tail auf torn-write prüfen, gültige Frames anwenden
 ↓
VERIFY EVENT CHAIN           // prev_hash-Kette + Sequenznummern lückenlos
 ↓
AUTHORIZE EVENTS             // actor_pubkey jedes Events gegen bekannte Authority-Menge prüfen
 ↓
FOLD                         // State aus Events materialisieren
 ↓
MATERIALIZE                  // active vs. pending Einflüsse trennen
 ↓
DERIVE                       // emergente Rolle ableiten
 ↓
BUILD RUNTIME PROJECTION     // C2-Sicht + Hero/Demon-Sicht aufbauen
 ↓
START FORGE                  // Forge-Schleife aktivieren
 ↓
START HERO/DEMON HOSTING     // Hero- und Demon-Runtime starten
 ↓
START C2                     // Command & Control Interface öffnen
```

**Entscheidender Unterschied:** Forge, Guardians und Evolution werden **nicht**
aus demselben State abgeleitet. Sie besitzen unterschiedliche Vertrauenswurzeln.

---

## 9. Abgrenzung zu anderen Vertrauenswurzeln

| Vertrauenswurzel | Beantwortet |
|------------------|-------------|
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

Genesis Authority und SOUL sind strukturell gleichwertig: beide unveränderlich,
beide außerhalb des Rebuilder-Zustands, beide Protokollparameter beim Start.
Ihre Domänen sind strikt getrennt:

- **SOUL** = Identitätsanker (Wer)
- **GENESIS AUTHORITY** = Machtanker (Wer darf was)

---

## 10. Vollständiges Vertrauensbild

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
                           C2
```

**Genesis Authority besitzt das alleinige Recht, protokollarische Macht zu begründen.**

---

## 11. Implementierungshinweise

### 11.1 Zukünftiges `genesis.zig`

Geplanter Ort: `bkg/libs/bkg-db/src/genesis/genesis.zig`

Mindestinhalt:

```zig
pub const GenesisAuthorityRecord = struct {
    genesis_id:          [16]u8,
    protocol_version:    u32,
    host_soul_cid:       [32]u8,
    forge_pubkey:        [32]u8,
    guardian_pubkeys:    [][32]u8,  // heap-allokiert, Länge in guardian_count
    guardian_count:      u8,
    genesis_timestamp:   u64,
    genesis_hash:        [32]u8,
    genesis_signature:   [64]u8,
};

pub fn computeGenesisHash(rec: *const GenesisAuthorityRecord) [32]u8
pub fn freeGenesisRecord(rec: *const GenesisAuthorityRecord, allocator: std.mem.Allocator) void
pub fn verifyGenesisRecord(rec: *const GenesisAuthorityRecord) GenesisVerifyError!void
```

Implementiert in `bkg/libs/bkg-db/src/genesis/genesis.zig`.

### 11.2 Rebuild-Signatur — implementiert

`rebuildProtocol` nimmt einen `genesis_authority`-Parameter als unveränderlichen Protokollparameter:

```zig
pub fn rebuildProtocol(
    allocator: std.mem.Allocator,
    genesis:   *const GenesisAuthorityRecord,
    events:    []const LedgerEventEnvelope,
) RebuildError!RebuildResult
```

Die AUTHORIZE-Phase prüft `envelope.actor_pubkey` gegen `genesis.forge_pubkey` für
privilegierte Events. `guardian_set_changed`-Events werden zusätzlich gegen `forge_pubkey`
geprüft — Verletzung ergibt `UnauthorizedGuardianChange`.

Implementiert in `bkg/libs/bkg-db/src/engine/rebuild.zig`.

### 11.3 Serialisierungsformat

`GenesisAuthorityRecord` wird als binäre Datei gespeichert — **nicht** im WAL,
**nicht** im Segment-Store. Empfohlener Pfad: `<data_dir>/genesis.bin`.

Format: Canonical TLV analog zu `ledger_wal.zig`, feste Feldreihenfolge,
kein HashMap, kein Pointer-Inhalt im Bytestream.
