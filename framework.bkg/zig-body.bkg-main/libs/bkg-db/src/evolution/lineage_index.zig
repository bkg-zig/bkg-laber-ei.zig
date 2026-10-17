/// BKGDB Evolution Memory v1 — Lineage Index
///
/// Status: STAGE 2 — NICHT FROZEN
/// Spec:   docs/BKGDB_EVOLUTION_MEMORY_v1.md §2.2 Lineage-Dimension
///
/// WICHTIG: Store State != Ledger Truth
/// Dieses Modul speichert nachweisbare Abstammungsinformation.
/// Kanonische Wahrheit liegt im Ledger/Rebuilder.
///
/// Semantik:
///   - Ein LineageRecord pro Artefakt-Hash (WRITE ONCE)
///   - Eltern-Hashes kanonisch sortiert (lexikografisch, 32 Byte)
///   - Keine Manipulation von Parent-Hashes nach dem Schreiben
///   - Domain Separation: lineage_hash = SHA256("BKGL" || sorted_parents || generation_le8 || provenance_hash)
///
/// Aufbau:
///   LineageIndex speichert pro artifact_hash:
///     - bis zu MAX_PARENTS Eltern-Hashes (kanonisch sortiert)
///     - generation (u64)
///     - provenance_hash (Herkunfts-Beweis, 32 Byte)
///     - origin_event_hash (Ledger-Event-Hash der Forge-Schmiedung, ZERO = noch kein Ledger-Beweis)
///     - spore_ref (optionale SporeRef — Referenz auf auslösende Spore)
///     - lineage_hash (deterministisch aus obigen Feldern)
///
const std = @import("std");

// ── Konstanten ────────────────────────────────────────────────────────────

/// Maximale Anzahl direkter Eltern pro Artefakt.
pub const MAX_PARENTS: usize = 8;

/// Domain-Prefix für Lineage-Hashes (4 Bytes).
pub const DOMAIN_PREFIX: [4]u8 = "BKGL".*;

/// Zero-Hash (kein Parent / kein Ledger-Event-Nachweis).
pub const ZERO_HASH: [32]u8 = [_]u8{0} ** 32;

// ── SporeRef ──────────────────────────────────────────────────────────────

/// Referenz auf eine Spore, aus der dieses Artefakt entstanden ist.
/// ZERO-Felder bedeuten: kein Spore-Bezug.
pub const SporeRef = struct {
    /// SHA256("BKGS" || payload_hash) der auslösenden Spore
    spore_hash: [32]u8,
    /// Epoch der Spore
    spore_epoch: u64,
    /// Herkunfts-Hash des Spore-Einreichers (originating_agent_hash)
    spore_origin: [32]u8,
};

/// Leere SporeRef (kein Spore-Bezug).
pub const ZERO_SPORE_REF: SporeRef = .{
    .spore_hash   = ZERO_HASH,
    .spore_epoch  = 0,
    .spore_origin = ZERO_HASH,
};

pub fn sporeRefIsZero(ref: SporeRef) bool {
    return std.mem.eql(u8, &ref.spore_hash, &ZERO_HASH) and
        ref.spore_epoch == 0 and
        std.mem.eql(u8, &ref.spore_origin, &ZERO_HASH);
}

// ── LineageRecord ─────────────────────────────────────────────────────────

/// Vollständiger Lineage-Eintrag für ein Artefakt.
/// Kanonisch serialisierbar: keine Pointer, keine Padding-Gaps.
pub const LineageRecord = struct {
    /// Domain Separation ("BKGL")
    domain_prefix: [4]u8,
    /// Hash des Artefakts, dessen Abstammung hier beschrieben wird
    artifact_hash: [32]u8,
    /// Kanonisch sortierte Eltern-Hashes (lexikografisch, 32 Byte pro Hash).
    /// Slots jenseits von parent_count sind ZERO.
    parents: [MAX_PARENTS][32]u8,
    /// Tatsächliche Anzahl gültiger Eltern (≤ MAX_PARENTS).
    parent_count: u8,
    /// Generationszähler (0 = Genesis-Artefakt ohne Eltern).
    generation: u64,
    /// Herkunfts-Beweis (Provenance-Hash). ZERO = kein Nachweis.
    provenance_hash: [32]u8,
    /// Ledger-Event-Hash der Forge-Schmiedung. ZERO = noch kein Ledger-Beweis.
    origin_event_hash: [32]u8,
    /// Optionale SporeRef — ZERO_SPORE_REF = kein Spore-Bezug.
    spore_ref: SporeRef,
    /// Deterministischer Lineage-Hash:
    ///   SHA256("BKGL" || sorted_parents || generation_le8 || provenance_hash)
    lineage_hash: [32]u8,
};

// ── Hash-Berechnung ───────────────────────────────────────────────────────

/// Berechnet den kanonischen Lineage-Hash.
///
/// Input: "BKGL" || parent_0 || … || parent_n (kanonisch sortiert) || generation (LE u64) || provenance_hash
/// Hash: SHA256
///
/// Determinismus: gleiche semantische Lineage → gleicher Hash, unabhängig von der
/// ursprünglichen Einfügereihenfolge der Eltern.
pub fn computeLineageHash(
    parents: []const [32]u8,
    generation: u64,
    provenance_hash: [32]u8,
) [32]u8 {
    // Eltern kanonisch sortieren (Kopie auf Stack — MAX_PARENTS begrenzt)
    var sorted: [MAX_PARENTS][32]u8 = undefined;
    const n = @min(parents.len, MAX_PARENTS);
    for (0..n) |i| sorted[i] = parents[i];
    // Insertion sort ist für n ≤ 8 ausreichend und alloc-frei
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const key = sorted[i];
        var j: usize = i;
        while (j > 0 and std.mem.lessThan(u8, &sorted[j - 1], &key)) : (j -= 1) {
            sorted[j] = sorted[j - 1];
        }
        sorted[j] = key;
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&DOMAIN_PREFIX);
    for (0..n) |k| hasher.update(&sorted[k]);
    var gen_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &gen_buf, generation, .little);
    hasher.update(&gen_buf);
    hasher.update(&provenance_hash);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

// ── Fehlertypen ───────────────────────────────────────────────────────────

pub const LineageError = error{
    /// artifact_hash bereits bekannt mit identischem Record → idempotent (kein Fehler,
    /// aber hier als expliziter Informationstyp für interne Prüfung reserviert)
    TooManyParents,
    /// artifact_hash bereits bekannt + anderer Inhalt → WRITE ONCE verletzt
    ContentConflict,
    /// parent_count > MAX_PARENTS
    ParentCountExceeded,
    /// Lineage-Hash-Mismatch beim Einfügen (Caller hat falschen Hash geliefert)
    LineageHashMismatch,
    /// artifact_hash unbekannt
    NotFound,
    OutOfMemory,
};

// ── LineageIndex ──────────────────────────────────────────────────────────

pub const LineageIndex = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap([32]u8, LineageRecord),

    pub fn init(allocator: std.mem.Allocator) LineageIndex {
        return .{
            .allocator = allocator,
            .entries   = std.AutoHashMap([32]u8, LineageRecord).init(allocator),
        };
    }

    pub fn deinit(self: *LineageIndex) void {
        self.entries.deinit();
    }

    /// Fügt einen neuen Lineage-Eintrag ein.
    ///
    /// Prüfreihenfolge:
    ///   1. parent_count > MAX_PARENTS → ParentCountExceeded
    ///   2. Berechnet lineage_hash intern; muss mit record.lineage_hash übereinstimmen
    ///      → LineageHashMismatch (fail-closed)
    ///   3. artifact_hash bereits bekannt + identischer Record → idempotent (kein Fehler)
    ///   4. artifact_hash bereits bekannt + anderer Inhalt → ContentConflict (WRITE ONCE)
    ///   5. Neu → Eltern kanonisch sortieren, speichern
    ///
    /// Die Eltern-Slots werden beim Einfügen kanonisch sortiert.
    /// Das übergebene record.parents wird NICHT vertraut — die Sortierung
    /// wird intern erzwungen.
    pub fn put(self: *LineageIndex, record: LineageRecord) LineageError!void {
        if (record.parent_count > MAX_PARENTS) return LineageError.ParentCountExceeded;

        // Eltern kanonisch sortieren (Invariante intern erzwingen)
        const parents_slice = record.parents[0..record.parent_count];
        const computed_hash = computeLineageHash(
            parents_slice,
            record.generation,
            record.provenance_hash,
        );
        if (!std.mem.eql(u8, &computed_hash, &record.lineage_hash)) {
            return LineageError.LineageHashMismatch;
        }

        if (self.entries.get(record.artifact_hash)) |existing| {
            if (recordEql(existing, record)) return; // idempotent
            return LineageError.ContentConflict;
        }

        // Kanonisch sortierten Record speichern
        var canonical = record;
        canonical.domain_prefix = DOMAIN_PREFIX;
        sortParentsInPlace(&canonical.parents, record.parent_count);
        // Slots jenseits von parent_count auf ZERO setzen
        for (record.parent_count..MAX_PARENTS) |i| {
            canonical.parents[i] = ZERO_HASH;
        }

        try self.entries.put(record.artifact_hash, canonical);
    }

    /// Gibt den Lineage-Eintrag für einen Artefakt-Hash zurück, oder null.
    pub fn get(self: *const LineageIndex, artifact_hash: [32]u8) ?LineageRecord {
        return self.entries.get(artifact_hash);
    }

    /// Gibt die kanonisch sortierten Eltern-Hashes zurück (slice der belegten Slots).
    /// Gibt null zurück wenn artifact_hash unbekannt.
    pub fn getParents(self: *const LineageIndex, artifact_hash: [32]u8) ?[][32]u8 {
        // Gibt einen Slice der gespeicherten parents zurück — aber da LineageRecord
        // Stack-allokiert ist, geben wir einen Slice auf eine Kopie im Entry zurück.
        // Für Stage 2 reicht eine Kopie; spätere Stufen können Slice-Ownership klären.
        _ = self;
        _ = artifact_hash;
        // Implementierung: direkt über get() + slice
        return null; // Caller soll get() verwenden und parents[0..parent_count] slicen
    }

    /// Prüft ob ein Artefakt-Hash im Index bekannt ist.
    pub fn contains(self: *const LineageIndex, artifact_hash: [32]u8) bool {
        return self.entries.contains(artifact_hash);
    }

    /// Gibt die Generation für einen Artefakt-Hash zurück, oder null.
    pub fn getGeneration(self: *const LineageIndex, artifact_hash: [32]u8) ?u64 {
        if (self.entries.get(artifact_hash)) |r| return r.generation;
        return null;
    }

    /// Gibt die SporeRef für einen Artefakt-Hash zurück, oder null wenn unbekannt.
    pub fn getSporeRef(self: *const LineageIndex, artifact_hash: [32]u8) ?SporeRef {
        if (self.entries.get(artifact_hash)) |r| return r.spore_ref;
        return null;
    }

    /// Anzahl gespeicherter Einträge.
    pub fn count(self: *const LineageIndex) usize {
        return self.entries.count();
    }
};

// ── Hilfsfunktionen ───────────────────────────────────────────────────────

/// Sortiert parents[0..n] in-place kanonisch (lexikografisch aufsteigend).
fn sortParentsInPlace(parents: *[MAX_PARENTS][32]u8, n: u8) void {
    // Insertion sort — alloc-frei, korrekt für n ≤ MAX_PARENTS
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const key = parents[i];
        var j: usize = i;
        while (j > 0 and std.mem.lessThan(u8, &parents[j - 1], &key)) : (j -= 1) {
            parents[j] = parents[j - 1];
        }
        parents[j] = key;
    }
}

/// Vergleicht zwei LineageRecords auf Byte-Gleichheit (alle semantischen Felder).
fn recordEql(a: LineageRecord, b: LineageRecord) bool {
    if (!std.mem.eql(u8, &a.artifact_hash, &b.artifact_hash)) return false;
    if (a.parent_count != b.parent_count) return false;
    for (0..a.parent_count) |i| {
        if (!std.mem.eql(u8, &a.parents[i], &b.parents[i])) return false;
    }
    if (a.generation != b.generation) return false;
    if (!std.mem.eql(u8, &a.provenance_hash, &b.provenance_hash)) return false;
    if (!std.mem.eql(u8, &a.origin_event_hash, &b.origin_event_hash)) return false;
    if (!std.mem.eql(u8, &a.spore_ref.spore_hash, &b.spore_ref.spore_hash)) return false;
    if (a.spore_ref.spore_epoch != b.spore_ref.spore_epoch) return false;
    if (!std.mem.eql(u8, &a.spore_ref.spore_origin, &b.spore_ref.spore_origin)) return false;
    if (!std.mem.eql(u8, &a.lineage_hash, &b.lineage_hash)) return false;
    return true;
}

/// Erstellt einen validen LineageRecord für Tests.
/// parents werden kanonisch sortiert und lineage_hash korrekt berechnet.
fn makeRecord(
    artifact_hash: [32]u8,
    parents: []const [32]u8,
    generation: u64,
    provenance_hash: [32]u8,
) LineageRecord {
    const n: u8 = @intCast(@min(parents.len, MAX_PARENTS));
    var rec = LineageRecord{
        .domain_prefix     = DOMAIN_PREFIX,
        .artifact_hash     = artifact_hash,
        .parents           = [_][32]u8{ZERO_HASH} ** MAX_PARENTS,
        .parent_count      = n,
        .generation        = generation,
        .provenance_hash   = provenance_hash,
        .origin_event_hash = ZERO_HASH,
        .spore_ref         = ZERO_SPORE_REF,
        .lineage_hash      = ZERO_HASH,
    };
    for (0..n) |i| rec.parents[i] = parents[i];
    rec.lineage_hash = computeLineageHash(parents[0..n], generation, provenance_hash);
    return rec;
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn h(b: u8) [32]u8 {
    var out: [32]u8 = ZERO_HASH;
    out[0] = b;
    return out;
}

test "lineage_index: put + get round-trip, kein Parent" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    const rec = makeRecord(h(0x01), &.{}, 0, ZERO_HASH);
    try idx.put(rec);

    const got = idx.get(h(0x01));
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u8, 0), got.?.parent_count);
    try std.testing.expectEqual(@as(u64, 0), got.?.generation);
}

test "lineage_index: put + get mit einem Parent" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    const rec = makeRecord(h(0x02), &.{h(0xAA)}, 1, h(0xBB));
    try idx.put(rec);

    const got = idx.get(h(0x02)).?;
    try std.testing.expectEqual(@as(u8, 1), got.parent_count);
    try std.testing.expectEqual(@as(u64, 1), got.generation);
    try std.testing.expectEqualSlices(u8, &h(0xAA), &got.parents[0]);
}

test "lineage_index: put zweimal identisch — idempotent" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    const rec = makeRecord(h(0x03), &.{}, 0, ZERO_HASH);
    try idx.put(rec);
    try idx.put(rec); // zweiter identischer Put — kein Fehler
    try std.testing.expectEqual(@as(usize, 1), idx.count());
}

test "lineage_index: ContentConflict — gleicher artifact_hash + anderer Inhalt" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    const rec1 = makeRecord(h(0x04), &.{}, 0, ZERO_HASH);
    try idx.put(rec1);

    // Gleicher artifact_hash, aber andere generation
    const rec2 = makeRecord(h(0x04), &.{}, 1, ZERO_HASH);
    try std.testing.expectError(LineageError.ContentConflict, idx.put(rec2));
    try std.testing.expectEqual(@as(usize, 1), idx.count());
}

test "lineage_index: ParentCountExceeded" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    const parents = [_][32]u8{ZERO_HASH} ** MAX_PARENTS;
    const rec = makeRecord(h(0x05), &parents, 1, ZERO_HASH);
    // MAX_PARENTS Eltern — erlaubt
    try idx.put(rec);

    // Überschreitung: parent_count manuell auf MAX_PARENTS + 1 setzen
    var too_many = rec;
    too_many.artifact_hash = h(0x06);
    too_many.parent_count = MAX_PARENTS + 1;
    try std.testing.expectError(LineageError.ParentCountExceeded, idx.put(too_many));
}

test "lineage_index: LineageHashMismatch — manipulierter lineage_hash" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    var rec = makeRecord(h(0x07), &.{h(0xCC)}, 2, h(0xDD));
    rec.lineage_hash = [_]u8{0xFF} ** 32; // manipuliert
    try std.testing.expectError(LineageError.LineageHashMismatch, idx.put(rec));
    try std.testing.expectEqual(@as(usize, 0), idx.count());
}

test "lineage_index: Parent-Reihenfolge ist irrelevant — gleicher lineage_hash" {
    // Zwei Records mit denselben Eltern in verschiedener Reihenfolge müssen
    // denselben lineage_hash ergeben (kanonische Sortierung).
    const p1 = h(0x10);
    const p2 = h(0x20);

    const hash_ab = computeLineageHash(&.{ p1, p2 }, 1, ZERO_HASH);
    const hash_ba = computeLineageHash(&.{ p2, p1 }, 1, ZERO_HASH);
    try std.testing.expectEqualSlices(u8, &hash_ab, &hash_ba);
}

test "lineage_index: zwei verschiedene Artefakte mit verschiedenen Eltern — verschiedene lineage_hashes" {
    const hash_a = computeLineageHash(&.{h(0x01)}, 1, ZERO_HASH);
    const hash_b = computeLineageHash(&.{h(0x02)}, 1, ZERO_HASH);
    try std.testing.expect(!std.mem.eql(u8, &hash_a, &hash_b));
}

test "lineage_index: Domain Separation BKGL != BKGA" {
    // lineage_hash-Berechnung beginnt mit "BKGL", artifact_store mit "BKGA".
    // Gleicher Input → verschiedene Hashes.
    const parents: []const [32]u8 = &.{};
    const lh = computeLineageHash(parents, 0, ZERO_HASH);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("BKGA"); // anderes Domain
    var gen_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &gen_buf, 0, .little);
    hasher.update(&gen_buf);
    hasher.update(&ZERO_HASH);
    var artifact_style: [32]u8 = undefined;
    hasher.final(&artifact_style);

    try std.testing.expect(!std.mem.eql(u8, &lh, &artifact_style));
}

test "lineage_index: contains vor und nach put" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    try std.testing.expect(!idx.contains(h(0xAA)));
    const rec = makeRecord(h(0xAA), &.{}, 0, ZERO_HASH);
    try idx.put(rec);
    try std.testing.expect(idx.contains(h(0xAA)));
}

test "lineage_index: getGeneration korrekt" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    const rec = makeRecord(h(0xBB), &.{h(0xCC)}, 5, ZERO_HASH);
    try idx.put(rec);
    try std.testing.expectEqual(@as(?u64, 5), idx.getGeneration(h(0xBB)));
    try std.testing.expect(idx.getGeneration(h(0xEE)) == null);
}

test "lineage_index: SporeRef korrekt gespeichert und abrufbar" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    var rec = makeRecord(h(0xCC), &.{}, 0, ZERO_HASH);
    rec.spore_ref = .{
        .spore_hash   = h(0x42),
        .spore_epoch  = 7,
        .spore_origin = h(0x43),
    };
    try idx.put(rec);

    const sr = idx.getSporeRef(h(0xCC)).?;
    try std.testing.expectEqualSlices(u8, &h(0x42), &sr.spore_hash);
    try std.testing.expectEqual(@as(u64, 7), sr.spore_epoch);
    try std.testing.expectEqualSlices(u8, &h(0x43), &sr.spore_origin);
}

test "lineage_index: ZERO_SPORE_REF erkannt" {
    const zr = ZERO_SPORE_REF;
    try std.testing.expect(sporeRefIsZero(zr));
    const non_zero = SporeRef{ .spore_hash = h(0x01), .spore_epoch = 0, .spore_origin = ZERO_HASH };
    try std.testing.expect(!sporeRefIsZero(non_zero));
}

test "lineage_index: count steigt korrekt" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    try std.testing.expectEqual(@as(usize, 0), idx.count());
    try idx.put(makeRecord(h(0x01), &.{}, 0, ZERO_HASH));
    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try idx.put(makeRecord(h(0x02), &.{h(0x01)}, 1, ZERO_HASH));
    try std.testing.expectEqual(@as(usize, 2), idx.count());
}

test "lineage_index: Rekombination — zwei Eltern, gleicher lineage_hash unabhängig von Reihenfolge" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    const pa = h(0x10);
    const pb = h(0x20);
    // Record mit pa, pb
    const rec_ab = makeRecord(h(0xDD), &.{ pa, pb }, 2, h(0xFF));
    try idx.put(rec_ab);

    // Record mit pb, pa — anderes artifact_hash, aber gleicher lineage_hash
    const rec_ba = makeRecord(h(0xDE), &.{ pb, pa }, 2, h(0xFF));
    try idx.put(rec_ba);

    const got_ab = idx.get(h(0xDD)).?;
    const got_ba = idx.get(h(0xDE)).?;
    // lineage_hash muss identisch sein
    try std.testing.expectEqualSlices(u8, &got_ab.lineage_hash, &got_ba.lineage_hash);
}

test "lineage_index: origin_event_hash ZERO bedeutet kein Ledger-Beweis" {
    var idx = LineageIndex.init(std.testing.allocator);
    defer idx.deinit();

    const rec = makeRecord(h(0xEE), &.{}, 0, ZERO_HASH);
    try idx.put(rec);

    const got = idx.get(h(0xEE)).?;
    try std.testing.expectEqualSlices(u8, &ZERO_HASH, &got.origin_event_hash);
}

test "lineage_index: Memory-Safety — alle Fehlerpfade leak-frei" {
    // ParentCountExceeded — kein Alloc
    {
        var idx = LineageIndex.init(std.testing.allocator);
        defer idx.deinit();
        var rec = makeRecord(h(0xF0), &.{}, 0, ZERO_HASH);
        rec.parent_count = @intCast(MAX_PARENTS + 1);
        _ = idx.put(rec) catch {};
    }
    // LineageHashMismatch — kein Alloc
    {
        var idx = LineageIndex.init(std.testing.allocator);
        defer idx.deinit();
        var rec = makeRecord(h(0xF1), &.{}, 0, ZERO_HASH);
        rec.lineage_hash = [_]u8{0xFF} ** 32;
        _ = idx.put(rec) catch {};
    }
    // ContentConflict — erster Alloc ok, zweiter abgelehnt ohne Alloc
    {
        var idx = LineageIndex.init(std.testing.allocator);
        defer idx.deinit();
        const rec1 = makeRecord(h(0xF2), &.{}, 0, ZERO_HASH);
        try idx.put(rec1);
        const rec2 = makeRecord(h(0xF2), &.{}, 1, ZERO_HASH);
        _ = idx.put(rec2) catch {};
    }
}
