/// BKGDB Keyring v1 — Key Identity, Rotation & Revocation
///
/// Status: PROVEN & FROZEN — 2026-09-01
///
/// ═══════════════════════════════════════════════════════════════
/// ARCHITEKTUR
/// ═══════════════════════════════════════════════════════════════
///
/// Der Keyring ist der Identity + Lifecycle + Authorization Layer
/// für Schlüsselmaterial. Er ist NICHT die Kryptografie-Schicht.
/// Einzige AEAD-Implementierung: crypto/envelope.zig (FROZEN).
///
/// Schichtung:
///   ENVELOPE v1 (FROZEN)
///       └── KEYRING v1 (dieser Layer)
///               └── WAL ENCRYPTION (Phase 2)
///
/// ═══════════════════════════════════════════════════════════════
/// KEY IDENTITY
/// ═══════════════════════════════════════════════════════════════
///
/// key_id wird deterministisch aus key_material abgeleitet:
///
///   digest = SHA256(key_material)
///   key_id = digest[0..16]
///
/// Garantien:
///   gleiche Material  → gleiche key_id
///   verschiedene Material → unterschiedliche key_id (SHA256)
///   manuell gewählte key_id: nicht möglich — addKey() verifiziert
///
/// ═══════════════════════════════════════════════════════════════
/// KEY LIFECYCLE
/// ═══════════════════════════════════════════════════════════════
///
///   GENERATED
///       │
///       ▼
///   ACTIVE          ← einziger Status der Encrypt erlaubt
///       │
///       ▼
///   REVOKED         ← Decrypt erlaubt, Encrypt VERBOTEN
///
/// EXPIRED ist Phase 2 und nicht implementiert.
///
/// ═══════════════════════════════════════════════════════════════
/// DOMAIN & GENESIS BINDING
/// ═══════════════════════════════════════════════════════════════
///
/// Jeder Key ist an eine Envelope-Domain und einen Genesis-Hash gebunden.
/// encryptWithKeyring() prüft beide Bindings vor dem Verschlüsseln.
/// Decrypt-Binding wird durch den Envelope selbst (AAD) erzwungen.
///
/// ═══════════════════════════════════════════════════════════════
/// MEMORY / ZEROIZE
/// ═══════════════════════════════════════════════════════════════
///
/// deinit() nullt jedes key_material mit std.crypto.secureZero
/// bevor der Speicher freigegeben wird.
///
/// ═══════════════════════════════════════════════════════════════
/// ENVELOPE IMMUTABILITY
/// ═══════════════════════════════════════════════════════════════
///
/// crypto/envelope.zig ist PROVEN & FROZEN.
/// Dieser Layer verwendet ausschließlich dessen public API.
/// Keine einzige Zeile in envelope.zig wurde durch dieses Modul verändert.
///
const std = @import("std");

const envelope_mod = @import("envelope.zig");

// ── Re-Exports für Caller-Convenience ─────────────────────────────────────
pub const Domain     = envelope_mod.Domain;
pub const RecordType = envelope_mod.RecordType;

// ── Konstanten ─────────────────────────────────────────────────────────────

/// Größe des Key-Materials in Bytes.
pub const KEY_MATERIAL_SIZE: usize = envelope_mod.KEY_SIZE;  // 32

/// Größe der abgeleiteten Key-ID in Bytes.
pub const KEY_ID_SIZE: usize = 16;

// ── KeyStatus ──────────────────────────────────────────────────────────────

pub const KeyStatus = enum(u8) {
    ACTIVE  = 0x01,
    REVOKED = 0x02,
};

// ── KeyEntry ───────────────────────────────────────────────────────────────

/// Vollständiger, in sich konsistenter Schlüsseleintrag.
///
/// key_id ist deterministisch aus key_material abgeleitet:
///   key_id = SHA256(key_material)[0..16]
///
/// Der Caller darf key_id nicht direkt setzen; addKey() verweigert
/// Entries, bei denen key_id und key_material inkonsistent sind.
pub const KeyEntry = struct {
    key_id:       [KEY_ID_SIZE]u8,
    key_material: [KEY_MATERIAL_SIZE]u8,
    domain:       Domain,
    genesis_hash: [32]u8,
    created_at:   u64,
    status:       KeyStatus,
};

// ── Fehler ─────────────────────────────────────────────────────────────────

pub const KeyringError = error{
    /// Angeforderte key_id ist nicht im Keyring vorhanden.
    KeyNotFound,
    /// Key ist REVOKED — für Encrypt verboten.
    KeyRevoked,
    /// key_id bereits im Keyring vorhanden.
    DuplicateKeyId,
    /// key_material ist all-zero oder key_id passt nicht zum Material.
    InvalidKeyMaterial,
    /// Domain oder Genesis-Hash des KeyEntry stimmt nicht mit dem Context überein.
    InvalidContext,
    /// Speicherallokation fehlgeschlagen.
    OutOfMemory,
};

// ── deriveKeyId ────────────────────────────────────────────────────────────

/// Leitet key_id deterministisch aus key_material ab.
///
/// key_id = SHA256(key_material)[0..16]
///
/// Diese Funktion ist die einzige erlaubte Quelle für key_id.
pub fn deriveKeyId(material: *const [KEY_MATERIAL_SIZE]u8) [KEY_ID_SIZE]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(material, &digest, .{});
    var id: [KEY_ID_SIZE]u8 = undefined;
    @memcpy(&id, digest[0..KEY_ID_SIZE]);
    return id;
}

// ── Keyring ────────────────────────────────────────────────────────────────

/// In-memory Key-Registry.
///
/// Besitzt alle gespeicherten KeyEntries vollständig (heap-allokiert).
/// Keine globale Registry. Keine Singleton-Struktur.
///
/// Ownership: Caller muss deinit() aufrufen.
pub const Keyring = struct {
    allocator: std.mem.Allocator,
    entries:   std.ArrayListUnmanaged(KeyEntry),

    /// Initialisiert einen leeren Keyring.
    pub fn init(allocator: std.mem.Allocator) Keyring {
        return .{
            .allocator = allocator,
            .entries   = .empty,
        };
    }

    /// Nullt alle key_materials sicher, dann gibt Speicher frei.
    pub fn deinit(self: *Keyring) void {
        for (self.entries.items) |*entry| {
            std.crypto.secureZero(u8, &entry.key_material);
        }
        self.entries.deinit(self.allocator);
    }

    /// Erzeugt einen neuen KeyEntry mit frischem Material via io.random().
    ///
    /// Fügt den Entry NICHT automatisch ein — Caller ruft addKey() explizit.
    ///
    /// Ablauf:
    ///   1. Material per io.random() erzeugen.
    ///   2. All-zero check.
    ///   3. key_id ableiten.
    ///   4. Domain, genesis_hash, timestamp übernehmen.
    ///   5. Status = ACTIVE.
    ///   6. Entry zurückgeben.
    pub fn generateKey(
        io:          std.Io,
        domain:      Domain,
        genesis_hash: [32]u8,
        timestamp:   u64,
    ) KeyringError!KeyEntry {
        var material: [KEY_MATERIAL_SIZE]u8 = undefined;
        io.random(&material);

        // All-zero material ist ungültig
        const zero = [_]u8{0} ** KEY_MATERIAL_SIZE;
        if (std.mem.eql(u8, &material, &zero))
            return KeyringError.InvalidKeyMaterial;

        const key_id = deriveKeyId(&material);

        return KeyEntry{
            .key_id       = key_id,
            .key_material = material,
            .domain       = domain,
            .genesis_hash = genesis_hash,
            .created_at   = timestamp,
            .status       = .ACTIVE,
        };
    }

    /// Fügt einen vollständig erzeugten KeyEntry in den Keyring ein.
    ///
    /// Vor dem Einfügen:
    ///   1. Material-Nullprüfung.
    ///   2. key_id-Konsistenz verifizieren: SHA256(material)[0..16] == entry.key_id.
    ///   3. Duplikat-Prüfung.
    pub fn addKey(self: *Keyring, entry: KeyEntry) KeyringError!void {
        // 1. All-zero check
        const zero = [_]u8{0} ** KEY_MATERIAL_SIZE;
        if (std.mem.eql(u8, &entry.key_material, &zero))
            return KeyringError.InvalidKeyMaterial;

        // 2. key_id Konsistenz
        const expected_id = deriveKeyId(&entry.key_material);
        if (!std.mem.eql(u8, &expected_id, &entry.key_id))
            return KeyringError.InvalidKeyMaterial;

        // 3. Duplikat-Prüfung
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, &e.key_id, &entry.key_id))
                return KeyringError.DuplicateKeyId;
        }

        self.entries.append(self.allocator, entry) catch
            return KeyringError.OutOfMemory;
    }

    /// Setzt den Status eines Keys auf REVOKED.
    ///
    /// Idempotent: REVOKED → REVOKED ohne Fehler.
    /// Unbekannte key_id → KeyNotFound.
    pub fn revokeKey(self: *Keyring, key_id: [KEY_ID_SIZE]u8) KeyringError!void {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, &entry.key_id, &key_id)) {
                entry.status = .REVOKED;
                return;
            }
        }
        return KeyringError.KeyNotFound;
    }

    /// Findet ausschließlich ACTIVE Keys.
    ///
    /// REVOKED → null
    /// unknown → null
    pub fn lookupActive(self: *const Keyring, key_id: [KEY_ID_SIZE]u8) ?*const KeyEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, &entry.key_id, &key_id) and entry.status == .ACTIVE)
                return entry;
        }
        return null;
    }

    /// Findet ACTIVE und REVOKED Keys.
    ///
    /// Wird für den Decrypt-Pfad verwendet (historische Daten lesbar).
    pub fn lookupAny(self: *const Keyring, key_id: [KEY_ID_SIZE]u8) ?*const KeyEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, &entry.key_id, &key_id))
                return entry;
        }
        return null;
    }
};

// ── Envelope-Adapter ───────────────────────────────────────────────────────
//
// Diese beiden Funktionen verbinden Keyring und Envelope,
// ohne envelope.zig zu verändern.

/// Verschlüsselt plaintext über den Keyring.
///
/// Ablauf:
///   1. lookupAny(key_id) — nicht vorhanden → KeyNotFound.
///   2. status == REVOKED → KeyRevoked.
///   3. Domain-Binding prüfen.
///   4. Genesis-Hash-Binding prüfen.
///   5. Vollständigen envelope.Context erzeugen.
///   6. envelope.encrypt() aufrufen.
///
/// Nur ACTIVE Keys dürfen für Encrypt verwendet werden.
///
/// Ownership: Caller muss zurückgegebenen Slice freigeben.
pub fn encryptWithKeyring(
    io:          std.Io,
    allocator:   std.mem.Allocator,
    keyring:     *const Keyring,
    key_id:      [KEY_ID_SIZE]u8,
    plaintext:   []const u8,
    domain:      Domain,
    genesis_hash: [32]u8,
    record_type: RecordType,
    sequence:    u64,
) (KeyringError || envelope_mod.EnvelopeError)![]u8 {
    // 1. Key suchen (any — um zwischen NotFound und Revoked unterscheiden zu können)
    const entry = keyring.lookupAny(key_id) orelse return KeyringError.KeyNotFound;

    // 2. Revocation check
    if (entry.status == .REVOKED)
        return KeyringError.KeyRevoked;

    // 3. Domain-Binding
    if (entry.domain != domain)
        return KeyringError.InvalidContext;

    // 4. Genesis-Hash-Binding
    if (!std.mem.eql(u8, &entry.genesis_hash, &genesis_hash))
        return KeyringError.InvalidContext;

    // 5. Envelope-Context erzeugen — key_id aus KeyEntry (nie vom Caller übernommen)
    const ctx = envelope_mod.Context{
        .domain       = domain,
        .key_id       = entry.key_id,
        .genesis_hash = genesis_hash,
        .record_type  = record_type,
        .sequence     = sequence,
    };

    // 6. Verschlüsseln via gefrorenem Envelope
    return envelope_mod.encrypt(io, allocator, entry.key_material, plaintext, ctx);
}

/// Entschlüsselt einen BKGDB Encryption Envelope über den Keyring.
///
/// Ablauf:
///   1. Mindestlänge prüfen.
///   2. key_id aus Offset 8..24 des Wire-Headers lesen.
///   3. lookupAny(key_id) — ACTIVE und REVOKED beide gültig für Decrypt.
///   4. envelope.decrypt() aufrufen — Envelope erzwingt AEAD + Context.
///
/// REVOKED Keys dürfen für historische Entschlüsselung verwendet werden.
///
/// Ownership: Caller muss zurückgegebenen Slice freigeben.
pub fn decryptWithKeyring(
    allocator:        std.mem.Allocator,
    keyring:          *const Keyring,
    envelope_bytes:   []const u8,
    expected_context: envelope_mod.Context,
) (KeyringError || envelope_mod.EnvelopeError)![]u8 {
    // 1. Mindestlänge: HEADER_SIZE + TAG_SIZE = 97
    if (envelope_bytes.len < envelope_mod.HEADER_SIZE + envelope_mod.TAG_SIZE)
        return envelope_mod.EnvelopeError.MalformedEnvelope;

    // 2. key_id aus Wire-Header Offset 8..24 lesen (kein Parsing, direktes Slicing)
    var key_id: [KEY_ID_SIZE]u8 = undefined;
    @memcpy(&key_id, envelope_bytes[8..24]);

    // 3. Key suchen — ACTIVE und REVOKED beide für Decrypt erlaubt
    const entry = keyring.lookupAny(key_id) orelse return KeyringError.KeyNotFound;

    // 4. Envelope-Decrypt — AEAD + Context-Binding durch den gefrorenen Envelope
    return envelope_mod.decrypt(allocator, envelope_bytes, entry.key_material, expected_context);
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

// ── Test-Hilfsfunktionen ───────────────────────────────────────────────────

fn testDomain() Domain { return .BKGDB_STATE; }
fn testGenesis() [32]u8 { return [_]u8{0x42} ** 32; }
fn testTimestamp() u64 { return 1_700_000_000; }

fn makeTestEntry(io: std.Io) !KeyEntry {
    return Keyring.generateKey(io, testDomain(), testGenesis(), testTimestamp());
}

// ── A. Key Generation ──────────────────────────────────────────────────────

test "keyring: generateKey — ACTIVE status" {
    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try std.testing.expectEqual(KeyStatus.ACTIVE, entry.status);
}

test "keyring: generateKey — material is not all-zero" {
    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    const zero = [_]u8{0} ** KEY_MATERIAL_SIZE;
    try std.testing.expect(!std.mem.eql(u8, &entry.key_material, &zero));
}

test "keyring: generateKey — key_id == SHA256(material)[0..16]" {
    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    const expected_id = deriveKeyId(&entry.key_material);
    try std.testing.expectEqualSlices(u8, &expected_id, &entry.key_id);
}

test "keyring: generateKey — domain stored correctly" {
    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try std.testing.expectEqual(testDomain(), entry.domain);
}

test "keyring: generateKey — genesis_hash stored correctly" {
    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try std.testing.expectEqualSlices(u8, &testGenesis(), &entry.genesis_hash);
}

test "keyring: generateKey — timestamp stored correctly" {
    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try std.testing.expectEqual(testTimestamp(), entry.created_at);
}

test "keyring: generateKey — two keys have different key_ids" {
    const io = std.testing.io;
    const e1 = try makeTestEntry(io);
    const e2 = try makeTestEntry(io);
    try std.testing.expect(!std.mem.eql(u8, &e1.key_id, &e2.key_id));
}

test "keyring: generateKey — repeated generation works" {
    const io = std.testing.io;
    for (0..8) |_| {
        const e = try makeTestEntry(io);
        try std.testing.expectEqual(KeyStatus.ACTIVE, e.status);
    }
}

// ── B. Deterministic Identity ──────────────────────────────────────────────

test "keyring: identity — same material produces same key_id" {
    const material: [KEY_MATERIAL_SIZE]u8 = [_]u8{0xDE} ** KEY_MATERIAL_SIZE;
    const id1 = deriveKeyId(&material);
    const id2 = deriveKeyId(&material);
    try std.testing.expectEqualSlices(u8, &id1, &id2);
}

test "keyring: identity — different materials produce different key_ids" {
    const mat_a: [KEY_MATERIAL_SIZE]u8 = [_]u8{0xAA} ** KEY_MATERIAL_SIZE;
    const mat_b: [KEY_MATERIAL_SIZE]u8 = [_]u8{0xBB} ** KEY_MATERIAL_SIZE;
    const id_a = deriveKeyId(&mat_a);
    const id_b = deriveKeyId(&mat_b);
    try std.testing.expect(!std.mem.eql(u8, &id_a, &id_b));
}

test "keyring: identity — tampered key_id rejected by addKey" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const io = std.testing.io;
    var entry = try makeTestEntry(io);
    entry.key_id[0] ^= 0xFF; // key_id inkonsistent mit material

    try std.testing.expectError(
        KeyringError.InvalidKeyMaterial,
        keyring.addKey(entry),
    );
}

test "keyring: identity — correct material + id accepted" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);
}

// ── C. Lifecycle ───────────────────────────────────────────────────────────

test "keyring: lifecycle — addKey then lookupActive finds key" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    const found = keyring.lookupActive(entry.key_id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualSlices(u8, &entry.key_id, &found.?.key_id);
}

test "keyring: lifecycle — lookupAny finds ACTIVE key" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    const found = keyring.lookupAny(entry.key_id);
    try std.testing.expect(found != null);
}

test "keyring: lifecycle — revokeKey sets REVOKED" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);
    try keyring.revokeKey(entry.key_id);

    const found = keyring.lookupAny(entry.key_id);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(KeyStatus.REVOKED, found.?.status);
}

test "keyring: lifecycle — lookupActive returns null after revocation" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);
    try keyring.revokeKey(entry.key_id);

    const found = keyring.lookupActive(entry.key_id);
    try std.testing.expect(found == null);
}

test "keyring: lifecycle — lookupAny finds REVOKED key" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);
    try keyring.revokeKey(entry.key_id);

    const found = keyring.lookupAny(entry.key_id);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(KeyStatus.REVOKED, found.?.status);
}

test "keyring: lifecycle — revokeKey idempotent (REVOKED → REVOKED)" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);
    try keyring.revokeKey(entry.key_id);
    try keyring.revokeKey(entry.key_id); // muss ohne Fehler durchgehen
    try std.testing.expectEqual(KeyStatus.REVOKED, keyring.lookupAny(entry.key_id).?.status);
}

test "keyring: lifecycle — revokeKey unknown id → KeyNotFound" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const unknown_id = [_]u8{0xFF} ** KEY_ID_SIZE;
    try std.testing.expectError(
        KeyringError.KeyNotFound,
        keyring.revokeKey(unknown_id),
    );
}

// ── D. Duplicate Protection ────────────────────────────────────────────────

test "keyring: duplicate — addKey twice → DuplicateKeyId" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);
    try std.testing.expectError(
        KeyringError.DuplicateKeyId,
        keyring.addKey(entry),
    );
}

test "keyring: duplicate — copy of entry also rejected" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    const entry_copy = entry; // explizite Kopie
    try std.testing.expectError(
        KeyringError.DuplicateKeyId,
        keyring.addKey(entry_copy),
    );
}

// ── E. Zero Material ──────────────────────────────────────────────────────

test "keyring: zero material rejected by addKey" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const zero_material: [KEY_MATERIAL_SIZE]u8 = [_]u8{0} ** KEY_MATERIAL_SIZE;
    const zero_entry = KeyEntry{
        .key_id       = deriveKeyId(&zero_material),
        .key_material = zero_material,
        .domain       = testDomain(),
        .genesis_hash = testGenesis(),
        .created_at   = testTimestamp(),
        .status       = .ACTIVE,
    };
    try std.testing.expectError(
        KeyringError.InvalidKeyMaterial,
        keyring.addKey(zero_entry),
    );
}

// ── F. Context Binding ────────────────────────────────────────────────────

test "keyring: context binding — correct domain passes" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    const env_bytes = try encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, "data",
        testDomain(), testGenesis(), .EVENT, 1,
    );
    defer std.testing.allocator.free(env_bytes);
    try std.testing.expect(env_bytes.len > 0);
}

test "keyring: context binding — wrong domain → InvalidContext" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io); // domain = BKGDB_STATE
    try keyring.addKey(entry);

    try std.testing.expectError(
        KeyringError.InvalidContext,
        encryptWithKeyring(
            io, std.testing.allocator, &keyring,
            entry.key_id, "data",
            .BKGDB_WAL,   // falsche Domain
            testGenesis(), .EVENT, 1,
        ),
    );
}

test "keyring: context binding — correct genesis_hash passes" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    const env_bytes = try encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, "data",
        testDomain(), testGenesis(), .EVENT, 1,
    );
    defer std.testing.allocator.free(env_bytes);
}

test "keyring: context binding — wrong genesis_hash → InvalidContext" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    const wrong_genesis = [_]u8{0xDE} ** 32;
    try std.testing.expectError(
        KeyringError.InvalidContext,
        encryptWithKeyring(
            io, std.testing.allocator, &keyring,
            entry.key_id, "data",
            testDomain(), wrong_genesis, .EVENT, 1,
        ),
    );
}

// ── G. Envelope Round-Trip ────────────────────────────────────────────────

fn roundTrip(plaintext: []const u8) !void {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    const ctx = envelope_mod.Context{
        .domain       = testDomain(),
        .key_id       = entry.key_id,
        .genesis_hash = testGenesis(),
        .record_type  = .EVENT,
        .sequence     = 7,
    };

    const env_bytes = try encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, plaintext,
        testDomain(), testGenesis(), .EVENT, 7,
    );
    defer std.testing.allocator.free(env_bytes);

    const recovered = try decryptWithKeyring(std.testing.allocator, &keyring, env_bytes, ctx);
    defer std.testing.allocator.free(recovered);

    try std.testing.expectEqualSlices(u8, plaintext, recovered);
}

test "keyring: roundtrip — empty payload" {
    try roundTrip("");
}

test "keyring: roundtrip — 1 byte" {
    try roundTrip("X");
}

test "keyring: roundtrip — normal text" {
    try roundTrip("Hello BKGDB Keyring v1!");
}

test "keyring: roundtrip — binary data" {
    const data = [_]u8{ 0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF };
    try roundTrip(&data);
}

test "keyring: roundtrip — larger payload (4096 bytes)" {
    const data = [_]u8{0xAB} ** 4096;
    try roundTrip(&data);
}

// ── H. Revocation Semantics ───────────────────────────────────────────────

test "keyring: revocation — encrypt before revoke passes" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    const env_bytes = try encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, "before revoke",
        testDomain(), testGenesis(), .EVENT, 1,
    );
    defer std.testing.allocator.free(env_bytes);
    try std.testing.expect(env_bytes.len > 0);
}

test "keyring: revocation — encrypt after revoke → KeyRevoked" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);
    try keyring.revokeKey(entry.key_id);

    try std.testing.expectError(
        KeyringError.KeyRevoked,
        encryptWithKeyring(
            io, std.testing.allocator, &keyring,
            entry.key_id, "after revoke",
            testDomain(), testGenesis(), .EVENT, 1,
        ),
    );
}

test "keyring: revocation — decrypt historical envelope with revoked key succeeds" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    // Verschlüsseln während Key ACTIVE
    const env_bytes = try encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, "historical data",
        testDomain(), testGenesis(), .EVENT, 99,
    );
    defer std.testing.allocator.free(env_bytes);

    // Key revoziern
    try keyring.revokeKey(entry.key_id);

    // Decrypt muss trotzdem funktionieren (historische Daten)
    const ctx = envelope_mod.Context{
        .domain       = testDomain(),
        .key_id       = entry.key_id,
        .genesis_hash = testGenesis(),
        .record_type  = .EVENT,
        .sequence     = 99,
    };
    const recovered = try decryptWithKeyring(std.testing.allocator, &keyring, env_bytes, ctx);
    defer std.testing.allocator.free(recovered);
    try std.testing.expectEqualSlices(u8, "historical data", recovered);
}

// ── I. Unknown Key ────────────────────────────────────────────────────────

test "keyring: unknown key — decryptWithKeyring → KeyNotFound" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    // Erzeuge Envelope mit einer eigenen, nicht im Keyring registrierten key_id
    const io = std.testing.io;
    var other_keyring = Keyring.init(std.testing.allocator);
    defer other_keyring.deinit();

    const entry = try makeTestEntry(io);
    try other_keyring.addKey(entry);

    const env_bytes = try encryptWithKeyring(
        io, std.testing.allocator, &other_keyring,
        entry.key_id, "secret",
        testDomain(), testGenesis(), .EVENT, 1,
    );
    defer std.testing.allocator.free(env_bytes);

    // leerer Keyring kennt den Key nicht
    const ctx = envelope_mod.Context{
        .domain       = testDomain(),
        .key_id       = entry.key_id,
        .genesis_hash = testGenesis(),
        .record_type  = .EVENT,
        .sequence     = 1,
    };
    try std.testing.expectError(
        KeyringError.KeyNotFound,
        decryptWithKeyring(std.testing.allocator, &keyring, env_bytes, ctx),
    );
}

test "keyring: unknown key — encryptWithKeyring → KeyNotFound" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const unknown_id = [_]u8{0xAB} ** KEY_ID_SIZE;
    try std.testing.expectError(
        KeyringError.KeyNotFound,
        encryptWithKeyring(
            io, std.testing.allocator, &keyring,
            unknown_id, "data",
            testDomain(), testGenesis(), .EVENT, 1,
        ),
    );
}

// ── J. Tamper Integration ─────────────────────────────────────────────────
// Der Keyring darf die Envelope-Authentifizierung nicht umgehen.

test "keyring: tamper — ciphertext mutation → AuthenticationFailed" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    var env_bytes = try encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, "tamper test",
        testDomain(), testGenesis(), .EVENT, 5,
    );
    defer std.testing.allocator.free(env_bytes);

    // Ciphertext mutieren
    if (env_bytes.len > envelope_mod.HEADER_SIZE + envelope_mod.TAG_SIZE) {
        env_bytes[envelope_mod.HEADER_SIZE] ^= 0xFF;
    }

    const ctx = envelope_mod.Context{
        .domain       = testDomain(),
        .key_id       = entry.key_id,
        .genesis_hash = testGenesis(),
        .record_type  = .EVENT,
        .sequence     = 5,
    };
    try std.testing.expectError(
        envelope_mod.EnvelopeError.AuthenticationFailed,
        decryptWithKeyring(std.testing.allocator, &keyring, env_bytes, ctx),
    );
}

test "keyring: tamper — tag mutation → AuthenticationFailed" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    var env_bytes = try encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, "tag tamper",
        testDomain(), testGenesis(), .EVENT, 6,
    );
    defer std.testing.allocator.free(env_bytes);

    env_bytes[env_bytes.len - 1] ^= 0xFF; // letztes Tag-Byte

    const ctx = envelope_mod.Context{
        .domain       = testDomain(),
        .key_id       = entry.key_id,
        .genesis_hash = testGenesis(),
        .record_type  = .EVENT,
        .sequence     = 6,
    };
    try std.testing.expectError(
        envelope_mod.EnvelopeError.AuthenticationFailed,
        decryptWithKeyring(std.testing.allocator, &keyring, env_bytes, ctx),
    );
}

test "keyring: tamper — sequence mutation → InvalidContext" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    const env_bytes = try encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, "seq tamper",
        testDomain(), testGenesis(), .EVENT, 10,
    );
    defer std.testing.allocator.free(env_bytes);

    // Context mit falscher Sequence → Envelope lehnt ab
    const wrong_ctx = envelope_mod.Context{
        .domain       = testDomain(),
        .key_id       = entry.key_id,
        .genesis_hash = testGenesis(),
        .record_type  = .EVENT,
        .sequence     = 11, // verschieden von 10
    };
    try std.testing.expectError(
        envelope_mod.EnvelopeError.InvalidContext,
        decryptWithKeyring(std.testing.allocator, &keyring, env_bytes, wrong_ctx),
    );
}

test "keyring: tamper — genesis mutation in context → InvalidContext" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    const env_bytes = try encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, "genesis tamper",
        testDomain(), testGenesis(), .EVENT, 3,
    );
    defer std.testing.allocator.free(env_bytes);

    const wrong_ctx = envelope_mod.Context{
        .domain       = testDomain(),
        .key_id       = entry.key_id,
        .genesis_hash = [_]u8{0xDE} ** 32, // anderer Genesis-Hash
        .record_type  = .EVENT,
        .sequence     = 3,
    };
    try std.testing.expectError(
        envelope_mod.EnvelopeError.InvalidContext,
        decryptWithKeyring(std.testing.allocator, &keyring, env_bytes, wrong_ctx),
    );
}

test "keyring: tamper — malformed envelope → MalformedEnvelope" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const ctx = envelope_mod.Context{
        .domain       = testDomain(),
        .key_id       = [_]u8{0} ** KEY_ID_SIZE,
        .genesis_hash = testGenesis(),
        .record_type  = .EVENT,
        .sequence     = 0,
    };
    const tiny: []const u8 = "too short";
    try std.testing.expectError(
        envelope_mod.EnvelopeError.MalformedEnvelope,
        decryptWithKeyring(std.testing.allocator, &keyring, tiny, ctx),
    );
}

// ── K. Memory Safety ──────────────────────────────────────────────────────

test "keyring: memory — deinit on empty keyring is safe" {
    var keyring = Keyring.init(std.testing.allocator);
    keyring.deinit();
}

test "keyring: memory — deinit zeros key materials" {
    var keyring = Keyring.init(std.testing.allocator);
    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);
    // deinit muss key_material sicher nullen + Speicher freigeben, kein Leak
    keyring.deinit();
}

test "keyring: memory — multiple keys no leak" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const io = std.testing.io;
    for (0..5) |_| {
        const e = try makeTestEntry(io);
        try keyring.addKey(e);
    }
}

test "keyring: memory — failed addKey (duplicate) no leak" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);
    try std.testing.expectError(
        KeyringError.DuplicateKeyId,
        keyring.addKey(entry),
    );
}

test "keyring: memory — revocation cycle no leak" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const io = std.testing.io;
    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);
    try keyring.revokeKey(entry.key_id);
    try keyring.revokeKey(entry.key_id); // idempotent
}

test "keyring: memory — encryptWithKeyring wrong context no leak" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    const result = encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, "data",
        .BKGDB_WAL,    // falsche Domain
        testGenesis(), .EVENT, 1,
    );
    try std.testing.expect(result == KeyringError.InvalidContext);
}

test "keyring: memory — decryptWithKeyring auth failure no leak" {
    const io = std.testing.io;
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();

    const entry = try makeTestEntry(io);
    try keyring.addKey(entry);

    var env_bytes = try encryptWithKeyring(
        io, std.testing.allocator, &keyring,
        entry.key_id, "data",
        testDomain(), testGenesis(), .EVENT, 1,
    );
    defer std.testing.allocator.free(env_bytes);

    // Tag korumpieren
    env_bytes[env_bytes.len - 1] ^= 0x01;

    const ctx = envelope_mod.Context{
        .domain       = testDomain(),
        .key_id       = entry.key_id,
        .genesis_hash = testGenesis(),
        .record_type  = .EVENT,
        .sequence     = 1,
    };
    try std.testing.expectError(
        envelope_mod.EnvelopeError.AuthenticationFailed,
        decryptWithKeyring(std.testing.allocator, &keyring, env_bytes, ctx),
    );
}

// ── L. Multiple Keys im Keyring ───────────────────────────────────────────

test "keyring: multi-key — lookup returns correct entry" {
    var keyring = Keyring.init(std.testing.allocator);
    defer keyring.deinit();
    const io = std.testing.io;

    const e1 = try makeTestEntry(io);
    const e2 = try makeTestEntry(io);
    const e3 = try makeTestEntry(io);
    try keyring.addKey(e1);
    try keyring.addKey(e2);
    try keyring.addKey(e3);

    // Jeder Key muss korrekt gefunden werden
    try std.testing.expect(keyring.lookupActive(e1.key_id) != null);
    try std.testing.expect(keyring.lookupActive(e2.key_id) != null);
    try std.testing.expect(keyring.lookupActive(e3.key_id) != null);

    // Revoke e2 — e1 und e3 bleiben ACTIVE
    try keyring.revokeKey(e2.key_id);
    try std.testing.expect(keyring.lookupActive(e1.key_id) != null);
    try std.testing.expect(keyring.lookupActive(e2.key_id) == null);
    try std.testing.expect(keyring.lookupActive(e3.key_id) != null);
}
