/// BKGDB — Native Zig Database Engine
/// WAL + MVCC + Content Addressing + Immutable Ledger + P2P Proof Protocol
///
/// Kein SQLite. Kein PostgreSQL. Keine externe Abhängigkeit.
///
/// Architektur-Schichten:
///   Mutable State       — WAL + MVCC (page.zig, storage.zig, wal.zig, txn.zig, engine.zig)
///   Immutable Ledger    — Append-only, kryptografisch verkettet (ledger.zig, merkle.zig)
///   Protocol            — Event-Typen, State-Projektion, Rebuild (protocol/)
///   Engine              — Deterministic Rebuild, LedgerWal, Segment, Merkle, Proofs (engine/)
///   P2P                 — Proof Protocol, Dispute Resolution (p2p/)
///
/// Vierfache Trennung (Protokoll-Invariante):
///   Hashchain        → kausale Reihenfolge
///   Merkle Root      → Segment-Mitgliedschaft
///   State Root       → materialisierter Zustand
///   Causal Fingerprint → Evolutionsgeschichte
pub const engine          = @import("engine.zig");
pub const page            = @import("page.zig");
pub const wal             = @import("wal.zig");
pub const storage         = @import("storage.zig");
pub const txn             = @import("txn.zig");
pub const btree           = @import("btree.zig");
pub const schema          = @import("schema.zig");
pub const ledger          = @import("ledger.zig");
pub const merkle          = @import("merkle.zig");
pub const protocol        = @import("protocol/protocol.zig");
// engine/segment_merkle.zig, engine/segment.zig und p2p_protocol.zig
// werden über das Modul-System (build.zig) eingebunden um Kollisionen zu vermeiden.
pub const segment_merkle  = @import("segment_merkle.zig");
pub const segment         = @import("segment.zig");
pub const p2p_protocol    = @import("p2p/p2p_protocol.zig");
