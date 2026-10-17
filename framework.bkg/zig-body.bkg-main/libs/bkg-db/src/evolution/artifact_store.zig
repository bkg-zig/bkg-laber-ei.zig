/// BKGDB Evolution Memory v1 — Artifact Store
///
/// Status: STAGE 1 — NICHT FROZEN
/// Spec:   docs/BKGDB_EVOLUTION_MEMORY_v1.md §Artifact Store
///
/// WICHTIG: Store State != Ledger Truth
/// Dieses Modul speichert Wissen und Kandidaten.
/// Kanonische Wahrheit liegt im Ledger/Rebuilder.
///
/// Semantik:
///   - Content-addressed, WRITE ONCE
///   - Kein Update, kein Delete als semantische Mutation
///   - Domain Separation: content_hash = SHA256("BKGA" || blob)
const std = @import("std");

// ── Domain Separation ─────────────────────────────────────────────────────

/// Domain-Prefix für Artifact-Hashes (4 Bytes).
pub const DOMAIN_PREFIX: [4]u8 = "BKGA".*;

/// Berechnet SHA256("BKGA" || blob).
fn domainHash(blob: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&DOMAIN_PREFIX);
    hasher.update(blob);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// Öffentliche Wrapper-Version für Tests und Adapter-Schicht.
pub fn domainHashForTest(blob: []const u8) [32]u8 {
    return domainHash(blob);
}

// ── ArtifactRecord ────────────────────────────────────────────────────────

/// Index-Eintrag für ein gespeichertes Artifact.
/// Kanonisch serialisierbar: keine Pointer, keine Padding-Gaps.
pub const ArtifactRecord = struct {
    /// Domain Separation ("BKGA")
    domain_prefix: [4]u8,
    /// SHA256("BKGA" || blob)
    content_hash: [32]u8,
    /// Länge des Blobs in Bytes
    blob_len: u32,
    /// Forge-Epoch zum Zeitpunkt des Schreibens
    stored_epoch: u64,
};

// ── Fehlertypen ───────────────────────────────────────────────────────────

pub const ArtifactError = error{
    HashMismatch,
    ContentConflict,
    EmptyContent,
    OutOfMemory,
};

// ── ArtifactStore ─────────────────────────────────────────────────────────

/// Interner Eintrag im Store (Record + geklonter Blob).
const Entry = struct {
    record: ArtifactRecord,
    blob: []u8,
};

pub const ArtifactStore = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap([32]u8, Entry),

    pub fn init(allocator: std.mem.Allocator) ArtifactStore {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap([32]u8, Entry).init(allocator),
        };
    }

    pub fn deinit(self: *ArtifactStore) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.blob);
        }
        self.entries.deinit();
    }

    /// Speichert einen Blob unter seinem Domain-Hash.
    ///
    /// Prüfreihenfolge (fail-closed):
    ///   1. Leerer Blob → EmptyContent
    ///   2. expected_hash bereits bekannt + Blob identisch → idempotent
    ///   3. expected_hash bereits bekannt + Blob verschieden → ContentConflict
    ///   4. SHA256("BKGA"||blob) ≠ expected_hash → HashMismatch
    ///   5. Neu → speichern
    pub fn put(
        self: *ArtifactStore,
        expected_hash: [32]u8,
        blob: []const u8,
        epoch: u64,
    ) ArtifactError!void {
        if (blob.len == 0) return ArtifactError.EmptyContent;

        // Zuerst: Ist der expected_hash bereits im Store?
        if (self.entries.get(expected_hash)) |existing| {
            // Idempotent bei identischem Blob
            if (std.mem.eql(u8, existing.blob, blob)) return;
            // Anderer Inhalt → ContentConflict (WRITE-ONCE, kein Überschreiben)
            return ArtifactError.ContentConflict;
        }

        // Hash-Verifikation: SHA256("BKGA"||blob) muss zu expected_hash passen
        const actual_hash = domainHash(blob);
        if (!std.mem.eql(u8, &actual_hash, &expected_hash)) {
            return ArtifactError.HashMismatch;
        }

        const blob_copy = try self.allocator.dupe(u8, blob);
        errdefer self.allocator.free(blob_copy);

        const record = ArtifactRecord{
            .domain_prefix = DOMAIN_PREFIX,
            .content_hash = actual_hash,
            .blob_len = @intCast(blob.len),
            .stored_epoch = epoch,
        };

        try self.entries.put(actual_hash, .{ .record = record, .blob = blob_copy });
    }

    /// Gibt einen Slice auf den gespeicherten Blob zurück, oder null.
    pub fn get(self: *const ArtifactStore, hash: [32]u8) ?[]const u8 {
        if (self.entries.get(hash)) |entry| return entry.blob;
        return null;
    }

    /// Prüft ob ein Blob unter diesem Hash bekannt ist.
    pub fn contains(self: *const ArtifactStore, hash: [32]u8) bool {
        return self.entries.contains(hash);
    }

    /// Anzahl gespeicherter Einträge.
    pub fn count(self: *const ArtifactStore) usize {
        return self.entries.count();
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "artifact_store: put + get round-trip" {
    var store = ArtifactStore.init(std.testing.allocator);
    defer store.deinit();

    const blob = "hello artifact";
    const h = domainHash(blob);
    try store.put(h, blob, 1);

    const got = store.get(h);
    try std.testing.expect(got != null);
    try std.testing.expectEqualSlices(u8, blob, got.?);
}

test "artifact_store: put zweimal identisch — idempotent" {
    var store = ArtifactStore.init(std.testing.allocator);
    defer store.deinit();

    const blob = "idempotent blob";
    const h = domainHash(blob);
    try store.put(h, blob, 1);
    try store.put(h, blob, 2); // zweiter Put — kein Fehler
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "artifact_store: gleicher Hash + anderer Inhalt — ContentConflict" {
    var store = ArtifactStore.init(std.testing.allocator);
    defer store.deinit();

    const blob = "original blob";
    const h = domainHash(blob);
    try store.put(h, blob, 1);

    // Zweiten put mit anderem blob, aber original-hash → ContentConflict
    const blob2 = "different blob";
    try std.testing.expectError(
        ArtifactError.ContentConflict,
        store.put(h, blob2, 2),
    );
    // Store unveränderter Zustand
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "artifact_store: falscher expected_hash — HashMismatch" {
    var store = ArtifactStore.init(std.testing.allocator);
    defer store.deinit();

    const blob = "some blob";
    const wrong_hash: [32]u8 = [_]u8{0xFF} ** 32;
    try std.testing.expectError(
        ArtifactError.HashMismatch,
        store.put(wrong_hash, blob, 1),
    );
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "artifact_store: leerer Blob — EmptyContent" {
    var store = ArtifactStore.init(std.testing.allocator);
    defer store.deinit();

    const blob: []const u8 = "";
    const h = domainHash(blob);
    try std.testing.expectError(
        ArtifactError.EmptyContent,
        store.put(h, blob, 1),
    );
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "artifact_store: get unbekannter Hash — null" {
    var store = ArtifactStore.init(std.testing.allocator);
    defer store.deinit();

    const unknown: [32]u8 = [_]u8{0xAB} ** 32;
    try std.testing.expect(store.get(unknown) == null);
}

test "artifact_store: contains vor und nach put" {
    var store = ArtifactStore.init(std.testing.allocator);
    defer store.deinit();

    const blob = "contains test";
    const h = domainHash(blob);

    try std.testing.expect(!store.contains(h));
    try store.put(h, blob, 1);
    try std.testing.expect(store.contains(h));
}

test "artifact_store: count steigt korrekt" {
    var store = ArtifactStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.count());
    const b1 = "blob one";
    try store.put(domainHash(b1), b1, 1);
    try std.testing.expectEqual(@as(usize, 1), store.count());
    const b2 = "blob two";
    try store.put(domainHash(b2), b2, 2);
    try std.testing.expectEqual(@as(usize, 2), store.count());
}

test "artifact_store: read-after-write — gespeicherter Blob unverändert" {
    var store = ArtifactStore.init(std.testing.allocator);
    defer store.deinit();

    const blob = "read after write";
    const h = domainHash(blob);
    try store.put(h, blob, 1);

    const got = store.get(h).?;
    try std.testing.expectEqualSlices(u8, blob, got);
    // Stellt sicher, dass es eine Kopie ist (andere Adresse)
    try std.testing.expect(got.ptr != blob.ptr);
}

test "artifact_store: WRITE-ONCE — zweiter put mit anderem Inhalt ändert Store nicht" {
    var store = ArtifactStore.init(std.testing.allocator);
    defer store.deinit();

    const original = "original content";
    const h = domainHash(original);
    try store.put(h, original, 1);

    // Versuch, unter dem originalen Hash einen anderen Blob zu speichern
    const other = "tampered content";
    const result = store.put(h, other, 2);
    try std.testing.expectError(ArtifactError.ContentConflict, result);

    // Ursprünglicher Blob bleibt erhalten
    const got = store.get(h).?;
    try std.testing.expectEqualSlices(u8, original, got);
}

test "artifact_store: Domain Separation SHA256('BKGA'||blob) != SHA256(blob)" {
    const blob = "domain separation test";
    const with_domain = domainHash(blob);

    // SHA256 ohne Prefix
    var raw_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(blob, &raw_hash, .{});

    try std.testing.expect(!std.mem.eql(u8, &with_domain, &raw_hash));
}

test "artifact_store: Memory-Safety — alle Fehlerpfade leak-frei" {
    // HashMismatch — kein Alloc
    {
        var store = ArtifactStore.init(std.testing.allocator);
        defer store.deinit();
        const wrong: [32]u8 = [_]u8{0x00} ** 32;
        _ = store.put(wrong, "data", 1) catch {};
    }
    // EmptyContent — kein Alloc
    {
        var store = ArtifactStore.init(std.testing.allocator);
        defer store.deinit();
        const h = domainHash("");
        _ = store.put(h, "", 1) catch {};
    }
    // ContentConflict — erste Alloc ok, zweite wird abgelehnt ohne Alloc
    {
        var store = ArtifactStore.init(std.testing.allocator);
        defer store.deinit();
        const b = "conflict test";
        try store.put(domainHash(b), b, 1);
        const h = domainHash(b);
        _ = store.put(h, "other data", 1) catch {};
    }
}
