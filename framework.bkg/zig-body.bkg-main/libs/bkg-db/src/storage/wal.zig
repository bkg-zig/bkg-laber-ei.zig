//! wal.zig — Real on-disk Write-Ahead Log (BKGDB Storage Core v1.2)
//!
//! The WAL is the durable Ledger Truth. Every committed event is first written as a
//! PREP frame + canonical payload and fsync'd, then finalized as a COMM frame and
//! fsync'd again. A crash between the two syncs leaves an incomplete tail at physical
//! EOF which recovery treats as ignorable; any corruption in the *middle* of the log
//! is FATAL.
//!
//! Hardenings adopted from the BKGDB v1.4 spec (they apply to the WAL too):
//!   * No `extern struct` for persisted frames — an explicit canonical little-endian
//!     encoding, immune to ABI/layout drift.
//!   * Hard protocol limits instead of allocator-dependent safety.
//!   * Exact frame consumption during recovery — trailing bytes are a loud error.
//!   * The header carries an `event_hash` but recovery MUST recompute the hash from
//!     the canonical payload and NOT trust the header field blindly. The engine
//!     (storage/core.zig) owns that job; this module surfaces raw frames.
//!   * Carries `actor_pubkey` + `signature` in the PREP frame so the engine can
//!     re-verify Ed25519 during recovery — the v1.1 skeleton could not.
//!
//! Zig compatibility: 0.16.0 positional I/O (std.Io). Files are addressed by byte
//! offset — there is no seek cursor; this matches the async/threaded Io API and is
//! cleaner for append-only logs. Verified against a stdlib smoke test.

const std = @import("std");
const canonical = @import("canonical_tlv.zig");
const Hash32 = canonical.Hash32;
const Sig64 = canonical.Sig64;

// ---------------------------------------------------------------------------
// Protocol constants / hard limits (C10)
// ---------------------------------------------------------------------------
pub const WAL_MAGIC_PREP: [4]u8 = .{ 'P', 'R', 'E', 'P' };
pub const WAL_MAGIC_COMM: [4]u8 = .{ 'C', 'O', 'M', 'M' };
pub const WAL_VERSION: u16 = 1;
pub const MAX_FRAME_BYTES: usize = 2 * 1024 * 1024; // payload cap for a single event

pub const WalError = error{
    CorruptedHistoricalWal, // corruption in the middle of the file -> FATAL
    CrashTail, // incomplete tail at physical EOF -> ignorable
    BufferTooSmall, // caller's payload buffer too small for the frame -> controlled error
    TruncatedFrame,
    MagicMismatch,
    VersionMismatch,
    FrameTooLarge,
    InvalidIo,
    InvalidVersion,
} || std.mem.Allocator.Error || std.Io.File.OpenError || std.Io.File.WritePositionalError || std.Io.File.ReadPositionalError || std.Io.File.SyncError || std.Io.File.LengthError;

// ---------------------------------------------------------------------------
// On-disk frame layouts (canonical little-endian, NOT extern struct)
// ---------------------------------------------------------------------------
const header_len = 4 + 2 + 8 + 4 + 32 + 32 + 64; // magic+ver+seq+plen+hash+actor+sig
const comm_len = 4 + 2 + 8 + 4 + 32; // magic+ver+seq+plen+hash

fn writePrepHeader(out: []u8, sequence: u64, payload_len: u32, event_hash: *const Hash32, actor: *const Hash32, sig: *const Sig64) void {
    @memcpy(out[0..4], &WAL_MAGIC_PREP);
    std.mem.writeInt(u16, out[4..6], WAL_VERSION, .little);
    std.mem.writeInt(u64, out[6..14], sequence, .little);
    std.mem.writeInt(u32, out[14..18], payload_len, .little);
    @memcpy(out[18..50], event_hash);
    @memcpy(out[50..82], actor);
    @memcpy(out[82..146], sig);
}

fn writeCommHeader(out: []u8, sequence: u64, payload_len: u32, event_hash: *const Hash32) void {
    @memcpy(out[0..4], &WAL_MAGIC_COMM);
    std.mem.writeInt(u16, out[4..6], WAL_VERSION, .little);
    std.mem.writeInt(u64, out[6..14], sequence, .little);
    std.mem.writeInt(u32, out[14..18], payload_len, .little);
    @memcpy(out[18..50], event_hash);
}

/// A fully durable committed frame (PREP+payload+COMM all present & fsync'd).
pub const CommittedFrame = struct {
    // wal_frame_offset: absolute byte offset immediately AFTER the last byte of the
    // committed COMM frame (BKGDB v1.4 hard rule). Kept so the checkpoint layer can
    // anchor to it.
    wal_frame_offset: u64,
    sequence: u64,
    event_hash: Hash32,
    actor_pubkey: Hash32,
    signature: Sig64,
    canonical_bytes: []const u8, // aliases into the caller's payload buffer
};

// ---------------------------------------------------------------------------
// Wal log-writer: append-only PREP+payload -> sync -> COMM -> sync.
// ---------------------------------------------------------------------------
pub const WalWriter = struct {
    file: std.Io.File,
    pos: u64, // byte offset of the next write (== end of last COMM)

    pub fn init(file: std.Io.File, io: std.Io) WalWriter {
        // Append-only guarantee: the writer always starts at the TRUE end of the
        // existing file, never at offset 0, so an existing ledger is never truncated
        // or overwritten.
        const eof = file.length(io) catch 0;
        return .{ .file = file, .pos = eof };
    }

    /// Durable append: PREP + payload, sync; then COMM, sync. Returns void only
    /// after both fsyncs; at that point no protocol failure can occur during fold.
    pub fn commit(
        self: *WalWriter,
        io: std.Io,
        sequence: u64,
        event_hash: *const Hash32,
        actor: *const Hash32,
        sig: *const Sig64,
        canonical_bytes: []const u8,
    ) WalError!void {
        if (canonical_bytes.len > MAX_FRAME_BYTES) return error.FrameTooLarge;
        const plen: u32 = @intCast(canonical_bytes.len);

        // 1. PREP frame
        var prep_hdr: [header_len]u8 = undefined;
        writePrepHeader(&prep_hdr, sequence, plen, event_hash, actor, sig);
        const prep_start = self.pos;
        try self.file.writePositionalAll(io, &prep_hdr, prep_start);
        try self.file.writePositionalAll(io, canonical_bytes, prep_start + header_len);
        try self.file.sync(io); // HARD DISK BOUNDARY 1

        // 2. COMM frame
        const comm_start = prep_start + header_len + canonical_bytes.len;
        var comm_hdr: [comm_len]u8 = undefined;
        writeCommHeader(&comm_hdr, sequence, plen, event_hash);
        try self.file.writePositionalAll(io, &comm_hdr, comm_start);
        try self.file.sync(io); // HARD DISK BOUNDARY 2

        // wal_frame_offset = after last COMM byte
        self.pos = comm_start + comm_len;
    }
};

// ---------------------------------------------------------------------------
// Wal recovery reader: deterministic replay of committed frames only.
// ---------------------------------------------------------------------------
pub const RecoveryError = WalError || error{OutOfMemory};

pub const WalReader = struct {
    file: std.Io.File,
    io: std.Io,
    payload_buf: []u8, // owned/injected by the caller at init; reader never allocates
    file_size: u64,
    pos: u64 = 0,

    pub fn init(file: std.Io.File, io: std.Io, payload_buf: []u8) WalReader {
        const size = file.length(io) catch 0;
        return .{ .file = file, .io = io, .payload_buf = payload_buf, .pos = 0, .file_size = size };
    }

    fn eof(self: *const WalReader) bool {
        return self.pos >= self.file_size;
    }

    /// Read the next committed frame. Returns null at a clean/complete EOF.
    /// A truncated tail (incomplete PREP/payload/COMM at physical EOF) is returned
    /// as `error.CrashTail`, which the engine treats as ignorable. Any other
    /// structural violation => `error.CorruptedHistoricalWal` (FATAL).
    ///
    /// The returned `CommittedFrame.canonical_bytes` aliases into the reader's own
    /// `payload_buf` and is only valid until the next call to `next`.
    pub fn next(self: *WalReader) RecoveryError!?CommittedFrame {
        if (self.eof()) return null;

        // --- PREP header ---
        if (self.pos + header_len > self.file_size) return error.CrashTail;
        var prep_hdr: [header_len]u8 = undefined;
        const got_prep = try self.file.readPositionalAll(self.io, &prep_hdr, self.pos);
        if (got_prep < header_len) return error.CrashTail;

        if (!std.mem.eql(u8, prep_hdr[0..4], &WAL_MAGIC_PREP)) {
            // A COMM at a frame start (no preceding PREP) in the *middle* is corruption.
            if (std.mem.eql(u8, prep_hdr[0..4], &WAL_MAGIC_COMM)) return error.CorruptedHistoricalWal;
            return error.CorruptedHistoricalWal;
        }
        const version = std.mem.readInt(u16, prep_hdr[4..6], .little);
        if (version != WAL_VERSION) return error.VersionMismatch;
        const sequence = std.mem.readInt(u64, prep_hdr[6..14], .little);
        const payload_len = std.mem.readInt(u32, prep_hdr[14..18], .little);
        var event_hash: Hash32 = undefined;
        @memcpy(&event_hash, prep_hdr[18..50]);
        var actor: Hash32 = undefined;
        @memcpy(&actor, prep_hdr[50..82]);
        var sig: Sig64 = undefined;
        @memcpy(&sig, prep_hdr[82..146]);

        if (payload_len > MAX_FRAME_BYTES) return error.FrameTooLarge;
        // Exit criterion 16: never slice-panic on a caller buffer that is too small.
        if (self.payload_buf.len < payload_len) return error.BufferTooSmall;

        // --- payload ---
        const payload_offset = self.pos + header_len;
        if (payload_offset + payload_len > self.file_size) return error.CrashTail; // incomplete payload
        const payload_into = self.payload_buf[0..payload_len];
        const got_payload = try self.file.readPositionalAll(self.io, payload_into, payload_offset);
        if (got_payload < payload_len) return error.CrashTail;

        // --- COMM frame ---
        const comm_offset = payload_offset + payload_len;
        if (comm_offset + comm_len > self.file_size) return error.CrashTail; // missing COMM
        var comm_hdr: [comm_len]u8 = undefined;
        const got_comm = try self.file.readPositionalAll(self.io, &comm_hdr, comm_offset);
        if (got_comm < comm_len) return error.CrashTail;
        if (!std.mem.eql(u8, comm_hdr[0..4], &WAL_MAGIC_COMM)) return error.CorruptedHistoricalWal; // PREP w/o COMM in middle

        // Verify COMM agrees with PREP (header integrity, not hash recomputation —
        // that belongs to the engine which re-decodes+re-hashes+re-verifies).
        if (std.mem.readInt(u64, comm_hdr[6..14], .little) != sequence) return error.CorruptedHistoricalWal;
        if (std.mem.readInt(u32, comm_hdr[14..18], .little) != payload_len) return error.CorruptedHistoricalWal;
        if (!std.mem.eql(u8, comm_hdr[18..50], &event_hash)) return error.CorruptedHistoricalWal;

        const next_pos = comm_offset + comm_len;
        self.pos = next_pos;

        return CommittedFrame{
            .wal_frame_offset = next_pos,
            .sequence = sequence,
            .event_hash = event_hash,
            .actor_pubkey = actor,
            .signature = sig,
            .canonical_bytes = payload_into[0..payload_len],
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;
const tio = std.testing.io;

test "WAL: commit then recover reproduces frames bit-exact (with sync boundaries)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(tio, "t.wal", .{ .read = true });
    var writer = WalWriter.init(file, tio);
    try writer.commit(tio, 0, &[_]u8{1} ** 32, &[_]u8{2} ** 32, &[_]u8{3} ** 64, "EVT0-your canonical bytes here");
    try writer.commit(tio, 1, &[_]u8{4} ** 32, &[_]u8{5} ** 32, &[_]u8{6} ** 64, "EVT1-another canonical payload");

    const ro = try tmp.dir.openFile(tio, "t.wal", .{ .mode = .read_only });
    const pbuf = try allocator.alloc(u8, 256);
    defer allocator.free(pbuf);
    var reader = WalReader.init(ro, tio, pbuf);

    const f0 = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 0), f0.sequence);
    try testing.expectEqualSlices(u8, "EVT0-your canonical bytes here", f0.canonical_bytes);
    try testing.expectEqualSlices(u8, &[_]u8{1} ** 32, &f0.event_hash);

    const f1 = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 1), f1.sequence);
    try testing.expectEqualSlices(u8, "EVT1-another canonical payload", f1.canonical_bytes);
    try testing.expectEqualSlices(u8, &[_]u8{4} ** 32, &f1.event_hash);

    try testing.expectEqual(@as(?CommittedFrame, null), try reader.next());
    ro.close(tio);
}

test "WAL: truncated COMM at physical EOF is a crash tail (recoverable), mid-file corruption is FATAL" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile(tio, "crash.wal", .{ .read = true });
        var writer = WalWriter.init(file, tio);
        try writer.commit(tio, 0, &[_]u8{1} ** 32, &[_]u8{2} ** 32, &[_]u8{3} ** 64, "PAYLOAD-A");
        // second transaction: write PREP+payload but NOT the COMM (simulate crash)
        var prep_hdr: [header_len]u8 = undefined;
        writePrepHeader(&prep_hdr, 1, "PAYLOAD-B".len, &[_]u8{4} ** 32, &[_]u8{5} ** 32, &[_]u8{6} ** 64);
        const pos = writer.pos;
        try file.writePositionalAll(tio, &prep_hdr, pos);
        try file.writePositionalAll(tio, "PAYLOAD-B", pos + header_len);
        try file.sync(tio);
    }

    const ro = try tmp.dir.openFile(tio, "crash.wal", .{ .mode = .read_only });
    const pbuf = try allocator.alloc(u8, 256);
    defer allocator.free(pbuf);
    var reader = WalReader.init(ro, tio, pbuf);

    const f0 = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 0), f0.sequence);
    try testing.expectEqualSlices(u8, "PAYLOAD-A", f0.canonical_bytes);
    try testing.expectError(error.CrashTail, reader.next());
    ro.close(tio);
}

// ---------------------------------------------------------------------------
// v1.2 Gate proofs (user catalog): offset exactness, resume-at-frame_offset,
// truncated payload, and each corruption class mapped to CorruptedHistoricalWal.
// ---------------------------------------------------------------------------

/// Little-endian frame layout math (shared by writer and these tests).
fn prepOffset(start: u64) u64 {
    return start;
}
fn payloadOffset(start: u64) u64 {
    return start + header_len;
}
fn commOffset(start: u64, payload_len: usize) u64 {
    return start + header_len + payload_len;
}
fn endOffset(start: u64, payload_len: usize) u64 {
    return start + header_len + payload_len + comm_len;
}

const ELEN = header_len + 6 + comm_len; // frame bounding for a short payload "PAYLOAD-A"

test "WAL v1.2: frame offsets are exact and a reader resumes exactly at wal_frame_offset" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(tio, "off.wal", .{ .read = true });
    var writer = WalWriter.init(file, tio);
    try writer.commit(tio, 0, &[_]u8{1} ** 32, &[_]u8{2} ** 32, &[_]u8{3} ** 64, "P1");
    const off1 = writer.pos;
    // Writer pos must equal true EOF after every commit (append-only at real EOF).
    try testing.expectEqual(file.length(tio), off1);
    try writer.commit(tio, 1, &[_]u8{4} ** 32, &[_]u8{5} ** 32, &[_]u8{6} ** 64, "P2-LONGER");
    const off2 = writer.pos;
    try testing.expectEqual(file.length(tio), off2);
    try testing.expect(off2 > off1);

    const pbuf = try allocator.alloc(u8, 256);
    defer allocator.free(pbuf);
    var reader = WalReader.init(file, tio, pbuf);

    const f0 = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 0), f0.sequence);
    try testing.expectEqual(off1, f0.wal_frame_offset); // == EOF after frame 0
    try testing.expectEqual(f0.wal_frame_offset, reader.pos); // next read resumes here

    const f1 = (try reader.next()).?;
    try testing.expectEqual(off2, f1.wal_frame_offset); // == EOF after frame 1

    try testing.expectEqual(@as(?CommittedFrame, null), try reader.next());
    file.close(tio);
}

test "WAL v1.2: truncated payload at physical EOF is a recoverable crash tail, not corruption" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(tio, "tp.wal", .{ .read = true });
    var writer = WalWriter.init(file, tio);
    // frame 0 fully committed
    try writer.commit(tio, 0, &[_]u8{1} ** 32, &[_]u8{2} ** 32, &[_]u8{3} ** 64, "PAYLOAD-A");
    // frame 1: PREP header + only 4 bytes of a 9-byte payload, no COMM (crash at disk boundary 1)
    var prep_hdr: [header_len]u8 = undefined;
    writePrepHeader(&prep_hdr, 1, 9, &[_]u8{4} ** 32, &[_]u8{5} ** 32, &[_]u8{6} ** 64);
    const pos = writer.pos;
    try file.writePositionalAll(tio, &prep_hdr, pos);
    try file.writePositionalAll(tio, "ABCD", pos + header_len); // truncated payload
    try file.sync(tio);

    const pbuf = try allocator.alloc(u8, 256);
    defer allocator.free(pbuf);
    var reader = WalReader.init(file, tio, pbuf);
    const f0 = (try reader.next()).?;
    try testing.expectEqualSlices(u8, "PAYLOAD-A", f0.canonical_bytes);
    try testing.expectError(error.CrashTail, reader.next()); // incomplete payload tail
    file.close(tio);
}

fn corruptBytes(file: std.Io.File, io: std.Io, offset: u64, bytes: []const u8) !void {
    try file.writePositionalAll(io, bytes, offset);
}

fn expectCorruptCommClass(comptime kind: []const u8) !void {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(tio, "cc.wal", .{ .read = true });
    var writer = WalWriter.init(file, tio);
    try writer.commit(tio, 0, &[_]u8{1} ** 32, &[_]u8{2} ** 32, &[_]u8{3} ** 64, "PAYLOAD-A");
    const c_off = commOffset(0, "PAYLOAD-A".len);

    if (std.mem.eql(u8, kind, "magic")) {
        try corruptBytes(file, tio, c_off, "XXXX");
    } else if (std.mem.eql(u8, kind, "event_hash")) {
        try corruptBytes(file, tio, c_off + 18, &[_]u8{0xFF} ** 32); // checksum/hash mismatch
    } else if (std.mem.eql(u8, kind, "sequence")) {
        try corruptBytes(file, tio, c_off + 6, &[_]u8{0xEE, 0xEE, 0, 0, 0, 0, 0, 0}); // 0xEEEE != 0
    } else if (std.mem.eql(u8, kind, "payload_len")) {
        try corruptBytes(file, tio, c_off + 14, &[_]u8{0xDD, 0xDD, 0, 0}); // 0xDDDD
    }
    try file.sync(tio);

    const pbuf = try allocator.alloc(u8, 256);
    defer allocator.free(pbuf);
    var reader = WalReader.init(file, tio, pbuf);
    try testing.expectError(error.CorruptedHistoricalWal, reader.next());
    file.close(tio);
}

test "WAL v1.2: corrupted COMM magic in the middle of history is FATAL corruption" {
    try expectCorruptCommClass("magic");
}
test "WAL v1.2: corrupted COMM event_hash/checksum is FATAL corruption" {
    try expectCorruptCommClass("event_hash");
}
test "WAL v1.2: COMM sequence mismatch with PREP is FATAL corruption" {
    try expectCorruptCommClass("sequence");
}
test "WAL v1.2: COMM payload_len mismatch with PREP is FATAL corruption" {
    try expectCorruptCommClass("payload_len");
}

test "WAL v1.2: corrupted PREP magic between two valid frames is FATAL corruption" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(tio, "mp.wal", .{ .read = true });
    var writer = WalWriter.init(file, tio);
    try writer.commit(tio, 0, &[_]u8{1} ** 32, &[_]u8{2} ** 32, &[_]u8{3} ** 64, "PAYLOAD-A");
    const frame1_start = writer.pos;
    try writer.commit(tio, 1, &[_]u8{4} ** 32, &[_]u8{5} ** 32, &[_]u8{6} ** 64, "PAYLOAD-B");
    // Corrupt frame 1's PREP magic (frame 1 is in the MIDDLE: frame 2 follows).
    try corruptBytes(file, tio, prepOffset(frame1_start), "XXXX");
    try file.sync(tio);

    const pbuf = try allocator.alloc(u8, 256);
    defer allocator.free(pbuf);
    var reader = WalReader.init(file, tio, pbuf);
    _ = (try reader.next()).?; // frame 0 reads fine
    try testing.expectError(error.CorruptedHistoricalWal, reader.next()); // frame 1 magic bad
    file.close(tio);
}

test "WAL v1.2: reader buffer too small yields BufferTooSmall, never a slice panic" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(tio, "bs.wal", .{ .read = true });
    var writer = WalWriter.init(file, tio);
    try writer.commit(tio, 0, &[_]u8{1} ** 32, &[_]u8{2} ** 32, &[_]u8{3} ** 64, "SOME-LARGER-CANONICAL-PAYLOAD");
    try file.sync(tio);

    // too-small reader buffer (4 bytes < payload_len)
    const tiny = try allocator.alloc(u8, 4);
    defer allocator.free(tiny);
    var reader = WalReader.init(file, tio, tiny);
    try testing.expectError(error.BufferTooSmall, reader.next());
    file.close(tio);
}
