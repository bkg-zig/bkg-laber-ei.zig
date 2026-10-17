/// BKGDB Protocol — HarnessManifestation (Materialized View)
///
/// HarnessManifestation ist die projizierte Darstellung eines Harness
/// aus dem Immutable Ledger. Sie ist KEIN primärer Speicher —
/// sie ist das gecachte Ergebnis von rebuild.rebuildHarnessState().
///
/// Vier aktive Datenstrukturen:
///   active_influence_set   — current_manifestation-Einflüsse (warten auf absorbed)
///   pending_forge_set      — PendingForgeEntry-Set (warten auf absorbed, mit Forge-Herkunft)
///   lineage_resonance_set  — permanente Resonanzen (nie verbraucht)
///   authority_set          — aktive Delegations-Mandate (zeitgebunden an Ledger-State)
///
/// causal_fingerprint:
///   SHA256(soul_cid || artifact_cid || all_influence_event_hashes_sorted)
///   Wird von Watchern verglichen. Abweichung → Challenge → Killchain.
///
/// Invariante: AUTHORIZE wird immer gegen den unmittelbar vorherigen Ledger-State
/// eines Events geprüft — niemals gegen einen später rekonstruierten Zustand.
/// Ein revociertes Mandat macht bereits erfolgte Events nicht ungültig, da diese
/// zum Zeitpunkt ihrer Entstehung gegen den damals gültigen State autorisiert wurden.
const std = @import("std");
const ids_mod = @import("ids.zig");

pub const Hash   = ids_mod.Hash;
pub const CID    = ids_mod.CID;
pub const IdType = ids_mod.IdType;
pub const ZERO_HASH = ids_mod.ZERO_HASH;

// ── TargetGeneration / InfluenceDirection ────────────────────────────────

pub const TargetGeneration = enum(u8) {
    current_manifestation = 0,
    next_generation       = 1,
};

pub const InfluenceDirection = enum(u8) {
    bless = 1,
    curse = 2,
};

// ── CausalInfluence ───────────────────────────────────────────────────────

/// Ein Einfluss in der Queue — entstammt einem influence_authorized Ledger-Event.
pub const CausalInfluence = struct {
    source_harness:      Hash,
    source_artifact_cid: Hash,
    shared_work_context: Hash,
    target_generation:   TargetGeneration,
    direction:           InfluenceDirection,
    decay_condition_cid: Hash,
    /// Hash des zugehörigen influence_authorized Ledger-Events (Kausal-Anker).
    causality_ledger_event: Hash,
};

// ── PendingForgeEntry ─────────────────────────────────────────────────────

/// Ein vom Forge geschmiedetes Artefakt — wartet auf Absorption durch den Harness.
///
/// Invariante: Ein Artefakt darf nur von genau dem Harness absorbiert werden,
/// für das die Forge es geschmiedet hat, und nur für genau die vom
/// Forge-Event deklarierte Generation.
///
///   absorbed_artifact_cid → was absorbiert werden soll
///   target_harness        → wer es absorbieren darf (muss mit state.identity.harness_id übereinstimmen)
///   forge_event_hash      → kausaler Anker des artifact_forged-Events
pub const PendingForgeEntry = struct {
    /// CID des geschmiedeten Artefakts (wird current_artifact_cid nach Absorption).
    artifact_cid:     Hash,
    /// Harness, für den dieses Artefakt bestimmt ist.
    target_harness:   Hash,
    /// Hash des artifact_forged-Events (kausaler Beweis, dass die Forge es autorisiert hat).
    forge_event_hash: Hash,
};

// ── AuthorityScope ────────────────────────────────────────────────────────

/// Scope eines Authority-Mandats.
///
/// Verhindert Mehrdeutigkeit bei `expires_at_generation`: eine Generation
/// ist nur innerhalb eines eindeutig definierten Scopes bedeutsam.
pub const AuthorityScope = union(enum(u8)) {
    /// Mandat gilt global für alle Operationen des delegierten Schlüssels.
    global: void,
    /// Mandat gilt nur für einen bestimmten Harness.
    harness: Hash,
    /// Mandat gilt nur innerhalb eines bestimmten Work Contexts.
    work_context: Hash,
    /// Mandat gilt nur für eine bestimmte Operation (Event-Type-Wert als u16).
    operation: u16,
};

/// Ein aktives Authority-Mandat — entsteht aus einem authority_delegated-Event.
///
/// Zeitbindungs-Invariante: Dieses Mandat ist nur gültig für Events, deren
/// Sequenz-Nummer ≤ revoked_at_sequence ist (ZERO = nicht widerrufen).
/// Ein bereits autorisiertes Event bleibt gültig, auch wenn das Mandat später
/// widerrufen wird — der Rebuild prüft immer gegen den State *vor* dem Event.
pub const AuthorityMandate = struct {
    /// Delegierter Public Key (darf Aktionen im Scope des Mandats signieren).
    delegated_pubkey:    Hash,
    /// Scope des Mandats.
    scope:               AuthorityScope,
    /// Ledger-Event, das dieses Mandat erteilt hat.
    grant_event_hash:    Hash,
    /// Ledger-Sequenz, ab der das Mandat widerrufen wurde (0 = aktiv).
    revoked_at_sequence: u64,
};

// ── LineageResonance ──────────────────────────────────────────────────────

/// Permanente Resonanz — entsteht aus absorbierten current_manifestation-Einflüssen.
/// Nie verbraucht. Bleibt dauerhaft in der Lineage.
pub const LineageResonance = struct {
    resonance_cid:           Hash,
    absorbed_at_epoch:       u64,
    causality_ledger_event:  Hash, // Hash des artifact_absorbed-Events
};

// ── HarnessProvenance ─────────────────────────────────────────────────────

/// Herkunft einer Manifestation — woher gebootet wurde.
pub const HarnessProvenance = struct {
    origin_spore_cid:         Hash, // Spore, aus der gebootet (ZERO wenn via LOST)
    origin_lost_cid:          Hash, // LOST, aus dem gebootet (ZERO wenn via Spore)
    causality_ledger_event:   Hash, // Hash des manifestation_booted_from_spore-Events
};

// ── HarnessIdentity ───────────────────────────────────────────────────────

pub const HarnessIdentity = struct {
    harness_id:           Hash,
    canonical_soul_hash:  Hash,
};

// ── HarnessManifestation ──────────────────────────────────────────────────

/// Vollständige Materialized View eines Harness.
///
/// Ownership-Regel:
///   active_influence_set, pending_forge_set, authority_set, lineage_resonance_set
///   sind owned slices (allokiert vom Aufrufer von rebuildHarnessState).
///   Freigabe via freeHarnessManifestation().
pub const HarnessManifestation = struct {
    identity:             HarnessIdentity,
    provenance:           HarnessProvenance,
    current_artifact_cid: Hash,

    /// current_manifestation-Einflüsse — Konsum via artifact_absorbed
    active_influence_set: []CausalInfluence,

    /// Geschmiedete Artefakte, die auf Absorption warten.
    /// Jeder Eintrag hält target_harness + forge_event_hash als kausalen Beweis.
    pending_forge_set:    []PendingForgeEntry,

    /// Permanente Resonanzen — nie verbraucht
    lineage_resonance_set: []LineageResonance,

    /// Aktive Authority-Mandate — zeitgebunden an den Ledger-State bei Entstehung.
    authority_set: []AuthorityMandate,

    /// Kryptografischer Fingerprint des aktuellen Zustands.
    /// SHA256(soul || artifact || sorted_influence_hashes)
    /// Watcher vergleichen diesen bei P2P-Challenges.
    causal_fingerprint: Hash,
};

/// Gibt alle owned Slices einer HarnessManifestation frei.
pub fn freeHarnessManifestation(m: *HarnessManifestation, allocator: std.mem.Allocator) void {
    allocator.free(m.active_influence_set);
    allocator.free(m.pending_forge_set);
    allocator.free(m.lineage_resonance_set);
    allocator.free(m.authority_set);
}

// ── Fingerprint ───────────────────────────────────────────────────────────

/// Berechnet den causal_fingerprint für eine HarnessManifestation.
///
/// Input: soul_hash || artifact_cid || (alle influence event hashes, nach Wert sortiert)
/// Hash: SHA256
///
/// Deterministisch: gleicher Zustand → gleicher Fingerprint, unabhängig von Reihenfolge
/// der Einflüsse in der Queue.
pub fn computeStateFingerprint(m: *const HarnessManifestation, allocator: std.mem.Allocator) !Hash {
    // Sammle alle Influence-Event-Hashes (beide Queues)
    const total = m.active_influence_set.len + m.pending_forge_set.len;
    var hashes = try allocator.alloc(Hash, total);
    defer allocator.free(hashes);

    var idx: usize = 0;
    for (m.active_influence_set) |inf| {
        hashes[idx] = inf.causality_ledger_event;
        idx += 1;
    }
    for (m.pending_forge_set) |pfe| {
        hashes[idx] = pfe.forge_event_hash;
        idx += 1;
    }

    // Sortiere für Determinismus
    std.mem.sortUnstable(Hash, hashes, {}, struct {
        fn lt(_: void, a: Hash, b: Hash) bool {
            return std.mem.lessThan(u8, &a, &b);
        }
    }.lt);

    // SHA256(soul || artifact || hashes...)
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&m.identity.canonical_soul_hash);
    hasher.update(&m.current_artifact_cid);
    for (hashes) |h| hasher.update(&h);

    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn mkh(b: u8) Hash {
    var h: Hash = ZERO_HASH;
    h[0] = b;
    return h;
}

test "state: computeStateFingerprint deterministisch" {
    const inf_a = CausalInfluence{
        .source_harness = mkh(0xA0), .source_artifact_cid = ZERO_HASH,
        .shared_work_context = ZERO_HASH, .target_generation = .current_manifestation,
        .direction = .bless, .decay_condition_cid = ZERO_HASH,
        .causality_ledger_event = mkh(0x01),
    };

    var active = [_]CausalInfluence{inf_a};
    var pending = [_]PendingForgeEntry{};
    var resonances = [_]LineageResonance{};
    var authorities = [_]AuthorityMandate{};

    const m = HarnessManifestation{
        .identity   = .{ .harness_id = mkh(0x10), .canonical_soul_hash = mkh(0x20) },
        .provenance = .{ .origin_spore_cid = ZERO_HASH, .origin_lost_cid = ZERO_HASH,
                         .causality_ledger_event = ZERO_HASH },
        .current_artifact_cid = mkh(0x30),
        .active_influence_set  = &active,
        .pending_forge_set     = &pending,
        .lineage_resonance_set = &resonances,
        .authority_set         = &authorities,
        .causal_fingerprint    = ZERO_HASH,
    };

    const fp1 = try computeStateFingerprint(&m, std.testing.allocator);
    const fp2 = try computeStateFingerprint(&m, std.testing.allocator);
    try std.testing.expect(ids_mod.hashEql(fp1, fp2));
    // Fingerprint ist nicht Zero
    try std.testing.expect(!ids_mod.isZero(fp1));
}

test "state: fingerprint ändert sich bei verschiedenem Artefakt" {
    var active = [_]CausalInfluence{};
    var pending = [_]PendingForgeEntry{};
    var resonances = [_]LineageResonance{};
    var authorities = [_]AuthorityMandate{};

    var m = HarnessManifestation{
        .identity   = .{ .harness_id = mkh(0x10), .canonical_soul_hash = mkh(0x20) },
        .provenance = .{ .origin_spore_cid = ZERO_HASH, .origin_lost_cid = ZERO_HASH,
                         .causality_ledger_event = ZERO_HASH },
        .current_artifact_cid = mkh(0x30),
        .active_influence_set  = &active,
        .pending_forge_set     = &pending,
        .lineage_resonance_set = &resonances,
        .authority_set         = &authorities,
        .causal_fingerprint    = ZERO_HASH,
    };

    const fp1 = try computeStateFingerprint(&m, std.testing.allocator);
    m.current_artifact_cid = mkh(0x31);
    const fp2 = try computeStateFingerprint(&m, std.testing.allocator);
    try std.testing.expect(!ids_mod.hashEql(fp1, fp2));
}

test "state: PendingForgeEntry — Felder vollständig" {
    const entry = PendingForgeEntry{
        .artifact_cid     = mkh(0xA1),
        .target_harness   = mkh(0xBB),
        .forge_event_hash = mkh(0xEE),
    };
    try std.testing.expect(ids_mod.hashEql(entry.artifact_cid, mkh(0xA1)));
    try std.testing.expect(ids_mod.hashEql(entry.target_harness, mkh(0xBB)));
    try std.testing.expect(ids_mod.hashEql(entry.forge_event_hash, mkh(0xEE)));
}

test "state: AuthorityScope Varianten kompilieren" {
    const s_global = AuthorityScope{ .global = {} };
    const s_harness = AuthorityScope{ .harness = mkh(0x11) };
    const s_ctx = AuthorityScope{ .work_context = mkh(0x22) };
    const s_op = AuthorityScope{ .operation = 500 };
    _ = s_global;
    _ = s_harness;
    _ = s_ctx;
    // operation scope = artifact_forged EventType
    try std.testing.expectEqual(@as(u16, 500), s_op.operation);
}

test "state: AuthorityMandate — aktiv und revociert unterscheidbar" {
    const active_mandate = AuthorityMandate{
        .delegated_pubkey    = mkh(0xDE),
        .scope               = .{ .global = {} },
        .grant_event_hash    = mkh(0x01),
        .revoked_at_sequence = 0, // aktiv
    };
    const revoked_mandate = AuthorityMandate{
        .delegated_pubkey    = mkh(0xDE),
        .scope               = .{ .global = {} },
        .grant_event_hash    = mkh(0x01),
        .revoked_at_sequence = 7, // widerrufen ab Seq 7
    };
    try std.testing.expectEqual(@as(u64, 0), active_mandate.revoked_at_sequence);
    try std.testing.expectEqual(@as(u64, 7), revoked_mandate.revoked_at_sequence);
}
