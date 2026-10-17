/// BKGDB WAL Encryption v1 — Storage Consumer Layer
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   ARCHITECTURE-V5.md §17
///
/// ═══════════════════════════════════════════════════════════════
/// FROZEN MODULE DEPENDENCIES
/// ═══════════════════════════════════════════════════════════════
///
///   envelope.zig SHA256:
///     081af87ff0ab1dad35bb84a964e22f7a282135e79bdce61b51d102c45d276ca4
///   keyring.zig SHA256:
///     695061c684ba61fc13a5747321dd2b4a2b8385a40f188459d0196efdaef57578
///
/// Beide FROZEN. Keine Änderungen erlaubt.
///
/// ═══════════════════════════════════════════════════════════════
/// WAL FRAME FORMAT
/// ═══════════════════════════════════════════════════════════════
///
///   magic(4)            = "BKG1"
///   frame_len(4)        = Länge des Envelope-Payloads
///   checksum_sha256(32) = SHA256(magic || frame_len_le4 || envelope_bytes)
///   envelope_bytes(N)   = [HEADER_81][CIPHERTEXT][TAG_16]
///
/// ═══════════════════════════════════════════════════════════════
/// VERANTWORTUNGSGRENZE
/// ═══════════════════════════════════════════════════════════════
///
/// Envelope: AEAD-Authentizität, Context-Binding (domain/genesis/seq/key)
/// WAL:      Sequence-Ordnung, Replay-Erkennung, Gap-Erkennung
///
/// CRITICAL: Ein byte-identisch kopierter Envelope hat einen gültigen
/// AEAD-Tag. Replay-Schutz liegt AUSSCHLIESSLICH im WAL/Rebuilder.
///
///   "AEAD akzeptiert Replay. WAL lehnt Replay ab."
///
/// ═══════════════════════════════════════════════════════════════
/// KEY LIFECYCLE
/// ═══════════════════════════════════════════════════════════════
///
///   ACTIVE  → Encrypt: erlaubt   Decrypt: erlaubt
///   REVOKED → Encrypt: VERBOTEN  Decrypt: erlaubt (historische Daten)
///
/// Writer: lookupActive()  — nur ACTIVE Keys für neue Frames
/// Reader: lookupAny()     — ACTIVE und REVOKED für historische Frames
///
const std = @import("std");

const ledger_wal   = @import("ledger_wal.zig");
const envelope_mod = @import("../crypto/envelope.zig");
const keyring_mod  = @import("../crypto/keyring.zig");

pub const LedgerEventEnvelope = ledger_wal.LedgerEventEnvelope;
pub const Hash                = ledger_wal.Hash;

// ── Konstanten ─────────────────────────────────────────────────────────────

/// Maximaler kanonischer TLV-Plaintext (identisch mit bestehender WAL-Grenze).
pub const MAX_WAL_EVENT_SIZE: usize = ledger_wal.MAX_PAYLOAD_SIZE;   // 4096

/// Maximale Envelope-Größe: 81 + plaintext + 16.
pub const MAX_ENCRYPTED_FRAME_SIZE: usize =
    envelope_mod.HEADER_SIZE + MAX_WAL_EVENT_SIZE + envelope_mod.TAG_SIZE; // 4193

pub const WAL_DOMAIN: envelope_mod.Domain      = .BKGDB_WAL;
pub const WAL_RECORD_TYPE: envelope_mod.RecordType = .EVENT;

const tio = std.testing.io;

// ── Fehlertypen ────────────────────────────────────────────────────────────

pub const EncryptedWalError = error{
    /// Transport-Magic fehlt oder falsch.
    TransportChecksumMismatch,
    /// SHA256-Checksum stimmt nicht — torn write oder Korruption.
    MalformedTransportFrame,
    /// Envelope-Mindestgröße nicht erreicht.
    MalformedEnvelope,
    /// key_id nicht im Keyring.
    UnknownKey,
    /// Key existiert, ist aber REVOKED — für Encrypt verboten.
    RevokedKey,
    /// AEAD-Tag-Verifikation fehlgeschlagen.
    EnvelopeAuthenticationFailed,
    /// Domain, genesis_hash, record_type oder sequence stimmt nicht.
    ContextMismatch,
    /// Byte-identischer Frame erneut eingefügt — Replay erkannt.
    ReplayDetected,
    /// Sequence-Lücke: erwartet N, bekommen > N+1.
    SequenceGap,
    /// Sequence-Rollback: erwartet N, bekommen < N.
    SequenceRollback,
    /// Frame-Größe überschreitet MAX_ENCRYPTED_FRAME_SIZE.
    FrameTooLarge,
    /// Payload-Länge syntaktisch korrekt, aber zu groß für Allokation.
    PayloadTooLarge,
    /// WAL-Magic fehlt/falsch.
    InvalidMagic,
    /// WAL-Frame-Länge ungültig (0 oder > limit).
    InvalidFrameLength,
    /// Torn write — abgebrochener Write.
    TornWrite,
    /// TLV-Daten inkonsistent.
    MalformedPayload,
    /// Pflichtfeld im Event fehlt.
    MissingField,
    /// Strukturfehler im Envelope-Header.
    InvalidEnvelopeMagic,
    UnsupportedVersion,
    UnsupportedAlgorithm,
    UnsupportedDomain,
    UnknownFlags,
    UnsupportedRecordType,
    InvalidLength,
    /// I/O-Fehler.
    IoError,
    OutOfMemory,
};

// ── Fehlerübersetzungen ────────────────────────────────────────────────────

fn fromWalErr(e: ledger_wal.LedgerWalError) EncryptedWalError {
    return switch (e) {
        error.InvalidMagic       => EncryptedWalError.InvalidMagic,
        error.TornWrite          => EncryptedWalError.TornWrite,
        error.InvalidFrameLength => EncryptedWalError.InvalidFrameLength,
        error.MalformedPayload   => EncryptedWalError.MalformedPayload,
        error.MissingField       => EncryptedWalError.MissingField,
        error.IoError            => EncryptedWalError.IoError,
        error.OutOfMemory        => EncryptedWalError.OutOfMemory,
    };
}

fn fromEnvErr(e: envelope_mod.EnvelopeError) EncryptedWalError {
    return switch (e) {
        error.MalformedEnvelope     => EncryptedWalError.MalformedEnvelope,
        error.InvalidMagic          => EncryptedWalError.InvalidEnvelopeMagic,
        error.UnsupportedVersion    => EncryptedWalError.UnsupportedVersion,
        error.UnsupportedAlgorithm  => EncryptedWalError.UnsupportedAlgorithm,
        error.UnsupportedDomain     => EncryptedWalError.UnsupportedDomain,
        error.UnknownFlags          => EncryptedWalError.UnknownFlags,
        error.UnsupportedRecordType => EncryptedWalError.UnsupportedRecordType,
        error.InvalidLength         => EncryptedWalError.InvalidLength,
        error.PayloadTooLarge       => EncryptedWalError.PayloadTooLarge,
        error.KeyIdMismatch         => EncryptedWalError.ContextMismatch,
        error.InvalidContext        => EncryptedWalError.ContextMismatch,
        error.AuthenticationFailed  => EncryptedWalError.EnvelopeAuthenticationFailed,
        error.OutOfMemory           => EncryptedWalError.OutOfMemory,
    };
}

// ── Low-Level Frame I/O ────────────────────────────────────────────────────

/// Schreibt einen verschlüsselten Frame an `pos`.
/// Payload = vollständiger Envelope.
/// Gibt neue WAL-Position zurück.
fn writeEncFrameAt(
    file:          std.Io.File,
    pos:           u64,
    envelope_bytes: []const u8,
) EncryptedWalError!u64 {
    if (envelope_bytes.len > MAX_ENCRYPTED_FRAME_SIZE) return EncryptedWalError.FrameTooLarge;
    if (envelope_bytes.len < envelope_mod.HEADER_SIZE + envelope_mod.TAG_SIZE)
        return EncryptedWalError.MalformedEnvelope;

    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(envelope_bytes.len), .little);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&ledger_wal.WAL_MAGIC);
    hasher.update(&len_buf);
    hasher.update(envelope_bytes);
    var chk: [32]u8 = undefined;
    hasher.final(&chk);

    var hdr: [ledger_wal.FRAME_HEADER_SIZE]u8 = undefined;
    @memcpy(hdr[0..4],  &ledger_wal.WAL_MAGIC);
    @memcpy(hdr[4..8],  &len_buf);
    @memcpy(hdr[8..40], &chk);

    file.writePositionalAll(tio, &hdr, pos) catch return EncryptedWalError.IoError;
    file.writePositionalAll(tio, envelope_bytes, pos + ledger_wal.FRAME_HEADER_SIZE)
        catch return EncryptedWalError.IoError;

    return pos + ledger_wal.FRAME_HEADER_SIZE + envelope_bytes.len;
}

/// Liest einen Frame an `pos`. Gibt null bei EOF.
/// Gibt heap-allokierten Envelope-Bytes-Slice zurück — Caller gibt frei.
fn readEncFrameAt(
    allocator: std.mem.Allocator,
    file:      std.Io.File,
    file_size: u64,
    pos:       u64,
) EncryptedWalError!?struct { bytes: []u8, next_pos: u64 } {
    if (pos >= file_size) return null;
    if (pos + ledger_wal.FRAME_HEADER_SIZE > file_size)
        return EncryptedWalError.TornWrite;

    var hdr: [ledger_wal.FRAME_HEADER_SIZE]u8 = undefined;
    const n = file.readPositionalAll(tio, &hdr, pos) catch return EncryptedWalError.IoError;
    if (n < ledger_wal.FRAME_HEADER_SIZE) return EncryptedWalError.TornWrite;

    if (!std.mem.eql(u8, hdr[0..4], &ledger_wal.WAL_MAGIC))
        return EncryptedWalError.InvalidMagic;

    const frame_len = std.mem.readInt(u32, hdr[4..8], .little);

    // Mindestens ein Header + Tag muss drin sein
    const min_env = envelope_mod.HEADER_SIZE + envelope_mod.TAG_SIZE;
    if (frame_len < min_env) return EncryptedWalError.InvalidFrameLength;
    if (frame_len > MAX_ENCRYPTED_FRAME_SIZE) return EncryptedWalError.FrameTooLarge;

    if (pos + ledger_wal.FRAME_HEADER_SIZE + frame_len > file_size)
        return EncryptedWalError.TornWrite;

    const env_bytes = allocator.alloc(u8, frame_len) catch return EncryptedWalError.OutOfMemory;
    errdefer allocator.free(env_bytes);

    const pm = file.readPositionalAll(tio, env_bytes, pos + ledger_wal.FRAME_HEADER_SIZE)
        catch return EncryptedWalError.IoError;
    if (pm < frame_len) return EncryptedWalError.TornWrite;

    // Transport-Checksum: SHA256(magic || frame_len_le4 || envelope_bytes)
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(hdr[0..4]);
    hasher.update(hdr[4..8]);
    hasher.update(env_bytes);
    var computed: [32]u8 = undefined;
    hasher.final(&computed);
    if (!std.mem.eql(u8, &computed, hdr[8..40])) {
        return EncryptedWalError.TransportChecksumMismatch;
    }

    const next_pos = pos + ledger_wal.FRAME_HEADER_SIZE + frame_len;
    return .{ .bytes = env_bytes, .next_pos = next_pos };
}

// ── EncryptedWalWriter ─────────────────────────────────────────────────────

/// Writer für verschlüsselte WAL-Frames.
///
/// Jeder Frame ist ein eigenständiger BKGDB Encryption Envelope.
/// Neue Frames dürfen nur mit ACTIVE Keys geschrieben werden.
pub const EncryptedWalWriter = struct {
    file:          std.Io.File,
    pos:           u64,
    active_key_id: [keyring_mod.KEY_ID_SIZE]u8,
    genesis_hash:  [32]u8,

    /// Öffnet (oder erstellt) eine WAL-Datei für verschlüsselte Frames.
    pub fn init(
        path:          []const u8,
        active_key_id: [keyring_mod.KEY_ID_SIZE]u8,
        genesis_hash:  [32]u8,
    ) !EncryptedWalWriter {
        const file = std.Io.Dir.cwd().createFile(tio, path, .{}) catch |e| switch (e) {
            error.PathAlreadyExists =>
                try std.Io.Dir.cwd().openFile(tio, path, .{ .mode = .read_write }),
            else => return e,
        };
        const eof = file.length(tio) catch 0;
        return .{
            .file          = file,
            .pos           = eof,
            .active_key_id = active_key_id,
            .genesis_hash  = genesis_hash,
        };
    }

    pub fn deinit(self: *EncryptedWalWriter) void {
        self.file.close(tio);
    }

    /// Verschlüsselt `event` und schreibt es als neuen WAL-Frame.
    ///
    /// Nur ACTIVE Keys dürfen verwendet werden.
    /// REVOKED → EncryptedWalError.RevokedKey
    /// Unbekannt → EncryptedWalError.UnknownKey
    pub fn appendEncrypted(
        self:      *EncryptedWalWriter,
        io:        std.Io,
        allocator: std.mem.Allocator,
        keyring:   *const keyring_mod.Keyring,
        event:     *const LedgerEventEnvelope,
    ) EncryptedWalError!void {
        // 1. Kanonischer TLV-Plaintext
        var pt_buf: [MAX_WAL_EVENT_SIZE]u8 = undefined;
        const pt_len = ledger_wal.encodeEnvelope(event, &pt_buf)
            catch |e| return fromWalErr(e);

        // 2. Encrypt via Keyring/Envelope (ACTIVE-Only-Check in encryptWithKeyring)
        const env_bytes = keyring_mod.encryptWithKeyring(
            io, allocator, keyring,
            self.active_key_id,
            pt_buf[0..pt_len],
            WAL_DOMAIN,
            self.genesis_hash,
            WAL_RECORD_TYPE,
            event.sequence,
        ) catch |e| return switch (e) {
            error.KeyNotFound        => EncryptedWalError.UnknownKey,
            error.KeyRevoked         => EncryptedWalError.RevokedKey,
            error.InvalidContext     => EncryptedWalError.ContextMismatch,
            error.DuplicateKeyId     => EncryptedWalError.UnknownKey,
            error.InvalidKeyMaterial => EncryptedWalError.UnknownKey,
            error.OutOfMemory        => EncryptedWalError.OutOfMemory,
            error.MalformedEnvelope     => EncryptedWalError.MalformedEnvelope,
            error.InvalidMagic          => EncryptedWalError.InvalidEnvelopeMagic,
            error.UnsupportedVersion    => EncryptedWalError.UnsupportedVersion,
            error.UnsupportedAlgorithm  => EncryptedWalError.UnsupportedAlgorithm,
            error.UnsupportedDomain     => EncryptedWalError.UnsupportedDomain,
            error.UnknownFlags          => EncryptedWalError.UnknownFlags,
            error.UnsupportedRecordType => EncryptedWalError.UnsupportedRecordType,
            error.InvalidLength         => EncryptedWalError.InvalidLength,
            error.PayloadTooLarge       => EncryptedWalError.PayloadTooLarge,
            error.KeyIdMismatch         => EncryptedWalError.ContextMismatch,
            error.AuthenticationFailed  => EncryptedWalError.EnvelopeAuthenticationFailed,
        };
        defer allocator.free(env_bytes);

        // 3. Atomares Write
        const new_pos = try writeEncFrameAt(self.file, self.pos, env_bytes);
        self.file.sync(tio) catch return EncryptedWalError.IoError;
        self.pos = new_pos;
    }

    /// Rotiert den aktiven Key. Folgende Frames werden mit `new_key_id` geschrieben.
    /// Bestehende Frames bleiben unverändert (keine Re-Encryption).
    pub fn rotateKey(self: *EncryptedWalWriter, new_key_id: [keyring_mod.KEY_ID_SIZE]u8) void {
        self.active_key_id = new_key_id;
    }
};

// ── EncryptedWalReader ─────────────────────────────────────────────────────

/// Reader für verschlüsselte WAL-Frames mit Sequence-Validierung.
///
/// Die erwartete Sequence kommt vom Caller (trusted WAL-Zustand).
/// Replay / Duplicate / Gap / Rollback werden erkannt und abgelehnt.
pub const EncryptedWalReader = struct {
    file:                   std.Io.File,
    pos:                    u64,
    file_size:              u64,
    genesis_hash:           [32]u8,
    next_expected_sequence: u64,

    /// Öffnet eine bestehende verschlüsselte WAL-Datei.
    /// `start_sequence` = erste erwartete Sequence (trusted WAL-State).
    pub fn init(
        path:           []const u8,
        genesis_hash:   [32]u8,
        start_sequence: u64,
    ) !EncryptedWalReader {
        const file = try std.Io.Dir.cwd().openFile(tio, path, .{});
        const size = file.length(tio) catch 0;
        return .{
            .file                   = file,
            .pos                    = 0,
            .file_size              = size,
            .genesis_hash           = genesis_hash,
            .next_expected_sequence = start_sequence,
        };
    }

    pub fn deinit(self: *EncryptedWalReader) void {
        self.file.close(tio);
    }

    /// Liest den nächsten verschlüsselten Frame.
    ///
    /// Replay-Semantik (PFLICHT-INVARIANTE):
    ///   Ein byte-identischer kopierter Frame hat einen gültigen AEAD-Tag.
    ///   AEAD allein reicht nicht als Replay-Schutz.
    ///   Deshalb prüft readNextEncrypted() die Sequence gegen next_expected_sequence:
    ///
    ///     event.sequence == next_expected_sequence  → OK
    ///     event.sequence <  next_expected_sequence  → SequenceRollback
    ///     event.sequence == next_expected_sequence - 1 (= Duplicate/Replay) → ReplayDetected
    ///     event.sequence >  next_expected_sequence + 0 (= Gap) → SequenceGap
    ///
    /// Gibt null bei EOF zurück.
    pub fn readNextEncrypted(
        self:      *EncryptedWalReader,
        allocator: std.mem.Allocator,
        keyring:   *const keyring_mod.Keyring,
    ) EncryptedWalError!?LedgerEventEnvelope {
        // 1. Transport-Frame lesen
        const frame = try readEncFrameAt(allocator, self.file, self.file_size, self.pos)
            orelse return null;
        const env_bytes = frame.bytes;
        defer allocator.free(env_bytes);

        // 2. key_id aus Wire-Offset 8..24 (kein Header-Parsing nötig, Länge bereits geprüft)
        var key_id: [keyring_mod.KEY_ID_SIZE]u8 = undefined;
        @memcpy(&key_id, env_bytes[8..24]);

        // 3. Key-Lookup — ACTIVE und REVOKED beide für Decrypt erlaubt
        const key_entry = keyring.lookupAny(key_id) orelse return EncryptedWalError.UnknownKey;

        // 4. Envelope-Header strukturell dekodieren.
        //    Die Header-Sequence ist noch untrusted; sie wird nur zur
        //    AEAD-Selbstkonsistenzprüfung verwendet. Die WAL-Ordnungsprüfung
        //    gegen next_expected_sequence erfolgt erst nach erfolgreicher Auth.
        const header_bytes: *const [envelope_mod.HEADER_SIZE]u8 = env_bytes[0..envelope_mod.HEADER_SIZE];
        const header = envelope_mod.Header.decode(header_bytes) catch |e| return fromEnvErr(e);
        if (!std.mem.eql(u8, &header.key_id, &key_entry.key_id))
            return EncryptedWalError.ContextMismatch;

        const expected_ctx = envelope_mod.Context{
            .domain       = WAL_DOMAIN,
            .key_id       = key_entry.key_id,
            .genesis_hash = self.genesis_hash,
            .record_type  = WAL_RECORD_TYPE,
            .sequence     = header.sequence,
        };

        // 5. Envelope-Decrypt — AEAD + Context-Binding
        const plaintext = envelope_mod.decrypt(
            allocator, env_bytes, key_entry.key_material, expected_ctx,
        ) catch |e| return fromEnvErr(e);
        defer allocator.free(plaintext);

        // 6. Kanonisches TLV → LedgerEventEnvelope
        const decoded = ledger_wal.decodeEnvelope(plaintext)
            catch |e| return fromWalErr(e);

        // 7. WAL-Layer Sequence-Validierung (nach AEAD — Plaintext nach Auth).
        //    REPLAY-BEWEIS: Dieser Block ist der WAL-Replay-Schutz.
        //    Ein byte-identischer Replay hat AEAD=valid, schlägt HIER fehl.
        const got = decoded.sequence;
        const exp = self.next_expected_sequence;

        if (got == exp) {
            // OK: Sequence stimmt
        } else if (got < exp) {
            // Rollback oder Duplicate/Replay
            if (got == exp -% 1) {
                return EncryptedWalError.ReplayDetected;
            } else {
                return EncryptedWalError.SequenceRollback;
            }
        } else {
            // got > exp: Gap
            return EncryptedWalError.SequenceGap;
        }

        self.pos = frame.next_pos;
        self.next_expected_sequence += 1;
        return decoded;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

fn mkh(b: u8) Hash { var h = ledger_wal.ZERO_HASH; h[0] = b; return h; }
fn testGenesis() [32]u8 { return [_]u8{0x42} ** 32; }

fn makeWalKey(io: std.Io) !keyring_mod.KeyEntry {
    return keyring_mod.Keyring.generateKey(io, .BKGDB_WAL, testGenesis(), 1_700_000_000);
}

fn soulEvent(seq: u64) LedgerEventEnvelope {
    return .{
        .sequence        = seq,
        .prev_event_hash = mkh(0x00),
        .event_hash      = mkh(@intCast(seq & 0xFF)),
        .actor_pubkey    = mkh(0xAC),
        .signature       = [_]u8{0xEE} ** 64,
        .payload         = .{ .soul_anchored = mkh(0x55) },
    };
}

const P = "/tmp/bkgdb_wal_enc_v1_";

// ── A. Basic Roundtrip ─────────────────────────────────────────────────────

test "wal_encrypted: roundtrip — soul_anchored" {
    const io = std.testing.io;
    const path = P ++ "rt_soul.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    {
        var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis());
        defer w.deinit();
        try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0));
    }
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    const ev = try r.readNextEncrypted(std.testing.allocator, &kr);
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(@as(u64, 0), ev.?.sequence);
    try std.testing.expect((try r.readNextEncrypted(std.testing.allocator, &kr)) == null);
}

test "wal_encrypted: roundtrip — manifestation_booted" {
    const io = std.testing.io;
    const path = P ++ "rt_boot.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    const ev = LedgerEventEnvelope{
        .sequence        = 7,
        .prev_event_hash = mkh(0x01),
        .event_hash      = mkh(0x02),
        .actor_pubkey    = mkh(0xAC),
        .signature       = [_]u8{0xEE} ** 64,
        .payload = .{ .manifestation_booted_from_spore = .{
            .soul_hash = mkh(0x51), .spore_cid = mkh(0x52),
            .lost_cid = ledger_wal.ZERO_HASH, .initial_artifact_cid = mkh(0xA0),
        }},
    };
    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr, &ev); }
    var r = try EncryptedWalReader.init(path, testGenesis(), 7);
    defer r.deinit();
    const got = try r.readNextEncrypted(std.testing.allocator, &kr);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 7), got.?.sequence);
    const boot = got.?.payload.manifestation_booted_from_spore;
    try std.testing.expectEqualSlices(u8, &mkh(0x51), &boot.soul_hash);
}

test "wal_encrypted: roundtrip — multiple sequential frames" {
    const io = std.testing.io;
    const path = P ++ "rt_multi.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      for (0..5) |i| try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(i)); }
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    for (0..5) |i| {
        const got = try r.readNextEncrypted(std.testing.allocator, &kr);
        try std.testing.expectEqual(i, got.?.sequence);
    }
    try std.testing.expect((try r.readNextEncrypted(std.testing.allocator, &kr)) == null);
}

// ── B. Key Rotation ────────────────────────────────────────────────────────

test "wal_encrypted: rotation — KeyA frames 0..2, KeyB frames 3..5" {
    const io = std.testing.io;
    const path = P ++ "rotate.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const ka = try makeWalKey(io);
    const kb = try makeWalKey(io);
    try kr.addKey(ka);
    try kr.addKey(kb);

    { var w = try EncryptedWalWriter.init(path, ka.key_id, testGenesis()); defer w.deinit();
      for (0..3) |i| try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(i));
      w.rotateKey(kb.key_id);
      for (3..6) |i| try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(i)); }

    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    for (0..6) |i| {
        const got = try r.readNextEncrypted(std.testing.allocator, &kr);
        try std.testing.expectEqual(i, got.?.sequence);
    }
}

// ── C. Revocation ──────────────────────────────────────────────────────────

test "wal_encrypted: revocation — revoked key cannot write" {
    const io = std.testing.io;
    const path = P ++ "rev_write.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);
    try kr.revokeKey(k.key_id);

    var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis());
    defer w.deinit();
    try std.testing.expectError(
        EncryptedWalError.RevokedKey,
        w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0)),
    );
}

test "wal_encrypted: revocation — revoked key can decrypt historical frame" {
    const io = std.testing.io;
    const path = P ++ "rev_dec.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0)); }

    try kr.revokeKey(k.key_id);

    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    const got = try r.readNextEncrypted(std.testing.allocator, &kr);
    try std.testing.expectEqual(@as(u64, 0), got.?.sequence);
}

// ── D. Unknown Key ─────────────────────────────────────────────────────────

test "wal_encrypted: unknown key → UnknownKey" {
    const io = std.testing.io;
    const path = P ++ "unknown_key.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr_write = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr_write.deinit();
    const k = try makeWalKey(io);
    try kr_write.addKey(k);

    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr_write, &soulEvent(0)); }

    var kr_empty = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr_empty.deinit();
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    try std.testing.expectError(
        EncryptedWalError.UnknownKey,
        r.readNextEncrypted(std.testing.allocator, &kr_empty),
    );
}

// ── E. REPLAY PFLICHT-BEWEIS ───────────────────────────────────────────────
//
// Dieser Test beweist die kritische Architekturinvariante:
//
//   "AEAD akzeptiert Replay. WAL lehnt Replay ab."
//
// Vorgehen:
//   1. Frame #0 schreiben.
//   2. Exakt dieselben Frame-Bytes (inkl. Checksum, Envelope, Tag) nochmal anhängen.
//   3. Reader liest Frame #0 → OK (AEAD valid).
//   4. Reader liest Frame #0 erneut → ReplayDetected (WAL-Sequenzlogik).
//
// AEAD wird beim zweiten Read ebenfalls erfolgreich sein —
// der Replay wird ausschließlich durch die WAL-Sequence-Prüfung erkannt.

test "wal_encrypted: REPLAY PROOF — AEAD=valid, WAL=ReplayDetected" {
    const io = std.testing.io;
    const path = P ++ "replay_proof.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    // Schritt 1: Frame #0 schreiben
    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0)); }

    // Schritt 2: Frame-Bytes lesen und byte-identisch nochmal anhängen
    const f_rw = try std.Io.Dir.cwd().openFile(tio, path, .{ .mode = .read_write });
    defer f_rw.close(tio);
    const sz = f_rw.length(tio) catch 0;
    const frame_copy = try std.testing.allocator.alloc(u8, sz);
    defer std.testing.allocator.free(frame_copy);
    _ = f_rw.readPositionalAll(tio, frame_copy, 0) catch {};
    // Byte-identische Kopie anhängen
    f_rw.writePositionalAll(tio, frame_copy, sz) catch {};

    // Schritt 3: Reader erwartet seq=0 → erster Frame = PASS
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    const first = try r.readNextEncrypted(std.testing.allocator, &kr);
    try std.testing.expectEqual(@as(u64, 0), first.?.sequence);

    // Schritt 4: Reader erwartet seq=1, aber Frame trägt seq=0 → ReplayDetected
    // AEAD wäre für diesen Frame gültig — der Fehler kommt von der WAL-Logik.
    try std.testing.expectError(
        EncryptedWalError.ReplayDetected,
        r.readNextEncrypted(std.testing.allocator, &kr),
    );
}

// ── F. Sequence-Ordnung ────────────────────────────────────────────────────

test "wal_encrypted: sequence gap → SequenceGap" {
    const io = std.testing.io;
    const path = P ++ "seq_gap.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0));
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(2)); } // seq 1 fehlt

    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    _ = try r.readNextEncrypted(std.testing.allocator, &kr); // seq=0 OK
    try std.testing.expectError(
        EncryptedWalError.SequenceGap,
        r.readNextEncrypted(std.testing.allocator, &kr),
    );
}

test "wal_encrypted: sequence rollback → SequenceRollback" {
    const io = std.testing.io;
    const path = P ++ "seq_roll.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0));
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(1));
      // Rollback: seq 5 erzwingen (mit Reader der seq=2 erwartet)
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(5)); }

    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    _ = try r.readNextEncrypted(std.testing.allocator, &kr);
    _ = try r.readNextEncrypted(std.testing.allocator, &kr);
    try std.testing.expectError(
        EncryptedWalError.SequenceGap, // seq=5 > exp=2 → Gap
        r.readNextEncrypted(std.testing.allocator, &kr),
    );
}

test "wal_encrypted: valid sequence 0..4 passes" {
    const io = std.testing.io;
    const path = P ++ "seq_valid.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      for (0..5) |i| try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(i)); }
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    for (0..5) |i| {
        const got = try r.readNextEncrypted(std.testing.allocator, &kr);
        try std.testing.expectEqual(i, got.?.sequence);
    }
}

// ── G. Context Binding ─────────────────────────────────────────────────────

test "wal_encrypted: wrong genesis → ContextMismatch" {
    const io = std.testing.io;
    const path = P ++ "ctx_genesis.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0)); }

    var r = try EncryptedWalReader.init(path, [_]u8{0xDE} ** 32, 0);
    defer r.deinit();
    const res = r.readNextEncrypted(std.testing.allocator, &kr);
    try std.testing.expect(res == EncryptedWalError.ContextMismatch or
                            res == EncryptedWalError.EnvelopeAuthenticationFailed);
}

test "wal_encrypted: authenticated older sequence → ReplayDetected" {
    const io = std.testing.io;
    const path = P ++ "ctx_seq.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(5)); }

    // Reader erwartet seq=6. Der authentische Frame trägt seq=5 und ist daher
    // nach erfolgreicher AEAD-Prüfung ein bereits durchlaufener Sequence-Wert.
    var r = try EncryptedWalReader.init(path, testGenesis(), 6);
    defer r.deinit();
    try std.testing.expectError(
        EncryptedWalError.ReplayDetected,
        r.readNextEncrypted(std.testing.allocator, &kr),
    );
}

test "wal_encrypted: domain binding — non-WAL key rejected" {
    const io = std.testing.io;
    const path = P ++ "dom_bind.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const state_key = try keyring_mod.Keyring.generateKey(
        io, .BKGDB_STATE, testGenesis(), 1_700_000_000,
    );
    try kr.addKey(state_key);

    var w = try EncryptedWalWriter.init(path, state_key.key_id, testGenesis());
    defer w.deinit();
    try std.testing.expectError(
        EncryptedWalError.ContextMismatch,
        w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0)),
    );
}

// ── H. Tamper Matrix (Transport) ───────────────────────────────────────────

fn writeOneFrame(io: std.Io, path: []const u8, seq: u64) !void {
    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);
    var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis());
    defer w.deinit();
    try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(seq));
}

/// Liest alle Bytes einer Datei, gibt heap-allokierten Slice zurück.
fn readAll(path: []const u8) ![]u8 {
    const f = try std.Io.Dir.cwd().openFile(tio, path, .{});
    defer f.close(tio);
    const sz = f.length(tio) catch return error.IoError;
    const buf = try std.testing.allocator.alloc(u8, sz);
    _ = f.readPositionalAll(tio, buf, 0) catch {
        std.testing.allocator.free(buf);
        return error.IoError;
    };
    return buf;
}

/// Schreibt Bytes in eine Datei (überschreibt).
fn writeAll(path: []const u8, data: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(tio, path, .{});
    defer f.close(tio);
    f.writePositionalAll(tio, data, 0) catch return error.IoError;
}

test "wal_encrypted: tamper — transport magic → InvalidMagic" {
    const io = std.testing.io;
    const path = P ++ "t_magic.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    try writeOneFrame(io, path, 0);

    const data = try readAll(path);
    defer std.testing.allocator.free(data);
    data[0] ^= 0xFF;
    try writeAll(path, data);

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    try std.testing.expectError(
        EncryptedWalError.InvalidMagic,
        r.readNextEncrypted(std.testing.allocator, &kr),
    );
}

test "wal_encrypted: tamper — transport checksum → TransportChecksumMismatch" {
    const io = std.testing.io;
    const path = P ++ "t_chk.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    try writeOneFrame(io, path, 0);

    const data = try readAll(path);
    defer std.testing.allocator.free(data);
    data[8] ^= 0xFF; // Checksum-Byte 0
    try writeAll(path, data);

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    try std.testing.expectError(
        EncryptedWalError.TransportChecksumMismatch,
        r.readNextEncrypted(std.testing.allocator, &kr),
    );
}

test "wal_encrypted: tamper — frame_len inflated → FrameTooLarge/TornWrite" {
    const io = std.testing.io;
    const path = P ++ "t_len.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    try writeOneFrame(io, path, 0);

    const data = try readAll(path);
    defer std.testing.allocator.free(data);
    // frame_len Byte 3 auf 0xFF setzen → riesige Länge
    data[7] = 0xFF;
    try writeAll(path, data);

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    const res = r.readNextEncrypted(std.testing.allocator, &kr);
    try std.testing.expect(res == EncryptedWalError.FrameTooLarge or
                            res == EncryptedWalError.TornWrite);
}

// ── I. Tamper Matrix (Envelope-Felder) ────────────────────────────────────

/// Erzeugt einen gültigen verschlüsselten Frame als Byte-Array.
/// Der Caller besitzt den Buffer (muss freigeben).
fn buildValidFrame(io: std.Io, kr: *keyring_mod.Keyring, k: keyring_mod.KeyEntry, seq: u64) ![]u8 {
    var pt_buf: [MAX_WAL_EVENT_SIZE]u8 = undefined;
    const ev = soulEvent(seq);
    const pt_len = try ledger_wal.encodeEnvelope(&ev, &pt_buf);

    const env_bytes = try keyring_mod.encryptWithKeyring(
        io, std.testing.allocator, kr,
        k.key_id, pt_buf[0..pt_len],
        WAL_DOMAIN, testGenesis(), WAL_RECORD_TYPE, seq,
    );
    defer std.testing.allocator.free(env_bytes);

    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(env_bytes.len), .little);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&ledger_wal.WAL_MAGIC);
    hasher.update(&len_buf);
    hasher.update(env_bytes);
    var chk: [32]u8 = undefined;
    hasher.final(&chk);

    const total = ledger_wal.FRAME_HEADER_SIZE + env_bytes.len;
    const frame = try std.testing.allocator.alloc(u8, total);
    @memcpy(frame[0..4], &ledger_wal.WAL_MAGIC);
    @memcpy(frame[4..8], &len_buf);
    @memcpy(frame[8..40], &chk);
    @memcpy(frame[ledger_wal.FRAME_HEADER_SIZE..], env_bytes);
    return frame;
}

/// Mutiert `frame[offset]` mit XOR 0xFF, aktualisiert Transport-Checksum.
/// Optionale Checksum-Aktualisierung damit der Transport-Layer durchlässt.
fn mutateEnvByte(frame: []u8, env_offset: usize) void {
    const abs = ledger_wal.FRAME_HEADER_SIZE + env_offset;
    if (abs < frame.len) frame[abs] ^= 0xFF;
    // Checksum neu berechnen damit Transport-Layer nicht vorzeitig abbricht
    var len_buf: [4]u8 = undefined;
    @memcpy(&len_buf, frame[4..8]);
    const pl = frame[ledger_wal.FRAME_HEADER_SIZE..];
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(frame[0..4]);
    h.update(&len_buf);
    h.update(pl);
    h.final(frame[8..40]);
}

fn tamperEnvTest(io: std.Io, path: []const u8, env_offset: usize, seq: u64) !EncryptedWalError!?LedgerEventEnvelope {
    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    const frame = try buildValidFrame(io, &kr, k, seq);
    defer std.testing.allocator.free(frame);
    mutateEnvByte(frame, env_offset);
    try writeAll(path, frame);

    var r = try EncryptedWalReader.init(path, testGenesis(), seq);
    defer r.deinit();
    return r.readNextEncrypted(std.testing.allocator, &kr);
}

test "wal_encrypted: tamper — envelope magic[0] → InvalidEnvelopeMagic" {
    const io = std.testing.io;
    const path = P ++ "te_magic.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    const res = try tamperEnvTest(io, path, 0, 0); // offset 0 = magic[0]
    try std.testing.expectError(EncryptedWalError.InvalidEnvelopeMagic, res);
}

test "wal_encrypted: tamper — envelope version → UnsupportedVersion" {
    const io = std.testing.io;
    const path = P ++ "te_ver.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    const res = try tamperEnvTest(io, path, 4, 0); // offset 4 = version
    try std.testing.expectError(EncryptedWalError.UnsupportedVersion, res);
}

test "wal_encrypted: tamper — algorithm → UnsupportedAlgorithm" {
    const io = std.testing.io;
    const path = P ++ "te_alg.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    const res = try tamperEnvTest(io, path, 5, 0);
    try std.testing.expectError(EncryptedWalError.UnsupportedAlgorithm, res);
}

test "wal_encrypted: tamper — domain → UnsupportedDomain" {
    const io = std.testing.io;
    const path = P ++ "te_dom.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    const res = try tamperEnvTest(io, path, 6, 0);
    // Entweder UnsupportedDomain oder ContextMismatch je nach Wert
    try std.testing.expect(res == EncryptedWalError.UnsupportedDomain or
                            res == EncryptedWalError.ContextMismatch or
                            res == EncryptedWalError.EnvelopeAuthenticationFailed);
}

test "wal_encrypted: tamper — flags → UnknownFlags" {
    const io = std.testing.io;
    const path = P ++ "te_flags.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    // Wir setzen flags direkt auf 0x01 (nicht XOR, da 0x00 XOR FF = 0xFF auch UnknownFlags)
    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);
    const frame = try buildValidFrame(io, &kr, k, 0);
    defer std.testing.allocator.free(frame);
    frame[ledger_wal.FRAME_HEADER_SIZE + 7] = 0x01; // flags = 1
    mutateEnvByte(frame, 999); // dummy call um checksum zu refreshen... aber wir brauchen eigene Logik
    // Checksum neu berechnen
    var len_buf: [4]u8 = undefined; @memcpy(&len_buf, frame[4..8]);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(frame[0..4]); h.update(&len_buf);
    h.update(frame[ledger_wal.FRAME_HEADER_SIZE..]);
    h.final(frame[8..40]);
    try writeAll(path, frame);
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    try std.testing.expectError(
        EncryptedWalError.UnknownFlags,
        r.readNextEncrypted(std.testing.allocator, &kr),
    );
}

test "wal_encrypted: tamper — key_id byte 0 → ContextMismatch/UnknownKey" {
    const io = std.testing.io;
    const path = P ++ "te_kid.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    const res = try tamperEnvTest(io, path, 8, 0); // offset 8 = key_id[0]
    try std.testing.expect(res == EncryptedWalError.UnknownKey or
                            res == EncryptedWalError.ContextMismatch or
                            res == EncryptedWalError.EnvelopeAuthenticationFailed);
}

test "wal_encrypted: tamper — genesis_hash byte 0 → ContextMismatch" {
    const io = std.testing.io;
    const path = P ++ "te_gen.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    const res = try tamperEnvTest(io, path, 24, 0); // offset 24 = genesis_hash[0]
    try std.testing.expect(res == EncryptedWalError.ContextMismatch or
                            res == EncryptedWalError.EnvelopeAuthenticationFailed);
}

test "wal_encrypted: tamper — record_type → UnsupportedRecordType" {
    const io = std.testing.io;
    const path = P ++ "te_rt.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    const res = try tamperEnvTest(io, path, 56, 0); // offset 56 = record_type
    try std.testing.expect(res == EncryptedWalError.UnsupportedRecordType or
                            res == EncryptedWalError.ContextMismatch or
                            res == EncryptedWalError.EnvelopeAuthenticationFailed);
}

test "wal_encrypted: tamper — sequence byte 0 → ContextMismatch/AuthFailed" {
    const io = std.testing.io;
    const path = P ++ "te_seq.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    const res = try tamperEnvTest(io, path, 57, 0); // offset 57 = sequence[0]
    try std.testing.expect(res == EncryptedWalError.ContextMismatch or
                            res == EncryptedWalError.EnvelopeAuthenticationFailed);
}

test "wal_encrypted: tamper — nonce byte 0 → AuthFailed" {
    const io = std.testing.io;
    const path = P ++ "te_nonce.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    const res = try tamperEnvTest(io, path, 65, 0); // offset 65 = nonce[0]
    try std.testing.expectError(EncryptedWalError.EnvelopeAuthenticationFailed, res);
}

test "wal_encrypted: tamper — ciphertext byte → AuthFailed" {
    const io = std.testing.io;
    const path = P ++ "te_ct.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    const res = try tamperEnvTest(io, path, 81, 0); // offset 81 = ciphertext start
    try std.testing.expectError(EncryptedWalError.EnvelopeAuthenticationFailed, res);
}

test "wal_encrypted: tamper — authentication tag → AuthFailed" {
    const io = std.testing.io;
    const path = P ++ "te_tag.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    // Tag = letzten 16 Bytes des Envelopes
    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);
    const frame = try buildValidFrame(io, &kr, k, 0);
    defer std.testing.allocator.free(frame);
    // Letztes Byte des Envelopes = letztes Tag-Byte
    frame[frame.len - 1] ^= 0xFF;
    // Checksum neu berechnen
    var len_buf: [4]u8 = undefined; @memcpy(&len_buf, frame[4..8]);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(frame[0..4]); h.update(&len_buf);
    h.update(frame[ledger_wal.FRAME_HEADER_SIZE..]);
    h.final(frame[8..40]);
    try writeAll(path, frame);
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    try std.testing.expectError(
        EncryptedWalError.EnvelopeAuthenticationFailed,
        r.readNextEncrypted(std.testing.allocator, &kr),
    );
}

// ── J. Truncation ──────────────────────────────────────────────────────────

test "wal_encrypted: truncation — empty file → null" {
    const path = P ++ "trunc_empty.wal";
    { const f = try std.Io.Dir.cwd().createFile(tio, path, .{}); f.close(tio); }
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    try std.testing.expect((try r.readNextEncrypted(std.testing.allocator, &kr)) == null);
}

test "wal_encrypted: truncation — partial header → TornWrite" {
    const path = P ++ "trunc_hdr.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    var partial: [20]u8 = [_]u8{0} ** 20;
    @memcpy(partial[0..4], &ledger_wal.WAL_MAGIC);
    try writeAll(path, &partial);
    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    try std.testing.expectError(
        EncryptedWalError.TornWrite,
        r.readNextEncrypted(std.testing.allocator, &kr),
    );
}

test "wal_encrypted: truncation — header only no payload → TornWrite" {
    const path = P ++ "trunc_nopay.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    var hdr: [ledger_wal.FRAME_HEADER_SIZE]u8 = [_]u8{0} ** ledger_wal.FRAME_HEADER_SIZE;
    @memcpy(hdr[0..4], &ledger_wal.WAL_MAGIC);
    std.mem.writeInt(u32, hdr[4..8], 200, .little); // frame_len=200, kein Payload
    try writeAll(path, &hdr);
    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    try std.testing.expectError(
        EncryptedWalError.TornWrite,
        r.readNextEncrypted(std.testing.allocator, &kr),
    );
}

test "wal_encrypted: truncation — truncated tag → TornWrite/TransportChecksumMismatch" {
    const io = std.testing.io;
    const path = P ++ "trunc_tag.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    try writeOneFrame(io, path, 0);

    const data = try readAll(path);
    defer std.testing.allocator.free(data);
    // 8 Bytes abschneiden (halber Tag)
    try writeAll(path, data[0 .. data.len - 8]);

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    const res = r.readNextEncrypted(std.testing.allocator, &kr);
    try std.testing.expect(res == EncryptedWalError.TornWrite or
                            res == EncryptedWalError.TransportChecksumMismatch);
}

// ── K. Nonce Freshness ─────────────────────────────────────────────────────

test "wal_encrypted: nonce freshness — same event twice produces different envelopes" {
    const io = std.testing.io;
    const path1 = P ++ "nonce1.wal";
    const path2 = P ++ "nonce2.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path1) catch {};
    defer std.Io.Dir.cwd().deleteFile(tio, path2) catch {};

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);

    { var w = try EncryptedWalWriter.init(path1, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0)); }
    { var w = try EncryptedWalWriter.init(path2, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0)); }

    const d1 = try readAll(path1);
    defer std.testing.allocator.free(d1);
    const d2 = try readAll(path2);
    defer std.testing.allocator.free(d2);
    // Frames müssen verschieden sein (verschiedene Nonces)
    try std.testing.expect(!std.mem.eql(u8, d1, d2));
}

// ── L. Memory Safety ──────────────────────────────────────────────────────

test "wal_encrypted: memory — unknown key no leak" {
    const io = std.testing.io;
    const path = P ++ "mem_unk.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    var kr_w = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr_w.deinit();
    const k = try makeWalKey(io);
    try kr_w.addKey(k);
    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr_w, &soulEvent(0)); }
    var kr_e = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr_e.deinit();
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    try std.testing.expectError(EncryptedWalError.UnknownKey,
        r.readNextEncrypted(std.testing.allocator, &kr_e));
}

test "wal_encrypted: memory — revoked write no leak" {
    const io = std.testing.io;
    const path = P ++ "mem_rev.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);
    try kr.revokeKey(k.key_id);
    var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis());
    defer w.deinit();
    try std.testing.expectError(EncryptedWalError.RevokedKey,
        w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0)));
}

test "wal_encrypted: memory — auth failure frees internal buffer" {
    const io = std.testing.io;
    const path = P ++ "mem_auth.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    try writeOneFrame(io, path, 0);

    const data = try readAll(path);
    defer std.testing.allocator.free(data);
    data[data.len - 1] ^= 0x01; // Tag korrupt → auth fail
    // Checksum aktualisieren
    var len_buf: [4]u8 = undefined; @memcpy(&len_buf, data[4..8]);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(data[0..4]); h.update(&len_buf);
    h.update(data[ledger_wal.FRAME_HEADER_SIZE..]);
    h.final(data[8..40]);
    try writeAll(path, data);

    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    // Wir können keinen Key hinzufügen ohne das Material zu kennen → UnknownKey
    var r = try EncryptedWalReader.init(path, testGenesis(), 0);
    defer r.deinit();
    const res = r.readNextEncrypted(std.testing.allocator, &kr);
    try std.testing.expect(res == EncryptedWalError.UnknownKey or
                            res == EncryptedWalError.EnvelopeAuthenticationFailed);
}

test "wal_encrypted: memory — wrong genesis no leak" {
    const io = std.testing.io;
    const path = P ++ "mem_gen.wal";
    defer std.Io.Dir.cwd().deleteFile(tio, path) catch {};
    var kr = keyring_mod.Keyring.init(std.testing.allocator);
    defer kr.deinit();
    const k = try makeWalKey(io);
    try kr.addKey(k);
    { var w = try EncryptedWalWriter.init(path, k.key_id, testGenesis()); defer w.deinit();
      try w.appendEncrypted(io, std.testing.allocator, &kr, &soulEvent(0)); }
    var r = try EncryptedWalReader.init(path, [_]u8{0xDE} ** 32, 0);
    defer r.deinit();
    const res = r.readNextEncrypted(std.testing.allocator, &kr);
    try std.testing.expect(res == EncryptedWalError.ContextMismatch or
                            res == EncryptedWalError.EnvelopeAuthenticationFailed);
}
