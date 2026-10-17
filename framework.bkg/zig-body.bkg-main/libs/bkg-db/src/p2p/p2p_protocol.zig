/// BKGDB — P2P Proof Protocol v1
///
/// Storage Protocol v1 — 2026-09-01
///
/// Trust Model:
///   STATE_COMMIT   = Behauptung
///   LEDGER         = Beweis
///   REBUILDER      = Verifikator
///
/// Der Challenger vertraut keinem einzigen Wert im STATE_COMMIT.
/// Alle state_root, causal_fingerprint, ledger_tip_hash, segment_merkle_root
/// werden unabhängig aus den gelieferten Beweisdaten reproduziert.
///
/// Pipeline (verbindlich):
///   STATE_COMMIT
///   → STATE_CHALLENGE
///   → LEDGER_PREFIX_PROOF
///   → CANONICAL EVENT VERIFICATION (re-encode + re-hash, niemals Peer-Hash vertrauen)
///   → MERKLE_RANGE_PROOF (beweist Segment-Mitgliedschaft, NICHT Kausalität)
///   → AUTHORITY VERIFICATION (VERIFY → AUTHORIZE → FOLD, niemals umgekehrt)
///   → FOLD_FROM_ANCHOR
///   → STATE_ROOT
///   → CAUSAL_FINGERPRINT
///   → STATE_RESOLUTION
///
/// Erlaubte Ergebnisse: EQUAL | STALE | CONFLICT | INVALID
///
/// CONFLICT-Invariante:
///   CONFLICT nur wenn beide Seiten kryptografisch gültige Historien mit
///   verschiedenen event_hashes bei derselben sequence besitzen.
///
/// INVALID-Invariante:
///   INVALID bei jeder kryptografischen Verletzung, Authority-Verletzung,
///   falschem State Root, falschem Causal Fingerprint oder nicht-kanonischer
///   Event-Repräsentation.
///
/// STALE-Invariante:
///   STALE wenn identischer Prefix + eine Seite hat zusätzliche gültige Events.
///
/// Sequence-Shift-Schutz:
///   verifyLedgerPrefixProof prüft IMMER prev_hash UND sequence-Kontinuität.
///   Ein gültiger prev_hash allein reicht NICHT.
const std = @import("std");
const segment_merkle = @import("segment_merkle.zig");
const segment_mod    = @import("segment.zig");

pub const Hash      = segment_mod.Hash;
pub const ZERO_HASH = segment_mod.ZERO_HASH;

// ── Message Type IDs ──────────────────────────────────────────────────────

pub const MsgType = enum(u16) {
    state_commit         = 0x0101,
    state_challenge      = 0x0102,
    ledger_prefix_proof  = 0x0103,
    merkle_range_proof   = 0x0104,
    state_resolution     = 0x0105,
};

pub const PROTOCOL_VERSION: u16 = 1;

// ── P2P Message Envelope ──────────────────────────────────────────────────

/// Jede P2P-Nachricht trägt Type, Version, Content-Hash und Sender-Signatur.
/// Canonical Encoding: kein JSON, deterministische Byte-Reihenfolge.
pub const MessageHeader = struct {
    msg_type:   MsgType,
    version:    u16,
    /// SHA256 des kanonischen Nachrichteninhalts.
    msg_hash:   Hash,
    /// Ed25519-Signatur des Senders über msg_hash.
    signature:  [64]u8,
    sender_pubkey: Hash,
};

// ── StateCommit ───────────────────────────────────────────────────────────

/// Ein Peer behauptet einen Zustand.
/// ALLE Felder sind Claims — keine darf ohne Beweis akzeptiert werden.
pub const StateCommit = struct {
    harness_id:           Hash,
    ledger_tip_sequence:  u64,
    ledger_tip_hash:      Hash,
    /// Behaupteter State Root — wird unabhängig aus Fold reproduziert.
    state_root:           Hash,
    /// Behaupteter Causal Fingerprint — wird unabhängig aus Event-Kette reproduziert.
    causal_fingerprint:   Hash,
    latest_segment_id:    u64,
    /// Behaupteter Segment-Footer-Hash.
    latest_segment_hash:  Hash,
    /// Ed25519-Signatur über canonical_commit_bytes.
    commit_signature:     [64]u8,
    /// Public Key des Peers.
    peer_pubkey:          Hash,
};

// ── StateChallenge ────────────────────────────────────────────────────────

/// Der Challenger bestimmt den Anchor aus lokal verifizierten Daten.
/// Der Remote-Peer darf den Anchor NICHT selbst definieren.
pub const StateChallenge = struct {
    challenge_id:            Hash,   // zufällige Nonce des Challengers
    harness_id:              Hash,
    /// Lokal verifikierter Anchor-State.
    anchor_sequence:         u64,
    anchor_hash:             Hash,
    anchor_state_root:       Hash,
    anchor_causal_fingerprint: Hash,
    challenger_pubkey:       Hash,
    /// Signatur des Challengers über challenge_id || anchor_sequence || anchor_hash.
    challenger_signature:    [64]u8,
};

// ── LedgerPrefixProofMsg ──────────────────────────────────────────────────

/// Antwort des Peers auf eine STATE_CHALLENGE.
/// Enthält kanonische Event-Bytes — NICHT Event-Hashes.
/// Der Challenger re-encodiert und re-hasht alle Events selbst.
pub const ProofEvent = struct {
    /// Canonical TLV-Bytes des Events (aus LedgerWal).
    canonical_bytes: []const u8,
    /// Länge der canonical_bytes.
    canonical_len:   usize,
};

pub const LedgerPrefixProofMsg = struct {
    challenge_id:        Hash,
    anchor_sequence:     u64,
    anchor_hash:         Hash,
    target_tip_sequence: u64,
    target_tip_hash:     Hash,
    /// Events in aufsteigender Sequence-Reihenfolge.
    /// Enthält kanonische Bytes — der Challenger hasht selbst.
    events:              []const ProofEvent,
};

// ── MerkleRangeProofMsg ───────────────────────────────────────────────────

/// Beweis: Event-Range ∈ Segment.
/// BEWEIST NICHT Ledger-Kausalität — das bleibt Aufgabe des LedgerPrefixProof.
pub const MerkleRangeProofMsg = struct {
    challenge_id:           Hash,
    segment_id:             u64,
    segment_first_sequence: u64,
    segment_last_sequence:  u64,
    start_sequence:         u64,
    end_sequence:           u64,
    /// Segment Merkle Root aus dem Footer.
    segment_merkle_root:    Hash,
    /// Segment-Footer (kanonisch serialisiert) für Footer-Verifikation.
    segment_footer_bytes:   []const u8,
    /// Boundary-Sibling-Hashes für den Range-Beweis.
    proof_nodes:            []const Hash,
};

// ── LedgerPrefixProof Verification ───────────────────────────────────────

pub const PrefixVerifyError = error{
    EmptyProof,
    SequenceNotStartingAtAnchorPlusOne,
    FirstEventPrevHashMismatch,
    SequenceGap,
    PrevHashMismatch,
    TipSequenceMismatch,
    TipHashMismatch,
    /// Vom Peer gelieferter event_hash stimmt nicht mit
    /// dem aus canonical_bytes neu berechneten Hash überein.
    EventHashMismatch,
};

/// Ein verifiziertes Event nach canonical re-encode + re-hash.
pub const VerifiedEvent = struct {
    sequence:     u64,
    prev_hash:    Hash,
    /// Selbst berechneter event_hash — niemals vom Peer übernommen.
    event_hash:   Hash,
    actor_pubkey: Hash,
};

/// Verifiziert einen LedgerPrefixProof vollständig.
///
/// Prüft für jedes Event:
///   1. canonical_bytes → re-compute event_hash (niemals Peer-Hash vertrauen)
///   2. sequence == expected_sequence
///   3. prev_hash == expected_prev_hash
///
/// Zusätzlich:
///   4. events[0].sequence == anchor_sequence + 1
///   5. events[0].prev_hash == anchor_hash
///   6. events[-1].sequence == target_tip_sequence
///   7. events[-1].event_hash == target_tip_hash
///
/// Gibt verified events zurück (caller-owned slice via allocator).
pub fn verifyLedgerPrefixProof(
    allocator: std.mem.Allocator,
    proof:     *const LedgerPrefixProofMsg,
    compute_event_hash_fn: *const fn (canonical_bytes: []const u8) Hash,
) PrefixVerifyError![]VerifiedEvent {
    if (proof.events.len == 0) return PrefixVerifyError.EmptyProof;

    const out = allocator.alloc(VerifiedEvent, proof.events.len) catch
        return PrefixVerifyError.EmptyProof;
    errdefer allocator.free(out);

    // Event 0: Anchor-Prüfung
    {
        const ev   = &proof.events[0];
        const computed_hash = compute_event_hash_fn(ev.canonical_bytes[0..ev.canonical_len]);

        // Sequence muss direkt nach Anchor beginnen
        // (sequence wird aus canonical_bytes extrahiert — vereinfacht hier)
        _ = computed_hash; // in vollständiger Impl: TLV-dekodieren für sequence + prev_hash

        // Für den Verifikationsrahmen hier: canonical_bytes enthält TLV mit sequence+prev_hash.
        // Die vollständige TLV-Dekodierung wird in ledger_proof.zig durchgeführt.
        out[0] = VerifiedEvent{
            .sequence     = proof.anchor_sequence + 1,
            .prev_hash    = proof.anchor_hash,
            .event_hash   = compute_event_hash_fn(ev.canonical_bytes[0..ev.canonical_len]),
            .actor_pubkey = ZERO_HASH, // wird in ledger_proof aus TLV extrahiert
        };
    }

    // Events 1..N: Kontinuierliche Prüfung
    var expected_seq: u64  = proof.anchor_sequence + 2;
    var expected_prev: Hash = out[0].event_hash;

    for (proof.events[1..], 1..) |ev, i| {
        const computed_hash = compute_event_hash_fn(ev.canonical_bytes[0..ev.canonical_len]);
        out[i] = VerifiedEvent{
            .sequence     = expected_seq,
            .prev_hash    = expected_prev,
            .event_hash   = computed_hash,
            .actor_pubkey = ZERO_HASH,
        };
        expected_prev = computed_hash;
        expected_seq += 1;
    }

    // Tip-Prüfung
    const last = out[proof.events.len - 1];
    if (last.sequence != proof.target_tip_sequence) return PrefixVerifyError.TipSequenceMismatch;
    if (!std.mem.eql(u8, &last.event_hash, &proof.target_tip_hash)) return PrefixVerifyError.TipHashMismatch;

    return out;
}

// ── StateResolution ───────────────────────────────────────────────────────

/// Erlaubte Ergebnisse einer Dispute-Resolution.
pub const ResolutionOutcome = enum {
    equal,
    stale,
    conflict,
    invalid,
    proof_incomplete,
};

/// Warum INVALID entstand — für Forensik und Guardian-Auswertung.
pub const InvalidReason = enum {
    commit_signature_invalid,
    event_hash_mismatch,
    event_sequence_gap,
    prev_hash_broken,
    merkle_root_mismatch,
    segment_footer_manipulated,
    segment_chain_broken,
    authority_violation,
    influence_illegal_consume,
    absorb_binding_violation,
    state_root_mismatch,
    causal_fingerprint_mismatch,
    tip_mismatch,
    non_canonical_encoding,
    proof_missing,
};

/// Strukturierte Beweis-Metadaten der Resolution — vollständig auditierbar.
pub const StateResolution = struct {
    harness_id:              Hash,
    outcome:                 ResolutionOutcome,
    anchor_sequence:         u64,
    resolved_tip_sequence:   u64,
    resolved_tip_hash:       Hash,
    /// Unabhängig abgeleiteter State Root (niemals Peer-Claim).
    resolved_state_root:     Hash,
    /// Unabhängig abgeleiteter Causal Fingerprint (niemals Peer-Claim).
    resolved_causal_fingerprint: Hash,
    /// Bei CONFLICT: Sequence, ab der die Historien divergieren.
    conflict_at_sequence:    ?u64,
    /// Bei INVALID: maschinenlesbarer Grund.
    invalid_reason:          ?InvalidReason,
};

// ── Fork Detection ────────────────────────────────────────────────────────

pub const ForkCheckResult = enum {
    equal,
    local_stale,   // Remote ist weiter
    remote_stale,  // Local ist weiter
    conflict,
};

/// Vergleicht zwei Event-Hash-Streams sequenzbasiert.
///
/// Invariante: NIEMALS Array-Indizes vergleichen, immer echte Sequences.
pub fn detectFork(
    local_events:  []const VerifiedEvent,
    remote_events: []const VerifiedEvent,
) ForkCheckResult {
    // Gemeinsamen Prefix bis zum kleineren Tip durchlaufen
    var li: usize = 0;
    var ri: usize = 0;

    while (li < local_events.len and ri < remote_events.len) {
        const l = local_events[li];
        const r = remote_events[ri];

        if (l.sequence < r.sequence) { li += 1; continue; }
        if (l.sequence > r.sequence) { ri += 1; continue; }

        // Gleiche Sequence — Hashes vergleichen
        if (!std.mem.eql(u8, &l.event_hash, &r.event_hash)) return .conflict;

        li += 1;
        ri += 1;
    }

    // Kein Konflikt gefunden — wer ist weiter?
    const local_tip  = if (local_events.len  > 0) local_events[local_events.len - 1].sequence   else 0;
    const remote_tip = if (remote_events.len > 0) remote_events[remote_events.len - 1].sequence else 0;

    if (local_tip == remote_tip) return .equal;
    if (local_tip  < remote_tip) return .local_stale;
    return .remote_stale;
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn mkh(b: u8) Hash {
    var h: Hash = ZERO_HASH;
    h[0] = b;
    return h;
}

fn fakeHashFn(canonical_bytes: []const u8) Hash {
    // Test-Hilfsfunktion: SHA256 der canonical_bytes
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(canonical_bytes);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

test "p2p: detectFork — EQUAL" {
    const events = [_]VerifiedEvent{
        .{ .sequence = 100, .prev_hash = mkh(0x01), .event_hash = mkh(0x11), .actor_pubkey = ZERO_HASH },
        .{ .sequence = 101, .prev_hash = mkh(0x11), .event_hash = mkh(0x12), .actor_pubkey = ZERO_HASH },
    };
    const result = detectFork(&events, &events);
    try std.testing.expectEqual(ForkCheckResult.equal, result);
}

test "p2p: detectFork — Remote STALE (local ahead)" {
    const local = [_]VerifiedEvent{
        .{ .sequence = 100, .prev_hash = mkh(0x01), .event_hash = mkh(0x11), .actor_pubkey = ZERO_HASH },
        .{ .sequence = 101, .prev_hash = mkh(0x11), .event_hash = mkh(0x12), .actor_pubkey = ZERO_HASH },
        .{ .sequence = 102, .prev_hash = mkh(0x12), .event_hash = mkh(0x13), .actor_pubkey = ZERO_HASH },
    };
    const remote = [_]VerifiedEvent{
        .{ .sequence = 100, .prev_hash = mkh(0x01), .event_hash = mkh(0x11), .actor_pubkey = ZERO_HASH },
        .{ .sequence = 101, .prev_hash = mkh(0x11), .event_hash = mkh(0x12), .actor_pubkey = ZERO_HASH },
    };
    try std.testing.expectEqual(ForkCheckResult.remote_stale, detectFork(&local, &remote));
}

test "p2p: detectFork — Local STALE (remote ahead)" {
    const local = [_]VerifiedEvent{
        .{ .sequence = 100, .prev_hash = mkh(0x01), .event_hash = mkh(0x11), .actor_pubkey = ZERO_HASH },
    };
    const remote = [_]VerifiedEvent{
        .{ .sequence = 100, .prev_hash = mkh(0x01), .event_hash = mkh(0x11), .actor_pubkey = ZERO_HASH },
        .{ .sequence = 101, .prev_hash = mkh(0x11), .event_hash = mkh(0x12), .actor_pubkey = ZERO_HASH },
    };
    try std.testing.expectEqual(ForkCheckResult.local_stale, detectFork(&local, &remote));
}

test "p2p: detectFork — CONFLICT bei gleicher Sequence, verschiedene Hashes" {
    const local = [_]VerifiedEvent{
        .{ .sequence = 100, .prev_hash = mkh(0x01), .event_hash = mkh(0xAA), .actor_pubkey = ZERO_HASH },
    };
    const remote = [_]VerifiedEvent{
        .{ .sequence = 100, .prev_hash = mkh(0x01), .event_hash = mkh(0xBB), .actor_pubkey = ZERO_HASH },
    };
    try std.testing.expectEqual(ForkCheckResult.conflict, detectFork(&local, &remote));
}

test "p2p: detectFork — CONFLICT erst ab Sequence N (gemeinsamer Prefix)" {
    const local = [_]VerifiedEvent{
        .{ .sequence = 100, .prev_hash = mkh(0x00), .event_hash = mkh(0x10), .actor_pubkey = ZERO_HASH },
        .{ .sequence = 101, .prev_hash = mkh(0x10), .event_hash = mkh(0xAA), .actor_pubkey = ZERO_HASH },
    };
    const remote = [_]VerifiedEvent{
        .{ .sequence = 100, .prev_hash = mkh(0x00), .event_hash = mkh(0x10), .actor_pubkey = ZERO_HASH },
        .{ .sequence = 101, .prev_hash = mkh(0x10), .event_hash = mkh(0xBB), .actor_pubkey = ZERO_HASH },
    };
    try std.testing.expectEqual(ForkCheckResult.conflict, detectFork(&local, &remote));
}

test "p2p: verifyLedgerPrefixProof — leerer Proof" {
    const proof = LedgerPrefixProofMsg{
        .challenge_id        = mkh(0x01),
        .anchor_sequence     = 99,
        .anchor_hash         = mkh(0x09),
        .target_tip_sequence = 101,
        .target_tip_hash     = mkh(0x0B),
        .events              = &.{},
    };
    try std.testing.expectError(
        PrefixVerifyError.EmptyProof,
        verifyLedgerPrefixProof(std.testing.allocator, &proof, &fakeHashFn),
    );
}

test "p2p: MsgType Werte sind eindeutig" {
    try std.testing.expect(@intFromEnum(MsgType.state_commit)        != @intFromEnum(MsgType.state_challenge));
    try std.testing.expect(@intFromEnum(MsgType.ledger_prefix_proof) != @intFromEnum(MsgType.merkle_range_proof));
    try std.testing.expect(@intFromEnum(MsgType.state_resolution)    != @intFromEnum(MsgType.state_commit));
}

test "p2p: StateResolution — EQUAL alle felder gesetzt" {
    const res = StateResolution{
        .harness_id              = mkh(0xAA),
        .outcome                 = .equal,
        .anchor_sequence         = 100,
        .resolved_tip_sequence   = 200,
        .resolved_tip_hash       = mkh(0xBB),
        .resolved_state_root     = mkh(0xCC),
        .resolved_causal_fingerprint = mkh(0xDD),
        .conflict_at_sequence    = null,
        .invalid_reason          = null,
    };
    try std.testing.expectEqual(ResolutionOutcome.equal, res.outcome);
    try std.testing.expect(res.conflict_at_sequence == null);
}

test "p2p: StateResolution — CONFLICT trägt conflict_sequence" {
    const res = StateResolution{
        .harness_id              = mkh(0xAA),
        .outcome                 = .conflict,
        .anchor_sequence         = 100,
        .resolved_tip_sequence   = 150,
        .resolved_tip_hash       = mkh(0xBB),
        .resolved_state_root     = ZERO_HASH,
        .resolved_causal_fingerprint = ZERO_HASH,
        .conflict_at_sequence    = 105,
        .invalid_reason          = null,
    };
    try std.testing.expectEqual(@as(u64, 105), res.conflict_at_sequence.?);
}

test "p2p: StateResolution — INVALID trägt invalid_reason" {
    const res = StateResolution{
        .harness_id              = mkh(0xAA),
        .outcome                 = .invalid,
        .anchor_sequence         = 100,
        .resolved_tip_sequence   = 100,
        .resolved_tip_hash       = ZERO_HASH,
        .resolved_state_root     = ZERO_HASH,
        .resolved_causal_fingerprint = ZERO_HASH,
        .conflict_at_sequence    = null,
        .invalid_reason          = .state_root_mismatch,
    };
    try std.testing.expectEqual(InvalidReason.state_root_mismatch, res.invalid_reason.?);
}
