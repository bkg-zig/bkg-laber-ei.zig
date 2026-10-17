/// BKGDB — Write-Ahead-Log (WAL)
///
/// Jede Mutation landet zuerst im WAL, dann im VersionStore.
/// Bei Recovery: nur committed Transaktionen werden übernommen.
/// Incomplete Transactions (kein Commit-Entry) werden verworfen.
///
/// WAL Write-Entry (binär, little-endian):
///   entry_len:   u32  — Länge des Records (exkl. entry_len selbst)
///   txn_id:      u64
///   entry_type:  u8   — 0x01=Write, 0x02=Commit, 0x03=Abort, 0x04=Checkpoint
///   flags:       u8   — (nur Write) bit0 = delete
///   key_len:     u16  — (nur Write)
///   key:         [key_len]u8
///   data_len:    u16  — (nur Write)
///   data:        [data_len]u8
///   checksum:    u32  — CRC32 aller Felder NACH entry_len und VOR checksum
///
/// Für Commit/Abort/Checkpoint: flags/key/data entfallen.
/// Checksum-Fehler eines vollständigen Records sind FATAL (kein stilles Skip).
/// Ein unvollständiger Record am EOF ist ein Crash-Tail und wird ignoriert.
const std = @import("std");

// ── Typen ─────────────────────────────────────────────────────────────────

pub const EntryType = enum(u8) {
    write = 0x01,
    commit = 0x02,
    abort = 0x03,
    checkpoint = 0x04,
};

pub const MAX_KEY_LEN: u16 = 4096;
pub const WRITE_FLAG_DELETE: u8 = 0x01;

/// Minimaler Header eines WAL-Eintrags — immer vorhanden.
pub const EntryHeader = extern struct {
    txn_id: u64,
    entry_type: u8,

    comptime {
        if (@sizeOf(EntryHeader) != 9) @compileError("EntryHeader must be 9 bytes");
    }
};

/// Vollständiger WAL-Eintrag (in-Memory Darstellung).
pub const WalEntry = struct {
    txn_id: u64,
    entry_type: EntryType,
    flags: u8,
    key: []const u8,
    data: []const u8,
};

// ── WAL-Datei-Format-Größen ───────────────────────────────────────────────

const COMMIT_ENTRY_SIZE: usize = 4 + 8 + 1 + 4;
const WRITE_ENTRY_OVERHEAD: usize = 4 + 8 + 1 + 1 + 2 + 2 + 4;

// ── WalWriter ─────────────────────────────────────────────────────────────

/// Schreibt WAL-Einträge in eine Datei (append-only).
pub const WalWriter = struct {
    file: std.Io.File,
    io: std.Io,
    pos: u64,

    pub fn open(io: std.Io, dir: std.Io.Dir, path: []const u8) !WalWriter {
        const file = try dir.createFile(io, path, .{ .read = true, .truncate = false });
        const eof = file.length(io) catch 0;
        return WalWriter{ .file = file, .io = io, .pos = eof };
    }

    pub fn close(self: *WalWriter) void {
        self.file.close(self.io);
    }

    /// Schreibt einen Write-Eintrag (Key + Wert + Delete-Flag) in den WAL.
    pub fn appendWrite(self: *WalWriter, txn_id: u64, key: []const u8, data: []const u8, is_delete: bool) !void {
        if (key.len > MAX_KEY_LEN) return error.KeyTooLarge;
        if (data.len > 65535) return error.DataTooLarge;
        var buf: [WRITE_ENTRY_OVERHEAD + MAX_KEY_LEN + 65535]u8 = undefined;
        var offset: usize = 4;

        writeU64Le(buf[offset..], txn_id);
        offset += 8;
        buf[offset] = @intFromEnum(EntryType.write);
        offset += 1;
        buf[offset] = if (is_delete) WRITE_FLAG_DELETE else 0;
        offset += 1;
        const key_len: u16 = @intCast(key.len);
        writeU16Le(buf[offset..], key_len);
        offset += 2;
        @memcpy(buf[offset..][0..key.len], key);
        offset += key.len;
        const data_len: u16 = @intCast(data.len);
        writeU16Le(buf[offset..], data_len);
        offset += 2;
        @memcpy(buf[offset..][0..data.len], data);
        offset += data.len;

        const checksum = std.hash.Crc32.hash(buf[4..offset]);
        writeU32Le(buf[offset..], checksum);
        offset += 4;
        writeU32Le(buf[0..], @intCast(offset - 4));

        try self.file.writePositionalAll(self.io, buf[0..offset], self.pos);
        self.pos += offset;
    }

    pub fn appendCommit(self: *WalWriter, txn_id: u64) !void {
        try self.appendSimple(txn_id, .commit);
    }

    pub fn appendAbort(self: *WalWriter, txn_id: u64) !void {
        try self.appendSimple(txn_id, .abort);
    }

    pub fn appendCheckpoint(self: *WalWriter, txn_id: u64) !void {
        try self.appendSimple(txn_id, .checkpoint);
    }

    pub fn sync(self: *WalWriter) !void {
        try self.file.sync(self.io);
    }

    fn appendSimple(self: *WalWriter, txn_id: u64, entry_type: EntryType) !void {
        var buf: [COMMIT_ENTRY_SIZE]u8 = undefined;
        var offset: usize = 4;
        writeU64Le(buf[offset..], txn_id);
        offset += 8;
        buf[offset] = @intFromEnum(entry_type);
        offset += 1;
        const checksum = std.hash.Crc32.hash(buf[4..offset]);
        writeU32Le(buf[offset..], checksum);
        offset += 4;
        writeU32Le(buf[0..], @intCast(offset - 4));
        try self.file.writePositionalAll(self.io, buf[0..offset], self.pos);
        self.pos += offset;
    }
};

// ── WalReader / Recovery ──────────────────────────────────────────────────

pub const ReadResult = union(enum) {
    entry: ParsedEntry,
    eof,
    crash_tail,
    corrupt,
};

pub const ParsedEntry = struct {
    txn_id: u64,
    entry_type: EntryType,
    flags: u8,
    key_buf: [MAX_KEY_LEN]u8,
    key_len: u16,
    data_buf: [65535]u8,
    data_len: u16,

    pub fn data(self: *const ParsedEntry) []const u8 {
        return self.data_buf[0..self.data_len];
    }

    pub fn key(self: *const ParsedEntry) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    pub fn isDelete(self: *const ParsedEntry) bool {
        return self.flags & WRITE_FLAG_DELETE != 0;
    }
};

/// Liest WAL-Einträge sequenziell aus einer Datei.
pub const WalReader = struct {
    file: std.Io.File,
    io: std.Io,
    file_size: u64,
    /// Byte-Offset nach dem letzten vollständig verifizierten Eintrag.
    durable_end: u64 = 0,
    pos: u64 = 0,

    pub fn open(io: std.Io, dir: std.Io.Dir, path: []const u8) !WalReader {
        const file = try dir.openFile(io, path, .{});
        const size = file.length(io) catch 0;
        return WalReader{ .file = file, .io = io, .file_size = size };
    }

    pub fn close(self: *WalReader) void {
        self.file.close(self.io);
    }

    /// Crash-Tail (unvollständiger letzter Record am EOF) → `.crash_tail`.
    /// Checksum- oder Strukturfehler eines vollständigen Records → `.corrupt`.
    pub fn readNext(self: *WalReader, allocator: std.mem.Allocator) !ReadResult {
        _ = allocator;
        if (self.pos >= self.file_size) return .eof;
        const start = self.pos;
        const remaining = self.file_size - start;
        if (remaining < 4) return .crash_tail;

        var len_buf: [4]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, &len_buf, start);
        if (n != 4) return .crash_tail;

        const payload_len = readU32Le(&len_buf);
        if (payload_len < 13) return .corrupt;
        if (payload_len > 8 + 1 + 1 + 2 + @as(u32, MAX_KEY_LEN) + 2 + 65535 + 4) return .corrupt;
        if (start + 4 + payload_len > self.file_size) return .crash_tail;

        var payload: [8 + 1 + 1 + 2 + @as(usize, MAX_KEY_LEN) + 2 + 65535 + 4]u8 = undefined;
        const pm = try self.file.readPositionalAll(self.io, payload[0..payload_len], start + 4);
        if (pm != payload_len) return .crash_tail;

        const checksum_offset = payload_len - 4;
        const stored_checksum = readU32Le(payload[checksum_offset..]);
        const computed_checksum = std.hash.Crc32.hash(payload[0..checksum_offset]);
        if (stored_checksum != computed_checksum) return .corrupt;

        var off: usize = 0;
        const txn_id = readU64Le(payload[off..]);
        off += 8;
        const entry_type_raw = payload[off];
        off += 1;
        const entry_type: EntryType = std.enums.fromInt(EntryType, entry_type_raw) orelse return .corrupt;

        var result = ParsedEntry{
            .txn_id = txn_id,
            .entry_type = entry_type,
            .flags = 0,
            .key_buf = [_]u8{0} ** MAX_KEY_LEN,
            .key_len = 0,
            .data_buf = [_]u8{0} ** 65535,
            .data_len = 0,
        };

        if (entry_type == .write) {
            if (checksum_offset < off + 1 + 2) return .corrupt;
            result.flags = payload[off];
            off += 1;
            result.key_len = readU16Le(payload[off..]);
            off += 2;
            if (result.key_len > MAX_KEY_LEN) return .corrupt;
            if (off + result.key_len + 2 > checksum_offset) return .corrupt;
            @memcpy(result.key_buf[0..result.key_len], payload[off..][0..result.key_len]);
            off += result.key_len;
            result.data_len = readU16Le(payload[off..]);
            off += 2;
            if (off + result.data_len > checksum_offset) return .corrupt;
            @memcpy(result.data_buf[0..result.data_len], payload[off..][0..result.data_len]);
        } else if (off != checksum_offset) {
            return .corrupt;
        }

        self.pos = start + 4 + payload_len;
        self.durable_end = self.pos;
        return .{ .entry = result };
    }
};

// ── Hilfsfunktionen ───────────────────────────────────────────────────────

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

fn writeU16Le(buf: []u8, v: u16) void {
    buf[0] = @truncate(v);
    buf[1] = @truncate(v >> 8);
}

fn readU32Le(buf: []const u8) u32 {
    return @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) | (@as(u32, buf[2]) << 16) | (@as(u32, buf[3]) << 24);
}

fn readU64Le(buf: []const u8) u64 {
    return @as(u64, buf[0]) | (@as(u64, buf[1]) << 8) | (@as(u64, buf[2]) << 16) |
        (@as(u64, buf[3]) << 24) | (@as(u64, buf[4]) << 32) | (@as(u64, buf[5]) << 40) |
        (@as(u64, buf[6]) << 48) | (@as(u64, buf[7]) << 56);
}

fn readU16Le(buf: []const u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "WAL write and read back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var w = try WalWriter.open(io, tmp.dir, "test.wal");
        defer w.close();
        try w.appendWrite(1, "user:1", "hello wal", false);
        try w.appendCommit(1);
    }

    var r = try WalReader.open(io, tmp.dir, "test.wal");
    defer r.close();

    const e1 = try r.readNext(std.testing.allocator);
    try std.testing.expect(e1 == .entry);
    try std.testing.expectEqual(@as(u64, 1), e1.entry.txn_id);
    try std.testing.expectEqual(EntryType.write, e1.entry.entry_type);
    try std.testing.expectEqualStrings("user:1", e1.entry.key());
    try std.testing.expectEqualStrings("hello wal", e1.entry.data());
    try std.testing.expect(!e1.entry.isDelete());

    const e2 = try r.readNext(std.testing.allocator);
    try std.testing.expect(e2 == .entry);
    try std.testing.expectEqual(EntryType.commit, e2.entry.entry_type);
    try std.testing.expectEqual(@as(u64, 1), e2.entry.txn_id);

    const e3 = try r.readNext(std.testing.allocator);
    try std.testing.expect(e3 == .eof);
}

test "WAL abort entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var w = try WalWriter.open(io, tmp.dir, "abort.wal");
        defer w.close();
        try w.appendAbort(7);
    }

    var r = try WalReader.open(io, tmp.dir, "abort.wal");
    defer r.close();
    const e = try r.readNext(std.testing.allocator);
    try std.testing.expect(e == .entry);
    try std.testing.expectEqual(EntryType.abort, e.entry.entry_type);
    try std.testing.expectEqual(@as(u64, 7), e.entry.txn_id);
}

test "WAL checkpoint entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var w = try WalWriter.open(io, tmp.dir, "ckpt.wal");
        defer w.close();
        try w.appendCheckpoint(99);
    }

    var r = try WalReader.open(io, tmp.dir, "ckpt.wal");
    defer r.close();
    const e = try r.readNext(std.testing.allocator);
    try std.testing.expect(e == .entry);
    try std.testing.expectEqual(EntryType.checkpoint, e.entry.entry_type);
}

test "WAL multiple transactions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var w = try WalWriter.open(io, tmp.dir, "multi.wal");
        defer w.close();
        try w.appendWrite(10, "k10", "txn10 data", false);
        try w.appendCommit(10);
        try w.appendWrite(11, "k11", "txn11 data", false);
        try w.appendAbort(11);
        try w.appendWrite(12, "k12", "txn12 data", false);
        try w.appendCommit(12);
    }

    var r = try WalReader.open(io, tmp.dir, "multi.wal");
    defer r.close();

    var committed: u32 = 0;
    var aborted: u32 = 0;
    while (true) {
        const e = try r.readNext(std.testing.allocator);
        switch (e) {
            .eof, .crash_tail => break,
            .corrupt => return error.Corrupt,
            .entry => |en| {
                if (en.entry_type == .commit) committed += 1;
                if (en.entry_type == .abort) aborted += 1;
            },
        }
    }
    try std.testing.expectEqual(@as(u32, 2), committed);
    try std.testing.expectEqual(@as(u32, 1), aborted);
}

test "WAL checksum mismatch is corrupt, not skipped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var w = try WalWriter.open(io, tmp.dir, "tamper.wal");
        defer w.close();
        try w.appendWrite(1, "k", "v", false);
        try w.appendCommit(1);
    }

    const file = try tmp.dir.openFile(io, "tamper.wal", .{ .mode = .read_write });
    defer file.close(io);
    var b: [1]u8 = undefined;
    _ = try file.readPositionalAll(io, &b, 8);
    b[0] ^= 0xFF;
    try file.writePositionalAll(io, &b, 8);
    try file.sync(io);

    var r = try WalReader.open(io, tmp.dir, "tamper.wal");
    defer r.close();
    const e = try r.readNext(std.testing.allocator);
    try std.testing.expect(e == .corrupt);
}

test "WAL crash tail at EOF is crash_tail, not corrupt" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var w = try WalWriter.open(io, tmp.dir, "tail.wal");
        defer w.close();
        try w.appendWrite(1, "keep", "me", false);
        try w.appendCommit(1);
        try w.sync();
    }

    {
        const file = try tmp.dir.openFile(io, "tail.wal", .{ .mode = .read_write });
        defer file.close(io);
        const size = try file.length(io);
        try file.writePositionalAll(io, "XXX", size);
        try file.sync(io);
    }

    var r = try WalReader.open(io, tmp.dir, "tail.wal");
    defer r.close();
    const e1 = try r.readNext(std.testing.allocator);
    try std.testing.expect(e1 == .entry);
    const e2 = try r.readNext(std.testing.allocator);
    try std.testing.expect(e2 == .entry);
    const e3 = try r.readNext(std.testing.allocator);
    try std.testing.expect(e3 == .crash_tail or e3 == .eof);
}
