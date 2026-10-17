# BKGDB — Native Zig Database

> Entscheidung getroffen: 2026-08-31
> Status: Production path — durable WAL recovery, fail-closed hash/signature checks

---

## Warum eine eigene Datenbank

Keine PostgreSQL. Keine Redis. Kein SQLite.

BKGDB ist eine native Zig-Datenbank mit genau den Eigenschaften,
die das BKG-Ökosystem benötigt — nicht mehr, nicht weniger.

Die wichtigste Eigenschaft ist, dass **Mutable State und Immutable Ledger
in derselben Datenbank-Engine leben**, aber mit fundamental anderen Garantien.

---

## Vier fundamentale Eigenschaften

| Eigenschaft | Was sie bedeutet |
|-------------|-----------------|
| **WAL** | Write-Ahead-Log — jede Mutation landet zuerst im Log, dann in Pages |
| **MVCC** | Multi-Version Concurrency Control — Leser blockieren keine Schreiber |
| **Content Addressing** | Objekt-IDs werden aus dem kryptografischen Hash des Inhalts berechnet |
| **Merkle State** | Der gesamte Zustand ist über Merkle Roots verifizierbar |

---

## Zwei Datenschichten

### Mutable State

Normaler Lese-/Schreibzugriff über WAL + MVCC.
Zustand darf sich ändern. Historische Versionen können verworfen werden.

```
─── eviladmin ─────────────────────────────────────────────────────
users             id, username, email, password_hash, role, status, timestamps
sessions          id, user_id, session_key, credential_id, expires_at, revoked_at
accounts          id, owner_user_id, display_name, provider, status, capacity_tps
credentials       id, account_id, owner_user_id, provider, encrypted_secret,
                  secret_nonce, secret_hash, preview, status, cooldown_until,
                  last_used_at, last_error_at, error_count, request_count
pools             id, owner_id, name, description, pool_type, status
pool_policies     pool_id, public_access, require_approval, contributor_routing, ...
pool_members      pool_id + user_id, role, joined_at
pool_credentials  pool_id + credential_id, added_at
user_quotas       user_id, max_requests_per_minute, max_tokens_per_minute, ...
key_health        credential_id + model, healthy, error_rate, avg_latency_ms, ...

─── BKG Network ───────────────────────────────────────────────────
peer_state        id, peer_id, zone_id, status, collateral, guardian_manifest_hash
guardian_state    id, peer_id, role, version, model_hash, policy_hash, forge_epoch
watcher_state     id, watcher_id, zone_id, current_peer_id, status
asset_balances    owner_id, asset_type, amount, updated_at
nft_ownership     nft_id, asset_class, owner_id, status, metadata_hash
capacity_state    peer_id, tps_available, tps_reserved, last_attested_at
```

### Immutable Ledger

Append-only. Einträge werden nie überschrieben oder gelöscht.
Jeder Eintrag ist mit dem Hash des vorherigen Eintrags verkettet (Merkle-Chain).

**Große Inhalte liegen außerhalb des Ledgers.
Die Chain trägt: Identität, Hashes, Provenance, Events und Zustandsbeweise.**

```
─── eviladmin ─────────────────────────────────────────────────────
audit_log         id, actor_id, target_type, target_id, action, ip, metadata, ts
usage_log         id, user_id, pool_id, credential_id, model, tokens, latency, ts
security_ledger   id, event_type, credential_id, session_id, peer_id, metadata, ts

─── BKG Network ───────────────────────────────────────────────────
algorithm_ledger  id, algo_id, version, parent_ids, source_hashes, xp, algo_reward,
                  verifier_results, benchmark_hash, forge_epoch, ts
asset_ledger      id, event_type, asset_class, nft_id, from_id, to_id,
                  amount, evidence_hash, quorum_ref, ts
forge_ledger      id, epoch, candidate_hash, guardian_verdicts, result,
                  parent_guardian_hashes, new_guardian_hash, ts
```

`security_ledger` — Event-Typen:

```
─── Key & Session ──────────────────────────────────────────────
KEY_CONFLICT             zwei Session-Identitäten für denselben Key
KEY_QUARANTINE           Key in Quarantäne gesetzt
KEY_REVOKED              Key explizit widerrufen
KEY_COMPROMISED          Emergency Kill Chain ausgelöst
SESSION_REVOKE           Session zwangsgeschlossen
KILL_CHAIN_START         Emergency Kill Chain begonnen
KILL_CHAIN_COMPLETE      Kill Chain abgeschlossen

─── Guardian / Quorum ──────────────────────────────────────────
GUARDIAN_FLAG              Guardian hat ein Event markiert
GUARDIAN_REJECT            Quorum hat ein Event abgelehnt
GUARDIAN_CHALLENGE         Guardian fordert Remote-Prüfung an
GUARDIAN_VERDICT           Signiertes Prüfergebnis eines Guardians
QUORUM_PASS                Quorum hat ein Event bestätigt
QUORUM_FAIL                Quorum hat ein Event abgelehnt
ALGORITHM_ACCEPTED         Algorithmus nach Quorum akzeptiert
ALGORITHM_REJECTED         Algorithmus nach Quorum abgelehnt
XP_GRANTED                 XP vergeben nach Quorum
ALGO_MINTED                ALGO geminted nach Quorum
CAPACITY_ATTESTED          Kapazität von Guardians bestätigt

─── Peer / Collateral ──────────────────────────────────────────
COLLATERAL_VIOLATION       Peer-Kaution-Verletzung durch Quorum bestätigt
COLLATERAL_FROZEN          Collateral eingefroren
COLLATERAL_RETURNED        Collateral zurückgegeben
PEER_JOINED                Peer dem Netz beigetreten (mit Collateral)
PEER_LEFT                  Peer sauber ausgetreten
GUARDIAN_REPUTATION_UPDATE Guardian meldet Reputationsänderung

─── Guardian-Versionierung ─────────────────────────────────────
GUARDIAN_VERSION_UPDATED   Hub hat neue Guardian-Version freigegeben (pro Rolle)
```

---

## Dateiformat auf Disk

```
data/
├── state.wal       Write-Ahead-Log für Mutable State (sequenzieller Append)
├── state.pages     Page Store für Mutable State (B-Tree, 4KB pages)
├── ledger.wal      Immutable Event Log (append-only, Merkle-gehasht)
└── meta.bkgdb      Engine-Metadaten (JSON)
```

`meta.bkgdb` Inhalt:

```json
{
  "version": 1,
  "schema_version": 1,
  "created_at": 1756684800,
  "last_checkpoint": 1756684800,
  "state_wal_size": 0,
  "ledger_entries": 0,
  "merkle_root": "0000...0000"
}
```

---

## Page-Layout (4KB)

```
Page (4096 Bytes):
┌──────────────────────────────────┐
│ Page Header (32 Bytes)           │
│   page_id:    u64                │
│   page_type:  u8 (data/index/...) │
│   free_start: u16                │
│   free_end:   u16                │
│   slot_count: u16                │
│   flags:      u8                 │
│   checksum:   u32                │
│   padding:    8 Bytes            │
├──────────────────────────────────┤
│ Slot Array (wächst von oben)     │
│   slot[0]: {offset: u16, len: u16} │
│   slot[1]: {offset: u16, len: u16} │
│   ...                            │
├──────────────────────────────────┤
│ Free Space                       │
├──────────────────────────────────┤
│ Record Data (wächst von unten)   │
│   record[n]: variable-length     │
│   record[1]: variable-length     │
│   record[0]: variable-length     │
└──────────────────────────────────┘
```

---

## WAL Entry Format

Jeder WAL-Eintrag ist atomar:

```
WAL Entry:
┌─────────────────────────────────┐
│ entry_len:   u32                │
│ txn_id:      u64                │
│ entry_type:  u8                 │
│   0x01 = Write                  │
│   0x02 = Commit                 │
│   0x03 = Abort                  │
│   0x04 = Checkpoint             │
│ page_id:     u64  (bei Write)   │
│ page_offset: u16  (bei Write)   │
│ data_len:    u16  (bei Write)   │
│ data:        [data_len]u8       │
│ checksum:    u32  (CRC32)       │
└─────────────────────────────────┘
```

Recovery: WAL von letztem Checkpoint bis Ende durchspielen.
Incomplete Transactions (kein Commit-Entry) werden verworfen.

---

## MVCC — Transaktionsnummern

```
txn_id = monoton steigender u64-Zähler
read_ts = txn_id zum Zeitpunkt des Transaktionsstarts
write_ts = txn_id zum Zeitpunkt des Commits
```

Jede Version eines Records trägt `write_ts`.
Eine Leseoperation mit `read_ts = T` sieht nur Records mit `write_ts ≤ T`.

Garbage Collection: Versionen mit `write_ts < min_active_read_ts` können freigegeben werden.

---

## Ledger Merkle-Chain

```
Entry 0:  hash = SHA256(data_0 || prev_hash_0)   prev = 0x00...00
Entry 1:  hash = SHA256(data_1 || hash_0)
Entry 2:  hash = SHA256(data_2 || hash_1)
...
Entry N:  hash = SHA256(data_N || hash_{N-1})
```

`merkle_root` in `meta.bkgdb` ist der Hash des letzten Ledger-Eintrags.

Verifikation eines Eintrags: Hash-Kette vom Eintrag bis zum bekannten Root nachrechnen.

---

## B-Tree Index

Primary Keys und explizite Indexes über B-Tree auf dem Page Store.

```
Intern Node:  [key, child_page_id, key, child_page_id, ...]
Leaf Node:    [key, record_page_id + slot_index, ...]
```

Leaf-Nodes sind doppelt verkettet für Range-Scans.

---

## Interne Modulstruktur

```
libs/bkg-db/src/
├── bkg_db.zig      Public API — re-exportiert alle öffentlichen Typen
├── engine.zig      Kern-Engine: öffnet DB, koordiniert alle Subsysteme
├── page.zig        Page-Struct, Header, Slot-Array, Record read/write
├── wal.zig         WAL append, read, recovery, checkpoint
├── storage.zig     Disk I/O: Datei open/close, page read/write, fsync
├── txn.zig         Transaction begin/commit/abort, MVCC-Snapshot, Write-Intent
├── btree.zig       B-Tree insert/lookup/delete/range-scan
├── schema.zig      Typen für Schema-Definitionen (Collection, Field, Index)
├── ledger.zig      Immutable Ledger: append, verify, merkle root
└── merkle.zig      SHA256-Hashing, Merkle-Chain, Proof
```

---

## Public API (Planung)

```zig
// DB öffnen
const db = try bkgdb.Engine.open(allocator, "./data");
defer db.close();

// Transaktion
const txn = try db.begin();
defer txn.deinit();

// Schreiben
try txn.put(collection, key, value);
try txn.commit();

// Lesen (snapshot zum txn-Zeitpunkt)
const val = try txn.get(collection, key);

// Scan
var iter = try txn.scan(collection, .{ .from = key_a, .to = key_b });
defer iter.deinit();
while (iter.next()) |entry| { ... }

// Ledger-Eintrag (append-only)
try db.ledger.append(event_type, payload);

// Merkle Root verifizieren
const root = db.ledger.merkleRoot();
```

---

## Typed Collections (eviladmin-Schicht)

Auf dem generischen BKGDB-API aufbauend definiert eviladmin
typsichere Collections in Zig:

```zig
// apps/eviladmin/src/db/collections/credentials.zig
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

## Implementierungsreihenfolge (Phase 1)

```
1. page.zig         Page-Layout, Header lesen/schreiben, Slot-Array
2. storage.zig      Datei öffnen, Page read/write, fsync
3. wal.zig          Entry schreiben, Sequenz lesen, Recovery
4. txn.zig          begin/commit/abort, MVCC-Timestamp
5. engine.zig       Alles zusammenhalten, open/close
6. btree.zig        Insert/Lookup (ohne Range zuerst)
7. schema.zig       Collection/Field/Index Definitionen
8. ledger.zig       Append, Hash-Chain
9. merkle.zig       SHA256 Chain, Root berechnen
10. bkg_db.zig      Public API zusammenstellen
```

Typed Collections kommen in Phase 2 (eviladmin-Schicht).

---

*Design: 2026-08-31*
*Nächster Schritt: page.zig implementieren*
