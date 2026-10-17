/// BKGDB Protocol — Content-Addressed IDs
///
/// In BKGDB gibt es keine UUIDs und keine Auto-Increments.
/// Alle Objekte sind durch den SHA256-Hash ihres Inhalts identifiziert (CID).
/// Ledger-Events sind durch den SHA256-Hash ihres serialisierten Envelopes identifiziert.
///
/// Prefix-Typisierung verhindert zur Laufzeit, dass ein Graph-Edge
/// versehentlich auf den falschen Entitätstyp zeigt.
const std = @import("std");

pub const Hash = [32]u8;

pub const ZERO_HASH: Hash = [_]u8{0} ** 32;

pub fn hashEql(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, &a, &b);
}

pub fn isZero(h: Hash) bool {
    return hashEql(h, ZERO_HASH);
}

// ── IdType ────────────────────────────────────────────────────────────────

/// Typ-Prefix für CIDs. Macht Graph-Kanten selbst-dokumentierend und prüfbar.
pub const IdType = enum(u8) {
    soul              = 0x01,
    artifact          = 0x02,
    work_context      = 0x03,
    policy            = 0x04,
    ledger_event      = 0x05,
    spore             = 0x06,
    lost              = 0x07,
    harness           = 0x08,
    resonance         = 0x09,
    decay_condition   = 0x0A,
    forge_candidate   = 0x0B,
    capsule           = 0x0C,
    evidence          = 0x0D,
    evolution_event   = 0x0E,
};

// ── CID ───────────────────────────────────────────────────────────────────

/// Content Identifier: Typ + SHA256-Hash des Inhalts.
/// Zwei CIDs sind gleich gdw. type_prefix UND hash identisch.
pub const CID = struct {
    type_prefix: IdType,
    hash: Hash,

    pub fn eql(self: CID, other: CID) bool {
        return self.type_prefix == other.type_prefix and hashEql(self.hash, other.hash);
    }

    pub fn isZeroCid(self: CID) bool {
        return isZero(self.hash);
    }

    /// Prüft ob dieser CID den erwarteten Typ hat.
    pub fn expectType(self: CID, expected: IdType) error{TypeMismatch}!void {
        if (self.type_prefix != expected) return error.TypeMismatch;
    }
};

/// Erstellt einen CID aus Typ und Hash (kein Kopieren, kein Alloc).
pub fn cid(t: IdType, h: Hash) CID {
    return .{ .type_prefix = t, .hash = h };
}

/// Zero-CID (optionaler Wert / "kein Parent").
pub fn zeroCid(t: IdType) CID {
    return .{ .type_prefix = t, .hash = ZERO_HASH };
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "ids: CID equality" {
    var h: Hash = ZERO_HASH;
    h[0] = 0x42;
    const a = cid(.artifact, h);
    const b = cid(.artifact, h);
    const c = cid(.soul, h);
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "ids: CID type check" {
    const c = cid(.soul, ZERO_HASH);
    try c.expectType(.soul);
    try std.testing.expectError(error.TypeMismatch, c.expectType(.artifact));
}

test "ids: zeroCid" {
    const z = zeroCid(.spore);
    try std.testing.expect(z.isZeroCid());
    try std.testing.expectEqual(IdType.spore, z.type_prefix);
}

test "ids: neue IdType Integer-Repräsentationen 0x0B–0x0E" {
    try std.testing.expectEqual(@as(u8, 0x0B), @intFromEnum(IdType.forge_candidate));
    try std.testing.expectEqual(@as(u8, 0x0C), @intFromEnum(IdType.capsule));
    try std.testing.expectEqual(@as(u8, 0x0D), @intFromEnum(IdType.evidence));
    try std.testing.expectEqual(@as(u8, 0x0E), @intFromEnum(IdType.evolution_event));
}

test "ids: expectType neue Typen" {
    const fc = cid(.forge_candidate, ZERO_HASH);
    try fc.expectType(.forge_candidate);
    try std.testing.expectError(error.TypeMismatch, fc.expectType(.artifact));

    const cap = cid(.capsule, ZERO_HASH);
    try cap.expectType(.capsule);
    try std.testing.expectError(error.TypeMismatch, cap.expectType(.soul));

    const ev = cid(.evidence, ZERO_HASH);
    try ev.expectType(.evidence);
    try std.testing.expectError(error.TypeMismatch, ev.expectType(.ledger_event));

    const ee = cid(.evolution_event, ZERO_HASH);
    try ee.expectType(.evolution_event);
    try std.testing.expectError(error.TypeMismatch, ee.expectType(.spore));
}

test "ids: alle 14 IdType-Werte 0x01–0x0E eindeutig" {
    // Prüft, dass kein Wert doppelt vergeben wurde
    const all = [_]u8{
        @intFromEnum(IdType.soul),
        @intFromEnum(IdType.artifact),
        @intFromEnum(IdType.work_context),
        @intFromEnum(IdType.policy),
        @intFromEnum(IdType.ledger_event),
        @intFromEnum(IdType.spore),
        @intFromEnum(IdType.lost),
        @intFromEnum(IdType.harness),
        @intFromEnum(IdType.resonance),
        @intFromEnum(IdType.decay_condition),
        @intFromEnum(IdType.forge_candidate),
        @intFromEnum(IdType.capsule),
        @intFromEnum(IdType.evidence),
        @intFromEnum(IdType.evolution_event),
    };
    for (all, 0..) |a, i| {
        for (all, 0..) |b, j| {
            if (i != j) {
                try std.testing.expect(a != b);
            }
        }
    }
}

test "ids: forge_candidate CID != artifact CID bei gleichem Hash" {
    const h = ZERO_HASH;
    const fc = cid(.forge_candidate, h);
    const ar = cid(.artifact, h);
    try std.testing.expect(!fc.eql(ar));
}
