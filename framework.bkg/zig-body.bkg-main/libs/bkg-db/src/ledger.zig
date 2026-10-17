/// BKGDB — Immutable Ledger
///
/// Append-only Log für alle sicherheits-, wirtschafts- und evolutionsrelevanten Events.
/// Einträge werden NIEMALS überschrieben oder gelöscht.
/// Jeder Eintrag ist mit dem Hash des vorherigen Eintrags verkettet (Merkle-Chain).
///
/// Ledger-Typen:
///   security_ledger   Key/Session-Events, Guardian-Events, Killchain
///   audit_log         Admin- und Security-Events
///   usage_log         Proxy-Request-Historie
///   algorithm_ledger  Algorithmus-Erzeugung, Versionen, XP, ALGO
///   asset_ledger      NFT-Minting, Transfers, Consumption, Evolution
///   forge_ledger      Forge-Epochen, Guardian-Generationen, Kandidaten
///
/// Disk-Layout (ledger.wal):
///   Sequenzieller Append von LedgerEntry-Paketen.
///   Jedes Paket: entry_len(4) + serialisierter LedgerEntry + entry_hash(32)
const std = @import("std");
const merkle = @import("merkle.zig");

pub const Hash = merkle.Hash;
pub const MerkleChain = merkle.MerkleChain;

// ── Event-Typen ───────────────────────────────────────────────────────────

pub const LedgerEventType = enum(u16) {
    // ── Key & Session ────────────────────────────────────────────────────
    key_conflict = 0x0001,
    key_quarantine = 0x0002,
    key_revoked = 0x0003,
    key_compromised = 0x0004,
    session_revoke = 0x0005,
    kill_chain_start = 0x0006,
    kill_chain_complete = 0x0007,

    // ── Guardian / Quorum ────────────────────────────────────────────────
    guardian_flag = 0x0101,
    guardian_reject = 0x0102,
    guardian_challenge = 0x0103,
    guardian_verdict = 0x0104,
    quorum_pass = 0x0105,
    quorum_fail = 0x0106,
    algorithm_accepted = 0x0107,
    algorithm_rejected = 0x0108,
    xp_granted = 0x0109,
    algo_minted = 0x010a,
    capacity_attested = 0x010b,

    // ── Peer / Collateral ────────────────────────────────────────────────
    collateral_violation = 0x0201,
    collateral_frozen = 0x0202,
    collateral_returned = 0x0203,
    peer_joined = 0x0204,
    peer_left = 0x0205,
    guardian_reputation_update = 0x0206,

    // ── Guardian-Versionierung ───────────────────────────────────────────
    guardian_version_updated = 0x0301,

    // ── Audit / Admin ─────────────────────────────────────────────────────
    admin_action = 0x0401,
    user_created = 0x0402,
    user_suspended = 0x0403,
    credential_added = 0x0404,
    credential_revoked = 0x0405,

    // ── Usage ─────────────────────────────────────────────────────────────
    request_completed = 0x0501,

    // ── Algorithmen ───────────────────────────────────────────────────────
    algorithm_created = 0x0601,
    algorithm_versioned = 0x0602,
    algorithm_verified = 0x0603,

    // ── Assets / NFT ──────────────────────────────────────────────────────
    nft_minted = 0x0701,
    nft_transferred = 0x0702,
    nft_consumed = 0x0703,
    nft_frozen = 0x0704,

    // ── Forge ─────────────────────────────────────────────────────────────
    forge_epoch_started = 0x0801,
    forge_candidate_submitted = 0x0802,
    forge_candidate_verified = 0x0803,
    forge_guardian_generated = 0x0804,
};

// ── LedgerEntry ───────────────────────────────────────────────────────────

/// In-Memory Darstellung eines Ledger-Eintrags.
pub const LedgerEntry = struct {
    /// Monoton steigender Zähler (innerhalb dieses Ledgers)
    seq: u64,
    /// Unix-Timestamp in Sekunden
    timestamp: i64,
    /// Event-Typ
    event_type: LedgerEventType,
    /// Betroffene Entity (z.B. credential_id, peer_id, algo_id) — optional
    entity_id: [36]u8,
    entity_id_len: u8,
    /// Auslösende Actor-ID — optional
    actor_id: [36]u8,
    actor_id_len: u8,
    /// Kompaktes Payload (max. 1KB — große Inhalte außerhalb des Ledgers)
    payload: [1024]u8,
    payload_len: u16,
    /// SHA256-Hash dieses Eintrags (SHA256(serialized_entry || prev_hash))
    entry_hash: Hash,
    /// Hash des vorherigen Eintrags (Genesis = alle Nullen)
    prev_hash: Hash,

    pub fn entityIdSlice(self: *const LedgerEntry) []const u8 {
        return self.entity_id[0..self.entity_id_len];
    }

    pub fn actorIdSlice(self: *const LedgerEntry) []const u8 {
        return self.actor_id[0..self.actor_id_len];
    }

    pub fn payloadSlice(self: *const LedgerEntry) []const u8 {
        return self.payload[0..self.payload_len];
    }
};

/// Parameter für das Anlegen eines neuen Eintrags.
pub const AppendParams = struct {
    event_type: LedgerEventType,
    entity_id: ?[]const u8 = null,
    actor_id: ?[]const u8 = null,
    payload: ?[]const u8 = null,
    timestamp: ?i64 = null,
};

// ── Serialisierung ────────────────────────────────────────────────────────

/// Serialisiert einen LedgerEntry für das Hash-Berechnen (ohne entry_hash und prev_hash).
fn serializeForHash(entry: *const LedgerEntry, buf: []u8) usize {
    var off: usize = 0;
    // seq (8), timestamp (8), event_type (2)
    writeU64Le(buf[off..], entry.seq); off += 8;
    writeI64Le(buf[off..], entry.timestamp); off += 8;
    writeU16Le(buf[off..], @intFromEnum(entry.event_type)); off += 2;
    // entity_id
    buf[off] = entry.entity_id_len; off += 1;
    @memcpy(buf[off..][0..entry.entity_id_len], entry.entity_id[0..entry.entity_id_len]);
    off += entry.entity_id_len;
    // actor_id
    buf[off] = entry.actor_id_len; off += 1;
    @memcpy(buf[off..][0..entry.actor_id_len], entry.actor_id[0..entry.actor_id_len]);
    off += entry.actor_id_len;
    // payload
    writeU16Le(buf[off..], entry.payload_len); off += 2;
    @memcpy(buf[off..][0..entry.payload_len], entry.payload[0..entry.payload_len]);
    off += entry.payload_len;
    return off;
}

// ── Ledger ────────────────────────────────────────────────────────────────

pub const LedgerError = error{
    /// Letzter Eintrag ist unvollständig und liegt nicht am EOF-Tail.
    TruncatedLedger,
    /// Gespeicherter Hash stimmt nicht mit dem neu berechneten überein.
    TamperedLedger,
    /// prev_hash bricht die Kette.
    BrokenChain,
    /// Sequenz ist nicht lückenlos monoton.
    InvalidSequence,
    /// event_type ist kein bekannter LedgerEventType.
    InvalidEventType,
};

/// Verwaltet einen Append-only Ledger mit Merkle-Chain.
pub const Ledger = struct {
    chain: MerkleChain,
    entry_count: u64,
    file: std.Io.File,
    io: std.Io,
    /// Byte-Offset des nächsten Appends (nach dem letzten verifizierten Eintrag).
    pos: u64,

    /// Öffnet oder erstellt einen Ledger.
    /// Existierende Dateien werden vollständig neu gelesen: jeder Eintrag wird
    /// re-serialisiert und der Hash neu berechnet. Abweichung → fail-closed.
    /// Ein Crash-Tail (unvollständiger letzter Eintrag am EOF) wird abgeschnitten,
    /// Korruption in der Mitte ist FATAL.
    pub fn open(io: std.Io, dir: std.Io.Dir, path: []const u8) !Ledger {
        const file = try dir.createFile(io, path, .{ .read = true, .truncate = false });
        errdefer file.close(io);

        var led = Ledger{
            .chain = MerkleChain.init(),
            .entry_count = 0,
            .file = file,
            .io = io,
            .pos = 0,
        };
        try led.replayFromDisk();
        return led;
    }

    fn replayFromDisk(self: *Ledger) !void {
        const size = try self.file.length(self.io);
        if (size == 0) {
            self.pos = 0;
            return;
        }

        var expected_prev = merkle.GENESIS_HASH;
        var expected_seq: u64 = 0;
        var offset: u64 = 0;

        while (offset < size) {
            var len_buf: [4]u8 = undefined;
            const remaining = size - offset;
            // Ein vollständiger Eintrag braucht mindestens 4 + 86 Bytes.
            // Weniger am Dateiende ist ein Crash-Tail, kein stilles Reparieren in der Mitte.
            if (remaining < 4 + 86) {
                try self.file.setLength(self.io, offset);
                break;
            }
            const n = try self.file.readPositionalAll(self.io, &len_buf, offset);
            if (n != 4) {
                try self.file.setLength(self.io, offset);
                break;
            }
            const body_len = readU32Le(&len_buf);
            if (body_len < 86 or body_len > 2040) return LedgerError.TamperedLedger;
            if (offset + 4 + body_len > size) {
                try self.file.setLength(self.io, offset);
                break;
            }

            var body: [2040]u8 = undefined;
            const got = try self.file.readPositionalAll(self.io, body[0..body_len], offset + 4);
            if (got != body_len) {
                try self.file.setLength(self.io, offset);
                break;
            }

            const entry = try parseStoredEntry(body[0..body_len]);
            if (entry.seq != expected_seq) return LedgerError.InvalidSequence;
            if (!merkle.hashEql(&entry.prev_hash, &expected_prev)) return LedgerError.BrokenChain;

            var ser_buf: [2048]u8 = undefined;
            const ser_len = serializeForHash(&entry, &ser_buf);
            const recomputed = merkle.entryHash(ser_buf[0..ser_len], &entry.prev_hash);
            if (!merkle.hashEql(&recomputed, &entry.entry_hash)) return LedgerError.TamperedLedger;

            self.chain.root = entry.entry_hash;
            self.chain.entry_count += 1;
            self.entry_count += 1;
            expected_prev = entry.entry_hash;
            expected_seq += 1;
            offset += 4 + body_len;
        }
        self.pos = offset;
    }

    pub fn close(self: *Ledger) void {
        self.file.close(self.io);
    }

    /// Fügt einen neuen Eintrag hinzu. Gibt den Eintrag zurück.
    /// Einträge können NICHT geändert oder gelöscht werden.
    pub fn append(self: *Ledger, params: AppendParams) !LedgerEntry {
        var entry = LedgerEntry{
            .seq = self.entry_count,
            .timestamp = params.timestamp orelse std.Io.Clock.real.now(self.io).toSeconds(),
            .event_type = params.event_type,
            .entity_id = [_]u8{0} ** 36,
            .entity_id_len = 0,
            .actor_id = [_]u8{0} ** 36,
            .actor_id_len = 0,
            .payload = [_]u8{0} ** 1024,
            .payload_len = 0,
            .entry_hash = merkle.GENESIS_HASH,
            .prev_hash = self.chain.root,
        };

        if (params.entity_id) |eid| {
            const len = @min(eid.len, 36);
            @memcpy(entry.entity_id[0..len], eid[0..len]);
            entry.entity_id_len = @intCast(len);
        }
        if (params.actor_id) |aid| {
            const len = @min(aid.len, 36);
            @memcpy(entry.actor_id[0..len], aid[0..len]);
            entry.actor_id_len = @intCast(len);
        }
        if (params.payload) |p| {
            const len = @min(p.len, 1024);
            @memcpy(entry.payload[0..len], p[0..len]);
            entry.payload_len = @intCast(len);
        }

        // Hash berechnen: SHA256(serialized || prev_hash)
        var ser_buf: [2048]u8 = undefined;
        const ser_len = serializeForHash(&entry, &ser_buf);
        entry.entry_hash = merkle.entryHash(ser_buf[0..ser_len], &entry.prev_hash);

        // Chain aktualisieren
        self.chain.root = entry.entry_hash;
        self.chain.entry_count += 1;
        self.entry_count += 1;

        // Auf Disk schreiben
        try self.writeEntry(&entry);

        return entry;
    }

    /// Gibt den aktuellen Merkle-Root zurück.
    pub fn merkleRoot(self: *const Ledger) *const Hash {
        return &self.chain.root;
    }

    fn writeEntry(self: *Ledger, entry: *const LedgerEntry) !void {
        // Format: entry_len(4) + seq(8) + timestamp(8) + event_type(2) +
        //         entity_id_len(1) + entity_id + actor_id_len(1) + actor_id +
        //         payload_len(2) + payload + prev_hash(32) + entry_hash(32)
        var buf: [2048]u8 = undefined;
        var off: usize = 4; // Platz für entry_len

        writeU64Le(buf[off..], entry.seq); off += 8;
        writeI64Le(buf[off..], entry.timestamp); off += 8;
        writeU16Le(buf[off..], @intFromEnum(entry.event_type)); off += 2;
        buf[off] = entry.entity_id_len; off += 1;
        @memcpy(buf[off..][0..entry.entity_id_len], entry.entity_id[0..entry.entity_id_len]);
        off += entry.entity_id_len;
        buf[off] = entry.actor_id_len; off += 1;
        @memcpy(buf[off..][0..entry.actor_id_len], entry.actor_id[0..entry.actor_id_len]);
        off += entry.actor_id_len;
        writeU16Le(buf[off..], entry.payload_len); off += 2;
        @memcpy(buf[off..][0..entry.payload_len], entry.payload[0..entry.payload_len]);
        off += entry.payload_len;
        @memcpy(buf[off..][0..32], &entry.prev_hash); off += 32;
        @memcpy(buf[off..][0..32], &entry.entry_hash); off += 32;

        // entry_len einschreiben (exkl. den ersten 4 Bytes)
        writeU32Le(buf[0..], @intCast(off - 4));

        try self.file.writePositionalAll(self.io, buf[0..off], self.pos);
        try self.file.sync(self.io);
        self.pos += off;
    }
};

fn parseStoredEntry(body: []const u8) LedgerError!LedgerEntry {
    var off: usize = 0;
    if (body.len < 86) return LedgerError.TruncatedLedger;

    const seq = readU64Le(body[off..]);
    off += 8;
    const timestamp = readI64Le(body[off..]);
    off += 8;
    const event_type_raw = readU16Le(body[off..]);
    off += 2;
    const event_type = std.enums.fromInt(LedgerEventType, event_type_raw) orelse
        return LedgerError.InvalidEventType;

    if (off >= body.len) return LedgerError.TruncatedLedger;
    const entity_id_len = body[off];
    off += 1;
    if (entity_id_len > 36) return LedgerError.TamperedLedger;
    if (off + entity_id_len > body.len) return LedgerError.TruncatedLedger;
    var entity_id = [_]u8{0} ** 36;
    @memcpy(entity_id[0..entity_id_len], body[off..][0..entity_id_len]);
    off += entity_id_len;

    if (off >= body.len) return LedgerError.TruncatedLedger;
    const actor_id_len = body[off];
    off += 1;
    if (actor_id_len > 36) return LedgerError.TamperedLedger;
    if (off + actor_id_len > body.len) return LedgerError.TruncatedLedger;
    var actor_id = [_]u8{0} ** 36;
    @memcpy(actor_id[0..actor_id_len], body[off..][0..actor_id_len]);
    off += actor_id_len;

    if (off + 2 > body.len) return LedgerError.TruncatedLedger;
    const payload_len = readU16Le(body[off..]);
    off += 2;
    if (payload_len > 1024) return LedgerError.TamperedLedger;
    if (off + payload_len + 64 > body.len) return LedgerError.TruncatedLedger;
    var payload = [_]u8{0} ** 1024;
    @memcpy(payload[0..payload_len], body[off..][0..payload_len]);
    off += payload_len;

    var prev_hash: Hash = undefined;
    @memcpy(&prev_hash, body[off..][0..32]);
    off += 32;
    var entry_hash: Hash = undefined;
    @memcpy(&entry_hash, body[off..][0..32]);
    off += 32;
    if (off != body.len) return LedgerError.TamperedLedger;

    return LedgerEntry{
        .seq = seq,
        .timestamp = timestamp,
        .event_type = event_type,
        .entity_id = entity_id,
        .entity_id_len = entity_id_len,
        .actor_id = actor_id,
        .actor_id_len = actor_id_len,
        .payload = payload,
        .payload_len = payload_len,
        .entry_hash = entry_hash,
        .prev_hash = prev_hash,
    };
}

// ── Hilfsfunktionen ───────────────────────────────────────────────────────

fn writeU16Le(buf: []u8, v: u16) void {
    buf[0] = @truncate(v);
    buf[1] = @truncate(v >> 8);
}

fn writeU32Le(buf: []u8, v: u32) void {
    buf[0] = @truncate(v);
    buf[1] = @truncate(v >> 8);
    buf[2] = @truncate(v >> 16);
    buf[3] = @truncate(v >> 24);
}

fn writeU64Le(buf: []u8, v: u64) void {
    buf[0] = @truncate(v);
    buf[1] = @truncate(v >> 8);
    buf[2] = @truncate(v >> 16);
    buf[3] = @truncate(v >> 24);
    buf[4] = @truncate(v >> 32);
    buf[5] = @truncate(v >> 40);
    buf[6] = @truncate(v >> 48);
    buf[7] = @truncate(v >> 56);
}

fn writeI64Le(buf: []u8, v: i64) void {
    writeU64Le(buf, @bitCast(v));
}

fn readU16Le(buf: []const u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

fn readU32Le(buf: []const u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

fn readU64Le(buf: []const u8) u64 {
    return @as(u64, buf[0]) |
        (@as(u64, buf[1]) << 8) |
        (@as(u64, buf[2]) << 16) |
        (@as(u64, buf[3]) << 24) |
        (@as(u64, buf[4]) << 32) |
        (@as(u64, buf[5]) << 40) |
        (@as(u64, buf[6]) << 48) |
        (@as(u64, buf[7]) << 56);
}

fn readI64Le(buf: []const u8) i64 {
    return @bitCast(readU64Le(buf));
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "Ledger append single entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var l = try Ledger.open(io, tmp.dir, "test.ledger");
    defer l.close();

    const e = try l.append(.{
        .event_type = .key_conflict,
        .entity_id = "cred-123",
        .actor_id = "user-456",
        .payload = "conflict detected",
    });

    try std.testing.expectEqual(@as(u64, 0), e.seq);
    try std.testing.expectEqual(LedgerEventType.key_conflict, e.event_type);
    try std.testing.expectEqualStrings("cred-123", e.entityIdSlice());
    try std.testing.expectEqualStrings("user-456", e.actorIdSlice());
    try std.testing.expectEqualStrings("conflict detected", e.payloadSlice());
    try std.testing.expect(@as(u64, 1) == l.entry_count);
    // Hash muss nicht-Genesis sein
    try std.testing.expect(!merkle.isGenesis(&e.entry_hash));
}

test "Ledger hash chain: second entry has first as prev_hash" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var l = try Ledger.open(io, tmp.dir, "chain.ledger");
    defer l.close();

    const e1 = try l.append(.{ .event_type = .peer_joined, .entity_id = "peer-1" });
    const e2 = try l.append(.{ .event_type = .peer_joined, .entity_id = "peer-2" });

    try std.testing.expect(merkle.hashEql(&e1.entry_hash, &e2.prev_hash));
    try std.testing.expect(!merkle.hashEql(&e1.entry_hash, &e2.entry_hash));
    try std.testing.expectEqual(@as(u64, 2), l.entry_count);
}

test "Ledger genesis prev_hash for first entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var l = try Ledger.open(io, tmp.dir, "genesis.ledger");
    defer l.close();

    const e = try l.append(.{ .event_type = .algo_minted });
    try std.testing.expect(merkle.isGenesis(&e.prev_hash));
}

test "Ledger merkle root advances with each append" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var l = try Ledger.open(io, tmp.dir, "root.ledger");
    defer l.close();

    try std.testing.expect(merkle.isGenesis(l.merkleRoot()));
    _ = try l.append(.{ .event_type = .xp_granted });
    try std.testing.expect(!merkle.isGenesis(l.merkleRoot()));
    const root1 = l.chain.root;
    _ = try l.append(.{ .event_type = .xp_granted });
    try std.testing.expect(!merkle.hashEql(&root1, l.merkleRoot()));
}

test "Ledger all security event types compile" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var l = try Ledger.open(io, tmp.dir, "events.ledger");
    defer l.close();

    const events = [_]LedgerEventType{
        .key_conflict, .key_quarantine, .key_revoked, .key_compromised,
        .session_revoke, .kill_chain_start, .kill_chain_complete,
        .guardian_flag, .quorum_pass, .quorum_fail,
        .peer_joined, .peer_left,
        .algo_minted, .xp_granted,
        .nft_minted, .nft_transferred,
        .forge_epoch_started, .forge_candidate_verified,
    };
    for (events) |ev| {
        _ = try l.append(.{ .event_type = ev });
    }
    try std.testing.expectEqual(@as(u64, events.len), l.entry_count);
}

test "Ledger reopen reconstructs the same merkle root" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root1: Hash = undefined;
    var count1: u64 = 0;
    {
        var l = try Ledger.open(io, tmp.dir, "reopen.ledger");
        defer l.close();
        _ = try l.append(.{ .event_type = .peer_joined, .entity_id = "peer-1", .payload = "a" });
        _ = try l.append(.{ .event_type = .guardian_flag, .entity_id = "g-1", .payload = "b" });
        _ = try l.append(.{ .event_type = .key_revoked, .actor_id = "actor", .payload = "c" });
        root1 = l.chain.root;
        count1 = l.entry_count;
    }

    var l2 = try Ledger.open(io, tmp.dir, "reopen.ledger");
    defer l2.close();
    try std.testing.expectEqual(count1, l2.entry_count);
    try std.testing.expect(merkle.hashEql(&root1, l2.merkleRoot()));

    const e4 = try l2.append(.{ .event_type = .peer_left, .entity_id = "peer-1" });
    try std.testing.expectEqual(@as(u64, 3), e4.seq);
    try std.testing.expect(merkle.hashEql(&root1, &e4.prev_hash));
}

test "Ledger reopen rejects a tampered entry hash" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var l = try Ledger.open(io, tmp.dir, "tamper.ledger");
        defer l.close();
        _ = try l.append(.{ .event_type = .kill_chain_start, .payload = "start" });
        _ = try l.append(.{ .event_type = .kill_chain_complete, .payload = "done" });
    }

    const file = try tmp.dir.openFile(io, "tamper.ledger", .{ .mode = .read_write });
    defer file.close(io);
    const size = try file.length(io);
    try std.testing.expect(size > 32);
    var hash_buf: [32]u8 = undefined;
    const n = try file.readPositionalAll(io, &hash_buf, size - 32);
    try std.testing.expectEqual(@as(usize, 32), n);
    hash_buf[0] ^= 0xFF;
    try file.writePositionalAll(io, &hash_buf, size - 32);
    try file.sync(io);

    try std.testing.expectError(LedgerError.TamperedLedger, Ledger.open(io, tmp.dir, "tamper.ledger"));
}

test "Ledger crash tail at EOF is truncated, history is kept" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root1: Hash = undefined;
    {
        var l = try Ledger.open(io, tmp.dir, "tail.ledger");
        defer l.close();
        _ = try l.append(.{ .event_type = .xp_granted, .payload = "keep-me" });
        root1 = l.chain.root;
    }

    {
        const file = try tmp.dir.openFile(io, "tail.ledger", .{ .mode = .read_write });
        defer file.close(io);
        const size = try file.length(io);
        try file.writePositionalAll(io, "CRASH", size);
        try file.sync(io);
    }

    var l2 = try Ledger.open(io, tmp.dir, "tail.ledger");
    defer l2.close();
    try std.testing.expectEqual(@as(u64, 1), l2.entry_count);
    try std.testing.expect(merkle.hashEql(&root1, l2.merkleRoot()));
}
