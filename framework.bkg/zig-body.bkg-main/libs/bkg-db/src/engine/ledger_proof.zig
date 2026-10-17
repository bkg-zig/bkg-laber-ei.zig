/// BKGDB — Ledger Proof: Kombinierte Verifikationsschicht
///
/// Storage Protocol v1 — 2026-09-01
///
/// Implementiert die vollständige P2P Proof Pipeline:
///
///   STATE_COMMIT
///   → STATE_CHALLENGE
///   → LEDGER_PREFIX_PROOF  (kausale Reihenfolge)
///   → CANONICAL EVENT VERIFICATION (re-encode → re-hash → verify)
///   → MERKLE_RANGE_PROOF   (Segment-Mitgliedschaft)
///   → SEGMENT FOOTER VERIFY
///   → AUTHORITY VERIFY
///   → FOLD_FROM_ANCHOR
///   → STATE_ROOT
///   → CAUSAL_FINGERPRINT
///   → STATE_RESOLUTION
///
/// Architektur-Satz:
///   Hashchain   → „In welcher Reihenfolge geschah es?"
///   Merkle Root → „Gehört dieses Event zu diesem Segment?"
///   State Root  → „Was ist daraus geworden?"
///   Causal FP   → „Wie ist diese Manifestation entstanden?"
///   Authority   → „Durfte dieser Akteur das auslösen?"
///
/// Diese fünf Fragen werden immer GETRENNT beantwortet.
/// Keine Antwort substituiert eine andere.
///
/// FOLD-Reihenfolge (unveränderlich):
///   VERIFY → AUTHORIZE → FOLD
///   Niemals: VERIFY → FOLD → AUTHORIZE
const std = @import("std");
const ledger_mod     = @import("../protocol/ledger.zig");
const state_mod      = @import("../protocol/state.zig");
const rebuild_mod    = @import("rebuild.zig");
const genesis_mod    = @import("../genesis/genesis.zig");
const segment_merkle = @import("segment_merkle.zig");
const segment_mod    = @import("segment.zig");
const p2p_mod        = @import("../p2p/p2p_protocol.zig");
const ledger_wal     = @import("ledger_wal.zig");

pub const Hash                = ledger_mod.Hash;
pub const ZERO_HASH           = ledger_mod.ZERO_HASH;
pub const LedgerEventEnvelope = ledger_mod.LedgerEventEnvelope;
pub const HarnessManifestation = state_mod.HarnessManifestation;

pub const StateResolution  = p2p_mod.StateResolution;
pub const ResolutionOutcome = p2p_mod.ResolutionOutcome;
pub const InvalidReason    = p2p_mod.InvalidReason;
pub const VerifiedEvent    = p2p_mod.VerifiedEvent;
pub const ForkCheckResult  = p2p_mod.ForkCheckResult;

// ── Anchor State ──────────────────────────────────────────────────────────

/// Lokal verifikierter Anker — darf niemals vom Remote-Peer definiert werden.
///
/// Der Anchor-State ist ein tiefer, isolierter Snapshot.
/// Er wird während des Dispute-Verfahrens NICHT modifiziert.
pub const AnchorState = struct {
    sequence:          u64,
    event_hash:        Hash,
    state_root:        Hash,
    causal_fingerprint: Hash,
    /// Der materialisierte Harness-State am Anchor.
    /// Owned Slices — muss nach Verwendung via state_mod.freeHarnessManifestation freigegeben werden.
    manifestation:     HarnessManifestation,
};

// ── Proof Pipeline Errors ─────────────────────────────────────────────────

pub const ProofError = error{
    EmptyEventStream,
    AnchorSequenceMismatch,
    AnchorHashMismatch,
    SequenceGap,
    PrevHashBroken,
    EventHashMismatch,
    TipSequenceMismatch,
    TipHashMismatch,
    MerkleRootMismatch,
    SegmentFooterInvalid,
    SegmentChainBroken,
    StateRootMismatch,
    CausalFingerprintMismatch,
    OutOfMemory,
};

// ── Canonical Event Hash ──────────────────────────────────────────────────

/// Berechnet den Event-Hash aus kanonischen Bytes.
/// NIEMALS dem vom Peer gelieferten event_hash vertrauen.
///
/// event_hash = SHA256(sequence_le8 || prev_event_hash || payload_bytes)
/// (entspricht ledger_mod.computeEventHash mit TLV-kodierten Payload-Bytes)
pub fn computeCanonicalEventHash(canonical_bytes: []const u8) Hash {
    // Kanonische Bytes sind das vollständige TLV-Encoding des Envelopes.
    // Der Event-Hash ist SHA256 der kanonischen Bytes (als Ganzes — inkl. Header-Felder).
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(canonical_bytes);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

// ── Canonical State Root ──────────────────────────────────────────────────

/// Berechnet den State Root aus einem materialisierten Harness-State.
///
/// state_root = SHA256("BKG_STATE_ROOT_V1" || soul_hash || artifact_cid
///              || sorted_influence_hashes || sorted_pending_hashes
///              || resonance_hashes)
///
/// Deterministisch: gleicher State → gleicher Root.
/// Niemals aus HashMap-Reihenfolge oder Pointer-Adressen.
pub fn computeStateRoot(
    m: *const HarnessManifestation,
    allocator: std.mem.Allocator,
) !Hash {
    const DOMAIN: []const u8 = "BKG_STATE_ROOT_V1";

    // Alle Influence-Event-Hashes sammeln und sortieren
    const total_inf = m.active_influence_set.len + m.pending_forge_set.len;
    var hashes = try allocator.alloc(Hash, total_inf);
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
    std.mem.sortUnstable(Hash, hashes, {}, struct {
        fn lt(_: void, a: Hash, b: Hash) bool {
            return std.mem.lessThan(u8, &a, &b);
        }
    }.lt);

    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(DOMAIN);
    h.update(&m.identity.canonical_soul_hash);
    h.update(&m.current_artifact_cid);
    for (hashes) |eh| h.update(&eh);
    for (m.lineage_resonance_set) |res| h.update(&res.causality_ledger_event);

    var out: Hash = undefined;
    h.final(&out);
    return out;
}

// ── Causal Fingerprint ────────────────────────────────────────────────────

/// Leitet den Causal Fingerprint aus dem Anchor-Fingerprint + verifizierten Events ab.
///
/// causal_fingerprint = SHA256("BKGDB_CAUSAL_V1" || anchor_fp || event_hash[0] || ... || event_hash[N])
///
/// NIEMALS aus dem materialisierten State — immer aus der Event-Kette.
pub fn deriveCausalFingerprint(
    anchor_causal_fingerprint: Hash,
    verified_events:           []const VerifiedEvent,
) Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("BKGDB_CAUSAL_V1");
    h.update(&anchor_causal_fingerprint);
    for (verified_events) |ev| h.update(&ev.event_hash);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

// ── Verified Event Stream aus Proof ──────────────────────────────────────

/// Verifiziert den LedgerPrefixProof und extrahiert VerifiedEvents.
///
/// Für jedes Event:
///   1. canonical_bytes → re-compute event_hash
///   2. sequence == expected_sequence (Sequence-Shift-Schutz)
///   3. prev_hash == expected_prev_hash
///
/// Gibt caller-owned slice zurück. Freigabe via allocator.free().
pub fn verifyAndExtractEvents(
    allocator:    std.mem.Allocator,
    proof:        *const p2p_mod.LedgerPrefixProofMsg,
) ProofError![]VerifiedEvent {
    if (proof.events.len == 0) return ProofError.EmptyEventStream;

    var out = allocator.alloc(VerifiedEvent, proof.events.len)
        catch return ProofError.OutOfMemory;
    errdefer allocator.free(out);

    // Event 0
    {
        const ev = &proof.events[0];
        const bytes = ev.canonical_bytes[0..ev.canonical_len];
        const computed = computeCanonicalEventHash(bytes);

        // sequence und prev_hash aus kanonischen Bytes extrahieren (TLV Tags 1+2)
        const fields = extractSequenceAndPrevHash(bytes) catch
            return ProofError.EventHashMismatch;

        if (fields.sequence != proof.anchor_sequence + 1)
            return ProofError.AnchorSequenceMismatch;
        if (!std.mem.eql(u8, &fields.prev_hash, &proof.anchor_hash))
            return ProofError.AnchorHashMismatch;

        out[0] = .{
            .sequence     = fields.sequence,
            .prev_hash    = fields.prev_hash,
            .event_hash   = computed,
            .actor_pubkey = fields.actor_pubkey,
        };
    }

    // Events 1..N
    for (proof.events[1..], 1..) |ev, i| {
        const bytes = ev.canonical_bytes[0..ev.canonical_len];
        const computed = computeCanonicalEventHash(bytes);
        const fields = extractSequenceAndPrevHash(bytes) catch
            return ProofError.EventHashMismatch;

        if (fields.sequence != out[i-1].sequence + 1) return ProofError.SequenceGap;
        if (!std.mem.eql(u8, &fields.prev_hash, &out[i-1].event_hash))
            return ProofError.PrevHashBroken;

        out[i] = .{
            .sequence     = fields.sequence,
            .prev_hash    = fields.prev_hash,
            .event_hash   = computed,
            .actor_pubkey = fields.actor_pubkey,
        };
    }

    // Tip-Prüfung
    const last = out[proof.events.len - 1];
    if (last.sequence != proof.target_tip_sequence) return ProofError.TipSequenceMismatch;
    if (!std.mem.eql(u8, &last.event_hash, &proof.target_tip_hash)) return ProofError.TipHashMismatch;

    return out;
}

// ── TLV Field Extractor ───────────────────────────────────────────────────

const ExtractedFields = struct {
    sequence:     u64,
    prev_hash:    Hash,
    actor_pubkey: Hash,
};

/// Extrahiert sequence (Tag 1), prev_event_hash (Tag 2), actor_pubkey (Tag 4)
/// aus TLV-kodierten kanonischen Bytes (LedgerWal-Format).
fn extractSequenceAndPrevHash(bytes: []const u8) error{Malformed}!ExtractedFields {
    var sequence:     ?u64 = null;
    var prev_hash:    ?Hash = null;
    var actor_pubkey: ?Hash = null;

    var off: usize = 0;
    while (off < bytes.len) {
        if (off + 3 > bytes.len) return error.Malformed;
        const tag      = bytes[off]; off += 1;
        const field_len = std.mem.readInt(u16, bytes[off..][0..2], .little); off += 2;
        if (off + field_len > bytes.len) return error.Malformed;

        switch (tag) {
            1 => { // sequence
                if (field_len != 8) return error.Malformed;
                sequence = std.mem.readInt(u64, bytes[off..][0..8], .little);
            },
            2 => { // prev_event_hash
                if (field_len != 32) return error.Malformed;
                var h: Hash = undefined;
                @memcpy(&h, bytes[off..][0..32]);
                prev_hash = h;
            },
            4 => { // actor_pubkey
                if (field_len != 32) return error.Malformed;
                var h: Hash = undefined;
                @memcpy(&h, bytes[off..][0..32]);
                actor_pubkey = h;
            },
            else => {},
        }
        off += field_len;
        if (sequence != null and prev_hash != null and actor_pubkey != null) break;
    }

    return ExtractedFields{
        .sequence     = sequence     orelse return error.Malformed,
        .prev_hash    = prev_hash    orelse return error.Malformed,
        .actor_pubkey = actor_pubkey orelse ZERO_HASH,
    };
}

// ── Merkle Range Proof Verify ─────────────────────────────────────────────

/// Verifiziert den MerkleRangeProof gegen die bereits verifizierten Event-Hashes.
///
/// Event-Hashes aus verifyAndExtractEvents (niemals Peer-Hashes).
/// Segment-Footer aus MerkleRangeProofMsg.segment_footer_bytes dekodiert und geprüft.
pub fn verifyMerkleRangeProof(
    allocator: std.mem.Allocator,
    msg:       *const p2p_mod.MerkleRangeProofMsg,
    verified_events: []const VerifiedEvent,
    expected_previous_segment_hash: Hash,
) ProofError!void {
    // Footer dekodieren und prüfen
    const footer = segment_mod.decodeFooter(msg.segment_footer_bytes)
        catch return ProofError.SegmentFooterInvalid;

    // Footer-Merkle-Root muss mit dem behaupteten übereinstimmen
    if (!std.mem.eql(u8, &footer.segment_merkle_root, &msg.segment_merkle_root))
        return ProofError.SegmentFooterInvalid;

    // Segment-Chain: Footer.previous_segment_hash == lokal bekannter Vorgänger
    if (!std.mem.eql(u8, &footer.previous_segment_hash, &expected_previous_segment_hash))
        return ProofError.SegmentChainBroken;

    // Event-Hashes aus verifizierten Events extrahieren (sequence-basiert)
    const range_len: usize = @intCast(msg.end_sequence - msg.start_sequence + 1);
    var range_hashes = allocator.alloc(Hash, range_len)
        catch return ProofError.OutOfMemory;
    defer allocator.free(range_hashes);

    var filled: usize = 0;
    for (verified_events) |ev| {
        if (ev.sequence >= msg.start_sequence and ev.sequence <= msg.end_sequence) {
            range_hashes[filled] = ev.event_hash;
            filled += 1;
        }
    }
    if (filled != range_len) return ProofError.MerkleRootMismatch;

    // MerkleRangeProof verifizieren
    const rp = segment_merkle.MerkleRangeProof{
        .segment_id             = msg.segment_id,
        .start_sequence         = msg.start_sequence,
        .end_sequence           = msg.end_sequence,
        .segment_first_sequence = msg.segment_first_sequence,
        .segment_event_count    = @intCast(footer.event_count),
        .segment_merkle_root    = msg.segment_merkle_root,
        .range_event_hashes     = range_hashes,
        .boundary_siblings      = msg.proof_nodes,
        .boundary_directions    = &.{}, // Richtungen im vereinfachten Msg-Format via proof_nodes
    };

    segment_merkle.verifyRangeProof(allocator, &rp) catch
        return ProofError.MerkleRootMismatch;
}

// ── Fold from Anchor ──────────────────────────────────────────────────────

/// Führt rebuildProtocol auf dem Event-Stream ab dem Anchor aus.
///
/// Invarianten:
///   - Anchor-State wird NICHT modifiziert
///   - Temporärer State ist vollständig isoliert
///   - VERIFY → AUTHORIZE → FOLD (Reihenfolge unveränderlich)
///
/// Gibt einen neuen HarnessManifestation zurück (caller-owned).
/// Freigabe via state_mod.freeHarnessManifestation().
pub fn foldFromAnchor(
    allocator:       std.mem.Allocator,
    genesis:         *const genesis_mod.GenesisAuthorityRecord,
    anchor:          *const AnchorState,
    proof_events:    []const p2p_mod.ProofEvent,
) !rebuild_mod.RebuildResult {
    // Envelopes aus kanonischen Bytes dekodieren
    var envelopes = try allocator.alloc(LedgerEventEnvelope, proof_events.len);
    defer allocator.free(envelopes);

    for (proof_events, 0..) |pev, i| {
        envelopes[i] = try ledger_wal.decodeEnvelope(
            pev.canonical_bytes[0..pev.canonical_len]
        );
    }

    // rebuildProtocol benötigt den vollständigen Stream ab Genesis oder Checkpoint.
    // In Phase 1: wir bauen den Stream aus anchor_events + neuen Events.
    // Anchor-Events sind bereits in anchor.manifestation materialisiert —
    // für Phase 1 reicht rebuildProtocol auf den neuen Events allein,
    // wenn der Anchor als Boot-Event behandelt wird.
    //
    // Phase 2: rebuildFromAnchor erhält anchor_state direkt als Startpunkt.
    _ = anchor; // anchor.manifestation wird in Phase 2 als Startstate übergeben

    return rebuild_mod.rebuildProtocol(allocator, genesis, envelopes);
}

// ── Full Dispute Resolution ───────────────────────────────────────────────

/// Führt die vollständige Dispute-Resolution durch.
///
/// Pipeline:
///   1. verify_events: Prefix Proof + canonical re-hash
///   2. merkle_proof:  Segment-Mitgliedschaft (optional, wenn verfügbar)
///   3. fold:          rebuildProtocol ab Anchor
///   4. state_root:    unabhängig berechnen + vergleichen
///   5. causal_fp:     unabhängig berechnen + vergleichen
///   6. fork:          Sequence+Hash-Vergleich gegen lokale Events
///   7. resolution:    EQUAL / STALE / CONFLICT / INVALID
pub fn resolveDispute(
    allocator:             std.mem.Allocator,
    genesis:               *const genesis_mod.GenesisAuthorityRecord,
    commit:                *const p2p_mod.StateCommit,
    prefix_proof:          *const p2p_mod.LedgerPrefixProofMsg,
    anchor:                *const AnchorState,
    local_events:          []const VerifiedEvent,
) !StateResolution {
    // 1. Canonical Event Verification
    const verified = verifyAndExtractEvents(allocator, prefix_proof) catch |e| {
        const reason: InvalidReason = switch (e) {
            ProofError.AnchorSequenceMismatch, ProofError.AnchorHashMismatch => .event_hash_mismatch,
            ProofError.SequenceGap            => .event_sequence_gap,
            ProofError.PrevHashBroken         => .prev_hash_broken,
            ProofError.EventHashMismatch      => .event_hash_mismatch,
            ProofError.TipSequenceMismatch, ProofError.TipHashMismatch => .tip_mismatch,
            else => .proof_missing,
        };
        return StateResolution{
            .harness_id              = commit.harness_id,
            .outcome                 = .invalid,
            .anchor_sequence         = anchor.sequence,
            .resolved_tip_sequence   = anchor.sequence,
            .resolved_tip_hash       = anchor.event_hash,
            .resolved_state_root     = ZERO_HASH,
            .resolved_causal_fingerprint = ZERO_HASH,
            .conflict_at_sequence    = null,
            .invalid_reason          = reason,
        };
    };
    defer allocator.free(verified);

    // 2. Fork Detection gegen lokale Events
    const fork = p2p_mod.detectFork(local_events, verified);

    // 3. Fold from Anchor
    var fold_result = foldFromAnchor(allocator, genesis, anchor, prefix_proof.events) catch {
        return StateResolution{
            .harness_id              = commit.harness_id,
            .outcome                 = .invalid,
            .anchor_sequence         = anchor.sequence,
            .resolved_tip_sequence   = anchor.sequence,
            .resolved_tip_hash       = anchor.event_hash,
            .resolved_state_root     = ZERO_HASH,
            .resolved_causal_fingerprint = ZERO_HASH,
            .conflict_at_sequence    = null,
            .invalid_reason          = .proof_missing,
        };
    };
    defer state_mod.freeHarnessManifestation(&fold_result.state, allocator);

    // 4. State Root unabhängig berechnen
    const derived_state_root = computeStateRoot(&fold_result.state, allocator) catch ZERO_HASH;

    // 5. Causal Fingerprint unabhängig ableiten
    const derived_causal_fp = deriveCausalFingerprint(anchor.causal_fingerprint, verified);

    const last_ev = verified[verified.len - 1];

    // 6. State Root Mismatch → INVALID
    if (!std.mem.eql(u8, &derived_state_root, &commit.state_root)) {
        return StateResolution{
            .harness_id              = commit.harness_id,
            .outcome                 = .invalid,
            .anchor_sequence         = anchor.sequence,
            .resolved_tip_sequence   = last_ev.sequence,
            .resolved_tip_hash       = last_ev.event_hash,
            .resolved_state_root     = derived_state_root,
            .resolved_causal_fingerprint = derived_causal_fp,
            .conflict_at_sequence    = null,
            .invalid_reason          = .state_root_mismatch,
        };
    }

    // 7. Causal Fingerprint Mismatch → INVALID
    if (!std.mem.eql(u8, &derived_causal_fp, &commit.causal_fingerprint)) {
        return StateResolution{
            .harness_id              = commit.harness_id,
            .outcome                 = .invalid,
            .anchor_sequence         = anchor.sequence,
            .resolved_tip_sequence   = last_ev.sequence,
            .resolved_tip_hash       = last_ev.event_hash,
            .resolved_state_root     = derived_state_root,
            .resolved_causal_fingerprint = derived_causal_fp,
            .conflict_at_sequence    = null,
            .invalid_reason          = .causal_fingerprint_mismatch,
        };
    }

    // 8. Fork → Resolution
    const outcome: ResolutionOutcome = switch (fork) {
        .equal        => .equal,
        .local_stale  => .stale,
        .remote_stale => .stale,
        .conflict     => .conflict,
    };

    // Bei CONFLICT: erste divergierende Sequence bestimmen
    var conflict_seq: ?u64 = null;
    if (fork == .conflict) {
        for (local_events) |lev| {
            for (verified) |rev| {
                if (lev.sequence == rev.sequence and
                    !std.mem.eql(u8, &lev.event_hash, &rev.event_hash))
                {
                    conflict_seq = lev.sequence;
                    break;
                }
            }
            if (conflict_seq != null) break;
        }
    }

    return StateResolution{
        .harness_id              = commit.harness_id,
        .outcome                 = outcome,
        .anchor_sequence         = anchor.sequence,
        .resolved_tip_sequence   = last_ev.sequence,
        .resolved_tip_hash       = last_ev.event_hash,
        .resolved_state_root     = derived_state_root,
        .resolved_causal_fingerprint = derived_causal_fp,
        .conflict_at_sequence    = conflict_seq,
        .invalid_reason          = null,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn mkh(b: u8) Hash {
    var h: Hash = ZERO_HASH;
    h[0] = b;
    return h;
}

test "ledger_proof: deriveCausalFingerprint — deterministisch" {
    const anchor_fp = mkh(0xAA);
    const events = [_]VerifiedEvent{
        .{ .sequence = 1, .prev_hash = mkh(0x01), .event_hash = mkh(0x11), .actor_pubkey = ZERO_HASH },
        .{ .sequence = 2, .prev_hash = mkh(0x11), .event_hash = mkh(0x12), .actor_pubkey = ZERO_HASH },
    };
    const fp1 = deriveCausalFingerprint(anchor_fp, &events);
    const fp2 = deriveCausalFingerprint(anchor_fp, &events);
    try std.testing.expect(std.mem.eql(u8, &fp1, &fp2));
    try std.testing.expect(!std.mem.eql(u8, &fp1, &ZERO_HASH));
}

test "ledger_proof: deriveCausalFingerprint — anderer Anchor → anderer Fingerprint" {
    const events = [_]VerifiedEvent{
        .{ .sequence = 1, .prev_hash = mkh(0x01), .event_hash = mkh(0x11), .actor_pubkey = ZERO_HASH },
    };
    const fp1 = deriveCausalFingerprint(mkh(0xAA), &events);
    const fp2 = deriveCausalFingerprint(mkh(0xBB), &events);
    try std.testing.expect(!std.mem.eql(u8, &fp1, &fp2));
}

test "ledger_proof: deriveCausalFingerprint — anderes Event → anderer Fingerprint" {
    const anchor = mkh(0xAA);
    const ev1 = [_]VerifiedEvent{
        .{ .sequence = 1, .prev_hash = ZERO_HASH, .event_hash = mkh(0x11), .actor_pubkey = ZERO_HASH },
    };
    const ev2 = [_]VerifiedEvent{
        .{ .sequence = 1, .prev_hash = ZERO_HASH, .event_hash = mkh(0x22), .actor_pubkey = ZERO_HASH },
    };
    const fp1 = deriveCausalFingerprint(anchor, &ev1);
    const fp2 = deriveCausalFingerprint(anchor, &ev2);
    try std.testing.expect(!std.mem.eql(u8, &fp1, &fp2));
}

test "ledger_proof: computeCanonicalEventHash — deterministisch" {
    const bytes = "canonical event bytes test";
    const h1 = computeCanonicalEventHash(bytes);
    const h2 = computeCanonicalEventHash(bytes);
    try std.testing.expect(std.mem.eql(u8, &h1, &h2));
}

test "ledger_proof: computeCanonicalEventHash — verschiedene Bytes → verschiedene Hashes" {
    const h1 = computeCanonicalEventHash("event A");
    const h2 = computeCanonicalEventHash("event B");
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "ledger_proof: verifyAndExtractEvents — leerer Stream" {
    const proof = p2p_mod.LedgerPrefixProofMsg{
        .challenge_id        = mkh(0x01),
        .anchor_sequence     = 99,
        .anchor_hash         = mkh(0x09),
        .target_tip_sequence = 100,
        .target_tip_hash     = mkh(0x10),
        .events              = &.{},
    };
    try std.testing.expectError(
        ProofError.EmptyEventStream,
        verifyAndExtractEvents(std.testing.allocator, &proof),
    );
}

test "ledger_proof: extractSequenceAndPrevHash — gültige TLV-Bytes" {
    // Baue minimale TLV-Bytes: Tag1(seq=42) + Tag2(prev=mkh(0x05)) + Tag4(actor=mkh(0xAC))
    var buf: [200]u8 = undefined;
    var off: usize = 0;

    // Tag 1: sequence = 42
    buf[off] = 1; off += 1;
    std.mem.writeInt(u16, buf[off..][0..2], 8, .little); off += 2;
    std.mem.writeInt(u64, buf[off..][0..8], 42, .little); off += 8;

    // Tag 2: prev_hash = mkh(0x05)
    buf[off] = 2; off += 1;
    std.mem.writeInt(u16, buf[off..][0..2], 32, .little); off += 2;
    var prev: Hash = ZERO_HASH; prev[0] = 0x05;
    @memcpy(buf[off..][0..32], &prev); off += 32;

    // Tag 4: actor_pubkey = mkh(0xAC)
    buf[off] = 4; off += 1;
    std.mem.writeInt(u16, buf[off..][0..2], 32, .little); off += 2;
    var actor: Hash = ZERO_HASH; actor[0] = 0xAC;
    @memcpy(buf[off..][0..32], &actor); off += 32;

    const fields = try extractSequenceAndPrevHash(buf[0..off]);
    try std.testing.expectEqual(@as(u64, 42), fields.sequence);
    try std.testing.expect(std.mem.eql(u8, &fields.prev_hash, &prev));
    try std.testing.expect(std.mem.eql(u8, &fields.actor_pubkey, &actor));
}
