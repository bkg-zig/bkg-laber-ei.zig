/// BKGDB Encryption Envelope v1
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   GENESIS_AUTHORITY_v1.md (kryptografische Primitive)
///
/// ═══════════════════════════════════════════════════════════════
/// WIRE FORMAT (81-Byte-Header, Little Endian, kein Padding)
/// ═══════════════════════════════════════════════════════════════
///
///  Offset  Size  Field
///  ──────  ────  ─────────────────
///       0     4  magic            [0x42, 0x4B, 0x47, 0x31] = "BKG1"
///       4     1  version          0x01
///       5     1  algorithm        0x01 = ChaCha20Poly1305
///       6     1  domain           0x01–0x05 (s. Domain enum)
///       7     1  flags            0x00 (reserviert)
///       8    16  key_id           opaker Schlüssel-Bezeichner
///      24    32  genesis_hash     Genesis Authority Hash
///      56     1  record_type      0x01–0x05 (s. RecordType enum)
///      57     8  sequence         Ledger-Sequenznummer (u64 LE)
///      65    12  nonce            ChaCha20Poly1305-Nonce (frisch per io.random)
///      77     4  ciphertext_len   Payload-Länge in Bytes (u32 LE)
///      81     N  ciphertext       verschlüsselter Payload
///   81+N    16  authentication_tag  Poly1305-Tag
///
/// Header-Größe:         81 Bytes
/// Tag-Größe:            16 Bytes
/// Gesamter Envelope:    97 + ciphertext_len Bytes
///
/// ═══════════════════════════════════════════════════════════════
/// AAD SEMANTICS
/// ═══════════════════════════════════════════════════════════════
///
/// Die exakt selben 81 Bytes, die als Wire-Header serialisiert werden,
/// dienen gleichzeitig als AEAD Additional Authenticated Data (AAD).
/// Header.encode() ist die einzige Quelle für beides.
///
/// ═══════════════════════════════════════════════════════════════
/// CONTEXT BINDING
/// ═══════════════════════════════════════════════════════════════
///
/// Jeder Envelope ist kryptografisch an seinen Context gebunden:
///   domain, key_id, genesis_hash, record_type, sequence
///
/// Beim Decrypt wird der dekodierte Header gegen den erwarteten Context
/// geprüft. Ein STATE-Envelope kann nicht als WAL-Envelope akzeptiert
/// werden. Kein Feld kann ohne AEAD-Bruch manipuliert werden.
///
/// ═══════════════════════════════════════════════════════════════
/// NONCE GENERATION
/// ═══════════════════════════════════════════════════════════════
///
/// Nonces werden ausschließlich über injiziertes std.Io erzeugt:
///   io.random(nonce_buffer)
///
/// Kein std.crypto.random. Kein globaler RNG. Kein OS-spezifischer Code.
///
/// ═══════════════════════════════════════════════════════════════
/// FAIL-CLOSED BEHAVIOR
/// ═══════════════════════════════════════════════════════════════
///
/// Plaintext wird niemals vor erfolgreicher AEAD-Verifikation zurückgegeben.
/// Bei AuthenticationFailed wird der intern allozierte Plaintext-Puffer
/// freigegeben. Der Caller erhält in diesem Fall keinen Plaintext.
///
/// ═══════════════════════════════════════════════════════════════
/// BUFFER OWNERSHIP
/// ═══════════════════════════════════════════════════════════════
///
/// encrypt() gibt einen owned Slice zurück — Caller muss ihn mit dem
/// übergebenen Allocator freigeben.
///
/// decrypt() gibt einen owned Slice zurück — Caller muss ihn mit dem
/// übergebenen Allocator freigeben.
///
/// Auf Fehlerpfaden werden intern allozierte Puffer stets freigegeben.
///
/// ═══════════════════════════════════════════════════════════════
/// MAXIMUM PAYLOAD
/// ═══════════════════════════════════════════════════════════════
///
/// MAX_ENVELOPE_PAYLOAD = 64 MiB
/// ciphertext_len wird vor jeder Allokation gegen diesen Wert geprüft.
///
const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

// ── Konstanten ─────────────────────────────────────────────────────────────

/// Exakte Wire-Header-Größe in Bytes (unveränderlich, Teil des v1-Formats).
pub const HEADER_SIZE: usize = 81;

/// Poly1305-Tag-Größe.
pub const TAG_SIZE: usize = Aead.tag_length;        // 16

/// ChaCha20-Nonce-Größe.
pub const NONCE_SIZE: usize = Aead.nonce_length;    // 12

/// ChaCha20Poly1305-Schlüsselgröße.
pub const KEY_SIZE: usize = Aead.key_length;         // 32

/// Envelope v1 — Wire-Version.
pub const VERSION: u8 = 0x01;

/// Algorithm-Tag für ChaCha20Poly1305.
pub const ALG_CHACHA20_POLY1305: u8 = 0x01;

/// Reserviert; muss exakt 0x00 sein.
pub const FLAGS_RESERVED: u8 = 0x00;

/// Maximum ciphertext_len — wird vor Allokation geprüft.
pub const MAX_ENVELOPE_PAYLOAD: u32 = 64 * 1024 * 1024;

/// Magic-Bytes "BKG1".
pub const MAGIC: [4]u8 = .{ 0x42, 0x4B, 0x47, 0x31 };

// ── Kompilezeitprüfung der Konstanten ──────────────────────────────────────
comptime {
    // Sicherstellen, dass Aead-Konstanten zu Zig 0.16 ChaCha20Poly1305 passen.
    if (TAG_SIZE != 16)   @compileError("TAG_SIZE muss 16 sein");
    if (NONCE_SIZE != 12) @compileError("NONCE_SIZE muss 12 sein");
    if (KEY_SIZE != 32)   @compileError("KEY_SIZE muss 32 sein");
    // HEADER_SIZE-Berechnung:
    // 4 (magic) + 1 (version) + 1 (alg) + 1 (domain) + 1 (flags)
    // + 16 (key_id) + 32 (genesis_hash) + 1 (record_type)
    // + 8 (sequence) + 12 (nonce) + 4 (ciphertext_len) = 81
    if (HEADER_SIZE != 81) @compileError("HEADER_SIZE muss 81 sein");
}

// ── Domain ─────────────────────────────────────────────────────────────────

/// Bezeichnet den BKGDB-Layer, dem ein Envelope angehört.
pub const Domain = enum(u8) {
    BKGDB_WAL     = 0x01,
    BKGDB_GENESIS = 0x02,
    BKGDB_STATE   = 0x03,
    BKGDB_DERIVED = 0x04,
    BKGDB_TEST    = 0x05,
};

/// Liest einen Domain-Wert aus einem Rohbyte.
/// Unbekannte Werte → UnsupportedDomain.
fn domainFromByte(b: u8) EnvelopeError!Domain {
    return switch (b) {
        0x01 => .BKGDB_WAL,
        0x02 => .BKGDB_GENESIS,
        0x03 => .BKGDB_STATE,
        0x04 => .BKGDB_DERIVED,
        0x05 => .BKGDB_TEST,
        else => EnvelopeError.UnsupportedDomain,
    };
}

// ── RecordType ─────────────────────────────────────────────────────────────

/// Bezeichnet den Typ des verschlüsselten Records.
pub const RecordType = enum(u8) {
    EVENT          = 0x01,
    WAL_FRAME      = 0x02,
    GENESIS_RECORD = 0x03,
    STATE_SNAPSHOT = 0x04,
    DERIVED_STATE  = 0x05,
};

/// Liest einen RecordType-Wert aus einem Rohbyte.
/// Unbekannte Werte → UnsupportedRecordType.
fn recordTypeFromByte(b: u8) EnvelopeError!RecordType {
    return switch (b) {
        0x01 => .EVENT,
        0x02 => .WAL_FRAME,
        0x03 => .GENESIS_RECORD,
        0x04 => .STATE_SNAPSHOT,
        0x05 => .DERIVED_STATE,
        else => EnvelopeError.UnsupportedRecordType,
    };
}

// ── Fehler ─────────────────────────────────────────────────────────────────

pub const EnvelopeError = error{
    /// Envelope kürzer als erlaubt oder inkonsistente Länge.
    MalformedEnvelope,
    /// Magic-Bytes stimmen nicht mit "BKG1" überein.
    InvalidMagic,
    /// Version-Feld ist nicht 0x01.
    UnsupportedVersion,
    /// Algorithm-Feld ist nicht 0x01 (ChaCha20Poly1305).
    UnsupportedAlgorithm,
    /// Domain-Wert ist nicht in {0x01..0x05}.
    UnsupportedDomain,
    /// Flags-Feld ist nicht 0x00.
    UnknownFlags,
    /// RecordType-Wert ist nicht in {0x01..0x05}.
    UnsupportedRecordType,
    /// Längenfeld ergibt eine inkonsistente Envelope-Gesamtgröße.
    InvalidLength,
    /// ciphertext_len übersteigt MAX_ENVELOPE_PAYLOAD.
    PayloadTooLarge,
    /// key_id im Header stimmt nicht mit dem erwarteten Context überein.
    KeyIdMismatch,
    /// Domain, genesis_hash, record_type oder sequence stimmt nicht überein.
    InvalidContext,
    /// AEAD-Tag-Verifikation fehlgeschlagen — kein Plaintext zurückgegeben.
    AuthenticationFailed,
    /// Speicherallokation fehlgeschlagen.
    OutOfMemory,
};

// ── Context ────────────────────────────────────────────────────────────────

/// Kryptografisch bindender Kontext eines Envelopes.
///
/// Alle fünf Felder sind Bestandteil des AEAD-AAD über den Header.
/// Beim Decrypt wird der dekodierte Header gegen den erwarteten Context
/// Feld für Feld verglichen — jede Abweichung → Fehler.
pub const Context = struct {
    domain:       Domain,
    key_id:       [16]u8,
    genesis_hash: [32]u8,
    record_type:  RecordType,
    sequence:     u64,
};

// ── Header ─────────────────────────────────────────────────────────────────

/// Vollständiger 81-Byte Wire-Header eines BKGDB Encryption Envelopes.
///
/// encode() und decode() sind die einzigen erlaubten Wege zwischen
/// struct-Repräsentation und Wire-Bytes. Kein asBytes, kein bitCast.
pub const Header = struct {
    magic:          [4]u8,
    version:        u8,
    algorithm:      u8,
    domain:         Domain,
    flags:          u8,
    key_id:         [16]u8,
    genesis_hash:   [32]u8,
    record_type:    RecordType,
    sequence:       u64,
    nonce:          [NONCE_SIZE]u8,
    ciphertext_len: u32,

    /// Serialisiert den Header kanonisch in exakt 81 Bytes.
    ///
    /// Diese Funktion ist die Single Source of Truth für:
    ///   1. Den Wire-Header (erster Teil des Envelopes)
    ///   2. Den AEAD-AAD (identische Bytes, gleiche Funktion)
    ///
    /// Explizite Feld-für-Feld-Codierung. Little Endian. Kein Padding.
    /// Keine Struct-Layout-Abhängigkeit.
    pub fn encode(self: *const Header, out: *[HEADER_SIZE]u8) void {
        // Offset 0..4: magic (4 Bytes)
        out[0] = self.magic[0];
        out[1] = self.magic[1];
        out[2] = self.magic[2];
        out[3] = self.magic[3];
        // Offset 4: version (1 Byte)
        out[4] = self.version;
        // Offset 5: algorithm (1 Byte)
        out[5] = self.algorithm;
        // Offset 6: domain (1 Byte)
        out[6] = @intFromEnum(self.domain);
        // Offset 7: flags (1 Byte)
        out[7] = self.flags;
        // Offset 8..24: key_id (16 Bytes)
        @memcpy(out[8..24], &self.key_id);
        // Offset 24..56: genesis_hash (32 Bytes)
        @memcpy(out[24..56], &self.genesis_hash);
        // Offset 56: record_type (1 Byte)
        out[56] = @intFromEnum(self.record_type);
        // Offset 57..65: sequence (8 Bytes, LE)
        std.mem.writeInt(u64, out[57..65], self.sequence, .little);
        // Offset 65..77: nonce (12 Bytes)
        @memcpy(out[65..77], &self.nonce);
        // Offset 77..81: ciphertext_len (4 Bytes, LE)
        std.mem.writeInt(u32, out[77..81], self.ciphertext_len, .little);
    }

    /// Dekodiert 81 Wire-Bytes in einen Header.
    ///
    /// Prüfreihenfolge (fail-closed, jeder Fehler bricht sofort ab):
    ///   1. Magic
    ///   2. Version
    ///   3. Algorithm
    ///   4. Domain
    ///   5. Flags
    ///   6. Key-ID (gelesen)
    ///   7. Genesis-Hash (gelesen)
    ///   8. Record-Type
    ///   9. Sequence (gelesen)
    ///  10. Nonce (gelesen)
    ///  11. ciphertext_len (gelesen)
    ///  12. Maximalgröße gegen MAX_ENVELOPE_PAYLOAD
    pub fn decode(bytes: *const [HEADER_SIZE]u8) EnvelopeError!Header {
        // 1. Magic
        if (bytes[0] != MAGIC[0] or bytes[1] != MAGIC[1] or
            bytes[2] != MAGIC[2] or bytes[3] != MAGIC[3])
            return EnvelopeError.InvalidMagic;

        // 2. Version
        if (bytes[4] != VERSION)
            return EnvelopeError.UnsupportedVersion;

        // 3. Algorithm
        if (bytes[5] != ALG_CHACHA20_POLY1305)
            return EnvelopeError.UnsupportedAlgorithm;

        // 4. Domain — unbekannter Wert → UnsupportedDomain
        const domain = try domainFromByte(bytes[6]);

        // 5. Flags
        if (bytes[7] != FLAGS_RESERVED)
            return EnvelopeError.UnknownFlags;

        // 6. Key-ID
        var key_id: [16]u8 = undefined;
        @memcpy(&key_id, bytes[8..24]);

        // 7. Genesis-Hash
        var genesis_hash: [32]u8 = undefined;
        @memcpy(&genesis_hash, bytes[24..56]);

        // 8. Record-Type — unbekannter Wert → UnsupportedRecordType
        const record_type = try recordTypeFromByte(bytes[56]);

        // 9. Sequence
        const sequence = std.mem.readInt(u64, bytes[57..65], .little);

        // 10. Nonce
        var nonce: [NONCE_SIZE]u8 = undefined;
        @memcpy(&nonce, bytes[65..77]);

        // 11. ciphertext_len
        const ciphertext_len = std.mem.readInt(u32, bytes[77..81], .little);

        // 12. Maximalgröße
        if (ciphertext_len > MAX_ENVELOPE_PAYLOAD)
            return EnvelopeError.PayloadTooLarge;

        return Header{
            .magic          = .{ bytes[0], bytes[1], bytes[2], bytes[3] },
            .version        = bytes[4],
            .algorithm      = bytes[5],
            .domain         = domain,
            .flags          = bytes[7],
            .key_id         = key_id,
            .genesis_hash   = genesis_hash,
            .record_type    = record_type,
            .sequence       = sequence,
            .nonce          = nonce,
            .ciphertext_len = ciphertext_len,
        };
    }
};

// ── encrypt ────────────────────────────────────────────────────────────────

/// Verschlüsselt plaintext in einen vollständigen BKGDB Encryption Envelope.
///
/// Ablauf:
///   1. Payload-Länge gegen MAX_ENVELOPE_PAYLOAD prüfen.
///   2. Nonce via io.random() frisch erzeugen.
///   3. Header konstruieren (magic, version, alg, context, nonce, len).
///   4. Header mit encode() in [81]u8 serialisieren.
///   5. Envelope-Puffer allozieren (81 + N + 16 Bytes).
///   6. Wire-Header kopieren.
///   7. ChaCha20Poly1305.encrypt() mit AAD = header_bytes.
///   8. 16-Byte-Tag anhängen.
///   9. Envelope zurückgeben (owned — Caller muss freigeben).
///
/// Nonce: frisch per io.random() — kein globaler RNG, kein fester Wert.
///
/// Ownership: Caller muss den zurückgegebenen Slice freigeben.
pub fn encrypt(
    io:        std.Io,
    allocator: std.mem.Allocator,
    key:       [KEY_SIZE]u8,
    plaintext: []const u8,
    context:   Context,
) EnvelopeError![]u8 {
    // 1. Payload-Länge prüfen
    if (plaintext.len > MAX_ENVELOPE_PAYLOAD)
        return EnvelopeError.PayloadTooLarge;

    // 2. Nonce frisch erzeugen
    var nonce: [NONCE_SIZE]u8 = undefined;
    io.random(&nonce);

    // 3. Header konstruieren
    const ciphertext_len: u32 = @intCast(plaintext.len);
    const header = Header{
        .magic          = MAGIC,
        .version        = VERSION,
        .algorithm      = ALG_CHACHA20_POLY1305,
        .domain         = context.domain,
        .flags          = FLAGS_RESERVED,
        .key_id         = context.key_id,
        .genesis_hash   = context.genesis_hash,
        .record_type    = context.record_type,
        .sequence       = context.sequence,
        .nonce          = nonce,
        .ciphertext_len = ciphertext_len,
    };

    // 4. Header serialisieren — Single Source of Truth für Wire-Header und AAD
    var header_bytes: [HEADER_SIZE]u8 = undefined;
    header.encode(&header_bytes);

    // 5. Envelope allozieren: 81 (header) + N (ciphertext) + 16 (tag)
    const envelope_len = HEADER_SIZE + plaintext.len + TAG_SIZE;
    const envelope = allocator.alloc(u8, envelope_len) catch
        return EnvelopeError.OutOfMemory;

    // 6. Wire-Header kopieren
    @memcpy(envelope[0..HEADER_SIZE], &header_bytes);

    // 7. ChaCha20Poly1305.encrypt
    //    AAD = header_bytes (identisch mit Wire-Header)
    const ct_slice  = envelope[HEADER_SIZE .. HEADER_SIZE + plaintext.len];
    var tag_buf: [TAG_SIZE]u8 = undefined;
    Aead.encrypt(ct_slice, &tag_buf, plaintext, &header_bytes, nonce, key);

    // 8. Tag anhängen
    @memcpy(envelope[HEADER_SIZE + plaintext.len ..], &tag_buf);

    return envelope;
}

// ── decrypt ────────────────────────────────────────────────────────────────

/// Entschlüsselt einen BKGDB Encryption Envelope.
///
/// Ablauf:
///   1. Mindestlänge (81 + 16 = 97) prüfen.
///   2. Ersten 81 Bytes als Header extrahieren.
///   3. Header dekodieren (fail-closed).
///   4. ciphertext_len gegen MAX prüfen (bereits in decode, hier redundant sicher).
///   5. Exakte Envelope-Gesamtlänge prüfen.
///   6. Context validieren (domain, key_id, genesis_hash, record_type, sequence).
///   7. Ciphertext- und Tag-Slices setzen.
///   8. Plaintext-Puffer erst jetzt allozieren.
///   9. AEAD-Decrypt — Authentication vor Plaintext-Rückgabe.
///  10. Bei Fehler: Puffer freigeben, AuthenticationFailed.
///  11. Nur bei Erfolg: Plaintext zurückgeben.
///
/// FAIL-CLOSED: Kein Plaintext verlässt diese Funktion vor Auth-Erfolg.
///
/// Ownership: Caller muss den zurückgegebenen Slice freigeben.
pub fn decrypt(
    allocator:        std.mem.Allocator,
    envelope:         []const u8,
    key:              [KEY_SIZE]u8,
    expected_context: Context,
) EnvelopeError![]u8 {
    // 1. Mindestlänge: 81 (header) + 16 (tag) = 97
    if (envelope.len < HEADER_SIZE + TAG_SIZE)
        return EnvelopeError.MalformedEnvelope;

    // 2. Header-Bytes extrahieren
    const header_bytes: *const [HEADER_SIZE]u8 = envelope[0..HEADER_SIZE];

    // 3. Header dekodieren — fail-closed (gibt strukturelle Fehler zurück)
    const header = try Header.decode(header_bytes);

    // 4. ciphertext_len ist bereits in decode() gegen MAX geprüft.
    //    Exakte Gesamtlänge prüfen.
    const expected_total = HEADER_SIZE + @as(usize, header.ciphertext_len) + TAG_SIZE;
    if (envelope.len != expected_total)
        return EnvelopeError.InvalidLength;

    // 5. Context validieren — jede Abweichung → spezifischer Fehler
    // key_id
    if (!std.mem.eql(u8, &header.key_id, &expected_context.key_id))
        return EnvelopeError.KeyIdMismatch;

    // domain, genesis_hash, record_type, sequence
    if (header.domain != expected_context.domain or
        !std.mem.eql(u8, &header.genesis_hash, &expected_context.genesis_hash) or
        header.record_type != expected_context.record_type or
        header.sequence != expected_context.sequence)
        return EnvelopeError.InvalidContext;

    // 6. Ciphertext- und Tag-Slices
    const ct_start  = HEADER_SIZE;
    const ct_end    = HEADER_SIZE + @as(usize, header.ciphertext_len);
    const ciphertext = envelope[ct_start..ct_end];
    const tag_bytes  = envelope[ct_end .. ct_end + TAG_SIZE];
    var tag: [TAG_SIZE]u8 = undefined;
    @memcpy(&tag, tag_bytes);

    // 7. Plaintext-Puffer allozieren — erst JETZT, NACH aller Strukturprüfung
    const plaintext_buf = allocator.alloc(u8, header.ciphertext_len) catch
        return EnvelopeError.OutOfMemory;

    // 8. AEAD-Decrypt — AAD = identische header_bytes (Wire-Header)
    //    FAIL-CLOSED: bei Fehler Puffer freigeben, AuthenticationFailed.
    Aead.decrypt(plaintext_buf, ciphertext, tag, header_bytes, header.nonce, key) catch {
        allocator.free(plaintext_buf);
        return EnvelopeError.AuthenticationFailed;
    };

    // 9. Nur bei erfolgreicher Authentifizierung Plaintext zurückgeben.
    return plaintext_buf;
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

// ── Test-Hilfsfunktionen ───────────────────────────────────────────────────

fn testKey(b: u8) [KEY_SIZE]u8 {
    return [_]u8{b} ** KEY_SIZE;
}

fn testContext() Context {
    return .{
        .domain       = .BKGDB_STATE,
        .key_id       = [_]u8{0x11} ** 16,
        .genesis_hash = [_]u8{0x42} ** 32,
        .record_type  = .EVENT,
        .sequence     = 42,
    };
}

fn testEncrypt(plaintext: []const u8) ![]u8 {
    const io = std.testing.io;
    const key = testKey(0xFE);
    const ctx = testContext();
    return encrypt(io, std.testing.allocator, key, plaintext, ctx);
}

// ── A. Basic Round-Trip ────────────────────────────────────────────────────

test "envelope: basic — empty plaintext" {
    const envelope = try testEncrypt("");
    defer std.testing.allocator.free(envelope);
    const pt = try decrypt(std.testing.allocator, envelope, testKey(0xFE), testContext());
    defer std.testing.allocator.free(pt);
    try std.testing.expectEqualSlices(u8, "", pt);
}

test "envelope: basic — 1 byte" {
    const envelope = try testEncrypt("X");
    defer std.testing.allocator.free(envelope);
    const pt = try decrypt(std.testing.allocator, envelope, testKey(0xFE), testContext());
    defer std.testing.allocator.free(pt);
    try std.testing.expectEqualSlices(u8, "X", pt);
}

test "envelope: basic — normal text" {
    const msg = "Hello, BKGDB Encryption Envelope v1!";
    const envelope = try testEncrypt(msg);
    defer std.testing.allocator.free(envelope);
    const pt = try decrypt(std.testing.allocator, envelope, testKey(0xFE), testContext());
    defer std.testing.allocator.free(pt);
    try std.testing.expectEqualSlices(u8, msg, pt);
}

test "envelope: basic — binary data" {
    const msg = [_]u8{ 0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF, 0xAB, 0xCD };
    const envelope = try testEncrypt(&msg);
    defer std.testing.allocator.free(envelope);
    const pt = try decrypt(std.testing.allocator, envelope, testKey(0xFE), testContext());
    defer std.testing.allocator.free(pt);
    try std.testing.expectEqualSlices(u8, &msg, pt);
}

test "envelope: basic — zero bytes" {
    const msg = [_]u8{0x00} ** 64;
    const envelope = try testEncrypt(&msg);
    defer std.testing.allocator.free(envelope);
    const pt = try decrypt(std.testing.allocator, envelope, testKey(0xFE), testContext());
    defer std.testing.allocator.free(pt);
    try std.testing.expectEqualSlices(u8, &msg, pt);
}

test "envelope: basic — 0xff bytes" {
    const msg = [_]u8{0xFF} ** 64;
    const envelope = try testEncrypt(&msg);
    defer std.testing.allocator.free(envelope);
    const pt = try decrypt(std.testing.allocator, envelope, testKey(0xFE), testContext());
    defer std.testing.allocator.free(pt);
    try std.testing.expectEqualSlices(u8, &msg, pt);
}

test "envelope: basic — larger payload (4096 bytes)" {
    const msg = [_]u8{0xAB} ** 4096;
    const envelope = try testEncrypt(&msg);
    defer std.testing.allocator.free(envelope);
    const pt = try decrypt(std.testing.allocator, envelope, testKey(0xFE), testContext());
    defer std.testing.allocator.free(pt);
    try std.testing.expectEqualSlices(u8, &msg, pt);
}

test "envelope: basic — boundary 65535 bytes" {
    const msg = [_]u8{0x55} ** 65535;
    const envelope = try testEncrypt(&msg);
    defer std.testing.allocator.free(envelope);
    const pt = try decrypt(std.testing.allocator, envelope, testKey(0xFE), testContext());
    defer std.testing.allocator.free(pt);
    try std.testing.expectEqualSlices(u8, &msg, pt);
}

// ── B. Canonical Header ────────────────────────────────────────────────────

test "envelope: header — encode produces correct offsets" {
    const ctx = testContext();
    const header = Header{
        .magic          = MAGIC,
        .version        = VERSION,
        .algorithm      = ALG_CHACHA20_POLY1305,
        .domain         = ctx.domain,
        .flags          = FLAGS_RESERVED,
        .key_id         = ctx.key_id,
        .genesis_hash   = ctx.genesis_hash,
        .record_type    = ctx.record_type,
        .sequence       = ctx.sequence,
        .nonce          = [_]u8{0x7E} ** NONCE_SIZE,
        .ciphertext_len = 256,
    };
    var out: [HEADER_SIZE]u8 = undefined;
    header.encode(&out);

    // Offset 0..4: magic "BKG1"
    try std.testing.expectEqualSlices(u8, &MAGIC, out[0..4]);
    // Offset 4: version
    try std.testing.expectEqual(VERSION, out[4]);
    // Offset 5: algorithm
    try std.testing.expectEqual(ALG_CHACHA20_POLY1305, out[5]);
    // Offset 6: domain
    try std.testing.expectEqual(@as(u8, 0x03), out[6]); // BKGDB_STATE
    // Offset 7: flags
    try std.testing.expectEqual(FLAGS_RESERVED, out[7]);
    // Offset 8..24: key_id
    try std.testing.expectEqualSlices(u8, &ctx.key_id, out[8..24]);
    // Offset 24..56: genesis_hash
    try std.testing.expectEqualSlices(u8, &ctx.genesis_hash, out[24..56]);
    // Offset 56: record_type
    try std.testing.expectEqual(@as(u8, 0x01), out[56]); // EVENT
    // Offset 57..65: sequence (LE)
    const seq_read = std.mem.readInt(u64, out[57..65], .little);
    try std.testing.expectEqual(ctx.sequence, seq_read);
    // Offset 65..77: nonce
    try std.testing.expectEqualSlices(u8, &([_]u8{0x7E} ** NONCE_SIZE), out[65..77]);
    // Offset 77..81: ciphertext_len (LE)
    const len_read = std.mem.readInt(u32, out[77..81], .little);
    try std.testing.expectEqual(@as(u32, 256), len_read);
}

test "envelope: header — decode after encode roundtrip (full 81 bytes)" {
    const ctx = testContext();
    const original = Header{
        .magic          = MAGIC,
        .version        = VERSION,
        .algorithm      = ALG_CHACHA20_POLY1305,
        .domain         = ctx.domain,
        .flags          = FLAGS_RESERVED,
        .key_id         = ctx.key_id,
        .genesis_hash   = ctx.genesis_hash,
        .record_type    = ctx.record_type,
        .sequence       = 0xDEADBEEFCAFEBABE,
        .nonce          = [_]u8{0x5A} ** NONCE_SIZE,
        .ciphertext_len = 1024,
    };
    var encoded: [HEADER_SIZE]u8 = undefined;
    original.encode(&encoded);

    // encode(decode(bytes)) == bytes — komplette 81 Bytes vergleichen
    const decoded = try Header.decode(&encoded);
    var re_encoded: [HEADER_SIZE]u8 = undefined;
    decoded.encode(&re_encoded);
    try std.testing.expectEqualSlices(u8, &encoded, &re_encoded);
}

test "envelope: header — header size is exactly 81" {
    try std.testing.expectEqual(@as(usize, 81), HEADER_SIZE);
}

// ── C. Tamper Matrix ───────────────────────────────────────────────────────

/// Erzeugt einen gültigen Envelope und gibt Header+Ciphertext zurück.
fn makeTamperEnvelope(allocator: std.mem.Allocator) ![]u8 {
    const io = std.testing.io;
    const key = testKey(0xAA);
    const ctx = testContext();
    return encrypt(io, allocator, key, "tamper test payload", ctx);
}

test "envelope: tamper — magic byte 0 → InvalidMagic" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[0] ^= 0xFF;
    try std.testing.expectError(
        EnvelopeError.InvalidMagic,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — version byte → UnsupportedVersion" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[4] ^= 0xFF;
    try std.testing.expectError(
        EnvelopeError.UnsupportedVersion,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — algorithm byte → UnsupportedAlgorithm" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[5] ^= 0xFF;
    try std.testing.expectError(
        EnvelopeError.UnsupportedAlgorithm,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — domain byte → UnsupportedDomain" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[6] = 0xFF; // ungültiger Domain-Wert
    try std.testing.expectError(
        EnvelopeError.UnsupportedDomain,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — flags byte → UnknownFlags" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[7] = 0x01; // flags ≠ 0x00
    try std.testing.expectError(
        EnvelopeError.UnknownFlags,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — key_id byte 0 → KeyIdMismatch" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[8] ^= 0xFF;
    try std.testing.expectError(
        EnvelopeError.KeyIdMismatch,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — key_id byte 15 → KeyIdMismatch" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[23] ^= 0xFF;
    try std.testing.expectError(
        EnvelopeError.KeyIdMismatch,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — genesis_hash byte 0 → InvalidContext" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[24] ^= 0xFF;
    try std.testing.expectError(
        EnvelopeError.InvalidContext,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — genesis_hash byte 31 → InvalidContext" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[55] ^= 0xFF;
    try std.testing.expectError(
        EnvelopeError.InvalidContext,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — record_type byte → UnsupportedRecordType" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[56] = 0xFF;
    try std.testing.expectError(
        EnvelopeError.UnsupportedRecordType,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — sequence byte 0 → InvalidContext" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[57] ^= 0xFF;
    try std.testing.expectError(
        EnvelopeError.InvalidContext,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — sequence byte 7 → InvalidContext" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[64] ^= 0xFF;
    try std.testing.expectError(
        EnvelopeError.InvalidContext,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — nonce byte 0 → AuthenticationFailed" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[65] ^= 0xFF; // nonce[0]
    // Header strukturell gültig, aber AAD/Nonce geändert → AEAD schlägt fehl
    try std.testing.expectError(
        EnvelopeError.AuthenticationFailed,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — nonce byte 11 → AuthenticationFailed" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[76] ^= 0xFF; // nonce[11]
    try std.testing.expectError(
        EnvelopeError.AuthenticationFailed,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — ciphertext_len byte 0 → InvalidLength" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    // Erhöhe ciphertext_len leicht — Envelope-Gesamtlänge passt nicht mehr
    const original_len = std.mem.readInt(u32, env[77..81], .little);
    std.mem.writeInt(u32, env[77..81], original_len +% 1, .little);
    const result = decrypt(std.testing.allocator, env, testKey(0xAA), testContext());
    // Entweder PayloadTooLarge (falls overflow) oder InvalidLength
    const is_expected = (result == EnvelopeError.InvalidLength or
                         result == EnvelopeError.PayloadTooLarge or
                         result == EnvelopeError.AuthenticationFailed);
    try std.testing.expect(is_expected);
}

test "envelope: tamper — ciphertext_len byte 3 → oversized" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    // Setze MSB auf 0xFF — erzeugt riesige ciphertext_len
    env[80] = 0xFF;
    const result = decrypt(std.testing.allocator, env, testKey(0xAA), testContext());
    const is_expected = (result == EnvelopeError.PayloadTooLarge or
                         result == EnvelopeError.InvalidLength);
    try std.testing.expect(is_expected);
}

test "envelope: tamper — ciphertext body → AuthenticationFailed" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    if (env.len > HEADER_SIZE + TAG_SIZE) {
        env[HEADER_SIZE] ^= 0xFF; // erster Ciphertext-Byte
    }
    try std.testing.expectError(
        EnvelopeError.AuthenticationFailed,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: tamper — authentication tag → AuthenticationFailed" {
    var env = try makeTamperEnvelope(std.testing.allocator);
    defer std.testing.allocator.free(env);
    env[env.len - 1] ^= 0xFF; // letztes Tag-Byte
    try std.testing.expectError(
        EnvelopeError.AuthenticationFailed,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

// ── D. Context-Swap Matrix ─────────────────────────────────────────────────

test "envelope: context-swap — wrong domain → InvalidContext" {
    const io = std.testing.io;
    const key = testKey(0xBB);
    const ctx = testContext();
    const env = try encrypt(io, std.testing.allocator, key, "data", ctx);
    defer std.testing.allocator.free(env);

    var wrong = ctx;
    wrong.domain = .BKGDB_WAL;
    try std.testing.expectError(
        EnvelopeError.InvalidContext,
        decrypt(std.testing.allocator, env, key, wrong),
    );
}

test "envelope: context-swap — wrong key_id → KeyIdMismatch" {
    const io = std.testing.io;
    const key = testKey(0xBB);
    const ctx = testContext();
    const env = try encrypt(io, std.testing.allocator, key, "data", ctx);
    defer std.testing.allocator.free(env);

    var wrong = ctx;
    wrong.key_id = [_]u8{0xFF} ** 16;
    try std.testing.expectError(
        EnvelopeError.KeyIdMismatch,
        decrypt(std.testing.allocator, env, key, wrong),
    );
}

test "envelope: context-swap — wrong genesis_hash → InvalidContext" {
    const io = std.testing.io;
    const key = testKey(0xBB);
    const ctx = testContext();
    const env = try encrypt(io, std.testing.allocator, key, "data", ctx);
    defer std.testing.allocator.free(env);

    var wrong = ctx;
    wrong.genesis_hash = [_]u8{0x00} ** 32;
    try std.testing.expectError(
        EnvelopeError.InvalidContext,
        decrypt(std.testing.allocator, env, key, wrong),
    );
}

test "envelope: context-swap — wrong record_type → InvalidContext" {
    const io = std.testing.io;
    const key = testKey(0xBB);
    const ctx = testContext();
    const env = try encrypt(io, std.testing.allocator, key, "data", ctx);
    defer std.testing.allocator.free(env);

    var wrong = ctx;
    wrong.record_type = .WAL_FRAME;
    try std.testing.expectError(
        EnvelopeError.InvalidContext,
        decrypt(std.testing.allocator, env, key, wrong),
    );
}

test "envelope: context-swap — wrong sequence → InvalidContext" {
    const io = std.testing.io;
    const key = testKey(0xBB);
    const ctx = testContext();
    const env = try encrypt(io, std.testing.allocator, key, "data", ctx);
    defer std.testing.allocator.free(env);

    var wrong = ctx;
    wrong.sequence = ctx.sequence + 1;
    try std.testing.expectError(
        EnvelopeError.InvalidContext,
        decrypt(std.testing.allocator, env, key, wrong),
    );
}

// ── E. Wrong Key ───────────────────────────────────────────────────────────

test "envelope: wrong key — key B → AuthenticationFailed" {
    const io = std.testing.io;
    const env = try encrypt(io, std.testing.allocator, testKey(0xAA), "secret", testContext());
    defer std.testing.allocator.free(env);
    try std.testing.expectError(
        EnvelopeError.AuthenticationFailed,
        decrypt(std.testing.allocator, env, testKey(0xBB), testContext()),
    );
}

test "envelope: wrong key — all-zero key → AuthenticationFailed" {
    const io = std.testing.io;
    const env = try encrypt(io, std.testing.allocator, testKey(0xAA), "secret", testContext());
    defer std.testing.allocator.free(env);
    try std.testing.expectError(
        EnvelopeError.AuthenticationFailed,
        decrypt(std.testing.allocator, env, testKey(0x00), testContext()),
    );
}

test "envelope: wrong key — fully different key → AuthenticationFailed" {
    const io = std.testing.io;
    var other_key: [KEY_SIZE]u8 = undefined;
    for (&other_key, 0..) |*b, i| b.* = @as(u8, @intCast(i));
    const env = try encrypt(io, std.testing.allocator, testKey(0xAA), "secret", testContext());
    defer std.testing.allocator.free(env);
    try std.testing.expectError(
        EnvelopeError.AuthenticationFailed,
        decrypt(std.testing.allocator, env, other_key, testContext()),
    );
}

// ── F. Nonce Freshness ────────────────────────────────────────────────────

test "envelope: nonce freshness — zwei Encrypts mit gleichen Inputs erzeugen verschiedene Envelopes" {
    const io = std.testing.io;
    const key = testKey(0xCC);
    const ctx = testContext();
    const pt = "nonce freshness test";

    const env1 = try encrypt(io, std.testing.allocator, key, pt, ctx);
    defer std.testing.allocator.free(env1);
    const env2 = try encrypt(io, std.testing.allocator, key, pt, ctx);
    defer std.testing.allocator.free(env2);

    // Beide Envelopes müssen verschieden sein (verschiedene Nonces)
    try std.testing.expect(!std.mem.eql(u8, env1, env2));

    // Beide müssen erfolgreich entschlüsselt werden können
    const pt1 = try decrypt(std.testing.allocator, env1, key, ctx);
    defer std.testing.allocator.free(pt1);
    const pt2 = try decrypt(std.testing.allocator, env2, key, ctx);
    defer std.testing.allocator.free(pt2);
    try std.testing.expectEqualSlices(u8, pt, pt1);
    try std.testing.expectEqualSlices(u8, pt, pt2);
}

// ── G. Malformed Input ────────────────────────────────────────────────────

test "envelope: malformed — empty input → MalformedEnvelope" {
    try std.testing.expectError(
        EnvelopeError.MalformedEnvelope,
        decrypt(std.testing.allocator, "", testKey(0xAA), testContext()),
    );
}

test "envelope: malformed — 1 byte → MalformedEnvelope" {
    const data = [_]u8{0x42};
    try std.testing.expectError(
        EnvelopeError.MalformedEnvelope,
        decrypt(std.testing.allocator, &data, testKey(0xAA), testContext()),
    );
}

test "envelope: malformed — 80 bytes → MalformedEnvelope" {
    const data = [_]u8{0x00} ** 80;
    try std.testing.expectError(
        EnvelopeError.MalformedEnvelope,
        decrypt(std.testing.allocator, &data, testKey(0xAA), testContext()),
    );
}

test "envelope: malformed — 81 bytes → MalformedEnvelope (kein Tag)" {
    // 81 Bytes < 81+16 = 97 Minimum
    const data = [_]u8{0x00} ** 81;
    try std.testing.expectError(
        EnvelopeError.MalformedEnvelope,
        decrypt(std.testing.allocator, &data, testKey(0xAA), testContext()),
    );
}

test "envelope: malformed — 96 bytes → MalformedEnvelope" {
    // 96 < 97
    const data = [_]u8{0x00} ** 96;
    try std.testing.expectError(
        EnvelopeError.MalformedEnvelope,
        decrypt(std.testing.allocator, &data, testKey(0xAA), testContext()),
    );
}

test "envelope: malformed — truncated ciphertext → InvalidLength" {
    const io = std.testing.io;
    const env_full = try encrypt(io, std.testing.allocator, testKey(0xAA), "hello world", testContext());
    defer std.testing.allocator.free(env_full);
    // Kürze auf header + halbes Ciphertext (kein vollständiger Tag)
    const truncated = env_full[0 .. env_full.len - 10];
    const result = decrypt(std.testing.allocator, truncated, testKey(0xAA), testContext());
    const is_expected = (result == EnvelopeError.InvalidLength or
                         result == EnvelopeError.MalformedEnvelope);
    try std.testing.expect(is_expected);
}

test "envelope: malformed — invalid magic → InvalidMagic" {
    var data = [_]u8{0x00} ** 97;
    data[0] = 0xFF; // kaputtes Magic
    try std.testing.expectError(
        EnvelopeError.InvalidMagic,
        decrypt(std.testing.allocator, &data, testKey(0xAA), testContext()),
    );
}

test "envelope: malformed — invalid version → UnsupportedVersion" {
    var data: [97]u8 = [_]u8{0x00} ** 97;
    data[0] = MAGIC[0]; data[1] = MAGIC[1]; data[2] = MAGIC[2]; data[3] = MAGIC[3];
    data[4] = 0xFF; // ungültige Version
    data[5] = ALG_CHACHA20_POLY1305;
    data[6] = 0x01; // BKGDB_WAL
    try std.testing.expectError(
        EnvelopeError.UnsupportedVersion,
        decrypt(std.testing.allocator, &data, testKey(0xAA), testContext()),
    );
}

test "envelope: malformed — invalid algorithm → UnsupportedAlgorithm" {
    var data: [97]u8 = [_]u8{0x00} ** 97;
    data[0] = MAGIC[0]; data[1] = MAGIC[1]; data[2] = MAGIC[2]; data[3] = MAGIC[3];
    data[4] = VERSION;
    data[5] = 0xFF; // ungültiger Algorithmus
    data[6] = 0x01;
    try std.testing.expectError(
        EnvelopeError.UnsupportedAlgorithm,
        decrypt(std.testing.allocator, &data, testKey(0xAA), testContext()),
    );
}

test "envelope: malformed — invalid domain → UnsupportedDomain" {
    var data: [97]u8 = [_]u8{0x00} ** 97;
    data[0] = MAGIC[0]; data[1] = MAGIC[1]; data[2] = MAGIC[2]; data[3] = MAGIC[3];
    data[4] = VERSION;
    data[5] = ALG_CHACHA20_POLY1305;
    data[6] = 0xFF; // ungültige Domain
    try std.testing.expectError(
        EnvelopeError.UnsupportedDomain,
        decrypt(std.testing.allocator, &data, testKey(0xAA), testContext()),
    );
}

test "envelope: malformed — invalid record_type → UnsupportedRecordType" {
    var data: [97]u8 = [_]u8{0x00} ** 97;
    data[0] = MAGIC[0]; data[1] = MAGIC[1]; data[2] = MAGIC[2]; data[3] = MAGIC[3];
    data[4] = VERSION;
    data[5] = ALG_CHACHA20_POLY1305;
    data[6] = 0x01; // BKGDB_WAL
    data[7] = FLAGS_RESERVED;
    data[56] = 0xFF; // ungültiger RecordType
    try std.testing.expectError(
        EnvelopeError.UnsupportedRecordType,
        decrypt(std.testing.allocator, &data, testKey(0xAA), testContext()),
    );
}

test "envelope: malformed — invalid flags → UnknownFlags" {
    var data: [97]u8 = [_]u8{0x00} ** 97;
    data[0] = MAGIC[0]; data[1] = MAGIC[1]; data[2] = MAGIC[2]; data[3] = MAGIC[3];
    data[4] = VERSION;
    data[5] = ALG_CHACHA20_POLY1305;
    data[6] = 0x01; // BKGDB_WAL
    data[7] = 0x01; // flags ≠ 0 → UnknownFlags
    try std.testing.expectError(
        EnvelopeError.UnknownFlags,
        decrypt(std.testing.allocator, &data, testKey(0xAA), testContext()),
    );
}

test "envelope: malformed — oversized ciphertext_len does not allocate" {
    // Setze ciphertext_len auf MAX+1 — muss vor Allokation abgelehnt werden
    var data: [97]u8 = [_]u8{0x00} ** 97;
    data[0] = MAGIC[0]; data[1] = MAGIC[1]; data[2] = MAGIC[2]; data[3] = MAGIC[3];
    data[4] = VERSION;
    data[5] = ALG_CHACHA20_POLY1305;
    data[6] = 0x01; // BKGDB_WAL
    data[7] = FLAGS_RESERVED;
    data[56] = 0x01; // EVENT
    // ciphertext_len = MAX+1
    std.mem.writeInt(u32, data[77..81], MAX_ENVELOPE_PAYLOAD + 1, .little);
    try std.testing.expectError(
        EnvelopeError.PayloadTooLarge,
        decrypt(std.testing.allocator, &data, testKey(0xAA), testContext()),
    );
}

// ── H. Memory Safety ──────────────────────────────────────────────────────

test "envelope: memory — successful encrypt/decrypt no leak" {
    const io = std.testing.io;
    const key = testKey(0xDE);
    const ctx = testContext();
    const env = try encrypt(io, std.testing.allocator, key, "leak test", ctx);
    defer std.testing.allocator.free(env);
    const pt = try decrypt(std.testing.allocator, env, key, ctx);
    defer std.testing.allocator.free(pt);
    try std.testing.expectEqualSlices(u8, "leak test", pt);
}

test "envelope: memory — wrong key frees buffer internally" {
    const io = std.testing.io;
    const env = try encrypt(io, std.testing.allocator, testKey(0xAA), "data", testContext());
    defer std.testing.allocator.free(env);
    try std.testing.expectError(
        EnvelopeError.AuthenticationFailed,
        decrypt(std.testing.allocator, env, testKey(0xFF), testContext()),
    );
    // Kein Leak: interner Puffer wurde auf Fehlerpfad freigegeben
}

test "envelope: memory — corrupted tag frees buffer internally" {
    const io = std.testing.io;
    var env = try encrypt(io, std.testing.allocator, testKey(0xAA), "data", testContext());
    defer std.testing.allocator.free(env);
    env[env.len - 1] ^= 0x01;
    try std.testing.expectError(
        EnvelopeError.AuthenticationFailed,
        decrypt(std.testing.allocator, env, testKey(0xAA), testContext()),
    );
}

test "envelope: memory — truncated envelope no leak" {
    const io = std.testing.io;
    const env_full = try encrypt(io, std.testing.allocator, testKey(0xAA), "data", testContext());
    defer std.testing.allocator.free(env_full);
    const truncated = env_full[0..HEADER_SIZE]; // kein Tag
    const result = decrypt(std.testing.allocator, truncated, testKey(0xAA), testContext());
    try std.testing.expect(result == EnvelopeError.MalformedEnvelope);
}

test "envelope: memory — oversized payload encrypt rejected" {
    // plaintext.len > MAX → Fehler ohne Allokation
    const io = std.testing.io;
    // Wir können keinen echten MAX+1 Puffer allozieren, daher simulieren wir
    // den Check mit einem Slice-Trick: großer Slice mit 0-Kapazität
    _ = io; // io nicht benötigt, da Fehler vor Allokation
    // Direkter Unit-Test: encrypt prüft len vor Allokation
    const fake_ptr = @as([*]const u8, @ptrFromInt(0x1000));
    const oversized: []const u8 = fake_ptr[0..@as(usize, MAX_ENVELOPE_PAYLOAD) + 1];
    try std.testing.expectError(
        EnvelopeError.PayloadTooLarge,
        encrypt(std.testing.io, std.testing.allocator, testKey(0xAA), oversized, testContext()),
    );
}

// ── I. All Domain und RecordType Varianten ────────────────────────────────

test "envelope: all domains roundtrip" {
    const domains = [_]Domain{ .BKGDB_WAL, .BKGDB_GENESIS, .BKGDB_STATE, .BKGDB_DERIVED, .BKGDB_TEST };
    const io = std.testing.io;
    const key = testKey(0x77);
    for (domains) |domain| {
        var ctx = testContext();
        ctx.domain = domain;
        const env = try encrypt(io, std.testing.allocator, key, "domain test", ctx);
        defer std.testing.allocator.free(env);
        const pt = try decrypt(std.testing.allocator, env, key, ctx);
        defer std.testing.allocator.free(pt);
        try std.testing.expectEqualSlices(u8, "domain test", pt);
    }
}

test "envelope: all record types roundtrip" {
    const types = [_]RecordType{ .EVENT, .WAL_FRAME, .GENESIS_RECORD, .STATE_SNAPSHOT, .DERIVED_STATE };
    const io = std.testing.io;
    const key = testKey(0x88);
    for (types) |rt| {
        var ctx = testContext();
        ctx.record_type = rt;
        const env = try encrypt(io, std.testing.allocator, key, "record type test", ctx);
        defer std.testing.allocator.free(env);
        const pt = try decrypt(std.testing.allocator, env, key, ctx);
        defer std.testing.allocator.free(pt);
        try std.testing.expectEqualSlices(u8, "record type test", pt);
    }
}

// ── J. Envelope-Größenprüfung ─────────────────────────────────────────────

test "envelope: size — envelope length is exactly 97 + plaintext.len" {
    const io = std.testing.io;
    const key = testKey(0xAA);
    const ctx = testContext();
    const pt = "size check";
    const env = try encrypt(io, std.testing.allocator, key, pt, ctx);
    defer std.testing.allocator.free(env);
    try std.testing.expectEqual(HEADER_SIZE + pt.len + TAG_SIZE, env.len);
    try std.testing.expectEqual(@as(usize, 97 + pt.len), env.len);
}
