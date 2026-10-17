/// BKGDB — Segment Layer
///
/// Storage Protocol v1 — 2026-09-01
///
/// Ein Segment ist eine physische, sequence-basierte Partition des Ledgers.
///
/// Segmentierung:
///   - Basiert auf Sequence-Bereichen (NICHT auf Generationen).
///   - Rotation bei: Hard-Size-Limit | Hard-Event-Count | Admin-Checkpoint.
///   - Generationen bleiben im Event — physische Segments sind Storage-Einheiten.
///
/// Segment-Chain:
///   Segment N.header.previous_segment_footer_hash == Hash(Segment N-1.footer)
///   Damit entsteht eine kryptografische Kette über Segment-Grenzen hinweg.
///
/// Compaction-Invariante:
///   Compaction darf physische Darstellung verändern, aber NIEMALS:
///     event_hash, sequence, prev_event_hash, content-id irgendeines Events.
///
/// Segment-Header-Format (kanonisch, little-endian):
///   magic:                    [4]u8  = "BSEG"
///   version:                  u16    = 1
///   segment_id:               u64
///   first_sequence:           u64
///   previous_segment_footer_hash: [32]u8
///
/// Segment-Footer-Format (kanonisch, little-endian):
///   magic:                    [4]u8  = "SEND"
///   segment_id:               u64
///   first_sequence:           u64
///   last_sequence:            u64
///   last_event_hash:          [32]u8
///   segment_content_hash:     [32]u8  = SHA256 aller event_hashes in Reihenfolge
///   segment_merkle_root:      [32]u8  = deterministischer Merkle Root (segment_merkle.zig)
///   state_root:               [32]u8
///   causal_fingerprint:       [32]u8
///   previous_segment_hash:    [32]u8  = Hash(vorheriger Footer)
///   event_count:              u64
///
/// Footer-Hash:
///   footer_hash = SHA256("BKG_FOOTER_V1" || canonical_footer_bytes)
///   Referenziert vom nächsten Segment-Header als previous_segment_footer_hash.
const std = @import("std");
const merkle_mod = @import("segment_merkle.zig");

pub const Hash = [32]u8;
pub const ZERO_HASH: Hash = [_]u8{0} ** 32;

// ── Segment-Konstanten ────────────────────────────────────────────────────

pub const SEGMENT_HEADER_MAGIC: [4]u8 = .{ 'B', 'S', 'E', 'G' };
pub const SEGMENT_FOOTER_MAGIC: [4]u8 = .{ 'S', 'E', 'N', 'D' };
pub const SEGMENT_VERSION:      u16   = 1;

/// Hard-Limit: maximale Events pro Segment (verhindert unbegrenzten Rebuild).
pub const SEGMENT_MAX_EVENTS: u64   = 1_000_000;
/// Hard-Limit: maximale Byte-Größe eines Segments (~256 MiB).
pub const SEGMENT_MAX_BYTES:  usize = 256 * 1024 * 1024;

// ── Rotation Policy ───────────────────────────────────────────────────────

/// Grund für eine Segment-Rotation.
pub const RotationReason = enum {
    event_count_limit,
    byte_size_limit,
    admin_checkpoint,
};

/// Gibt true zurück wenn ein neues Segment geöffnet werden soll.
pub fn shouldRotate(
    current_event_count: u64,
    current_byte_size:   usize,
    admin_requested:     bool,
) ?RotationReason {
    if (admin_requested)                          return .admin_checkpoint;
    if (current_event_count >= SEGMENT_MAX_EVENTS) return .event_count_limit;
    if (current_byte_size   >= SEGMENT_MAX_BYTES)  return .byte_size_limit;
    return null;
}

// ── SegmentHeader ─────────────────────────────────────────────────────────

/// In-Memory Repräsentation des Segment-Headers.
pub const SegmentHeader = struct {
    segment_id:                   u64,
    first_sequence:               u64,
    /// Hash des vorherigen Segment-Footers (ZERO für das erste Segment).
    previous_segment_footer_hash: Hash,
};

/// Serialisiert einen SegmentHeader kanonisch (little-endian).
pub fn encodeHeader(header: *const SegmentHeader, buf: []u8) usize {
    var off: usize = 0;
    @memcpy(buf[off..][0..4], &SEGMENT_HEADER_MAGIC); off += 4;
    std.mem.writeInt(u16, buf[off..][0..2], SEGMENT_VERSION, .little); off += 2;
    std.mem.writeInt(u64, buf[off..][0..8], header.segment_id, .little); off += 8;
    std.mem.writeInt(u64, buf[off..][0..8], header.first_sequence, .little); off += 8;
    @memcpy(buf[off..][0..32], &header.previous_segment_footer_hash); off += 32;
    return off;
}

pub const HEADER_ENCODED_SIZE: usize = 4 + 2 + 8 + 8 + 32; // = 54

// ── SegmentFooter ─────────────────────────────────────────────────────────

/// Vollständiger Segment-Footer — kryptografisches Abschluss-Siegel.
pub const SegmentFooter = struct {
    segment_id:               u64,
    first_sequence:           u64,
    last_sequence:            u64,
    last_event_hash:          Hash,
    /// SHA256 aller event_hashes des Segments in Sequence-Reihenfolge.
    segment_content_hash:     Hash,
    /// Deterministischer Merkle Root (aus segment_merkle.buildMerkleRoot).
    segment_merkle_root:      Hash,
    /// Materialized State Root am Ende des Segments.
    state_root:               Hash,
    /// Causal Fingerprint am Ende des Segments.
    causal_fingerprint:       Hash,
    /// Hash(Footer des vorherigen Segments) — bildet die Segment-Chain.
    previous_segment_hash:    Hash,
    event_count:              u64,
};

pub const FOOTER_ENCODED_SIZE: usize = 4 + 8 + 8 + 8 + 32 + 32 + 32 + 32 + 32 + 32 + 8;
// magic + segment_id + first_seq + last_seq + last_event_hash + content_hash
// + merkle_root + state_root + causal_fp + prev_seg_hash + event_count = 228

/// Serialisiert einen SegmentFooter kanonisch (little-endian).
pub fn encodeFooter(footer: *const SegmentFooter, buf: []u8) usize {
    var off: usize = 0;
    @memcpy(buf[off..][0..4], &SEGMENT_FOOTER_MAGIC); off += 4;
    std.mem.writeInt(u64, buf[off..][0..8], footer.segment_id, .little); off += 8;
    std.mem.writeInt(u64, buf[off..][0..8], footer.first_sequence, .little); off += 8;
    std.mem.writeInt(u64, buf[off..][0..8], footer.last_sequence, .little); off += 8;
    @memcpy(buf[off..][0..32], &footer.last_event_hash); off += 32;
    @memcpy(buf[off..][0..32], &footer.segment_content_hash); off += 32;
    @memcpy(buf[off..][0..32], &footer.segment_merkle_root); off += 32;
    @memcpy(buf[off..][0..32], &footer.state_root); off += 32;
    @memcpy(buf[off..][0..32], &footer.causal_fingerprint); off += 32;
    @memcpy(buf[off..][0..32], &footer.previous_segment_hash); off += 32;
    std.mem.writeInt(u64, buf[off..][0..8], footer.event_count, .little); off += 8;
    return off;
}

/// Berechnet den kanonischen Footer-Hash.
/// footer_hash = SHA256("BKG_FOOTER_V1" || encoded_footer_bytes)
/// Dieser Hash wird vom nächsten Segment-Header als previous_segment_footer_hash referenziert.
pub fn computeFooterHash(footer: *const SegmentFooter) Hash {
    var buf: [FOOTER_ENCODED_SIZE]u8 = undefined;
    const len = encodeFooter(footer, &buf);
    return merkle_mod.hashSegmentFooter(buf[0..len]);
}

/// Dekodiert einen SegmentFooter aus kanonischen Bytes.
pub const FooterDecodeError = error{ InvalidMagic, BufferTooSmall };

pub fn decodeFooter(buf: []const u8) FooterDecodeError!SegmentFooter {
    if (buf.len < FOOTER_ENCODED_SIZE) return FooterDecodeError.BufferTooSmall;
    if (!std.mem.eql(u8, buf[0..4], &SEGMENT_FOOTER_MAGIC)) return FooterDecodeError.InvalidMagic;
    var off: usize = 4;
    const segment_id = std.mem.readInt(u64, buf[off..][0..8], .little); off += 8;
    const first_seq  = std.mem.readInt(u64, buf[off..][0..8], .little); off += 8;
    const last_seq   = std.mem.readInt(u64, buf[off..][0..8], .little); off += 8;
    var last_ev:  Hash = undefined; @memcpy(&last_ev,  buf[off..][0..32]); off += 32;
    var cont_h:   Hash = undefined; @memcpy(&cont_h,   buf[off..][0..32]); off += 32;
    var merk_r:   Hash = undefined; @memcpy(&merk_r,   buf[off..][0..32]); off += 32;
    var state_r:  Hash = undefined; @memcpy(&state_r,  buf[off..][0..32]); off += 32;
    var causal_f: Hash = undefined; @memcpy(&causal_f, buf[off..][0..32]); off += 32;
    var prev_s:   Hash = undefined; @memcpy(&prev_s,   buf[off..][0..32]); off += 32;
    const ev_cnt = std.mem.readInt(u64, buf[off..][0..8], .little);
    return SegmentFooter{
        .segment_id            = segment_id,
        .first_sequence        = first_seq,
        .last_sequence         = last_seq,
        .last_event_hash       = last_ev,
        .segment_content_hash  = cont_h,
        .segment_merkle_root   = merk_r,
        .state_root            = state_r,
        .causal_fingerprint    = causal_f,
        .previous_segment_hash = prev_s,
        .event_count           = ev_cnt,
    };
}

// ── Segment Content Hash ──────────────────────────────────────────────────

/// Berechnet den segment_content_hash aus allen event_hashes in Sequence-Reihenfolge.
/// segment_content_hash = SHA256(event_hash[0] || event_hash[1] || ... || event_hash[N])
pub fn computeContentHash(event_hashes: []const Hash) Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (event_hashes) |eh| h.update(&eh);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

// ── Segment Chain Verification ────────────────────────────────────────────

pub const ChainError = error{
    SegmentChainBroken,
    FooterMagicInvalid,
};

/// Verifiziert die Segment-Chain: Footer[N].hash == Header[N+1].previous_segment_footer_hash
pub fn verifySegmentChain(
    previous_footer: *const SegmentFooter,
    next_header:     *const SegmentHeader,
) ChainError!void {
    const expected = computeFooterHash(previous_footer);
    if (!std.mem.eql(u8, &expected, &next_header.previous_segment_footer_hash))
        return ChainError.SegmentChainBroken;
}

// ── StateCheckpoint ───────────────────────────────────────────────────────

/// Kryptografischer Recovery-Anker.
///
/// Recovery-Invariante:
///   Beim Neustart: Checkpoint laden → WAL ab wal_frame_offset → Fold → fertig.
///   wal_frame_offset verhindert doppeltes Replay bereits enthaltener Events.
///
/// Ein Checkpoint ist KEIN Ledger-Ersatz.
///   Bei Beschädigung: Checkpoint verwerfen → älteren Checkpoint oder Genesis nutzen.
pub const StateCheckpoint = struct {
    /// ID des WAL-Segments, ab dem Recovery beginnt.
    wal_segment_id:   u64,
    /// Byte-Offset in der WAL-Datei (explizit — kein impliziter Cursor).
    wal_frame_offset: u64,
    /// Ledger-Sequence des Checkpoint-Moments.
    ledger_sequence:  u64,
    /// Ledger-Tip-Hash des Checkpoint-Moments.
    ledger_tip_hash:  Hash,
    /// State Root am Checkpoint.
    state_root:       Hash,
    /// Causal Fingerprint am Checkpoint.
    causal_fingerprint: Hash,
    /// Merkle Root des aktiven Segments am Checkpoint (für Footer-Verifikation).
    segment_merkle_root_at_checkpoint: Hash,
    /// Segment-ID des aktiven Segments am Checkpoint.
    segment_id_at_checkpoint: u64,
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "segment: encodeFooter / decodeFooter round-trip" {
    const footer = SegmentFooter{
        .segment_id            = 42,
        .first_sequence        = 1000,
        .last_sequence         = 1999,
        .last_event_hash       = [_]u8{0xAB} ** 32,
        .segment_content_hash  = [_]u8{0xCD} ** 32,
        .segment_merkle_root   = [_]u8{0xEF} ** 32,
        .state_root            = [_]u8{0x12} ** 32,
        .causal_fingerprint    = [_]u8{0x34} ** 32,
        .previous_segment_hash = [_]u8{0x56} ** 32,
        .event_count           = 1000,
    };
    var buf: [FOOTER_ENCODED_SIZE]u8 = undefined;
    const n = encodeFooter(&footer, &buf);
    try std.testing.expectEqual(FOOTER_ENCODED_SIZE, n);

    const decoded = try decodeFooter(&buf);
    try std.testing.expectEqual(footer.segment_id, decoded.segment_id);
    try std.testing.expectEqual(footer.first_sequence, decoded.first_sequence);
    try std.testing.expectEqual(footer.last_sequence, decoded.last_sequence);
    try std.testing.expectEqual(footer.event_count, decoded.event_count);
    try std.testing.expect(std.mem.eql(u8, &footer.segment_merkle_root, &decoded.segment_merkle_root));
    try std.testing.expect(std.mem.eql(u8, &footer.state_root, &decoded.state_root));
}

test "segment: computeFooterHash deterministisch" {
    const footer = SegmentFooter{
        .segment_id = 1, .first_sequence = 0, .last_sequence = 99,
        .last_event_hash = [_]u8{1} ** 32, .segment_content_hash = [_]u8{2} ** 32,
        .segment_merkle_root = [_]u8{3} ** 32, .state_root = [_]u8{4} ** 32,
        .causal_fingerprint = [_]u8{5} ** 32, .previous_segment_hash = ZERO_HASH,
        .event_count = 100,
    };
    const h1 = computeFooterHash(&footer);
    const h2 = computeFooterHash(&footer);
    try std.testing.expect(std.mem.eql(u8, &h1, &h2));
    try std.testing.expect(!std.mem.eql(u8, &h1, &ZERO_HASH));
}

test "segment: verifySegmentChain — gültige Chain" {
    const footer = SegmentFooter{
        .segment_id = 1, .first_sequence = 0, .last_sequence = 99,
        .last_event_hash = [_]u8{1} ** 32, .segment_content_hash = [_]u8{2} ** 32,
        .segment_merkle_root = [_]u8{3} ** 32, .state_root = [_]u8{4} ** 32,
        .causal_fingerprint = [_]u8{5} ** 32, .previous_segment_hash = ZERO_HASH,
        .event_count = 100,
    };
    const footer_hash = computeFooterHash(&footer);
    const next_header = SegmentHeader{
        .segment_id = 2,
        .first_sequence = 100,
        .previous_segment_footer_hash = footer_hash,
    };
    try verifySegmentChain(&footer, &next_header);
}

test "segment: verifySegmentChain — gebrochene Chain" {
    const footer = SegmentFooter{
        .segment_id = 1, .first_sequence = 0, .last_sequence = 99,
        .last_event_hash = [_]u8{1} ** 32, .segment_content_hash = [_]u8{2} ** 32,
        .segment_merkle_root = [_]u8{3} ** 32, .state_root = [_]u8{4} ** 32,
        .causal_fingerprint = [_]u8{5} ** 32, .previous_segment_hash = ZERO_HASH,
        .event_count = 100,
    };
    const next_header = SegmentHeader{
        .segment_id = 2,
        .first_sequence = 100,
        .previous_segment_footer_hash = [_]u8{0xFF} ** 32, // manipuliert
    };
    try std.testing.expectError(ChainError.SegmentChainBroken, verifySegmentChain(&footer, &next_header));
}

test "segment: computeContentHash ändert sich bei verschiedenen Events" {
    const h1 = computeContentHash(&.{ [_]u8{1} ** 32, [_]u8{2} ** 32 });
    const h2 = computeContentHash(&.{ [_]u8{1} ** 32, [_]u8{3} ** 32 });
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "segment: shouldRotate — Rotation-Gründe" {
    try std.testing.expect(shouldRotate(0, 0, true) == .admin_checkpoint);
    try std.testing.expect(shouldRotate(SEGMENT_MAX_EVENTS, 0, false) == .event_count_limit);
    try std.testing.expect(shouldRotate(0, SEGMENT_MAX_BYTES, false) == .byte_size_limit);
    try std.testing.expect(shouldRotate(0, 0, false) == null);
}

test "segment: decodeFooter — ungültige Magic" {
    var buf: [FOOTER_ENCODED_SIZE]u8 = [_]u8{0} ** FOOTER_ENCODED_SIZE;
    try std.testing.expectError(FooterDecodeError.InvalidMagic, decodeFooter(&buf));
}
