//! canonical_tlv.zig — Deterministic Canonical TLV Codec (BKGDB Storage Core v1.2)
//!
//! Purpose:
//!   The event bytes that are hashed, Ed25519-verified and persisted to the WAL
//!   MUST be exactly the canonical bytes produced by `encodeEvent`. There is no
//!   divergence between what is validated and what is stored.
//!
//! Design invariants:
//!   * Canonicality — identical logical events always encode to identical bytes.
//!     This is guaranteed by a fixed, per-type field order and a fixed TLV layout
//!     (tag:u8, len:u16, value). No map/set iteration ordering, no timestamps, no
//!     allocator addresses, no undefined bytes may leak into the encoding.
//!   * Round-trip — decode(encode(e)) == e. Proved by a property test below.
//!   * Signatures are NOT part of the hashed payload. The Ed25519 signature is
//!     produced over the canonical bytes and stored separately in the WAL frame.
//!
//! Zig compatibility: 0.16.0. Uses fixed buffers and BoundedArray (stable API);
//! deliberately avoids std.ArrayList's post-0.13 API churn.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

// ---------------------------------------------------------------------------
// Event type identifiers (TLV tag 0x02 => event_type_id)
// ---------------------------------------------------------------------------
pub const EVENT_INFLUENCE_AUTHORIZED: u8 = 0x20;
pub const EVENT_CROSS_LINEAGE_COMPOSED: u8 = 0x21;
pub const EVENT_ARTIFACT_FORGED: u8 = 0x22;
pub const EVENT_ARTIFACT_ABSORBED: u8 = 0x23;
pub const EVENT_GUARDIAN_VERDICT: u8 = 0x24;
pub const EVENT_AUTHORITY_DELEGATED: u8 = 0x25;
pub const EVENT_AUTHORITY_REVOKED: u8 = 0x26;

// ---------------------------------------------------------------------------
// Payload tags (nested TLV level, value carries the type-specific structure)
// ---------------------------------------------------------------------------
const T_VERSION: u8 = 0x01;
const T_EVENT_TYPE: u8 = 0x02;
const T_SEQUENCE: u8 = 0x03;
const T_PREV_HASH: u8 = 0x04;
const T_ACTOR: u8 = 0x05;

// Per-event field tags (each event type has a fixed sub-field ordering)
const F_TARGET_ARTIFACT: u8 = 0x10; // 32-byte CID
const F_TARGET_GENERATION: u8 = 0x11; // u64
const F_BENEFICIARY: u8 = 0x12; // 32-byte id
const F_BLESSING_CURSE: u8 = 0x13; // u8 capacity type (0=blessing,1=curse)
const F_EXTERNAL_PARENTS: u8 = 0x14; // list of 32-byte parent ids
const F_ARTIFACT_FORGED_CID: u8 = 0x15; // 32-byte new artifact cid
const F_REQUIRED_CAPABILITY: u8 = 0x16; // u8 capability id
const F_BLESSING_SOURCE: u8 = 0x17; // 32-byte blessed-lineage id
const F_GUARDIANS: u8 = 0x18; // list of 32-byte guardian pubkeys (sorted)
const F_VERDICT_OK: u8 = 0x19; // u8 bool
const F_VERDICT_REF: u8 = 0x1A; // 32-byte referenced event hash
const F_DELEGATE_PUBKEY: u8 = 0x1B; // 32-byte delegate
const F_ROLE_TYPE: u8 = 0x1C; // u8 role
const F_VALID_UNTIL_GEN: u8 = 0x1D; // u64
const F_SCOPE_CID: u8 = 0x1E; // 32-byte scope cid
const F_REVOKED_REF: u8 = 0x1F; // 32-byte delegated-event hash
const F_RESONANCE_LINEAGE: u8 = 0x20; // 32-byte lineage id

// ---------------------------------------------------------------------------
// Causal fingerprint label: a per-storage running hash. Kept here so both the
// commit path and recovery path can reference the same constant.
// ---------------------------------------------------------------------------
pub const CAUSAL_LABEL: []const u8 = "BKG_CAUSAL_V1";
pub const STATE_ROOT_LABEL: []const u8 = "BKG_STATE_ROOT_V1";
pub const EVENT_LABEL: []const u8 = "BKG_EVENT_V1";
pub const GENESIS_PARENT_HASH = [_]u8{0x42} ** 32;

pub const Hash32 = [32]u8;
pub const Sig64 = [64]u8;

// ---------------------------------------------------------------------------
// Event domain model. A tagged union with a fixed field set per type.
// ---------------------------------------------------------------------------
pub const InfluenceKind = enum(u8) { blessing = 0, curse = 1 };

pub const Capability = enum(u8) {
    artifact_inspect = 0,
    lineal_inspect = 1,
    role_invoke = 2,
    self_derive = 3,
};

pub const RoleType = enum(u8) {
    lineage_guardian = 0,
    delegator = 1,
    signer = 2,
};

pub const Payload = union(enum) {
    influence_authorized: struct {
        target_artifact: Hash32,
        target_generation: u64,
        beneficiary: Hash32,
        kind: InfluenceKind,
    },
    cross_lineage_composed: struct {
        // Declares provenance + external parents. Does NOT consume curses.
        external_parents: []const Hash32,
    },
    artifact_forged: struct {
        artifact_cid: Hash32,
        required_capability: Capability,
        // consumes exactly one curse (validated during AUTHORIZE of the parent)
        blessing_source: Hash32,
    },
    artifact_absorbed: struct {
        artifact_cid: Hash32,
        // consumes one blessing
        blessing_source: Hash32,
    },
    guardian_verdict: struct {
        guardians: []const Hash32, // sorted, canonical
        verdict_ok: bool,
        verdict_ref: Hash32, // event hash this verdict evaluates
    },
    authority_delegated: struct {
        delegate_pubkey: Hash32,
        role_type: RoleType,
        valid_until_generation: u64,
        scope_cid: Hash32,
    },
    authority_revoked: struct {
        revoked_ref: Hash32, // the delegated event being revoked
    },
};

pub const Event = struct {
    version: u8 = 1,
    event_type_id: u8,
    sequence: u64,
    prev_hash: Hash32,
    actor_pubkey: Hash32,
    payload: Payload,

    pub fn eventType(p: Payload) u8 {
        return switch (p) {
            .influence_authorized => EVENT_INFLUENCE_AUTHORIZED,
            .cross_lineage_composed => EVENT_CROSS_LINEAGE_COMPOSED,
            .artifact_forged => EVENT_ARTIFACT_FORGED,
            .artifact_absorbed => EVENT_ARTIFACT_ABSORBED,
            .guardian_verdict => EVENT_GUARDIAN_VERDICT,
            .authority_delegated => EVENT_AUTHORITY_DELEGATED,
            .authority_revoked => EVENT_AUTHORITY_REVOKED,
        };
    }
};

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------
const MAX_PAYLOAD: usize = 2 * 1024 * 1024; // hard cap for a single event payload

pub const EncodeError = error{ PayloadTooLarge } || std.mem.Allocator.Error;

fn putTlv(buf: *[MAX_PAYLOAD]u8, pos: *usize, tag: u8, value: []const u8) EncodeError!void {
    if (value.len > 0xFFFF) return error.PayloadTooLarge;
    if (pos.* + 3 + value.len > MAX_PAYLOAD) return error.PayloadTooLarge;
    buf[pos.*] = tag;
    buf[pos.* + 1] = @intCast(value.len >> 8);
    buf[pos.* + 2] = @intCast(value.len & 0xFF);
    @memcpy(buf[pos.* + 3 .. pos.* + 3 + value.len], value);
    pos.* += 3 + value.len;
}

fn putHash32(buf: *[MAX_PAYLOAD]u8, pos: *usize, tag: u8, h: *const Hash32) EncodeError!void {
    try putTlv(buf, pos, tag, h);
}

fn putU64(buf: *[MAX_PAYLOAD]u8, pos: *usize, tag: u8, v: u64) EncodeError!void {
    var le: [8]u8 = undefined;
    std.mem.writeInt(u64, &le, v, .little);
    try putTlv(buf, pos, tag, &le);
}

fn putU8(buf: *[MAX_PAYLOAD]u8, pos: *usize, tag: u8, v: u8) EncodeError!void {
    const b = [1]u8{v};
    try putTlv(buf, pos, tag, &b);
}

fn putHashList(buf: *[MAX_PAYLOAD]u8, pos: *usize, tag: u8, list: []const Hash32) EncodeError!void {
    var inner: [MAX_PAYLOAD]u8 = undefined;
    var ipos: usize = 0;
    for (list) |item| {
        @memcpy(inner[ipos .. ipos + 32], &item);
        ipos += 32;
    }
    try putTlv(buf, pos, tag, inner[0..ipos]);
}

/// Produce the canonical event bytes. This exact byte string is what gets hashed,
/// verified and written to the WAL.
pub fn encodeEvent(allocator: std.mem.Allocator, e: *const Event) EncodeError![]u8 {
    var buf: [MAX_PAYLOAD]u8 = undefined;
    var pos: usize = 0;

    try putU8(&buf, &pos, T_VERSION, e.version);
    try putU8(&buf, &pos, T_EVENT_TYPE, e.event_type_id);
    try putU64(&buf, &pos, T_SEQUENCE, e.sequence);
    try putHash32(&buf, &pos, T_PREV_HASH, &e.prev_hash);
    try putHash32(&buf, &pos, T_ACTOR, &e.actor_pubkey);

    switch (e.payload) {
        .influence_authorized => |p| {
            try putHash32(&buf, &pos, F_TARGET_ARTIFACT, &p.target_artifact);
            try putU64(&buf, &pos, F_TARGET_GENERATION, p.target_generation);
            try putHash32(&buf, &pos, F_BENEFICIARY, &p.beneficiary);
            try putU8(&buf, &pos, F_BLESSING_CURSE, @intFromEnum(p.kind));
        },
        .cross_lineage_composed => |p| {
            try putHashList(&buf, &pos, F_EXTERNAL_PARENTS, p.external_parents);
        },
        .artifact_forged => |p| {
            try putHash32(&buf, &pos, F_ARTIFACT_FORGED_CID, &p.artifact_cid);
            try putU8(&buf, &pos, F_REQUIRED_CAPABILITY, @intFromEnum(p.required_capability));
            try putHash32(&buf, &pos, F_BLESSING_SOURCE, &p.blessing_source);
        },
        .artifact_absorbed => |p| {
            try putHash32(&buf, &pos, F_ARTIFACT_FORGED_CID, &p.artifact_cid);
            try putHash32(&buf, &pos, F_BLESSING_SOURCE, &p.blessing_source);
        },
        .guardian_verdict => |p| {
            try putHashList(&buf, &pos, F_GUARDIANS, p.guardians);
            try putU8(&buf, &pos, F_VERDICT_OK, @intFromBool(p.verdict_ok));
            try putHash32(&buf, &pos, F_VERDICT_REF, &p.verdict_ref);
        },
        .authority_delegated => |p| {
            try putHash32(&buf, &pos, F_DELEGATE_PUBKEY, &p.delegate_pubkey);
            try putU8(&buf, &pos, F_ROLE_TYPE, @intFromEnum(p.role_type));
            try putU64(&buf, &pos, F_VALID_UNTIL_GEN, p.valid_until_generation);
            try putHash32(&buf, &pos, F_SCOPE_CID, &p.scope_cid);
        },
        .authority_revoked => |p| {
            try putHash32(&buf, &pos, F_REVOKED_REF, &p.revoked_ref);
        },
    }

    const out = try allocator.alloc(u8, pos);
    @memcpy(out, buf[0..pos]);
    return out;
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------
pub const ParseError = error{
    Truncated,
    UnknownTag,
    UnexpectedTag,
    BadTypeId,
    ValueTooLong,
    BadExternalParentsAlignment,
    BadGuardianListAlignment,
    Malformed,
} || std.mem.Allocator.Error;

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *Reader) ParseError!struct { tag: u8, value: []const u8 } {
        if (self.pos + 3 > self.data.len) return error.Truncated;
        const tag = self.data[self.pos];
        const len: usize = (@as(usize, self.data[self.pos + 1]) << 8) | self.data[self.pos + 2];
        self.pos += 3;
        if (self.pos + len > self.data.len) return error.Truncated;
        const value = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return .{ .tag = tag, .value = value };
    }
};

fn needLen(value: []const u8, n: usize) ParseError![]const u8 {
    if (value.len != n) return error.UnexpectedTag;
    return value;
}

fn readU64(value: []const u8) ParseError!u64 {
    if (value.len != 8) return error.UnexpectedTag;
    return std.mem.readInt(u64, value[0..8], .little);
}

fn readU8(value: []const u8) ParseError!u8 {
    return (try needLen(value, 1))[0];
}

fn readHash32(value: []const u8) ParseError!Hash32 {
    var out: Hash32 = undefined;
    @memcpy(&out, try needLen(value, 32));
    return out;
}

const PubkeyList64 = std.BoundedArray(Hash32, 64);

fn readHashList(allocator: std.mem.Allocator, value: []const u8) ParseError![]const Hash32 {
    if (value.len % 32 != 0) return error.BadGuardianListAlignment;
    const out = try allocator.alloc(Hash32, value.len / 32);
    for (out, 0..) |*item, i| {
        @memcpy(item, value[i * 32 .. i * 32 + 32]);
    }
    return out;
}

pub const DecodedEvent = struct {
    event: Event,
    // slice owned by caller-provided allocator
    pub fn deinit(self: *const DecodedEvent, allocator: std.mem.Allocator) void {
        switch (self.event.payload) {
            .cross_lineage_composed => |p| allocator.free(p.external_parents),
            .guardian_verdict => |p| allocator.free(p.guardians),
            else => {},
        }
    }
};

/// Decode canonical bytes back into an Event. Fails loudly on any structural
/// violation — recovery may only continue when this function returns VALID.
pub fn decodeEvent(allocator: std.mem.Allocator, bytes: []const u8) ParseError!DecodedEvent {
    var r = Reader{ .data = bytes };
    var version: ?u8 = null;
    var type_id: ?u8 = null;
    var sequence: ?u64 = null;
    var prev_hash: ?Hash32 = null;
    var actor: ?Hash32 = null;

    var target_artifact: ?Hash32 = null;
    var target_generation: ?u64 = null;
    var beneficiary: ?Hash32 = null;
    var kind: ?u8 = null;
    var external_parents: ?[]const Hash32 = null;
    var artifact_cid: ?Hash32 = null;
    var capability: ?u8 = null;
    var blessing_source: ?Hash32 = null;
    var guardians: ?[]const Hash32 = null;
    var verdict_ok: ?u8 = null;
    var verdict_ref: ?Hash32 = null;
    var delegate_pubkey: ?Hash32 = null;
    var role_type: ?u8 = null;
    var valid_until: ?u64 = null;
    var scope_cid: ?Hash32 = null;
    var revoked_ref: ?Hash32 = null;

    while (r.pos < r.data.len) {
        const t = try r.next();
        switch (t.tag) {
            T_VERSION => version = try readU8(t.value),
            T_EVENT_TYPE => type_id = try readU8(t.value),
            T_SEQUENCE => sequence = try readU64(t.value),
            T_PREV_HASH => prev_hash = try readHash32(t.value),
            T_ACTOR => actor = try readHash32(t.value),
            F_TARGET_ARTIFACT => target_artifact = try readHash32(t.value),
            F_TARGET_GENERATION => target_generation = try readU64(t.value),
            F_BENEFICIARY => beneficiary = try readHash32(t.value),
            F_BLESSING_CURSE => kind = try readU8(t.value),
            F_EXTERNAL_PARENTS => external_parents = try readHashList(allocator, t.value),
            // artifact_forged and artifact_absorbed share the CID tag
            F_ARTIFACT_FORGED_CID => artifact_cid = try readHash32(t.value),
            F_REQUIRED_CAPABILITY => capability = try readU8(t.value),
            F_BLESSING_SOURCE => blessing_source = try readHash32(t.value),
            F_GUARDIANS => guardians = try readHashList(allocator, t.value),
            F_VERDICT_OK => verdict_ok = try readU8(t.value),
            F_VERDICT_REF => verdict_ref = try readHash32(t.value),
            F_DELEGATE_PUBKEY => delegate_pubkey = try readHash32(t.value),
            F_ROLE_TYPE => role_type = try readU8(t.value),
            F_VALID_UNTIL_GEN => valid_until = try readU64(t.value),
            F_SCOPE_CID => scope_cid = try readHash32(t.value),
            F_REVOKED_REF => revoked_ref = try readHash32(t.value),
            else => return error.UnknownTag,
        }
    }

    const v = version orelse return error.Malformed;
    const ty = type_id orelse return error.Malformed;
    const seq = sequence orelse return error.Malformed;
    const prev = prev_hash orelse return error.Malformed;
    const act = actor orelse return error.Malformed;

    const payload: Payload = switch (ty) {
        EVENT_INFLUENCE_AUTHORIZED => .{ .influence_authorized = .{
            .target_artifact = target_artifact orelse return error.Malformed,
            .target_generation = target_generation orelse return error.Malformed,
            .beneficiary = beneficiary orelse return error.Malformed,
            .kind = @enumFromInt(kind orelse return error.Malformed),
        } },
        EVENT_CROSS_LINEAGE_COMPOSED => .{ .cross_lineage_composed = .{
            .external_parents = external_parents orelse return error.Malformed,
        } },
        EVENT_ARTIFACT_FORGED => .{ .artifact_forged = .{
            .artifact_cid = artifact_cid orelse return error.Malformed,
            .required_capability = @enumFromInt(capability orelse return error.Malformed),
            .blessing_source = blessing_source orelse return error.Malformed,
        } },
        EVENT_ARTIFACT_ABSORBED => .{ .artifact_absorbed = .{
            .artifact_cid = artifact_cid orelse return error.Malformed,
            .blessing_source = blessing_source orelse return error.Malformed,
        } },
        EVENT_GUARDIAN_VERDICT => .{ .guardian_verdict = .{
            .guardians = guardians orelse return error.Malformed,
            .verdict_ok = (verdict_ok orelse return error.Malformed) != 0,

            .verdict_ref = verdict_ref orelse return error.Malformed,
        } },
        EVENT_AUTHORITY_DELEGATED => .{ .authority_delegated = .{
            .delegate_pubkey = delegate_pubkey orelse return error.Malformed,
            .role_type = @enumFromInt(role_type orelse return error.Malformed),
            .valid_until_generation = valid_until orelse return error.Malformed,
            .scope_cid = scope_cid orelse return error.Malformed,
        } },
        EVENT_AUTHORITY_REVOKED => .{ .authority_revoked = .{
            .revoked_ref = revoked_ref orelse return error.Malformed,
        } },
        else => return error.BadTypeId,
    };

    return .{ .event = .{
        .version = v,
        .event_type_id = ty,
        .sequence = seq,
        .prev_hash = prev,
        .actor_pubkey = act,
        .payload = payload,
    } };
}

/// Compute the deterministic event hash over canonical bytes.
pub fn eventHash(canonical_bytes: []const u8) Hash32 {
    var hasher = Sha256.init(.{});
    hasher.update(EVENT_LABEL);
    hasher.update(canonical_bytes);
    var out: Hash32 = undefined;
    hasher.final(&out);
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "canonical TLV: per-type encode/decode round-trip and hash determinism" {
    const allocator = testing.allocator;
    const a_pk: Hash32 = [_]u8{1} ** 32;
    const b_pk: Hash32 = [_]u8{2} ** 32;
    const cid1: Hash32 = [_]u8{0xAA} ** 32;
    const cid2: Hash32 = [_]u8{0xBB} ** 32;
    const scope: Hash32 = [_]u8{0xCC} ** 32;

    const events = [_]Event{
        .{ .event_type_id = EVENT_INFLUENCE_AUTHORIZED, .sequence = 0, .prev_hash = GENESIS_PARENT_HASH, .actor_pubkey = a_pk, .payload = .{ .influence_authorized = .{ .target_artifact = cid1, .target_generation = 1, .beneficiary = b_pk, .kind = .curse } } },
        .{ .event_type_id = EVENT_CROSS_LINEAGE_COMPOSED, .sequence = 1, .prev_hash = [_]u8{3} ** 32, .actor_pubkey = a_pk, .payload = .{ .cross_lineage_composed = .{ .external_parents = &.{ cid1, cid2 } } } },
        .{ .event_type_id = EVENT_ARTIFACT_FORGED, .sequence = 2, .prev_hash = [_]u8{4} ** 32, .actor_pubkey = a_pk, .payload = .{ .artifact_forged = .{ .artifact_cid = cid1, .required_capability = .role_invoke, .blessing_source = cid2 } } },
        .{ .event_type_id = EVENT_ARTIFACT_ABSORBED, .sequence = 3, .prev_hash = [_]u8{5} ** 32, .actor_pubkey = b_pk, .payload = .{ .artifact_absorbed = .{ .artifact_cid = cid1, .blessing_source = cid2 } } },
        .{ .event_type_id = EVENT_GUARDIAN_VERDICT, .sequence = 4, .prev_hash = [_]u8{6} ** 32, .actor_pubkey = a_pk, .payload = .{ .guardian_verdict = .{ .guardians = &.{ a_pk, b_pk }, .verdict_ok = true, .verdict_ref = [_]u8{7} ** 32 } } },
        .{ .event_type_id = EVENT_AUTHORITY_DELEGATED, .sequence = 5, .prev_hash = [_]u8{8} ** 32, .actor_pubkey = a_pk, .payload = .{ .authority_delegated = .{ .delegate_pubkey = b_pk, .role_type = .signer, .valid_until_generation = 100, .scope_cid = scope } } },
        .{ .event_type_id = EVENT_AUTHORITY_REVOKED, .sequence = 6, .prev_hash = [_]u8{9} ** 32, .actor_pubkey = a_pk, .payload = .{ .authority_revoked = .{ .revoked_ref = [_]u8{8} ** 32 } } },
    };

    for (events) |orig| {
        const canonical = try encodeEvent(allocator, &orig);
        defer allocator.free(canonical);

        // determinism: encoding twice yields identical bytes
        const canonical2 = try encodeEvent(allocator, &orig);
        defer allocator.free(canonical2);
        try testing.expectEqualSlices(u8, canonical, canonical2);

        const dec = try decodeEvent(allocator, canonical);
        defer dec.deinit(allocator);
        try testing.expectEqual(orig.event_type_id, dec.event.event_type_id);
        try testing.expectEqual(orig.sequence, dec.event.sequence);
        try testing.expectEqualSlices(u8, &orig.prev_hash, &dec.event.prev_hash);

        // identical logical payloads hash identically
        const h1 = eventHash(canonical);
        const h2 = eventHash(canonical2);
        try testing.expectEqualSlices(u8, &h1, &h2);
    }
}

test "canonical TLV: decode failure on truncated bytes is loud" {
    const allocator = testing.allocator;
    const good = try encodeEvent(allocator, &.{
        .event_type_id = EVENT_ARTIFACT_FORGED, .sequence = 0, .prev_hash = GENESIS_PARENT_HASH,
        .actor_pubkey = [_]u8{1} ** 32,
        .payload = .{ .artifact_forged = .{ .artifact_cid = [_]u8{2} ** 32, .required_capability = .self_derive, .blessing_source = [_]u8{3} ** 32 } },
    });
    defer allocator.free(good);
    // truncate the tail -> must fail loudly (never silently accept)
    const truncated = good[0 .. good.len - 7];
    try testing.expectError(error.Truncated, decodeEvent(allocator, truncated));
}
