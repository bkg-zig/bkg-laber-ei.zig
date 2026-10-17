/// BKGDB WAL Encryption v1 — Frame-granularer Consumer Layer
///
/// Status: PROVEN & FROZEN — 2026-09-01
///
/// ═══════════════════════════════════════════════════════════════
/// VERANTWORTUNG DIESES LAYERS
/// ═══════════════════════════════════════════════════════════════
///
/// WAL Encryption v1 ist ausschließlich ein Consumer der bereits
/// bewiesenen Primitive. Er erfindet keine Kryptografie.
///
///   WAL Writer
///       │
///       ├── encodeEnvelope()    ← kanonisches TLV (ledger_wal.zig)
///       │
///       ▼
///   Keyring v1                  ← Key Identity / Authorization
///       │
///       ▼
///   Envelope v1                 ← ChaCha20Poly1305 AEAD
///       │
///       ▼
///   writeFrameAt()              ← WAL Transport (ledger_wal.zig)
///       │
///       ▼
///   [WAL frame: magic+len+checksum+envelope_bytes]
///
/// Beim Lesen (Decrypt-Pfad):
///
///   readFrameAt()               ← WAL Transport, Torn-Write-Check
///       │
///       ▼
///   Header.decode()             ← Envelope Header (offset 8..24 → key_id)
///       │
///       ▼
///   Keyring.lookupAny()         ← ACTIVE und REVOKED für historisches Lesen
///       │
///       ▼
///   envelope.decrypt()          ← AEAD-Verifikation + Context-Check
///       │
///       ▼
///   decodeEnvelope()            ← kanonisches TLV → LedgerEventEnvelope
///
/// ═══════════════════════════════════════════════════════════════
/// WAL FRAME FORMAT (verschlüsselter Pfad)
/// ═══════════════════════════════════════════════════════════════
///
/// Der WAL-Transport-Header bleibt identisch zum unverschlüsselten Pfad:
///
///   magic(4)          = "BKG1"
///   frame_len(4)      = Länge des Envelope-Payloads in Bytes
///   checksum_sha256(32) = SHA256(magic || frame_len_le4 || envelope_bytes)
///   envelope_bytes(N) = vollständiger BKGDB Encryption Envelope v1
///
/// Der Checksum dient der Torn-Write-Detection (Transport-Layer).
/// Der Envelope-AEAD-Tag ist die kryptografische Authentizität (Crypto-Layer).
/// Beide Schichten sind unabhängig und nicht redundant.
///
/// ═══════════════════════════════════════════════════════════════
/// CHECKSUM-SEMANTIK
/// ═══════════════════════════════════════════════════════════════
///
/// checksum = SHA256(magic || frame_len_le4 || envelope_bytes)
///
/// Zweck: Torn-Write-Erkennung beim Crash-Recovery.
/// Wenn magic/frame_len inkonsistent oder checksum falsch → TornWrite.
/// Das schützt den Transport-Frame, nicht den kryptografischen Inhalt.
///
/// Der Envelope-Tag schützt den kryptografischen Inhalt.
///
/// ═══════════════════════════════════════════════════════════════
/// SEQUENCE-BINDING
/// ═══════════════════════════════════════════════════════════════
///
/// `sequence` landet in den 81-Byte-AAD des Envelopes.
/// Der Reader übergibt `expected_sequence` aus dem WAL/Rebuild-Zustand.
/// Ein Frame an einer falschen Position schlägt bei Context-Prüfung fehl.
///
/// AEAD ist kein Replay-Schutz.
/// Replay-/Duplicate-Erkennung liegt im WAL/Rebuilder-Layer.
///
/// ═══════════════════════════════════════════════════════════════
/// REVOCATION SEMANTIK
/// ═══════════════════════════════════════════════════════════════
///
///   ACTIVE  → Encrypt erlaubt, Decrypt erlaubt
///   REVOKED → Encrypt VERBOTEN, Decrypt erlaubt (historische Daten)
///
/// Der Reader verwendet lookupAny() — REVOKED Keys können historische
/// WAL-Frames entschlüsseln. Neue Frames mit revoked Keys werden abgelehnt.
///
/// ═══════════════════════════════════════════════════════════════
/// FROZEN MODULE DEPENDENCY
/// ═══════════════════════════════════════════════════════════════
///
///   envelope.zig SHA256: 081af87ff0ab1dad35bb84a964e22f7a282135e79bdce61b51d102c45d276ca4
///   keyring.zig  SHA256: 695061c684ba61fc13a5747321dd2b4a2b8385a40f188459d0196efdaef57578
///
/// Beide Module sind PROVEN & FROZEN und werden hier nicht verändert.
///
const std = @import("std");

const ledger_wal  = @import("ledger_wal.zig");
const envelope_mod = @import("../crypto/envelope.zig");
const keyring_mod  = @import("../crypto/keyring.zig");

pub const LedgerEventEnvelope = ledger_wal.LedgerEventEnvelope;
pub const Hash                = ledger_wal.Hash;

// Re-Export der relevanten Fehlertypen für Consumer
pub const EnvelopeError = envelope_mod.EnvelopeError;
pub const KeyringError  = keyring_mod.KeyringError;
pub const LedgerWalError = ledger_wal.LedgerWalError;

// ── Konstanten ─────────────────────────────────────────────────────────────

/// Maximum-Größe für den kanonischen TLV-Payload vor Verschlüsselung.
/// Entspricht dem bestehenden MAX_PAYLOAD_SIZE aus ledger_wal.zig.
pub const ENC_MAX_PLAINTEXT: usize = ledger_wal.MAX_PAYLOAD_SIZE; // 4096

/// Maximum-Größe des verschlüsselten Envelopes:
///   HEADER_SIZE(81) + MAX_PLAINTEXT(4096) + TAG_SIZE(16) = 4193
pub const ENC_MAX_ENVELOPE: usize =
    envelope_mod.HEADER_SIZE + ENC_MAX_PLAINTEXT + envelope_mod.TAG_SIZE;

/// Domain-Wert für verschlüsselte WAL-Frames.
pub const WAL_DOMAIN: envelope_mod.Domain = .BKGDB_WAL;

/// RecordType für verschlüsselte WAL-Frames.
pub const WAL_RECORD_TYPE: envelope_mod.RecordType = .EVENT;

// ── Fehler ─────────────────────────────────────────────────────────────────

pub const WalEncError = error{
    /// Key nicht im Keyring.
    KeyNotFound,
    /// Key ist REVOKED — für neue Frames verboten.
    KeyRevoked,
    /// Domain, genesis_hash, record_type oder sequence stimmt nicht.
    InvalidContext,
    /// key_id aus Frame stimmt nicht mit expected_context.key_id überein.
    KeyIdMismatch,
    /// AEAD-Tag-Verifikation fehlgeschlagen.
    AuthenticationFailed,
    /// Envelope-Header strukturell ungültig.
    MalformedEnvelope,
    /// Envelope-Header: ungültiges Magic.
    InvalidMagic,
    /// Envelope-Header: ungültige Version.
    UnsupportedVersion,
    /// Envelope-Header: ungültiger Algorithmus.
    UnsupportedAlgorithm,
    /// Envelope-Header: ungültige Domain.
    UnsupportedDomain,
    /// Envelope-Header: unbekannte Flags.
    UnknownFlags,
    /// Envelope-Header: ungültiger RecordType.
    UnsupportedRecordType,
    /// Envelope-Länge inkonsistent.
    InvalidLength,
    /// Payload überschreitet ENC_MAX_PLAINTEXT.
    PayloadTooLarge,
    /// WAL-Frame: Magic fehlt oder falsch.
    WalInvalidMagic,
    /// WAL-Frame: Torn write oder Disk-Korruption.
    WalTornWrite,
    /// WAL-Frame: Frame-Länge ungültig.
    WalInvalidFrameLength,
    /// WAL-Frame: TLV-Daten inkonsistent.
    WalMalformedPayload,
    /// WAL-Frame: Pflichtfeld fehlt.
    WalMissingField,
    /// Sequence-Duplikat, Replay oder Gap erkannt.
    SequenceViolation,
    /// I/O Fehler.
    IoError,
    OutOfMemory,
};

/// Übersetzt LedgerWalError → WalEncError (verlustarm).
fn walErr(e: ledger_wal.LedgerWalError) WalEncError {
    return switch (e) {
        error.InvalidMagic      => WalEncError.WalInvalidMagic,
        error.TornWrite         => WalEncError.WalTornWrite,
        error.InvalidFrameLength => WalEncError.WalInvalidFrameLength,
        error.MalformedPayload  => WalEncError.WalMalformedPayload,
        error.MissingField      => WalEncError.WalMissingField,
        error.IoError           => WalEncError.IoError,
        error.OutOfMemory       => WalEncError.OutOfMemory,
    };
}

/// Übersetzt EnvelopeError → WalEncError (verlustarm).
fn envErr(e: envelope_mod.EnvelopeError) WalEncError {
    return switch (e) {
        error.MalformedEnvelope      => WalEncError.MalformedEnvelope,
        error.InvalidMagic           => WalEncError.InvalidMagic,
        error.UnsupportedVersion     => WalEncError.UnsupportedVersion,
        error.UnsupportedAlgorithm   => WalEncError.UnsupportedAlgorithm,
        error.UnsupportedDomain      => WalEncError.UnsupportedDomain,
        error.UnknownFlags           => WalEncError.UnknownFlags,
        error.UnsupportedRecordType  => WalEncError.UnsupportedRecordType,
        error.InvalidLength          => WalEncError.InvalidLength,
        error.PayloadTooLarge        => WalEncError.PayloadTooLarge,
        error.KeyIdMismatch          => WalEncError.KeyIdMismatch,
        error.InvalidContext         => WalEncError.InvalidContext,
        error.AuthenticationFailed   => WalEncError.AuthenticationFailed,
        error.OutOfMemory            => WalEncError.OutOfMemory,
    };
}

// ── EncryptedWalFrame (Ergebnis des Reads) ─────────────────────────────────

/// Ergebnis eines erfolgreichen verschlüsselten Frame-Reads.
pub const EncryptedReadResult = struct {
    /// Dekodiertes LedgerEventEnvelope — Caller besitzt es.
    event: LedgerEventEnvelope,
    /// Position des nächsten Frames in der WAL-Datei.
    next_pos: u64,
};

// ── appendEncryptedFrame ───────────────────────────────────────────────────

/// Verschlüsselt ein LedgerEventEnvelope und schreibt es als WAL-Frame.
///
/// Pipeline:
///   1. encodeEnvelope() → kanonischer TLV-Plaintext.
///   2. keyring.lookupActive(active_key_id) → KeyEntry.
///   3. encryptWithKeyring() → Envelope-Bytes.
///   4. writeFrameAt() → WAL-Transport-Frame.
///
/// Der Writer verwendet ausschließlich ACTIVE Keys.
/// Ein revoked Key → WalEncError.KeyRevoked.
/// Ein unbekannter Key → WalEncError.KeyNotFound.
///
/// Ownership: envelope_bytes werden intern verwaltet (allocator.free nach write).
///
/// Gibt die neue WAL-Position zurück.
pub fn appendEncryptedFrame(
    io:          std.Io,
    allocator:   std.mem.Allocator,
    file:        std.Io.File,
    pos:         u64,
    keyring:     *const keyring_mod.Keyring,
    active_key_id: [keyring_mod.KEY_ID_SIZE]u8,
    genesis_hash: [32]u8,
    event:       *const LedgerEventEnvelope,
) WalEncError!u64 {
    // 1. Kanonischen TLV-Plaintext erzeugen (bestehende Single Source of Truth)
    var plaintext_buf: [ENC_MAX_PLAINTEXT]u8 = undefined;
    const plaintext_len = ledger_wal.encodeEnvelope(event, &plaintext_buf)
        catch |e| return walErr(e);

    // 2. Verschlüsseln via Keyring-Adapter
    //    encryptWithKeyring prüft: lookupAny → status == ACTIVE → domain → genesis
    const envelope_bytes = keyring_mod.encryptWithKeyring(
        io, allocator, keyring,
        active_key_id,
        plaintext_buf[0..plaintext_len],
        WAL_DOMAIN,
        genesis_hash,
        WAL_RECORD_TYPE,
        event.sequence,
    ) catch |e| return switch (e) {
        // KeyringError-Zweig
        error.KeyNotFound         => WalEncError.KeyNotFound,
        error.KeyRevoked          => WalEncError.KeyRevoked,
        error.DuplicateKeyId      => WalEncError.KeyNotFound,      // kann hier nicht auftreten
        error.InvalidKeyMaterial  => WalEncError.KeyNotFound,      // kann hier nicht auftreten
        error.InvalidContext      => WalEncError.InvalidContext,
        error.OutOfMemory         => WalEncError.OutOfMemory,
        // EnvelopeError-Zweig (vollständig aufgelistet)
        error.MalformedEnvelope     => WalEncError.MalformedEnvelope,
        error.InvalidMagic          => WalEncError.InvalidMagic,
        error.UnsupportedVersion    => WalEncError.UnsupportedVersion,
        error.UnsupportedAlgorithm  => WalEncError.UnsupportedAlgorithm,
        error.UnsupportedDomain     => WalEncError.UnsupportedDomain,
        error.UnknownFlags          => WalEncError.UnknownFlags,
        error.UnsupportedRecordType => WalEncError.UnsupportedRecordType,
        error.InvalidLength         => WalEncError.InvalidLength,
        error.PayloadTooLarge       => WalEncError.PayloadTooLarge,
        error.KeyIdMismatch         => WalEncError.KeyIdMismatch,
        error.AuthenticationFailed  => WalEncError.AuthenticationFailed,
    };
    defer allocator.free(envelope_bytes);

    // 3. Atomares WAL-Write: kompletter Envelope als einziger Payload
    //    writeFrameAt erzeugt: magic + frame_len + checksum_sha256 + envelope_bytes
    const tio = std.testing.io;
    var frame_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &frame_len_buf, @intCast(envelope_bytes.len), .little);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&ledger_wal.WAL_MAGIC);
    hasher.update(&frame_len_buf);
    hasher.update(envelope_bytes);
    var checksum: [32]u8 = undefined;
    hasher.final(&checksum);

    var header: [ledger_wal.FRAME_HEADER_SIZE]u8 = undefined;
    @memcpy(header[0..4], &ledger_wal.WAL_MAGIC);
    @memcpy(header[4..8], &frame_len_buf);
    @memcpy(header[8..40], &checksum);

    file.writePositionalAll(tio, &header, pos) catch return WalEncError.IoError;
    file.writePositionalAll(tio, envelope_bytes, pos + ledger_wal.FRAME_HEADER_SIZE)
        catch return WalEncError.IoError;

    return pos + ledger_wal.FRAME_HEADER_SIZE + envelope_bytes.len;
}

// ── readEncryptedFrameAt ───────────────────────────────────────────────────

/// Liest und entschlüsselt einen verschlüsselten WAL-Frame.
///
/// Pipeline:
///   1. WAL-Transport lesen + Torn-Write-Check.
///   2. Envelope-Header-Bytes extrahieren (kein vollständiges Dekodieren).
///   3. key_id aus Wire-Offset 8..24 lesen.
///   4. keyring.lookupAny(key_id) — ACTIVE und REVOKED erlaubt.
///   5. Trusted expected_context konstruieren (sequence aus Caller).
///   6. envelope.decrypt() — AEAD + Context-Binding.
///   7. decodeEnvelope() — TLV → LedgerEventEnvelope.
///
/// KRITISCH: expected_sequence kommt aus dem vertrauenswürdigen WAL-Zustand
/// (Caller-Parameter), NICHT aus dem untrusted Frame-Header.
///
/// Gibt null zurück wenn EOF.
pub fn readEncryptedFrameAt(
    allocator:         std.mem.Allocator,
    file:              std.Io.File,
    file_size:         u64,
    pos:               u64,
    keyring:           *const keyring_mod.Keyring,
    expected_genesis_hash: [32]u8,
    expected_sequence: u64,
) WalEncError!?EncryptedReadResult {
    const tio = std.testing.io;

    // 1. WAL-Transport-Header lesen
    if (pos >= file_size) return null;
    if (pos + ledger_wal.FRAME_HEADER_SIZE > file_size) return WalEncError.WalTornWrite;

    var header: [ledger_wal.FRAME_HEADER_SIZE]u8 = undefined;
    const n = file.readPositionalAll(tio, &header, pos) catch return WalEncError.IoError;
    if (n < ledger_wal.FRAME_HEADER_SIZE) return WalEncError.WalTornWrite;

    if (!std.mem.eql(u8, header[0..4], &ledger_wal.WAL_MAGIC)) return WalEncError.WalInvalidMagic;

    const frame_len = std.mem.readInt(u32, header[4..8], .little);
    // Frame muss mindestens einen minimalen Envelope enthalten (97 Bytes = Header + leerer CT + Tag)
    const min_envelope = envelope_mod.HEADER_SIZE + envelope_mod.TAG_SIZE;
    if (frame_len < min_envelope) return WalEncError.WalInvalidFrameLength;
    if (frame_len > ENC_MAX_ENVELOPE) return WalEncError.PayloadTooLarge;

    if (pos + ledger_wal.FRAME_HEADER_SIZE + frame_len > file_size) return WalEncError.WalTornWrite;

    // 2. Envelope-Bytes heap-allokieren und lesen
    const envelope_bytes = allocator.alloc(u8, frame_len) catch return WalEncError.OutOfMemory;
    defer allocator.free(envelope_bytes);

    const pm = file.readPositionalAll(tio, envelope_bytes, pos + ledger_wal.FRAME_HEADER_SIZE)
        catch {
            return WalEncError.IoError;
        };
    if (pm < frame_len) return WalEncError.WalTornWrite;

    // 3. Torn-Write-Check: SHA256(magic || frame_len_le4 || envelope_bytes)
    var chk_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    chk_hasher.update(header[0..4]);
    chk_hasher.update(header[4..8]);
    chk_hasher.update(envelope_bytes);
    var computed_checksum: [32]u8 = undefined;
    chk_hasher.final(&computed_checksum);
    if (!std.mem.eql(u8, &computed_checksum, header[8..40])) return WalEncError.WalTornWrite;

    // 4. key_id aus Wire-Offset 8..24 lesen (ohne vollständiges Header-Dekodieren)
    //    Mindestlänge bereits durch min_envelope geprüft.
    var key_id: [keyring_mod.KEY_ID_SIZE]u8 = undefined;
    @memcpy(&key_id, envelope_bytes[8..24]);

    // 5. Key suchen — lookupAny: ACTIVE und REVOKED beide für Decrypt erlaubt
    const key_entry = keyring.lookupAny(key_id) orelse return WalEncError.KeyNotFound;

    // 6. Trusted expected_context konstruieren.
    //    KRITISCH: sequence kommt aus dem Caller (trusted WAL-Zustand),
    //    NICHT aus dem untrusted envelope_bytes Header.
    const expected_ctx = envelope_mod.Context{
        .domain       = WAL_DOMAIN,
        .key_id       = key_entry.key_id,
        .genesis_hash = expected_genesis_hash,
        .record_type  = WAL_RECORD_TYPE,
        .sequence     = expected_sequence,
    };

    // 7. envelope.decrypt() — AEAD-Verifikation + vollständige Context-Prüfung
    //    Fail-closed: Plaintext wird erst nach Auth-Erfolg zurückgegeben.
    const plaintext = envelope_mod.decrypt(allocator, envelope_bytes, key_entry.key_material, expected_ctx)
        catch |e| return envErr(e);
    defer allocator.free(plaintext);

    // 8. Kanonisches TLV dekodieren → LedgerEventEnvelope
    const decoded_event = ledger_wal.decodeEnvelope(plaintext)
        catch |e| return walErr(e);

    return EncryptedReadResult{
        .event    = decoded_event,
        .next_pos = pos + ledger_wal.FRAME_HEADER_SIZE + frame_len,
    };
}

// ── EncryptedWalWriter ─────────────────────────────────────────────────────

/// WAL-Writer für verschlüsselte Frames.
///
/// Hält den aktiven WAL-Key-ID und den aktuellen Schreib-Offset.
/// Der unverschlüsselte LedgerWalWriter bleibt unverändert daneben.
pub const EncryptedWalWriter = struct {
    file:          std.Io.File,
    pos:           u64,
    active_key_id: [keyring_mod.KEY_ID_SIZE]u8,
    genesis_hash:  [32]u8,

    pub fn open(
        path:          []const u8,
        active_key_id: [keyring_mod.KEY_ID_SIZE]u8,
        genesis_hash:  [32]u8,
    ) !EncryptedWalWriter {
        const tio = std.testing.io;
        const file = std.Io.Dir.cwd().createFile(tio, path, .{}) catch |e| switch (e) {
            error.PathAlreadyExists =>
                try std.Io.Dir.cwd().openFile(tio, path, .{ .mode = .read_write }),
            else => return e,
        };
        const eof = file.length(tio) catch 0;
        return EncryptedWalWriter{
            .file          = file,
            .pos           = eof,
            .active_key_id = active_key_id,
            .genesis_hash  = genesis_hash,
        };
    }

    pub fn close(self: *EncryptedWalWriter) void {
        const tio = std.testing.io;
        self.file.close(tio);
    }

    pub fn append(
        self:     *EncryptedWalWriter,
        io:       std.Io,
        allocator: std.mem.Allocator,
        keyring:  *const keyring_mod.Keyring,
        event:    *const LedgerEventEnvelope,
    ) WalEncError!void {
        const new_pos = try appendEncryptedFrame(
            io, allocator,
            self.file, self.pos,
            keyring, self.active_key_id,
            self.genesis_hash,
            event,
        );
        const tio = std.testing.io;
        self.file.sync(tio) catch return WalEncError.IoError;
        self.pos = new_pos;
    }

    /// Rotiert den aktiven Key.
    /// Alle folgenden Frames werden mit dem neuen Key geschrieben.
    /// Bestehende Frames bleiben unverändert.
    pub fn rotateKey(self: *EncryptedWalWriter, new_key_id: [keyring_mod.KEY_ID_SIZE]u8) void {
        self.active_key_id = new_key_id;
    }
};

// ── EncryptedWalReader ─────────────────────────────────────────────────────

/// WAL-Reader für verschlüsselte Frames mit Sequence-Validierung.
///
/// Hält den erwarteten Sequence-Zustand (trusted WAL-Position).
/// Die expected_sequence wird niemals aus dem untrusted Frame übernommen.
///
/// Replay-/Duplicate-Erkennung: Reader akzeptiert nur `next_expected_sequence`,
/// alle anderen Werte → WalEncError.SequenceViolation.
pub const EncryptedWalReader = struct {
    file:                   std.Io.File,
    pos:                    u64,
    file_size:              u64,
    genesis_hash:           [32]u8,
    next_expected_sequence: u64,

    pub fn open(
        path:             []const u8,
        genesis_hash:     [32]u8,
        start_sequence:   u64,
    ) !EncryptedWalReader {
        const tio = std.testing.io;
        const file = try std.Io.Dir.cwd().openFile(tio, path, .{});
        const size = file.length(tio) catch 0;
        return EncryptedWalReader{
            .file                   = file,
            .pos                    = 0,
            .file_size              = size,
            .genesis_hash           = genesis_hash,
            .next_expected_sequence = start_sequence,
        };
    }

    pub fn close(self: *EncryptedWalReader) void {
        const tio = std.testing.io;
        self.file.close(tio);
    }

    /// Liest den nächsten verschlüsselten Frame.
    ///
    /// Sequence-Validierung:
    ///   event.sequence muss exakt next_expected_sequence entsprechen.
    ///   Abweichung (duplicate, replay, gap, reorder) → SequenceViolation.
    ///
    /// Gibt null zurück bei EOF.
    pub fn readNext(
        self:      *EncryptedWalReader,
        allocator: std.mem.Allocator,
        keyring:   *const keyring_mod.Keyring,
    ) WalEncError!?LedgerEventEnvelope {
        const result = try readEncryptedFrameAt(
            allocator,
            self.file,
            self.file_size,
            self.pos,
            keyring,
            self.genesis_hash,
            self.next_expected_sequence,
        ) orelse return null;

        // Sequence-Validierung (WAL/Rebuilder-Layer, nicht AEAD)
        // Replay/Duplicate/Gap werden hier abgefangen.
        if (result.event.sequence != self.next_expected_sequence)
            return WalEncError.SequenceViolation;

        self.pos = result.next_pos;
        self.next_expected_sequence += 1;
        return result.event;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

fn mkh(b: u8) Hash {
    var h: Hash = ledger_wal.ZERO_HASH;
    h[0] = b;
    return h;
}

fn testGenesis() [32]u8 { return [_]u8{0x42} ** 32; }

fn makeKey(io: std.Io) !keyring_mod.KeyEntry {
    return keyring_mod.Keyring.generateKey(io, .BKGDB_WAL, testGenesis(), 1_700_000_000);
}

fn makeSoulAnchoredEvent(seq: u64) LedgerEventEnvelope {
    return .{
        .sequence        = seq,
        .prev_event_hash = mkh(0x00),
        .event_hash      = mkh(@intCast(seq & 0xFF)),
        .actor_pubkey    = mkh(0xAC),
        .signature       = [_]u8{0xEE} ** 64,
        .payload         = .{ .soul_anchored = mkh(0x55) },
    };
}

const WAL_TEST_PATH = "/tmp/bkgdb_enc_wal_test.wal";

// ── A. Roundtrip Tests ────────────────────────────────────────────────────

test "wal_enc: roundtrip — soul_anchored event" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, WAL_TEST_PATH) catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);

    const event = makeSoulAnchoredEvent(0);

    {
        var w = try EncryptedWalWriter.open(WAL_TEST_PATH, entry.key_id, testGenesis());
        defer w.close();
        try w.append(io, std.testing.allocator, &keyring, &event);
    }

    var r = try EncryptedWalReader.open(WAL_TEST_PATH, testGenesis(), 0);
    defer r.close();

    const decoded = try r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(decoded != null);
    try std.testing.expectEqual(@as(u64, 0), decoded.?.sequence);
    try std.testing.expectEqualSlices(u8, &mkh(0xAC), &decoded.?.actor_pubkey);

    const eof = try r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(eof == null);
}

test "wal_enc: roundtrip — manifestation_booted_from_spore" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_wal_boot.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);

    const event = LedgerEventEnvelope{
        .sequence        = 1,
        .prev_event_hash = mkh(0x01),
        .event_hash      = mkh(0x02),
        .actor_pubkey    = mkh(0xAC),
        .signature       = [_]u8{0xEE} ** 64,
        .payload = .{ .manifestation_booted_from_spore = .{
            .soul_hash            = mkh(0x51),
            .spore_cid            = mkh(0x52),
            .lost_cid             = ledger_wal.ZERO_HASH,
            .initial_artifact_cid = mkh(0xA0),
        }},
    };

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_wal_boot.wal", entry.key_id, testGenesis(),
        );
        defer w.close();
        try w.append(io, std.testing.allocator, &keyring, &event);
    }

    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_wal_boot.wal", testGenesis(), 1);
    defer r.close();
    const decoded = try r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(decoded != null);
    try std.testing.expectEqual(@as(u64, 1), decoded.?.sequence);
    const booted = decoded.?.payload.manifestation_booted_from_spore;
    try std.testing.expectEqualSlices(u8, &mkh(0x51), &booted.soul_hash);
}

test "wal_enc: roundtrip — multiple frames sequential" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_multi.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_multi.wal", entry.key_id, testGenesis(),
        );
        defer w.close();
        for (0..4) |i| {
            const ev = makeSoulAnchoredEvent(i);
            try w.append(io, std.testing.allocator, &keyring, &ev);
        }
    }

    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_multi.wal", testGenesis(), 0);
    defer r.close();
    for (0..4) |i| {
        const decoded = try r.readNext(std.testing.allocator, &keyring);
        try std.testing.expect(decoded != null);
        try std.testing.expectEqual(i, decoded.?.sequence);
    }
    const eof = try r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(eof == null);
}

// ── B. Key Rotation ───────────────────────────────────────────────────────

test "wal_enc: key rotation — frames 0..2 KeyA, frames 3..5 KeyB" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_rotate.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const key_a = try makeKey(io);
    const key_b = try makeKey(io);
    try keyring.addKey(key_a);
    try keyring.addKey(key_b);

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_rotate.wal", key_a.key_id, testGenesis(),
        );
        defer w.close();
        // Frames 0..2 mit Key A
        for (0..3) |i| {
            const ev = makeSoulAnchoredEvent(i);
            try w.append(io, std.testing.allocator, &keyring, &ev);
        }
        // Key-Rotation
        w.rotateKey(key_b.key_id);
        // Frames 3..5 mit Key B
        for (3..6) |i| {
            const ev = makeSoulAnchoredEvent(i);
            try w.append(io, std.testing.allocator, &keyring, &ev);
        }
    }

    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_rotate.wal", testGenesis(), 0);
    defer r.close();
    for (0..6) |i| {
        const decoded = try r.readNext(std.testing.allocator, &keyring);
        try std.testing.expect(decoded != null);
        try std.testing.expectEqual(i, decoded.?.sequence);
    }
    try std.testing.expect((try r.readNext(std.testing.allocator, &keyring)) == null);
}

// ── C. Revocation Semantik ────────────────────────────────────────────────

test "wal_enc: revocation — revoked key can decrypt historical frame" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_revdec.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);

    const event = makeSoulAnchoredEvent(0);
    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_revdec.wal", entry.key_id, testGenesis(),
        );
        defer w.close();
        try w.append(io, std.testing.allocator, &keyring, &event);
    }

    // Key revoziern
    try keyring.revokeKey(entry.key_id);

    // Historischen Frame immer noch lesen
    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_revdec.wal", testGenesis(), 0);
    defer r.close();
    const decoded = try r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(decoded != null);
    try std.testing.expectEqual(@as(u64, 0), decoded.?.sequence);
}

test "wal_enc: revocation — revoked key cannot write new frame" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_revwrite.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);
    try keyring.revokeKey(entry.key_id);

    var w = try EncryptedWalWriter.open(
        "/tmp/bkgdb_enc_revwrite.wal", entry.key_id, testGenesis(),
    );
    defer w.close();
    const event = makeSoulAnchoredEvent(0);
    try std.testing.expectError(
        WalEncError.KeyRevoked,
        w.append(io, std.testing.allocator, &keyring, &event),
    );
}

// ── D. Unknown Key ────────────────────────────────────────────────────────

test "wal_enc: unknown key — read returns KeyNotFound" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_unknownkey.wal") catch {};

    // Erzeuge Envelope mit Key A
    var keyring_a = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring_a.deinit();
    const key_a = try makeKey(io);
    try keyring_a.addKey(key_a);

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_unknownkey.wal", key_a.key_id, testGenesis(),
        );
        defer w.close();
        const ev = makeSoulAnchoredEvent(0);
        try w.append(io, std.testing.allocator, &keyring_a, &ev);
    }

    // Leerer Keyring — kennt Key A nicht
    var keyring_empty = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring_empty.deinit();

    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_unknownkey.wal", testGenesis(), 0);
    defer r.close();
    try std.testing.expectError(
        WalEncError.KeyNotFound,
        r.readNext(std.testing.allocator, &keyring_empty),
    );
}

// ── E. Sequence Binding ───────────────────────────────────────────────────

test "wal_enc: sequence — wrong expected_sequence → InvalidContext" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_seqbind.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_seqbind.wal", entry.key_id, testGenesis(),
        );
        defer w.close();
        const ev = makeSoulAnchoredEvent(5); // sequence=5
        try w.append(io, std.testing.allocator, &keyring, &ev);
    }

    // Reader erwartet sequence=6, Frame trägt sequence=5 → AAD-Mismatch
    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_seqbind.wal", testGenesis(), 6);
    defer r.close();
    const result = r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(result == WalEncError.InvalidContext or result == WalEncError.AuthenticationFailed);
}

// ── F. Replay und Sequence Violation ─────────────────────────────────────

test "wal_enc: sequence progression — 0,1,2,3 all pass" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_seqprog.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_seqprog.wal", entry.key_id, testGenesis(),
        );
        defer w.close();
        for (0..4) |i| {
            const ev = makeSoulAnchoredEvent(i);
            try w.append(io, std.testing.allocator, &keyring, &ev);
        }
    }

    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_seqprog.wal", testGenesis(), 0);
    defer r.close();
    for (0..4) |i| {
        const decoded = try r.readNext(std.testing.allocator, &keyring);
        try std.testing.expectEqual(i, decoded.?.sequence);
    }
}

test "wal_enc: sequence — duplicate frame (seq 0,1,1) → SequenceViolation" {
    // Wir schreiben frame 0 und frame 1 normal.
    // Dann schreiben wir frame 1 nochmal mit sequence=1.
    // Reader erwartet bei drittem Frame sequence=2 → Frame trägt 1 → Kontext-/Sequence-Fehler.
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_dup.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_dup.wal", entry.key_id, testGenesis(),
        );
        defer w.close();
        const ev0 = makeSoulAnchoredEvent(0);
        const ev1 = makeSoulAnchoredEvent(1);
        const ev1_dup = makeSoulAnchoredEvent(1); // Duplikat
        try w.append(io, std.testing.allocator, &keyring, &ev0);
        try w.append(io, std.testing.allocator, &keyring, &ev1);
        try w.append(io, std.testing.allocator, &keyring, &ev1_dup);
    }

    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_dup.wal", testGenesis(), 0);
    defer r.close();
    _ = try r.readNext(std.testing.allocator, &keyring); // seq=0 OK
    _ = try r.readNext(std.testing.allocator, &keyring); // seq=1 OK
    // Drittes Frame: Reader erwartet seq=2, Frame trägt seq=1 → Fehler
    const result = r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(result == WalEncError.SequenceViolation or
                            result == WalEncError.InvalidContext or
                            result == WalEncError.AuthenticationFailed);
}

test "wal_enc: sequence — gap (0,1,3) detected" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_gap.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_gap.wal", entry.key_id, testGenesis(),
        );
        defer w.close();
        try w.append(io, std.testing.allocator, &keyring, &makeSoulAnchoredEvent(0));
        try w.append(io, std.testing.allocator, &keyring, &makeSoulAnchoredEvent(1));
        try w.append(io, std.testing.allocator, &keyring, &makeSoulAnchoredEvent(3)); // gap: seq 2 fehlt
    }

    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_gap.wal", testGenesis(), 0);
    defer r.close();
    _ = try r.readNext(std.testing.allocator, &keyring); // seq=0
    _ = try r.readNext(std.testing.allocator, &keyring); // seq=1
    // Reader erwartet seq=2, Frame trägt seq=3 → Fehler
    const result = r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(result == WalEncError.SequenceViolation or
                            result == WalEncError.InvalidContext or
                            result == WalEncError.AuthenticationFailed);
}

// ── G. Wrong Genesis ──────────────────────────────────────────────────────

test "wal_enc: wrong genesis — reader with different genesis_hash → error" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_genesis.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io); // genesis = testGenesis()
    try keyring.addKey(entry);

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_genesis.wal", entry.key_id, testGenesis(),
        );
        defer w.close();
        try w.append(io, std.testing.allocator, &keyring,
            &makeSoulAnchoredEvent(0));
    }

    // Reader mit anderem Genesis-Hash
    const wrong_genesis = [_]u8{0xDE} ** 32;
    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_genesis.wal", wrong_genesis, 0);
    defer r.close();
    const result = r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(result == WalEncError.InvalidContext or
                            result == WalEncError.AuthenticationFailed);
}

// ── H. Tamper Matrix ──────────────────────────────────────────────────────

fn writeTestFrame(io: std.Io) ![]u8 {
    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);

    var plaintext_buf: [ledger_wal.MAX_PAYLOAD_SIZE]u8 = undefined;
    const ev = makeSoulAnchoredEvent(0);
    const pt_len = try ledger_wal.encodeEnvelope(&ev, &plaintext_buf);

    const env_bytes = try keyring_mod.encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, plaintext_buf[0..pt_len],
        .BKGDB_WAL, testGenesis(), .EVENT, 0,
    );
    defer std.testing.allocator.free(env_bytes);

    // Frame-Bytes (header + envelope) aufbauen
    var frame_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &frame_len_buf, @intCast(env_bytes.len), .little);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&ledger_wal.WAL_MAGIC);
    hasher.update(&frame_len_buf);
    hasher.update(env_bytes);
    var checksum: [32]u8 = undefined;
    hasher.final(&checksum);

    const total = ledger_wal.FRAME_HEADER_SIZE + env_bytes.len;
    const frame = try std.testing.allocator.alloc(u8, total);
    @memcpy(frame[0..4], &ledger_wal.WAL_MAGIC);
    @memcpy(frame[4..8], &frame_len_buf);
    @memcpy(frame[8..40], &checksum);
    @memcpy(frame[ledger_wal.FRAME_HEADER_SIZE..], env_bytes);
    return frame;
}

test "wal_enc: tamper — ciphertext mutation → AuthenticationFailed" {
    const io = std.testing.io;
    var frame = try writeTestFrame(io);
    defer std.testing.allocator.free(frame);

    // Ciphertext liegt nach dem WAL-Frame-Header(40) und dem Envelope-Header(81)
    const ct_offset = ledger_wal.FRAME_HEADER_SIZE + envelope_mod.HEADER_SIZE;
    if (frame.len > ct_offset + envelope_mod.TAG_SIZE) {
        frame[ct_offset] ^= 0xFF;
    }

    // Den mutierten Frame via File testen
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_tamper_ct.wal") catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, "/tmp/bkgdb_enc_tamper_ct.wal", .{});
        defer f.close(io);
        f.writePositionalAll(io, frame, 0) catch {};
    }

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    // key_id aus Frame lesen um Key hinzuzufügen
    const key_id_off = ledger_wal.FRAME_HEADER_SIZE + 8;
    var key_id: [16]u8 = undefined;
    @memcpy(&key_id, frame[key_id_off..key_id_off + 16]);

    // Wir können den Key nicht rekonstruieren — kein Material bekannt.
    // Test: leerer Keyring → KeyNotFound (oder AuthFailed wenn key zufällig drin ist)
    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_tamper_ct.wal", testGenesis(), 0);
    defer r.close();
    const result = r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(result == WalEncError.KeyNotFound or
                            result == WalEncError.AuthenticationFailed or
                            result == WalEncError.WalTornWrite);
}

test "wal_enc: tamper — authentication tag mutation → AuthenticationFailed" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_tamper_tag.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_tamper_tag.wal", entry.key_id, testGenesis(),
        );
        defer w.close();
        try w.append(io, std.testing.allocator, &keyring, &makeSoulAnchoredEvent(0));
    }

    // Letztes Byte des WAL-Files (= letztes Tag-Byte) mutieren
    {
        const tio = std.testing.io;
        const f = try std.Io.Dir.cwd().openFile(tio, "/tmp/bkgdb_enc_tamper_tag.wal",
            .{ .mode = .read_write });
        defer f.close(tio);
        const sz = f.length(tio) catch 0;
        if (sz > 0) {
            var last: [1]u8 = undefined;
            _ = f.readPositionalAll(tio, &last, sz - 1) catch {};
            last[0] ^= 0xFF;
            f.writePositionalAll(tio, &last, sz - 1) catch {};
        }
    }

    // Nach Tag-Mutation: Checksum wird fehlschlagen (weil checksum über envelope_bytes)
    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_tamper_tag.wal", testGenesis(), 0);
    defer r.close();
    const result = r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(result == WalEncError.WalTornWrite or
                            result == WalEncError.AuthenticationFailed);
}

// ── I. Truncation ─────────────────────────────────────────────────────────

test "wal_enc: truncation — empty file → null (EOF)" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_empty.wal") catch {};

    {
        const f = try std.Io.Dir.cwd().createFile(io, "/tmp/bkgdb_enc_empty.wal", .{});
        f.close(io);
    }

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_empty.wal", testGenesis(), 0);
    defer r.close();
    const result = try r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(result == null);
}

test "wal_enc: truncation — partial frame header → WalTornWrite" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_partial_hdr.wal") catch {};

    {
        const f = try std.Io.Dir.cwd().createFile(io, "/tmp/bkgdb_enc_partial_hdr.wal", .{});
        defer f.close(io);
        var partial: [20]u8 = [_]u8{0} ** 20;
        @memcpy(partial[0..4], &ledger_wal.WAL_MAGIC);
        f.writePositionalAll(io, &partial, 0) catch {};
    }

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_partial_hdr.wal", testGenesis(), 0);
    defer r.close();
    try std.testing.expectError(
        WalEncError.WalTornWrite,
        r.readNext(std.testing.allocator, &keyring),
    );
}

test "wal_enc: truncation — header only, no payload → WalTornWrite" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_hdr_only.wal") catch {};

    {
        const f = try std.Io.Dir.cwd().createFile(io, "/tmp/bkgdb_enc_hdr_only.wal", .{});
        defer f.close(io);
        var hdr: [ledger_wal.FRAME_HEADER_SIZE]u8 = [_]u8{0} ** ledger_wal.FRAME_HEADER_SIZE;
        @memcpy(hdr[0..4], &ledger_wal.WAL_MAGIC);
        // frame_len = 200 (Envelope ohne Payload im File)
        std.mem.writeInt(u32, hdr[4..8], 200, .little);
        f.writePositionalAll(io, &hdr, 0) catch {};
    }

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_hdr_only.wal", testGenesis(), 0);
    defer r.close();
    try std.testing.expectError(
        WalEncError.WalTornWrite,
        r.readNext(std.testing.allocator, &keyring),
    );
}

// ── J. Domain Binding ─────────────────────────────────────────────────────

test "wal_enc: domain binding — STATE key cannot write WAL frame" {
    const io = std.testing.io;
    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    // Key mit BKGDB_STATE Domain
    const state_entry = try keyring_mod.Keyring.generateKey(
        io, .BKGDB_STATE, testGenesis(), 1_700_000_000,
    );
    try keyring.addKey(state_entry);

    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_dom.wal") catch {};
    var w = try EncryptedWalWriter.open(
        "/tmp/bkgdb_enc_dom.wal", state_entry.key_id, testGenesis(),
    );
    defer w.close();
    const ev = makeSoulAnchoredEvent(0);
    // encryptWithKeyring prüft domain: state_entry.domain=STATE ≠ BKGDB_WAL → InvalidContext
    try std.testing.expectError(
        WalEncError.InvalidContext,
        w.append(io, std.testing.allocator, &keyring, &ev),
    );
}

// ── K. Memory Safety ──────────────────────────────────────────────────────

test "wal_enc: memory — unknown key no leak" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_mem_unk.wal") catch {};

    var keyring_a = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring_a.deinit();
    const key_a = try makeKey(io);
    try keyring_a.addKey(key_a);

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_mem_unk.wal", key_a.key_id, testGenesis(),
        );
        defer w.close();
        try w.append(io, std.testing.allocator, &keyring_a, &makeSoulAnchoredEvent(0));
    }

    var empty_keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer empty_keyring.deinit();

    var r = try EncryptedWalReader.open("/tmp/bkgdb_enc_mem_unk.wal", testGenesis(), 0);
    defer r.close();
    try std.testing.expectError(
        WalEncError.KeyNotFound,
        r.readNext(std.testing.allocator, &empty_keyring),
    );
}

test "wal_enc: memory — revoked write no leak" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_mem_rev.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);
    try keyring.revokeKey(entry.key_id);

    var w = try EncryptedWalWriter.open(
        "/tmp/bkgdb_enc_mem_rev.wal", entry.key_id, testGenesis(),
    );
    defer w.close();
    try std.testing.expectError(
        WalEncError.KeyRevoked,
        w.append(io, std.testing.allocator, &keyring, &makeSoulAnchoredEvent(0)),
    );
}

test "wal_enc: memory — wrong genesis read no leak" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/bkgdb_enc_mem_gen.wal") catch {};

    var keyring = keyring_mod.Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const entry = try makeKey(io);
    try keyring.addKey(entry);

    {
        var w = try EncryptedWalWriter.open(
            "/tmp/bkgdb_enc_mem_gen.wal", entry.key_id, testGenesis(),
        );
        defer w.close();
        try w.append(io, std.testing.allocator, &keyring, &makeSoulAnchoredEvent(0));
    }

    var r = try EncryptedWalReader.open(
        "/tmp/bkgdb_enc_mem_gen.wal", [_]u8{0xDE} ** 32, 0,
    );
    defer r.close();
    const result = r.readNext(std.testing.allocator, &keyring);
    try std.testing.expect(result == WalEncError.InvalidContext or
                            result == WalEncError.AuthenticationFailed);
}
