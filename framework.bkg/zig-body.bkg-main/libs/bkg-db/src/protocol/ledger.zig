/// BKGDB Protocol — Kryptografisches Ledger-Envelope
///
/// Baseline verriegelt: 2026-09-01
///
/// Leitsatz: Mutable State sagt, was gilt. Der Ledger beweist, warum es gilt.
///           Der Rebuilder beweist, dass beides zusammenpasst.
///
/// Das LedgerEventEnvelope trennt Payload strikt vom kryptografischen Beweis.
/// Jede Manipulation bricht den event_hash → BrokenChainLink beim Rebuild.
///
/// event_hash = SHA256(sequence_le8 || prev_event_hash || payload_bytes)
/// signature  = Ed25519(actor_privkey, event_hash)
///
/// Vier Invarianten (Protocol Baseline):
///   1. Kryptografische Sequenzpflicht — Kette muss sich selbst beweisen
///   2. Strenge Konsum-Invarianten — Forge nur next_generation, Absorb nur current
///   3. Strikte Forge/Absorption-Trennung — Forge erschafft, Absorb integriert
///   4. Unabhängige Fingerprint-Berechnung — Fingerprint ≠ State-Projektion
const std = @import("std");
pub const ids = @import("ids.zig");
const ev  = @import("events.zig");

pub const Hash      = ids.Hash;
pub const ZERO_HASH = ids.ZERO_HASH;

/// Ed25519 Signatur (64 Bytes).
pub const Signature = [64]u8;

pub const ZERO_SIG: Signature = [_]u8{0} ** 64;

// ── EventPayload ──────────────────────────────────────────────────────────
// Jeder Payload-Typ entspricht exakt einem EventType aus events.zig.
// Der union-Tag ist der kanonische Typ für den switch im Rebuilder.

pub const PayloadManifestationBooted = struct {
    soul_hash:            Hash,
    spore_cid:            Hash, // ZERO wenn via LOST
    lost_cid:             Hash, // ZERO wenn via Spore
    initial_artifact_cid: Hash,
};

pub const PayloadC2BindingEstablished = struct {
    harness_id:            Hash,
    demon_id:              Hash,
    capability_policy_cid: Hash,
};

pub const PayloadC2BindingRevoked = struct {
    harness_id:  Hash,
    demon_id:    Hash,
    reason_hash: Hash,
};

pub const PayloadWatcherEvidenceSubmitted = struct {
    watcher_id:    Hash,
    harness_id:    Hash,
    evidence_cid:  Hash,
    work_context:  Hash,
};

pub const PayloadGuardianAuthorizationGranted = struct {
    guardian_id:     Hash,
    harness_source:  Hash,
    harness_target:  Hash,
    work_context:    Hash,
    evidence_refs:   [8]Hash,
    evidence_count:  u8,
};

pub const PayloadInfluenceAuthorized = struct {
    source_harness:               Hash,
    target_harness:               Hash,
    source_artifact_cid:          Hash,
    shared_work_context:          Hash,
    authorization_policy_hash:    Hash,
    guardian_authorization_event: Hash,
    target_generation:            ev.TargetGeneration,
    direction:                    ev.InfluenceDirection,
    decay_condition_cid:          Hash,
};

pub const PayloadArtifactForged = struct {
    harness_id:             Hash,
    previous_artifact_cid:  Hash,
    new_artifact_cid:       Hash,
    /// Event-Hashes der konsumierten next_generation-Einflüsse.
    consumed_influence_events: [ev.MAX_CONSUMED_INFLUENCES]Hash,
    consumed_count: u8,
    forge_epoch:    u64,
};

pub const PayloadArtifactAbsorbed = struct {
    harness_id:             Hash,
    absorbed_artifact_cid:  Hash,
    /// Event-Hashes der konsumierten current_manifestation-Einflüsse.
    consumed_influence_events: [ev.MAX_CONSUMED_INFLUENCES]Hash,
    consumed_count:         u8,
    resulting_resonance_cid: Hash,
};

/// guardian_set_changed: Ersetzt den aktuellen Guardian Root Set.
/// Ausschließlich von der Forge Authority signierbar (privilegiertes Event).
/// Neue Guardian-Pubkeys treten sofort in Kraft für alle folgenden Events.
pub const PayloadGuardianSetChanged = struct {
    /// Anzahl neuer Guardian-Pubkeys (1..255).
    new_guardian_count: u8,
    /// Neue Guardian-Pubkeys (0-padded ab new_guardian_count).
    new_guardian_pubkeys: [32][32]u8,
    /// Optionaler Kommentar-Hash (ZERO = kein Kommentar).
    reason_cid: ids.Hash,
};

/// Typisierter union aller Ledger-Payloads.
/// Tag-Namen entsprechen den EventType-Feldern aus events.zig.
pub const EventPayload = union(ev.EventType) {
    soul_anchored:                    ids.Hash, // = soul_cid (direkt)
    manifestation_booted_from_spore:  PayloadManifestationBooted,
    c2_binding_established:           PayloadC2BindingEstablished,
    c2_binding_revoked:               PayloadC2BindingRevoked,
    watcher_evidence_submitted:       PayloadWatcherEvidenceSubmitted,
    guardian_authorization_granted:   PayloadGuardianAuthorizationGranted,
    influence_authorized:             PayloadInfluenceAuthorized,
    artifact_forged:                  PayloadArtifactForged,
    artifact_absorbed:                PayloadArtifactAbsorbed,
    guardian_set_changed:             PayloadGuardianSetChanged,
};

// ── LedgerEventEnvelope ───────────────────────────────────────────────────

/// Das unveränderliche Ledger-Element.
/// Jede Manipulation bricht den event_hash → BrokenChainLink beim Rebuild.
pub const LedgerEventEnvelope = struct {
    sequence:        u64,
    prev_event_hash: Hash,      // Link in der Merkle-Kette
    event_hash:      Hash,      // SHA256(seq_le8 || prev_event_hash || payload_bytes)
    actor_pubkey:    Hash,      // Wer hat das Event ausgelöst (32-Byte Ed25519 pubkey)
    signature:       Signature, // Ed25519(actor_privkey, event_hash)
    payload:         EventPayload,
};

// ── Hash-Berechnung ───────────────────────────────────────────────────────

/// Berechnet den event_hash für ein Envelope.
/// payload_bytes muss der serialisierte Payload-Blob sein (Aufrufer verantwortlich).
pub fn computeEventHash(
    sequence: u64,
    prev_event_hash: Hash,
    payload_bytes: []const u8,
) Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var seq_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_buf, sequence, .little);
    hasher.update(&seq_buf);
    hasher.update(&prev_event_hash);
    hasher.update(payload_bytes);
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

/// GENESIS-Hash: prev_event_hash des ersten Events in einer Kette.
pub const GENESIS_PREV: Hash = ZERO_HASH;

// ── Ketten-Verifikation ───────────────────────────────────────────────────

pub const ChainError = error{
    BrokenChainLink,
    InvalidSequence,
    EmptyChain,
};

/// Verifiziert die kryptografische Sequenz einer Envelope-Kette.
/// Prüft prev_event_hash-Verknüpfung und Sequenz-Monotonie.
/// Prüft NICHT Signaturen (das ist Aufgabe des Rebuilders).
pub fn verifyChain(stream: []const LedgerEventEnvelope) ChainError!void {
    if (stream.len == 0) return ChainError.EmptyChain;

    var expected_prev = GENESIS_PREV;
    var expected_seq: u64 = stream[0].sequence; // erstes Seq als Basis

    for (stream) |env| {
        if (!ids.hashEql(env.prev_event_hash, expected_prev))
            return ChainError.BrokenChainLink;
        if (env.sequence != expected_seq)
            return ChainError.InvalidSequence;
        expected_prev = env.event_hash;
        expected_seq += 1;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn mkh(b: u8) Hash {
    var h: Hash = ZERO_HASH;
    h[0] = b;
    return h;
}

fn makeEnvelope(seq: u64, prev: Hash, payload: EventPayload) LedgerEventEnvelope {
    // event_hash vereinfacht für Tests: SHA256(seq || prev || tag_u16_le)
    var tag_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &tag_buf, @intFromEnum(std.meta.activeTag(payload)), .little);
    const h = computeEventHash(seq, prev, &tag_buf);
    return .{
        .sequence        = seq,
        .prev_event_hash = prev,
        .event_hash      = h,
        .actor_pubkey    = mkh(0xAC),
        .signature       = ZERO_SIG,
        .payload         = payload,
    };
}

test "ledger: computeEventHash ist deterministisch" {
    const h1 = computeEventHash(42, mkh(0x01), "payload");
    const h2 = computeEventHash(42, mkh(0x01), "payload");
    try std.testing.expect(ids.hashEql(h1, h2));
    // Andere Sequenz → anderer Hash
    const h3 = computeEventHash(43, mkh(0x01), "payload");
    try std.testing.expect(!ids.hashEql(h1, h3));
}

test "ledger: verifyChain gültige Kette" {
    const e0 = makeEnvelope(0, GENESIS_PREV, .{ .soul_anchored = mkh(0x10) });
    const e1 = makeEnvelope(1, e0.event_hash, .{ .soul_anchored = mkh(0x11) });
    const e2 = makeEnvelope(2, e1.event_hash, .{ .soul_anchored = mkh(0x12) });
    const chain = [_]LedgerEventEnvelope{ e0, e1, e2 };
    try verifyChain(&chain);
}

test "ledger: verifyChain erkennt BrokenChainLink" {
    const e0 = makeEnvelope(0, GENESIS_PREV, .{ .soul_anchored = mkh(0x10) });
    // e1 verweist auf falschen prev
    const e1 = makeEnvelope(1, mkh(0xFF), .{ .soul_anchored = mkh(0x11) });
    const chain = [_]LedgerEventEnvelope{ e0, e1 };
    try std.testing.expectError(ChainError.BrokenChainLink, verifyChain(&chain));
}

test "ledger: verifyChain erkennt InvalidSequence" {
    const e0 = makeEnvelope(0, GENESIS_PREV, .{ .soul_anchored = mkh(0x10) });
    // Sequence-Lücke: 0 → 2 statt 0 → 1
    const e1 = makeEnvelope(2, e0.event_hash, .{ .soul_anchored = mkh(0x11) });
    const chain = [_]LedgerEventEnvelope{ e0, e1 };
    try std.testing.expectError(ChainError.InvalidSequence, verifyChain(&chain));
}

test "ledger: EventPayload union tags korrekt" {
    const p = EventPayload{ .artifact_forged = .{
        .harness_id             = ZERO_HASH,
        .previous_artifact_cid  = ZERO_HASH,
        .new_artifact_cid       = mkh(0x42),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** ev.MAX_CONSUMED_INFLUENCES,
        .consumed_count         = 0,
        .forge_epoch            = 7,
    }};
    try std.testing.expectEqual(ev.EventType.artifact_forged, std.meta.activeTag(p));
    try std.testing.expect(ids.hashEql(mkh(0x42), p.artifact_forged.new_artifact_cid));
}
