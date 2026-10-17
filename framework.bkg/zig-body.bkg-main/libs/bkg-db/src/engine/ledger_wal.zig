/// BKGDB — LedgerWal: Crash-resistenter WAL für LedgerEventEnvelopes
///
/// Storage Protocol v1 — 2026-09-01
///
/// Dieses Modul ist die persistenz-schicht ausschließlich für Protocol-Events
/// (LedgerEventEnvelope). Es ist strikt von der Seiten-basierten storage.zig
/// / wal.zig getrennt: Jene verwalten Mutable State (MVCC), dieser WAL
/// verwaltet den Immutable Ledger (append-only, kryptografisch verriegelt).
///
/// Trennlinie:
///   WAL   → Transport / Durability (crash-resistent, torn-write-detection)
///   Ledger → Wahrheit (Immutable, content-addressed)
///   Cache  → Materialized View (nie auf Disk als kanonischer State)
///
/// Frame-Format (little-endian, binär-stabil):
///
///   magic:          [4]u8   = "BKG1"
///   frame_len:      u32     = Länge des TLV-Payload in Bytes
///   checksum:       [32]u8  = SHA256(magic || frame_len_le4 || payload)
///   payload:        [frame_len]u8  = TLV-kodiertes LedgerEventEnvelope
///
/// Torn-Write-Erkennung:
///   Wenn magic fehlt, frame_len inkonsistent oder checksum nicht passt
///   → TornWrite-Fehler → Recovery stoppt hart (kein Best-Effort).
///
/// TLV-Encoding (Canonical — deterministisch, binär-stabil):
///
///   Tag  1 (u8)   = sequence        (u64, 8 Bytes LE)
///   Tag  2 (u8)   = prev_event_hash ([32]u8)
///   Tag  3 (u8)   = event_hash      ([32]u8)
///   Tag  4 (u8)   = actor_pubkey    ([32]u8)
///   Tag  5 (u8)   = signature       ([64]u8)
///   Tag  6 (u8)   = payload_tag     (u16 LE — EventType)
///   Tag  7 (u8)   = payload_bytes   ([N]u8 — payload-typ-spezifisch)
///
/// Felder werden immer in dieser Reihenfolge (aufsteigend nach Tag) geschrieben.
/// Unbekannte Tags beim Lesen werden übersprungen (Vorwärtskompatibilität).
///
/// Canonical Encoding Invariante:
///   HashMaps und Pointer-Adressen kommen NIEMALS in den Bytestream.
///   Nur deterministische, typisierte Felder — in fester Reihenfolge.
const std = @import("std");
const ledger_mod = @import("../protocol/ledger.zig");
const state_mod  = @import("../protocol/state.zig");
const events_mod = @import("../protocol/events.zig");

pub const Hash               = ledger_mod.Hash;
pub const LedgerEventEnvelope = ledger_mod.LedgerEventEnvelope;
pub const ZERO_HASH          = ledger_mod.ZERO_HASH;

// ── Frame-Konstanten ──────────────────────────────────────────────────────

pub const WAL_MAGIC: [4]u8 = .{ 'B', 'K', 'G', '1' };

/// Overhead pro Frame: magic(4) + frame_len(4) + checksum(32) = 40 Bytes
pub const FRAME_HEADER_SIZE: usize = 4 + 4 + 32;

/// Maximale Payload-Größe pro Frame (Sanity-Limit).
pub const MAX_PAYLOAD_SIZE: usize = 4096;

// ── TLV-Tags ─────────────────────────────────────────────────────────────

const TAG_SEQUENCE:      u8 = 1;
const TAG_PREV_HASH:     u8 = 2;
const TAG_EVENT_HASH:    u8 = 3;
const TAG_ACTOR_PUBKEY:  u8 = 4;
const TAG_SIGNATURE:     u8 = 5;
const TAG_PAYLOAD_TYPE:  u8 = 6;
const TAG_PAYLOAD_BYTES: u8 = 7;

// ── Fehler ────────────────────────────────────────────────────────────────

pub const LedgerWalError = error{
    /// Magic fehlt oder ist falsch — Frame beginnt nicht mit "BKG1".
    InvalidMagic,
    /// Checksumme stimmt nicht — torn write oder Disk-Korruption.
    TornWrite,
    /// Frame-Länge überschreitet MAX_PAYLOAD_SIZE oder ist 0.
    InvalidFrameLength,
    /// TLV-Daten sind inkonsistent oder abgeschnitten.
    MalformedPayload,
    /// Ein Pflicht-Feld fehlt im dekodierten Envelope.
    MissingField,
    /// I/O Fehler beim Lesen/Schreiben.
    IoError,
    OutOfMemory,
};

// ── Canonical TLV Encoding ────────────────────────────────────────────────

/// Schreibt ein u8-TLV-Feld: tag(1) + len(2 LE) + value.
fn writeTlvField(buf: []u8, off: *usize, tag: u8, value: []const u8) void {
    buf[off.*] = tag;
    off.* += 1;
    const len: u16 = @intCast(value.len);
    std.mem.writeInt(u16, buf[off.*..][0..2], len, .little);
    off.* += 2;
    @memcpy(buf[off.*..][0..value.len], value);
    off.* += value.len;
}

/// Kanonische TLV-Serialisierung eines LedgerEventEnvelope.
///
/// Deterministisch: gleicher Envelope → gleicher Bytestream.
/// HashMaps, Pointer und Reihenfolge-Artefakte sind ausgeschlossen.
///
/// Gibt die Anzahl der geschriebenen Bytes zurück.
pub fn encodeEnvelope(env: *const LedgerEventEnvelope, buf: []u8) LedgerWalError!usize {
    if (buf.len < MAX_PAYLOAD_SIZE) return LedgerWalError.MalformedPayload;
    var off: usize = 0;

    // Tag 1: sequence (u64 LE)
    var seq_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_buf, env.sequence, .little);
    writeTlvField(buf, &off, TAG_SEQUENCE, &seq_buf);

    // Tag 2: prev_event_hash
    writeTlvField(buf, &off, TAG_PREV_HASH, &env.prev_event_hash);

    // Tag 3: event_hash
    writeTlvField(buf, &off, TAG_EVENT_HASH, &env.event_hash);

    // Tag 4: actor_pubkey
    writeTlvField(buf, &off, TAG_ACTOR_PUBKEY, &env.actor_pubkey);

    // Tag 5: signature
    writeTlvField(buf, &off, TAG_SIGNATURE, &env.signature);

    // Tag 6: payload type (u16 LE)
    var type_buf: [2]u8 = undefined;
    const payload_tag: u16 = @intFromEnum(std.meta.activeTag(env.payload));
    std.mem.writeInt(u16, &type_buf, payload_tag, .little);
    writeTlvField(buf, &off, TAG_PAYLOAD_TYPE, &type_buf);

    // Tag 7: payload bytes (payload-typ-spezifisch)
    // Scratch muss getrennt von buf liegen — sonst alias-Crash in @memcpy.
    var payload_scratch: [MAX_PAYLOAD_SIZE]u8 = undefined;
    const payload_bytes = try encodePayload(&env.payload, &payload_scratch);
    writeTlvField(buf, &off, TAG_PAYLOAD_BYTES, payload_bytes);

    return off;
}

/// Serialisiert den Payload-Union in einen Bytestream.
/// Gibt einen Slice auf `scratch` zurück (bereits beschrieben).
fn encodePayload(payload: *const ledger_mod.EventPayload, scratch: []u8) LedgerWalError![]const u8 {
    var off: usize = 0;

    switch (payload.*) {
        .soul_anchored => |h| {
            @memcpy(scratch[0..32], &h);
            off = 32;
        },
        .manifestation_booted_from_spore => |b| {
            @memcpy(scratch[off..][0..32], &b.soul_hash);            off += 32;
            @memcpy(scratch[off..][0..32], &b.spore_cid);            off += 32;
            @memcpy(scratch[off..][0..32], &b.lost_cid);             off += 32;
            @memcpy(scratch[off..][0..32], &b.initial_artifact_cid); off += 32;
        },
        .c2_binding_established => |b| {
            @memcpy(scratch[off..][0..32], &b.harness_id);            off += 32;
            @memcpy(scratch[off..][0..32], &b.demon_id);              off += 32;
            @memcpy(scratch[off..][0..32], &b.capability_policy_cid); off += 32;
        },
        .c2_binding_revoked => |b| {
            @memcpy(scratch[off..][0..32], &b.harness_id);  off += 32;
            @memcpy(scratch[off..][0..32], &b.demon_id);    off += 32;
            @memcpy(scratch[off..][0..32], &b.reason_hash); off += 32;
        },
        .watcher_evidence_submitted => |b| {
            @memcpy(scratch[off..][0..32], &b.watcher_id);   off += 32;
            @memcpy(scratch[off..][0..32], &b.harness_id);   off += 32;
            @memcpy(scratch[off..][0..32], &b.evidence_cid); off += 32;
            @memcpy(scratch[off..][0..32], &b.work_context); off += 32;
        },
        .guardian_authorization_granted => |b| {
            @memcpy(scratch[off..][0..32], &b.guardian_id);    off += 32;
            @memcpy(scratch[off..][0..32], &b.harness_source); off += 32;
            @memcpy(scratch[off..][0..32], &b.harness_target); off += 32;
            @memcpy(scratch[off..][0..32], &b.work_context);   off += 32;
            scratch[off] = b.evidence_count;                   off += 1;
            var i: usize = 0;
            while (i < b.evidence_count) : (i += 1) {
                @memcpy(scratch[off..][0..32], &b.evidence_refs[i]); off += 32;
            }
        },
        .influence_authorized => |b| {
            @memcpy(scratch[off..][0..32], &b.source_harness);               off += 32;
            @memcpy(scratch[off..][0..32], &b.target_harness);               off += 32;
            @memcpy(scratch[off..][0..32], &b.source_artifact_cid);          off += 32;
            @memcpy(scratch[off..][0..32], &b.shared_work_context);          off += 32;
            @memcpy(scratch[off..][0..32], &b.authorization_policy_hash);    off += 32;
            @memcpy(scratch[off..][0..32], &b.guardian_authorization_event); off += 32;
            scratch[off] = @intFromEnum(b.target_generation);                off += 1;
            scratch[off] = @intFromEnum(b.direction);                        off += 1;
            @memcpy(scratch[off..][0..32], &b.decay_condition_cid);          off += 32;
        },
        .artifact_forged => |b| {
            @memcpy(scratch[off..][0..32], &b.harness_id);            off += 32;
            @memcpy(scratch[off..][0..32], &b.previous_artifact_cid); off += 32;
            @memcpy(scratch[off..][0..32], &b.new_artifact_cid);      off += 32;
            scratch[off] = b.consumed_count;                          off += 1;
            var i: usize = 0;
            while (i < b.consumed_count) : (i += 1) {
                @memcpy(scratch[off..][0..32], &b.consumed_influence_events[i]); off += 32;
            }
            std.mem.writeInt(u64, scratch[off..][0..8], b.forge_epoch, .little); off += 8;
        },
        .artifact_absorbed => |b| {
            @memcpy(scratch[off..][0..32], &b.harness_id);             off += 32;
            @memcpy(scratch[off..][0..32], &b.absorbed_artifact_cid);  off += 32;
            scratch[off] = b.consumed_count;                           off += 1;
            var i: usize = 0;
            while (i < b.consumed_count) : (i += 1) {
                @memcpy(scratch[off..][0..32], &b.consumed_influence_events[i]); off += 32;
            }
            @memcpy(scratch[off..][0..32], &b.resulting_resonance_cid); off += 32;
        },
        .guardian_set_changed => |b| {
            scratch[off] = b.new_guardian_count;                       off += 1;
            var i: usize = 0;
            while (i < b.new_guardian_count) : (i += 1) {
                @memcpy(scratch[off..][0..32], &b.new_guardian_pubkeys[i]); off += 32;
            }
            @memcpy(scratch[off..][0..32], &b.reason_cid);             off += 32;
        },
    }

    return scratch[0..off];
}

// ── WAL Frame I/O ─────────────────────────────────────────────────────────

/// Schreibt ein Frame in die WAL-Datei.
///
/// Frame-Layout:
///   magic(4) || frame_len_le4(4) || checksum_sha256(32) || payload(frame_len)
///
/// checksum = SHA256(magic || frame_len_bytes || payload)
const tio = std.testing.io;

pub fn writeFrameAt(file: std.Io.File, pos: u64, payload: []const u8) LedgerWalError!u64 {
    if (payload.len > MAX_PAYLOAD_SIZE) return LedgerWalError.InvalidFrameLength;

    var frame_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &frame_len_buf, @intCast(payload.len), .little);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&WAL_MAGIC);
    hasher.update(&frame_len_buf);
    hasher.update(payload);
    var checksum: [32]u8 = undefined;
    hasher.final(&checksum);

    var header: [FRAME_HEADER_SIZE]u8 = undefined;
    @memcpy(header[0..4], &WAL_MAGIC);
    @memcpy(header[4..8], &frame_len_buf);
    @memcpy(header[8..40], &checksum);

    file.writePositionalAll(tio, &header, pos) catch return LedgerWalError.IoError;
    file.writePositionalAll(tio, payload, pos + FRAME_HEADER_SIZE) catch return LedgerWalError.IoError;
    return pos + FRAME_HEADER_SIZE + payload.len;
}

pub const ReadFrameResult = struct {
    payload_buf: [MAX_PAYLOAD_SIZE]u8,
    payload_len: usize,
    next_pos: u64,
};

pub fn readFrameAt(file: std.Io.File, pos: u64, file_size: u64) LedgerWalError!?ReadFrameResult {
    if (pos >= file_size) return null;
    if (pos + FRAME_HEADER_SIZE > file_size) return LedgerWalError.TornWrite;

    var header: [FRAME_HEADER_SIZE]u8 = undefined;
    const n = file.readPositionalAll(tio, &header, pos) catch return LedgerWalError.IoError;
    if (n < FRAME_HEADER_SIZE) return LedgerWalError.TornWrite;

    if (!std.mem.eql(u8, header[0..4], &WAL_MAGIC)) return LedgerWalError.InvalidMagic;

    const frame_len = std.mem.readInt(u32, header[4..8], .little);
    if (frame_len == 0 or frame_len > MAX_PAYLOAD_SIZE) return LedgerWalError.InvalidFrameLength;

    if (pos + FRAME_HEADER_SIZE + frame_len > file_size) return LedgerWalError.TornWrite;

    var result = ReadFrameResult{
        .payload_buf = [_]u8{0} ** MAX_PAYLOAD_SIZE,
        .payload_len = frame_len,
        .next_pos = pos + FRAME_HEADER_SIZE + frame_len,
    };
    const pm = file.readPositionalAll(tio, result.payload_buf[0..frame_len], pos + FRAME_HEADER_SIZE)
        catch return LedgerWalError.IoError;
    if (pm < frame_len) return LedgerWalError.TornWrite;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(header[0..4]);
    hasher.update(header[4..8]);
    hasher.update(result.payload_buf[0..frame_len]);
    var computed: [32]u8 = undefined;
    hasher.final(&computed);
    if (!std.mem.eql(u8, &computed, header[8..40])) return LedgerWalError.TornWrite;

    return result;
}

// ── LedgerWalWriter ───────────────────────────────────────────────────────

pub const LedgerWalWriter = struct {
    file: std.Io.File,
    pos: u64,

    pub fn open(path: []const u8) !LedgerWalWriter {
        const file = std.Io.Dir.cwd().createFile(tio, path, .{}) catch |e| switch (e) {
            error.PathAlreadyExists => try std.Io.Dir.cwd().openFile(tio, path, .{ .mode = .read_write }),
            else => return e,
        };
        const eof = file.length(tio) catch 0;
        return LedgerWalWriter{ .file = file, .pos = eof };
    }

    pub fn close(self: *LedgerWalWriter) void {
        self.file.close(tio);
    }

    pub fn append(self: *LedgerWalWriter, env: *const LedgerEventEnvelope) LedgerWalError!void {
        var payload_buf: [MAX_PAYLOAD_SIZE]u8 = undefined;
        const payload_len = try encodeEnvelope(env, &payload_buf);
        self.pos = try writeFrameAt(self.file, self.pos, payload_buf[0..payload_len]);
        self.file.sync(tio) catch return LedgerWalError.IoError;
    }
};

// ── LedgerWalReader / Recovery ────────────────────────────────────────────

pub const LedgerWalReader = struct {
    file: std.Io.File,
    pos: u64,
    file_size: u64,

    pub fn open(path: []const u8) !LedgerWalReader {
        const file = try std.Io.Dir.cwd().openFile(tio, path, .{});
        const size = file.length(tio) catch 0;
        return LedgerWalReader{ .file = file, .pos = 0, .file_size = size };
    }

    pub fn close(self: *LedgerWalReader) void {
        self.file.close(tio);
    }

    pub fn readNext(self: *LedgerWalReader, allocator: std.mem.Allocator) LedgerWalError!?LedgerEventEnvelope {
        _ = allocator;
        const frame = try readFrameAt(self.file, self.pos, self.file_size) orelse return null;
        self.pos = frame.next_pos;
        return try decodeEnvelope(frame.payload_buf[0..frame.payload_len]);
    }
};

// ── TLV Decoding ─────────────────────────────────────────────────────────

/// Dekodiert ein TLV-kodiertes Envelope aus einem Bytestream.
pub fn decodeEnvelope(data: []const u8) LedgerWalError!LedgerEventEnvelope {
    var sequence: ?u64 = null;
    var prev_event_hash: ?Hash = null;
    var event_hash: ?Hash = null;
    var actor_pubkey: ?Hash = null;
    var signature: ?[64]u8 = null;
    var payload_type: ?u16 = null;
    var payload_bytes_start: usize = 0;
    var payload_bytes_len: usize = 0;

    var off: usize = 0;
    while (off < data.len) {
        if (off + 3 > data.len) return LedgerWalError.MalformedPayload;
        const tag = data[off]; off += 1;
        const field_len = std.mem.readInt(u16, data[off..][0..2], .little); off += 2;
        if (off + field_len > data.len) return LedgerWalError.MalformedPayload;

        switch (tag) {
            TAG_SEQUENCE => {
                if (field_len != 8) return LedgerWalError.MalformedPayload;
                sequence = std.mem.readInt(u64, data[off..][0..8], .little);
            },
            TAG_PREV_HASH => {
                if (field_len != 32) return LedgerWalError.MalformedPayload;
                var h: Hash = undefined;
                @memcpy(&h, data[off..][0..32]);
                prev_event_hash = h;
            },
            TAG_EVENT_HASH => {
                if (field_len != 32) return LedgerWalError.MalformedPayload;
                var h: Hash = undefined;
                @memcpy(&h, data[off..][0..32]);
                event_hash = h;
            },
            TAG_ACTOR_PUBKEY => {
                if (field_len != 32) return LedgerWalError.MalformedPayload;
                var h: Hash = undefined;
                @memcpy(&h, data[off..][0..32]);
                actor_pubkey = h;
            },
            TAG_SIGNATURE => {
                if (field_len != 64) return LedgerWalError.MalformedPayload;
                var s: [64]u8 = undefined;
                @memcpy(&s, data[off..][0..64]);
                signature = s;
            },
            TAG_PAYLOAD_TYPE => {
                if (field_len != 2) return LedgerWalError.MalformedPayload;
                payload_type = std.mem.readInt(u16, data[off..][0..2], .little);
            },
            TAG_PAYLOAD_BYTES => {
                payload_bytes_start = off;
                payload_bytes_len = field_len;
            },
            else => {}, // unbekannte Tags überspringen (Vorwärtskompatibilität)
        }
        off += field_len;
    }

    // Pflichtfelder prüfen
    const seq  = sequence        orelse return LedgerWalError.MissingField;
    const prev = prev_event_hash orelse return LedgerWalError.MissingField;
    const evh  = event_hash      orelse return LedgerWalError.MissingField;
    const apk  = actor_pubkey    orelse return LedgerWalError.MissingField;
    const sig  = signature       orelse return LedgerWalError.MissingField;
    const ptype = payload_type   orelse return LedgerWalError.MissingField;
    if (payload_bytes_len == 0 and ptype != @intFromEnum(ledger_mod.ids.IdType.soul))
        return LedgerWalError.MissingField;

    const payload_data = data[payload_bytes_start..payload_bytes_start + payload_bytes_len];
    const decoded_payload = try decodePayload(ptype, payload_data);

    return LedgerEventEnvelope{
        .sequence        = seq,
        .prev_event_hash = prev,
        .event_hash      = evh,
        .actor_pubkey    = apk,
        .signature       = sig,
        .payload         = decoded_payload,
    };
}

fn intToEventType(v: u16) ?events_mod.EventType {
    inline for (std.meta.fields(events_mod.EventType)) |f| {
        if (f.value == v) return @enumFromInt(v);
    }
    return null;
}

fn decodePayload(ptype: u16, data: []const u8) LedgerWalError!ledger_mod.EventPayload {
    const event_type = intToEventType(ptype) orelse return LedgerWalError.MalformedPayload;

    var off: usize = 0;

    switch (event_type) {
        .soul_anchored => {
            if (data.len < 32) return LedgerWalError.MalformedPayload;
            var h: Hash = undefined;
            @memcpy(&h, data[0..32]);
            return .{ .soul_anchored = h };
        },
        .manifestation_booted_from_spore => {
            if (data.len < 128) return LedgerWalError.MalformedPayload;
            var soul: Hash = undefined; @memcpy(&soul, data[off..][0..32]); off += 32;
            var spore: Hash = undefined; @memcpy(&spore, data[off..][0..32]); off += 32;
            var lost: Hash = undefined; @memcpy(&lost, data[off..][0..32]); off += 32;
            var init_art: Hash = undefined; @memcpy(&init_art, data[off..][0..32]);
            return .{ .manifestation_booted_from_spore = .{
                .soul_hash = soul, .spore_cid = spore,
                .lost_cid = lost, .initial_artifact_cid = init_art,
            }};
        },
        .c2_binding_established => {
            if (data.len < 96) return LedgerWalError.MalformedPayload;
            var harness: Hash = undefined; @memcpy(&harness, data[off..][0..32]); off += 32;
            var demon: Hash = undefined; @memcpy(&demon, data[off..][0..32]); off += 32;
            var cap: Hash = undefined; @memcpy(&cap, data[off..][0..32]);
            return .{ .c2_binding_established = .{
                .harness_id = harness, .demon_id = demon, .capability_policy_cid = cap,
            }};
        },
        .c2_binding_revoked => {
            if (data.len < 96) return LedgerWalError.MalformedPayload;
            var harness: Hash = undefined; @memcpy(&harness, data[off..][0..32]); off += 32;
            var demon: Hash = undefined; @memcpy(&demon, data[off..][0..32]); off += 32;
            var reason: Hash = undefined; @memcpy(&reason, data[off..][0..32]);
            return .{ .c2_binding_revoked = .{
                .harness_id = harness, .demon_id = demon, .reason_hash = reason,
            }};
        },
        .watcher_evidence_submitted => {
            if (data.len < 128) return LedgerWalError.MalformedPayload;
            var watcher: Hash = undefined; @memcpy(&watcher, data[off..][0..32]); off += 32;
            var harness: Hash = undefined; @memcpy(&harness, data[off..][0..32]); off += 32;
            var evidence: Hash = undefined; @memcpy(&evidence, data[off..][0..32]); off += 32;
            var ctx: Hash = undefined; @memcpy(&ctx, data[off..][0..32]);
            return .{ .watcher_evidence_submitted = .{
                .watcher_id = watcher, .harness_id = harness,
                .evidence_cid = evidence, .work_context = ctx,
            }};
        },
        .guardian_authorization_granted => {
            if (data.len < 97) return LedgerWalError.MalformedPayload;
            var guardian: Hash = undefined; @memcpy(&guardian, data[off..][0..32]); off += 32;
            var src: Hash = undefined; @memcpy(&src, data[off..][0..32]); off += 32;
            var tgt: Hash = undefined; @memcpy(&tgt, data[off..][0..32]); off += 32;
            var ctx: Hash = undefined; @memcpy(&ctx, data[off..][0..32]); off += 32;
            const count = data[off]; off += 1;
            if (data.len < off + @as(usize, count) * 32) return LedgerWalError.MalformedPayload;
            var refs: [8]Hash = [_]Hash{ZERO_HASH} ** 8;
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                @memcpy(&refs[i], data[off..][0..32]); off += 32;
            }
            return .{ .guardian_authorization_granted = .{
                .guardian_id = guardian, .harness_source = src, .harness_target = tgt,
                .work_context = ctx, .evidence_refs = refs, .evidence_count = count,
            }};
        },
        .influence_authorized => {
            if (data.len < 194) return LedgerWalError.MalformedPayload;
            const ev = @import("../protocol/events.zig");
            var src_h: Hash = undefined; @memcpy(&src_h, data[off..][0..32]); off += 32;
            var tgt_h: Hash = undefined; @memcpy(&tgt_h, data[off..][0..32]); off += 32;
            var src_art: Hash = undefined; @memcpy(&src_art, data[off..][0..32]); off += 32;
            var ctx: Hash = undefined; @memcpy(&ctx, data[off..][0..32]); off += 32;
            var policy: Hash = undefined; @memcpy(&policy, data[off..][0..32]); off += 32;
            var guardian_ev: Hash = undefined; @memcpy(&guardian_ev, data[off..][0..32]); off += 32;
            const tgen_int = data[off]; off += 1;
            const tgen: ev.TargetGeneration = blk: {
                inline for (std.meta.fields(ev.TargetGeneration)) |f| {
                    if (f.value == tgen_int) break :blk @enumFromInt(tgen_int);
                }
                return LedgerWalError.MalformedPayload;
            };
            const dir_int = data[off]; off += 1;
            const dir: ev.InfluenceDirection = blk: {
                inline for (std.meta.fields(ev.InfluenceDirection)) |f| {
                    if (f.value == dir_int) break :blk @enumFromInt(dir_int);
                }
                return LedgerWalError.MalformedPayload;
            };
            var decay: Hash = undefined; @memcpy(&decay, data[off..][0..32]);
            return .{ .influence_authorized = .{
                .source_harness = src_h, .target_harness = tgt_h,
                .source_artifact_cid = src_art, .shared_work_context = ctx,
                .authorization_policy_hash = policy, .guardian_authorization_event = guardian_ev,
                .target_generation = tgen, .direction = dir, .decay_condition_cid = decay,
            }};
        },
        .artifact_forged => {
            if (data.len < 97) return LedgerWalError.MalformedPayload;
            var harness: Hash = undefined; @memcpy(&harness, data[off..][0..32]); off += 32;
            var prev_art: Hash = undefined; @memcpy(&prev_art, data[off..][0..32]); off += 32;
            var new_art: Hash = undefined; @memcpy(&new_art, data[off..][0..32]); off += 32;
            const count = data[off]; off += 1;
            if (data.len < off + @as(usize, count) * 32 + 8) return LedgerWalError.MalformedPayload;
            var consumed: [@import("../protocol/events.zig").MAX_CONSUMED_INFLUENCES]Hash = [_]Hash{ZERO_HASH} ** @import("../protocol/events.zig").MAX_CONSUMED_INFLUENCES;
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                @memcpy(&consumed[i], data[off..][0..32]); off += 32;
            }
            const epoch = std.mem.readInt(u64, data[off..][0..8], .little);
            return .{ .artifact_forged = .{
                .harness_id = harness, .previous_artifact_cid = prev_art,
                .new_artifact_cid = new_art,
                .consumed_influence_events = consumed, .consumed_count = count,
                .forge_epoch = epoch,
            }};
        },
        .artifact_absorbed => {
            if (data.len < 65) return LedgerWalError.MalformedPayload;
            var harness: Hash = undefined; @memcpy(&harness, data[off..][0..32]); off += 32;
            var absorbed: Hash = undefined; @memcpy(&absorbed, data[off..][0..32]); off += 32;
            const count = data[off]; off += 1;
            if (data.len < off + @as(usize, count) * 32 + 32) return LedgerWalError.MalformedPayload;
            var consumed: [@import("../protocol/events.zig").MAX_CONSUMED_INFLUENCES]Hash = [_]Hash{ZERO_HASH} ** @import("../protocol/events.zig").MAX_CONSUMED_INFLUENCES;
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                @memcpy(&consumed[i], data[off..][0..32]); off += 32;
            }
            var resonance: Hash = undefined; @memcpy(&resonance, data[off..][0..32]);
            return .{ .artifact_absorbed = .{
                .harness_id = harness, .absorbed_artifact_cid = absorbed,
                .consumed_influence_events = consumed, .consumed_count = count,
                .resulting_resonance_cid = resonance,
            }};
        },
        .guardian_set_changed => {
            if (data.len < 33) return LedgerWalError.MalformedPayload;
            const count = data[off]; off += 1;
            if (data.len < off + @as(usize, count) * 32 + 32) return LedgerWalError.MalformedPayload;
            var pubkeys: [32][32]u8 = [_][32]u8{ZERO_HASH} ** 32;
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                @memcpy(&pubkeys[i], data[off..][0..32]); off += 32;
            }
            var reason: Hash = undefined; @memcpy(&reason, data[off..][0..32]);
            return .{ .guardian_set_changed = .{
                .new_guardian_count = count,
                .new_guardian_pubkeys = pubkeys,
                .reason_cid = reason,
            }};
        },
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn mkh(b: u8) Hash {
    var h: Hash = ZERO_HASH;
    h[0] = b;
    return h;
}

test "ledger_wal: encode/decode round-trip — manifestation_booted" {
    const env = LedgerEventEnvelope{
        .sequence        = 7,
        .prev_event_hash = mkh(0x01),
        .event_hash      = mkh(0x02),
        .actor_pubkey    = mkh(0xAC),
        .signature       = [_]u8{0xEE} ** 64,
        .payload         = .{ .manifestation_booted_from_spore = .{
            .soul_hash            = mkh(0x51),
            .spore_cid            = mkh(0x52),
            .lost_cid             = ZERO_HASH,
            .initial_artifact_cid = mkh(0xA0),
        }},
    };

    var buf: [MAX_PAYLOAD_SIZE]u8 = undefined;
    const len = try encodeEnvelope(&env, &buf);
    const decoded = try decodeEnvelope(buf[0..len]);

    try std.testing.expectEqual(@as(u64, 7), decoded.sequence);
    try std.testing.expect(std.mem.eql(u8, &mkh(0x01), &decoded.prev_event_hash));
    try std.testing.expect(std.mem.eql(u8, &mkh(0x02), &decoded.event_hash));
    const booted = decoded.payload.manifestation_booted_from_spore;
    try std.testing.expect(std.mem.eql(u8, &mkh(0x51), &booted.soul_hash));
    try std.testing.expect(std.mem.eql(u8, &mkh(0xA0), &booted.initial_artifact_cid));
}

test "ledger_wal: encode/decode round-trip — artifact_forged" {
    var consumed = [_]Hash{ZERO_HASH} ** @import("../protocol/events.zig").MAX_CONSUMED_INFLUENCES;
    consumed[0] = mkh(0xC0);
    consumed[1] = mkh(0xC1);

    const env = LedgerEventEnvelope{
        .sequence        = 42,
        .prev_event_hash = mkh(0x10),
        .event_hash      = mkh(0x11),
        .actor_pubkey    = mkh(0xAC),
        .signature       = [_]u8{0} ** 64,
        .payload         = .{ .artifact_forged = .{
            .harness_id            = mkh(0xBB),
            .previous_artifact_cid = mkh(0xA0),
            .new_artifact_cid      = mkh(0xA1),
            .consumed_influence_events = consumed,
            .consumed_count        = 2,
            .forge_epoch           = 99,
        }},
    };

    var buf: [MAX_PAYLOAD_SIZE]u8 = undefined;
    const len = try encodeEnvelope(&env, &buf);
    const decoded = try decodeEnvelope(buf[0..len]);

    try std.testing.expectEqual(@as(u64, 42), decoded.sequence);
    const forged = decoded.payload.artifact_forged;
    try std.testing.expect(std.mem.eql(u8, &mkh(0xA1), &forged.new_artifact_cid));
    try std.testing.expectEqual(@as(u8, 2), forged.consumed_count);
    try std.testing.expectEqual(@as(u64, 99), forged.forge_epoch);
    try std.testing.expect(std.mem.eql(u8, &mkh(0xC0), &forged.consumed_influence_events[0]));
}

test "ledger_wal: write + read round-trip über Datei" {
    const path = "/tmp/bkgdb_test_proto.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    const env = LedgerEventEnvelope{
        .sequence        = 1,
        .prev_event_hash = ZERO_HASH,
        .event_hash      = mkh(0x42),
        .actor_pubkey    = mkh(0xAC),
        .signature       = [_]u8{0} ** 64,
        .payload         = .{ .soul_anchored = mkh(0x55) },
    };

    {
        var w = try LedgerWalWriter.open(path);
        defer w.close();
        try w.append(&env);
    }

    var r = try LedgerWalReader.open(path);
    defer r.close();

    const decoded = try r.readNext(std.testing.allocator);
    try std.testing.expect(decoded != null);
    try std.testing.expectEqual(@as(u64, 1), decoded.?.sequence);
    try std.testing.expect(std.mem.eql(u8, &mkh(0x42), &decoded.?.event_hash));

    const eof = try r.readNext(std.testing.allocator);
    try std.testing.expect(eof == null);
}

test "ledger_wal: torn write erkannt — abgeschnittener Frame" {
    const path = "/tmp/bkgdb_test_torn.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    // Nur den Header schreiben, keinen Payload → torn write
    {
        var header: [FRAME_HEADER_SIZE]u8 = [_]u8{0} ** FRAME_HEADER_SIZE;
        @memcpy(header[0..4], &WAL_MAGIC);
        std.mem.writeInt(u32, header[4..8][0..4], 128, .little);
        const f = try std.Io.Dir.cwd().createFile(tio, path, .{});
        defer f.close(tio);
        f.writePositionalAll(tio, &header, 0) catch {};
    }

    var r = try LedgerWalReader.open(path);
    defer r.close();
    try std.testing.expectError(
        LedgerWalError.TornWrite,
        r.readNext(std.testing.allocator),
    );
}

test "ledger_wal: ungültige Magic erkannt" {
    const path = "/tmp/bkgdb_test_magic.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    {
        const f = try std.Io.Dir.cwd().createFile(tio, path, .{});
        defer f.close(tio);
        var garbage: [FRAME_HEADER_SIZE]u8 = [_]u8{0xFF} ** FRAME_HEADER_SIZE;
        f.writePositionalAll(tio, &garbage, 0) catch {};
    }

    var r = try LedgerWalReader.open(path);
    defer r.close();
    try std.testing.expectError(
        LedgerWalError.InvalidMagic,
        r.readNext(std.testing.allocator),
    );
}
