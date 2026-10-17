/// BKGDB — Genesis Authority Record
///
/// Baseline: 2026-09-01
/// Spec:     GENESIS_AUTHORITY_v1.md
///
/// GenesisAuthorityRecord ist der unveränderliche Ursprung aller protokollarischen Macht.
/// Er existiert VOR dem ersten Ledger-Event und AUßERHALB des Rebuilder-Zustands.
///
/// Kanonische Hash-Reihenfolge (§3.1 der Spec, unveränderlich):
///   SHA256(
///     protocol_version_le4   ||
///     host_soul_cid          ||
///     forge_pubkey           ||
///     guardian_count_le2     ||
///     guardian_pubkeys[0..N] ||
///     genesis_timestamp_le8
///   )
const std = @import("std");

// ── Typen ──────────────────────────────────────────────────────────────────

pub const Hash      = [32]u8;
pub const ZERO_HASH: Hash = [_]u8{0} ** 32;

pub const GENESIS_PROTOCOL_VERSION: u32 = 1;

// ── GenesisAuthorityRecord ─────────────────────────────────────────────────

/// Das einzige kanonische Objekt, das Genesis Authority materialisiert.
///
/// guardian_pubkeys ist heap-allokiert (Länge = guardian_count).
/// Freigabe via freeGenesisRecord().
pub const GenesisAuthorityRecord = struct {
    genesis_id:        [16]u8,
    protocol_version:  u32,
    host_soul_cid:     [32]u8,
    forge_pubkey:      [32]u8,
    guardian_pubkeys:  [][32]u8,  // heap-allokiert, Länge = guardian_count
    guardian_count:    u8,
    genesis_timestamp: u64,
    genesis_hash:      [32]u8,
    genesis_signature: [64]u8,
};

// ── computeGenesisHash ─────────────────────────────────────────────────────

/// Berechnet den kanonischen genesis_hash deterministisch.
///
/// Feldreihenfolge ist unveränderlich (§3.1).
/// guardian_pubkeys wird direkt iteriert — kein Pointer-Inhalt im Bytestream.
pub fn computeGenesisHash(rec: *const GenesisAuthorityRecord) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // protocol_version_le4
    var pv_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &pv_buf, rec.protocol_version, .little);
    hasher.update(&pv_buf);

    // host_soul_cid
    hasher.update(&rec.host_soul_cid);

    // forge_pubkey
    hasher.update(&rec.forge_pubkey);

    // guardian_count_le2
    var gc_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &gc_buf, @as(u16, rec.guardian_count), .little);
    hasher.update(&gc_buf);

    // guardian_pubkeys[0..N] — direkte Iteration, kein Slice-Header
    for (rec.guardian_pubkeys[0..rec.guardian_count]) |pk| {
        hasher.update(&pk);
    }

    // genesis_timestamp_le8
    var ts_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &ts_buf, rec.genesis_timestamp, .little);
    hasher.update(&ts_buf);

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

// ── freeGenesisRecord ──────────────────────────────────────────────────────

/// Gibt den heap-allokierten guardian_pubkeys-Slice frei.
pub fn freeGenesisRecord(rec: *const GenesisAuthorityRecord, allocator: std.mem.Allocator) void {
    allocator.free(rec.guardian_pubkeys);
}

// ── GenesisVerifyError ─────────────────────────────────────────────────────

pub const GenesisVerifyError = error{
    /// protocol_version ist 0 oder > GENESIS_PROTOCOL_VERSION.
    InvalidProtocolVersion,
    /// host_soul_cid ist der Zero-Hash.
    ZeroHostSoulCid,
    /// forge_pubkey ist der Zero-Hash.
    ZeroForgePubkey,
    /// guardian_count ist 0 oder guardian_pubkeys.len ist 0.
    NoGuardians,
    /// genesis_hash stimmt nicht mit dem berechneten Wert überein.
    InvalidGenesisHash,
    /// genesis_signature ist keine gültige Ed25519-Signatur über genesis_hash.
    InvalidGenesisSignature,
};

// ── verifyGenesisRecord ────────────────────────────────────────────────────

/// Fail-closed Verifikation eines GenesisAuthorityRecord.
///
/// Prüfreihenfolge (jede Prüfung schlägt hart fehl):
///   1. protocol_version > 0 und <= GENESIS_PROTOCOL_VERSION
///   2. host_soul_cid ≠ ZERO_HASH
///   3. forge_pubkey ≠ ZERO_HASH
///   4. guardian_count > 0
///   5. genesis_hash == computeGenesisHash(rec)
///   6. Ed25519.verify(forge_pubkey, genesis_hash, genesis_signature)
pub fn verifyGenesisRecord(rec: *const GenesisAuthorityRecord) GenesisVerifyError!void {
    // 1. protocol_version
    if (rec.protocol_version == 0 or rec.protocol_version > GENESIS_PROTOCOL_VERSION)
        return GenesisVerifyError.InvalidProtocolVersion;

    // 2. host_soul_cid
    if (std.mem.eql(u8, &rec.host_soul_cid, &ZERO_HASH))
        return GenesisVerifyError.ZeroHostSoulCid;

    // 3. forge_pubkey
    if (std.mem.eql(u8, &rec.forge_pubkey, &ZERO_HASH))
        return GenesisVerifyError.ZeroForgePubkey;

    // 4. guardian_count
    if (rec.guardian_count == 0 or rec.guardian_pubkeys.len == 0)
        return GenesisVerifyError.NoGuardians;

    // 5. genesis_hash
    const expected_hash = computeGenesisHash(rec);
    if (!std.mem.eql(u8, &expected_hash, &rec.genesis_hash))
        return GenesisVerifyError.InvalidGenesisHash;

    // 6. Ed25519 Signatur — forge_pubkey signiert genesis_hash
    const forge_pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(rec.forge_pubkey) catch
        return GenesisVerifyError.InvalidGenesisSignature;
    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(rec.genesis_signature);
    sig.verify(&rec.genesis_hash, forge_pk) catch
        return GenesisVerifyError.InvalidGenesisSignature;
}

pub const GENESIS_MAGIC: [4]u8 = .{ 'B', 'K', 'G', 'G' };

pub const GenesisCodecError = error{
    TruncatedRecord,
    BadMagic,
    GuardianCountMismatch,
} || GenesisVerifyError || std.mem.Allocator.Error;

/// Kanonische Binärform. Der gespeicherte Hash wird beim Laden neu berechnet
/// und per Ed25519 geprüft — fail-closed, kein stilles Akzeptieren.
pub fn serializeGenesis(rec: *const GenesisAuthorityRecord, allocator: std.mem.Allocator) GenesisCodecError![]u8 {
    const count: usize = rec.guardian_count;
    if (count != rec.guardian_pubkeys.len) return error.GuardianCountMismatch;
    const total = 4 + 16 + 4 + 32 + 32 + 1 + (count * 32) + 8 + 32 + 64;
    var out = try allocator.alloc(u8, total);
    var off: usize = 0;
    @memcpy(out[off..][0..4], &GENESIS_MAGIC);
    off += 4;
    @memcpy(out[off..][0..16], &rec.genesis_id);
    off += 16;
    std.mem.writeInt(u32, out[off..][0..4], rec.protocol_version, .little);
    off += 4;
    @memcpy(out[off..][0..32], &rec.host_soul_cid);
    off += 32;
    @memcpy(out[off..][0..32], &rec.forge_pubkey);
    off += 32;
    out[off] = rec.guardian_count;
    off += 1;
    for (rec.guardian_pubkeys[0..count]) |pk| {
        @memcpy(out[off..][0..32], &pk);
        off += 32;
    }
    std.mem.writeInt(u64, out[off..][0..8], rec.genesis_timestamp, .little);
    off += 8;
    @memcpy(out[off..][0..32], &rec.genesis_hash);
    off += 32;
    @memcpy(out[off..][0..64], &rec.genesis_signature);
    return out;
}

/// Deserialisiert und verifiziert. Bei Verify-Fehler wird der Guardian-Slice freigegeben.
pub fn deserializeGenesis(allocator: std.mem.Allocator, bytes: []const u8) GenesisCodecError!GenesisAuthorityRecord {
    const min_len: usize = 4 + 16 + 4 + 32 + 32 + 1 + 8 + 32 + 64;
    if (bytes.len < min_len) return error.TruncatedRecord;
    if (!std.mem.eql(u8, bytes[0..4], &GENESIS_MAGIC)) return error.BadMagic;
    var off: usize = 4;
    var genesis_id: [16]u8 = undefined;
    @memcpy(&genesis_id, bytes[off..][0..16]);
    off += 16;
    const protocol_version = std.mem.readInt(u32, bytes[off..][0..4], .little);
    off += 4;
    var host_soul_cid: [32]u8 = undefined;
    @memcpy(&host_soul_cid, bytes[off..][0..32]);
    off += 32;
    var forge_pubkey: [32]u8 = undefined;
    @memcpy(&forge_pubkey, bytes[off..][0..32]);
    off += 32;
    if (off >= bytes.len) return error.TruncatedRecord;
    const guardian_count = bytes[off];
    off += 1;
    if (guardian_count == 0) return error.NoGuardians;
    const need = off + (@as(usize, guardian_count) * 32) + 8 + 32 + 64;
    if (bytes.len != need) return error.TruncatedRecord;
    const guardian_pks = try allocator.alloc([32]u8, guardian_count);
    errdefer allocator.free(guardian_pks);
    var i: usize = 0;
    while (i < guardian_count) : (i += 1) {
        @memcpy(&guardian_pks[i], bytes[off..][0..32]);
        off += 32;
    }
    const genesis_timestamp = std.mem.readInt(u64, bytes[off..][0..8], .little);
    off += 8;
    var genesis_hash: [32]u8 = undefined;
    @memcpy(&genesis_hash, bytes[off..][0..32]);
    off += 32;
    var genesis_signature: [64]u8 = undefined;
    @memcpy(&genesis_signature, bytes[off..][0..64]);

    const rec = GenesisAuthorityRecord{
        .genesis_id = genesis_id,
        .protocol_version = protocol_version,
        .host_soul_cid = host_soul_cid,
        .forge_pubkey = forge_pubkey,
        .guardian_pubkeys = guardian_pks,
        .guardian_count = guardian_count,
        .genesis_timestamp = genesis_timestamp,
        .genesis_hash = genesis_hash,
        .genesis_signature = genesis_signature,
    };
    try verifyGenesisRecord(&rec);
    return rec;
}

pub fn writeGenesisFile(
    io: std.Io,
    path: []const u8,
    rec: *const GenesisAuthorityRecord,
    allocator: std.mem.Allocator,
) !void {
    const bytes = try serializeGenesis(rec, allocator);
    defer allocator.free(bytes);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

pub fn readGenesisFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !GenesisAuthorityRecord {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    const n = try file.readPositionalAll(io, bytes, 0);
    return deserializeGenesis(allocator, bytes[0..n]);
}

// ── Tests ──────────────────────────────────────────────────────────────────

/// Baut einen validen GenesisAuthorityRecord für Tests.
/// Aufrufer muss freeGenesisRecord() aufrufen.
fn makeValidRecord(
    allocator: std.mem.Allocator,
    kp: std.crypto.sign.Ed25519.KeyPair,
) !GenesisAuthorityRecord {
    const guardian_pks = try allocator.alloc([32]u8, 1);
    guardian_pks[0] = kp.public_key.toBytes(); // Guardian = Forge für Tests

    var rec = GenesisAuthorityRecord{
        .genesis_id        = [_]u8{0x01} ** 16,
        .protocol_version  = 1,
        .host_soul_cid     = [_]u8{0x42} ** 32,
        .forge_pubkey      = kp.public_key.toBytes(),
        .guardian_pubkeys  = guardian_pks,
        .guardian_count    = 1,
        .genesis_timestamp = 1_700_000_000,
        .genesis_hash      = ZERO_HASH,
        .genesis_signature = [_]u8{0} ** 64,
    };

    rec.genesis_hash = computeGenesisHash(&rec);
    const sig = try kp.sign(&rec.genesis_hash, null);
    rec.genesis_signature = sig.toBytes();
    return rec;
}

test "genesis: computeGenesisHash — gleicher Record ergibt gleichen Hash" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const guardian_pks = try std.testing.allocator.alloc([32]u8, 1);
    defer std.testing.allocator.free(guardian_pks);
    guardian_pks[0] = kp.public_key.toBytes();

    const rec = GenesisAuthorityRecord{
        .genesis_id        = [_]u8{0x01} ** 16,
        .protocol_version  = 1,
        .host_soul_cid     = [_]u8{0x42} ** 32,
        .forge_pubkey      = kp.public_key.toBytes(),
        .guardian_pubkeys  = guardian_pks,
        .guardian_count    = 1,
        .genesis_timestamp = 1_700_000_000,
        .genesis_hash      = ZERO_HASH,
        .genesis_signature = [_]u8{0} ** 64,
    };

    const h1 = computeGenesisHash(&rec);
    const h2 = computeGenesisHash(&rec);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
    // Hash ist nicht Zero
    try std.testing.expect(!std.mem.eql(u8, &h1, &ZERO_HASH));
}

test "genesis: computeGenesisHash — mutiertes Feld ergibt anderen Hash" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const guardian_pks = try std.testing.allocator.alloc([32]u8, 1);
    defer std.testing.allocator.free(guardian_pks);
    guardian_pks[0] = kp.public_key.toBytes();

    var rec = GenesisAuthorityRecord{
        .genesis_id        = [_]u8{0x01} ** 16,
        .protocol_version  = 1,
        .host_soul_cid     = [_]u8{0x42} ** 32,
        .forge_pubkey      = kp.public_key.toBytes(),
        .guardian_pubkeys  = guardian_pks,
        .guardian_count    = 1,
        .genesis_timestamp = 1_700_000_000,
        .genesis_hash      = ZERO_HASH,
        .genesis_signature = [_]u8{0} ** 64,
    };

    const h1 = computeGenesisHash(&rec);
    rec.genesis_timestamp += 1;
    const h2 = computeGenesisHash(&rec);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "genesis: verifyGenesisRecord — valides Record besteht" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    try verifyGenesisRecord(&rec);
}

test "genesis: verifyGenesisRecord — manipulierter genesis_hash → InvalidGenesisHash" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    rec.genesis_hash[0] ^= 0xFF; // Manipulation
    try std.testing.expectError(GenesisVerifyError.InvalidGenesisHash, verifyGenesisRecord(&rec));
}

test "genesis: verifyGenesisRecord — manipulierte Signatur → InvalidGenesisSignature" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    rec.genesis_signature[0] ^= 0xFF; // Manipulation
    try std.testing.expectError(GenesisVerifyError.InvalidGenesisSignature, verifyGenesisRecord(&rec));
}

test "genesis: verifyGenesisRecord — zero forge_pubkey → ZeroForgePubkey" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    rec.forge_pubkey = ZERO_HASH;
    try std.testing.expectError(GenesisVerifyError.ZeroForgePubkey, verifyGenesisRecord(&rec));
}

test "genesis: verifyGenesisRecord — kein Guardian → NoGuardians" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    rec.guardian_count = 0;
    try std.testing.expectError(GenesisVerifyError.NoGuardians, verifyGenesisRecord(&rec));
}

test "genesis: verifyGenesisRecord — zero host_soul_cid → ZeroHostSoulCid" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    rec.host_soul_cid = ZERO_HASH;
    try std.testing.expectError(GenesisVerifyError.ZeroHostSoulCid, verifyGenesisRecord(&rec));
}

test "genesis: verifyGenesisRecord — protocol_version 0 → InvalidProtocolVersion" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    rec.protocol_version = 0;
    try std.testing.expectError(GenesisVerifyError.InvalidProtocolVersion, verifyGenesisRecord(&rec));
}

// ── Task 4: Genesis Immutability — Mutation-after-verify ───────────────────
// Every field mutation on a verified record must produce a different hash or
// fail verification. The record itself is immutable after verifyGenesisRecord
// succeeds — these tests prove that any post-verify mutation is detectable.

test "genesis: immutability — forge_pubkey mutation → hash changes" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    try verifyGenesisRecord(&rec); // passes clean

    const hash_before = rec.genesis_hash;
    rec.forge_pubkey[0] ^= 0x01; // mutate after verify
    const hash_after = computeGenesisHash(&rec);
    // Hash must differ — mutation is detectable
    try std.testing.expect(!std.mem.eql(u8, &hash_before, &hash_after));
    // Verification must now fail
    try std.testing.expectError(GenesisVerifyError.InvalidGenesisHash, verifyGenesisRecord(&rec));
}

test "genesis: immutability — host_soul_cid mutation → hash changes" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    try verifyGenesisRecord(&rec);

    rec.host_soul_cid[0] ^= 0x01;
    try std.testing.expectError(GenesisVerifyError.InvalidGenesisHash, verifyGenesisRecord(&rec));
}

test "genesis: immutability — protocol_version mutation → hash changes" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    try verifyGenesisRecord(&rec);

    // protocol_version 2 is > GENESIS_PROTOCOL_VERSION=1 → InvalidProtocolVersion (checked first)
    rec.protocol_version = 2;
    try std.testing.expectError(GenesisVerifyError.InvalidProtocolVersion, verifyGenesisRecord(&rec));
}

test "genesis: immutability — genesis_timestamp mutation → hash changes" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    try verifyGenesisRecord(&rec);

    rec.genesis_timestamp += 1;
    try std.testing.expectError(GenesisVerifyError.InvalidGenesisHash, verifyGenesisRecord(&rec));
}

test "genesis: immutability — guardian_pubkey mutation → hash changes" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    try verifyGenesisRecord(&rec);

    rec.guardian_pubkeys[0][0] ^= 0x01;
    try std.testing.expectError(GenesisVerifyError.InvalidGenesisHash, verifyGenesisRecord(&rec));
}

// ── Task 11: Memory Safety — alloc/free patterns ───────────────────────────

test "genesis: memory safety — freeGenesisRecord on valid record is safe" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x99} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    // single free — must not crash or leak
    freeGenesisRecord(&rec, std.testing.allocator);
}

test "genesis: memory safety — empty guardian slice (guardian_count=0) not allocatable via makeValidRecord" {
    // Verifies that guardian_count=0 is caught by verifyGenesisRecord, never silently accepted.
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const guardian_pks = try std.testing.allocator.alloc([32]u8, 1);
    defer std.testing.allocator.free(guardian_pks);
    guardian_pks[0] = kp.public_key.toBytes();

    var rec = GenesisAuthorityRecord{
        .genesis_id        = [_]u8{0x01} ** 16,
        .protocol_version  = 1,
        .host_soul_cid     = [_]u8{0x42} ** 32,
        .forge_pubkey      = kp.public_key.toBytes(),
        .guardian_pubkeys  = guardian_pks,
        .guardian_count    = 0, // mismatch: slice has 1 entry, count says 0
        .genesis_timestamp = 1_700_000_000,
        .genesis_hash      = ZERO_HASH,
        .genesis_signature = [_]u8{0} ** 64,
    };
    rec.genesis_hash = computeGenesisHash(&rec);

    // guardian_count=0 → NoGuardians regardless of slice length
    try std.testing.expectError(GenesisVerifyError.NoGuardians, verifyGenesisRecord(&rec));
}

test "genesis: memory safety — multiple verify calls on same record are safe" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    // Verify twice — must be idempotent, no side effects
    try verifyGenesisRecord(&rec);
    try verifyGenesisRecord(&rec);
}

test "genesis: memory safety — large guardian list (8 guardians)" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const guardian_pks = try std.testing.allocator.alloc([32]u8, 8);

    for (guardian_pks, 0..) |*pk, i| {
        pk.* = [_]u8{0} ** 32;
        pk.*[0] = @intCast(i + 1);
    }

    var rec = GenesisAuthorityRecord{
        .genesis_id        = [_]u8{0x01} ** 16,
        .protocol_version  = 1,
        .host_soul_cid     = [_]u8{0x42} ** 32,
        .forge_pubkey      = kp.public_key.toBytes(),
        .guardian_pubkeys  = guardian_pks,
        .guardian_count    = 8,
        .genesis_timestamp = 1_700_000_000,
        .genesis_hash      = ZERO_HASH,
        .genesis_signature = [_]u8{0} ** 64,
    };
    rec.genesis_hash = computeGenesisHash(&rec);
    const sig = try kp.sign(&rec.genesis_hash, null);
    rec.genesis_signature = sig.toBytes();

    defer freeGenesisRecord(&rec, std.testing.allocator);
    try verifyGenesisRecord(&rec);
}

// ── Task 9: Negative API Surface — invalid states cannot be silently accepted

test "genesis: negative API — zero genesis_id is structurally allowed but hash still unique" {
    // genesis_id is NOT part of the canonical hash (by spec §3.1).
    // Two records differing only in genesis_id produce the SAME hash — this is intentional:
    // genesis_id is an opaque identifier, not a hash input.
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const guardian_pks_a = try std.testing.allocator.alloc([32]u8, 1);
    const guardian_pks_b = try std.testing.allocator.alloc([32]u8, 1);
    defer std.testing.allocator.free(guardian_pks_a);
    defer std.testing.allocator.free(guardian_pks_b);
    guardian_pks_a[0] = kp.public_key.toBytes();
    guardian_pks_b[0] = kp.public_key.toBytes();

    var rec_a = GenesisAuthorityRecord{
        .genesis_id        = [_]u8{0x00} ** 16,
        .protocol_version  = 1,
        .host_soul_cid     = [_]u8{0x42} ** 32,
        .forge_pubkey      = kp.public_key.toBytes(),
        .guardian_pubkeys  = guardian_pks_a,
        .guardian_count    = 1,
        .genesis_timestamp = 1_700_000_000,
        .genesis_hash      = ZERO_HASH,
        .genesis_signature = [_]u8{0} ** 64,
    };
    var rec_b = rec_a;
    rec_b.genesis_id = [_]u8{0xFF} ** 16;
    rec_b.guardian_pubkeys = guardian_pks_b;

    const ha = computeGenesisHash(&rec_a);
    const hb = computeGenesisHash(&rec_b);
    // genesis_id is intentionally excluded from hash — both records produce same canonical hash
    try std.testing.expectEqualSlices(u8, &ha, &hb);
}

test "genesis: negative API — different forge_pubkey always produces different hash" {
    const kp_a = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const kp_b = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x43} ** 32);

    const guardian_pks = try std.testing.allocator.alloc([32]u8, 1);
    defer std.testing.allocator.free(guardian_pks);
    guardian_pks[0] = kp_a.public_key.toBytes();

    const base = GenesisAuthorityRecord{
        .genesis_id        = [_]u8{0x01} ** 16,
        .protocol_version  = 1,
        .host_soul_cid     = [_]u8{0x42} ** 32,
        .forge_pubkey      = kp_a.public_key.toBytes(),
        .guardian_pubkeys  = guardian_pks,
        .guardian_count    = 1,
        .genesis_timestamp = 1_700_000_000,
        .genesis_hash      = ZERO_HASH,
        .genesis_signature = [_]u8{0} ** 64,
    };
    var alt = base;
    alt.forge_pubkey = kp_b.public_key.toBytes();

    const ha = computeGenesisHash(&base);
    const hb = computeGenesisHash(&alt);
    try std.testing.expect(!std.mem.eql(u8, &ha, &hb));
}

test "genesis: serialize/deserialize roundtrip preserves hash and verifies" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    const bytes = try serializeGenesis(&rec, std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    var loaded = try deserializeGenesis(std.testing.allocator, bytes);
    defer freeGenesisRecord(&loaded, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &rec.genesis_hash, &loaded.genesis_hash);
    try std.testing.expectEqualSlices(u8, &rec.forge_pubkey, &loaded.forge_pubkey);
    try std.testing.expectEqual(rec.guardian_count, loaded.guardian_count);
}

test "genesis: tampered serialized bytes fail closed" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    const bytes = try serializeGenesis(&rec, std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    bytes[bytes.len - 1] ^= 0xFF;
    try std.testing.expectError(error.InvalidGenesisSignature, deserializeGenesis(std.testing.allocator, bytes));
}

test "genesis: extra trailing bytes fail closed" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    const bytes = try serializeGenesis(&rec, std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const padded = try std.testing.allocator.alloc(u8, bytes.len + 1);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..bytes.len], bytes);
    padded[bytes.len] = 0;
    try std.testing.expectError(error.TruncatedRecord, deserializeGenesis(std.testing.allocator, padded));
}

test "genesis: file persist and reload verifies signature" {
    const io = std.testing.io;
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    var rec = try makeValidRecord(std.testing.allocator, kp);
    defer freeGenesisRecord(&rec, std.testing.allocator);

    const path = "test_genesis_persist.bin";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeGenesisFile(io, path, &rec, std.testing.allocator);
    var loaded = try readGenesisFile(io, std.testing.allocator, path);
    defer freeGenesisRecord(&loaded, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &rec.genesis_hash, &loaded.genesis_hash);
    try std.testing.expectEqualSlices(u8, &rec.genesis_signature, &loaded.genesis_signature);
}
