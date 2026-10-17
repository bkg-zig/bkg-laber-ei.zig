/// BKGDB Stage 3.1.A — Tag Records und Tag-Sets
///
/// Implementiert Tag-Records und Tag-Sets gemäß Contract §30.
/// Domain: "BKGV" (DOMAIN_TAG_SET)
/// Tag-Hash: SHA256("BKGV" || tag_kind_u8 || value_hash)
///
const std = @import("std");
const dr = @import("domain_registry.zig");

// ── Konstanten ────────────────────────────────────────────────────────────

pub const MAX_TAGS_PER_SET: usize = 64;

// ── Fehlertypen ───────────────────────────────────────────────────────────

pub const TagSetError = error{
    /// MAX_TAGS_PER_SET (64) erreicht
    TagSetFull,
    /// tag_hash bereits im Set vorhanden
    DuplicateTag,
};

// ── TagKind ───────────────────────────────────────────────────────────────

pub const TagKind = enum(u8) {
    domain_tag = 1,
    capability = 2,
    source_family = 3,
    modality = 4,
    risk_class = 5,
    temporal_role = 6,
    evolution_role = 7,
    // 8–255 reserviert
};

// ── TagRecord ─────────────────────────────────────────────────────────────

pub const TagRecord = struct {
    /// "BKGV"
    domain_prefix: [4]u8,
    /// SHA256("BKGV" || tag_kind_u8 || value_hash)
    tag_hash: [32]u8,
    tag_kind: TagKind,
    /// SHA256 des normierten Tag-Werts
    value_hash: [32]u8,
};

// ── TagSet ────────────────────────────────────────────────────────────────

pub const TagSet = struct {
    /// "BKGV"
    domain_prefix: [4]u8,
    /// SHA256("BKGV" || tag_count_le2 || tag_hash_0 || ... || tag_hash_N) — kanonisch sortiert
    tag_set_hash: [32]u8,
    tags: [MAX_TAGS_PER_SET]TagRecord,
    tag_count: u8,

    /// Initialisiert einen leeren TagSet.
    pub fn init() TagSet {
        // Leerer Set hat definierten Hash
        const empty_hash = computeTagSetHash(&[_]TagRecord{});
        return TagSet{
            .domain_prefix = dr.DOMAIN_TAG_SET,
            .tag_set_hash = empty_hash,
            .tags = undefined,
            .tag_count = 0,
        };
    }

    /// Fügt einen Tag ein. Fail-closed bei Duplikaten, sortiert danach.
    pub fn add(self: *TagSet, allocator: std.mem.Allocator, tag: TagRecord) TagSetError!void {
        _ = allocator; // kein heap benötigt — fixed-size Array
        if (self.tag_count >= MAX_TAGS_PER_SET) return TagSetError.TagSetFull;

        // Duplikat-Prüfung
        for (self.tags[0..self.tag_count]) |existing| {
            if (std.mem.eql(u8, &existing.tag_hash, &tag.tag_hash)) {
                return TagSetError.DuplicateTag;
            }
        }

        self.tags[self.tag_count] = tag;
        self.tag_count += 1;

        // Kanonisch sortieren (lexikografisch nach tag_hash)
        sortTags(self.tags[0..self.tag_count]);

        // Hash neu berechnen
        self.tag_set_hash = computeTagSetHash(self.tags[0..self.tag_count]);
    }

    /// Berechnet den kanonischen Hash des TagSets (sortiert intern).
    pub fn computeHash(self: *const TagSet) [32]u8 {
        return computeTagSetHash(self.tags[0..self.tag_count]);
    }
};

// ── Hash-Funktionen ───────────────────────────────────────────────────────

/// Berechnet tag_hash = SHA256("BKGV" || tag_kind_u8 || value_hash)
pub fn computeTagHash(tag_kind: TagKind, value_hash: [32]u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&dr.DOMAIN_TAG_SET);
    h.update(&[_]u8{@intFromEnum(tag_kind)});
    h.update(&value_hash);
    return h.finalResult();
}

/// Konstruiert einen TagRecord.
pub fn buildTagRecord(tag_kind: TagKind, value_hash: [32]u8) TagRecord {
    return TagRecord{
        .domain_prefix = dr.DOMAIN_TAG_SET,
        .tag_hash = computeTagHash(tag_kind, value_hash),
        .tag_kind = tag_kind,
        .value_hash = value_hash,
    };
}

/// Berechnet tag_set_hash = SHA256("BKGV" || tag_count_le2 || tag_hash_0 || ... || tag_hash_N)
/// tags müssen bereits kanonisch sortiert sein (lexikografisch nach tag_hash).
pub fn computeTagSetHash(tags: []const TagRecord) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&dr.DOMAIN_TAG_SET);
    var count_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &count_buf, @intCast(tags.len), .little);
    h.update(&count_buf);
    for (tags) |tag| {
        h.update(&tag.tag_hash);
    }
    return h.finalResult();
}

// ── Hilfsfunktion: kanonische Sortierung ─────────────────────────────────

/// Sortiert Tags lexikografisch aufsteigend nach tag_hash.
fn sortTags(tags: []TagRecord) void {
    // Insertion Sort — für kleine Arrays (≤ 64) ausreichend
    var i: usize = 1;
    while (i < tags.len) : (i += 1) {
        const key = tags[i];
        var j: usize = i;
        while (j > 0 and std.mem.order(u8, &tags[j - 1].tag_hash, &key.tag_hash) == .gt) : (j -= 1) {
            tags[j] = tags[j - 1];
        }
        tags[j] = key;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "tag_set: computeTagHash ist deterministisch" {
    const vh = [_]u8{0xAA} ** 32;
    const h1 = computeTagHash(.domain_tag, vh);
    const h2 = computeTagHash(.domain_tag, vh);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "tag_set: verschiedene tag_kind → verschiedene tag_hash" {
    const vh = [_]u8{0xBB} ** 32;
    const h1 = computeTagHash(.domain_tag, vh);
    const h2 = computeTagHash(.capability, vh);
    const h3 = computeTagHash(.modality, vh);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
    try std.testing.expect(!std.mem.eql(u8, &h1, &h3));
    try std.testing.expect(!std.mem.eql(u8, &h2, &h3));
}

test "tag_set: verschiedene value_hash → verschiedene tag_hash" {
    const vh1 = [_]u8{0x01} ** 32;
    const vh2 = [_]u8{0x02} ** 32;
    const h1 = computeTagHash(.domain_tag, vh1);
    const h2 = computeTagHash(.domain_tag, vh2);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "tag_set: computeTagHash ist nicht ZERO" {
    const vh = [_]u8{0x33} ** 32;
    const h = computeTagHash(.source_family, vh);
    const zero = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &h, &zero));
}

test "tag_set: buildTagRecord domain_prefix korrekt" {
    const vh = [_]u8{0x44} ** 32;
    const rec = buildTagRecord(.modality, vh);
    try std.testing.expectEqualSlices(u8, "BKGV", &rec.domain_prefix);
}

test "tag_set: buildTagRecord tag_hash konsistent mit computeTagHash" {
    const vh = [_]u8{0x55} ** 32;
    const rec = buildTagRecord(.risk_class, vh);
    const expected = computeTagHash(.risk_class, vh);
    try std.testing.expectEqualSlices(u8, &expected, &rec.tag_hash);
}

test "tag_set: TagSet.init erzeugt leeren Set" {
    const ts = TagSet.init();
    try std.testing.expectEqual(@as(u8, 0), ts.tag_count);
    try std.testing.expectEqualSlices(u8, "BKGV", &ts.domain_prefix);
}

test "tag_set: Leerer TagSet hat definierten Hash (kein ZERO)" {
    const ts = TagSet.init();
    const zero = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &ts.tag_set_hash, &zero));
}

test "tag_set: tag_set_hash ändert sich wenn Tag hinzugefügt wird" {
    var ts = TagSet.init();
    const hash_before = ts.tag_set_hash;
    const vh = [_]u8{0x66} ** 32;
    const rec = buildTagRecord(.temporal_role, vh);
    try ts.add(std.testing.allocator, rec);
    try std.testing.expect(!std.mem.eql(u8, &hash_before, &ts.tag_set_hash));
}

test "tag_set: DuplicateTag beim zweiten Einfügen desselben tag_hash" {
    var ts = TagSet.init();
    const vh = [_]u8{0x77} ** 32;
    const rec = buildTagRecord(.evolution_role, vh);
    try ts.add(std.testing.allocator, rec);
    try std.testing.expectError(TagSetError.DuplicateTag, ts.add(std.testing.allocator, rec));
}

test "tag_set: TagSetFull bei 65. Tag" {
    var ts = TagSet.init();
    // 64 Tags einfügen
    var i: u8 = 0;
    while (i < MAX_TAGS_PER_SET) : (i += 1) {
        var vh = [_]u8{0} ** 32;
        vh[0] = i;
        vh[1] = 0xFF;
        const rec = buildTagRecord(.domain_tag, vh);
        try ts.add(std.testing.allocator, rec);
    }
    try std.testing.expectEqual(@as(u8, 64), ts.tag_count);
    // 65. Tag → TagSetFull
    const vh_extra = [_]u8{0xFE} ** 32;
    const extra = buildTagRecord(.capability, vh_extra);
    try std.testing.expectError(TagSetError.TagSetFull, ts.add(std.testing.allocator, extra));
}

test "tag_set: TagSet deterministisch (Reihenfolge der Einfügung egal)" {
    const vh1 = [_]u8{0x10} ** 32;
    const vh2 = [_]u8{0x20} ** 32;
    const vh3 = [_]u8{0x30} ** 32;
    const r1 = buildTagRecord(.domain_tag, vh1);
    const r2 = buildTagRecord(.capability, vh2);
    const r3 = buildTagRecord(.modality, vh3);

    // Set A: Reihenfolge 1, 2, 3
    var ts_a = TagSet.init();
    try ts_a.add(std.testing.allocator, r1);
    try ts_a.add(std.testing.allocator, r2);
    try ts_a.add(std.testing.allocator, r3);

    // Set B: Reihenfolge 3, 1, 2
    var ts_b = TagSet.init();
    try ts_b.add(std.testing.allocator, r3);
    try ts_b.add(std.testing.allocator, r1);
    try ts_b.add(std.testing.allocator, r2);

    try std.testing.expectEqualSlices(u8, &ts_a.tag_set_hash, &ts_b.tag_set_hash);
}

test "tag_set: Tag-Sortierung ist lexikografisch nach tag_hash" {
    const vh1 = [_]u8{0x01} ** 32;
    const vh2 = [_]u8{0x02} ** 32;
    const r1 = buildTagRecord(.domain_tag, vh1);
    const r2 = buildTagRecord(.domain_tag, vh2);

    // Beide Hashes berechnen und prüfen dass Sortierung korrekt
    var ts = TagSet.init();
    try ts.add(std.testing.allocator, r2); // erst r2 einfügen
    try ts.add(std.testing.allocator, r1); // dann r1

    // Nach Sortierung: tags[0].tag_hash < tags[1].tag_hash
    const order = std.mem.order(u8, &ts.tags[0].tag_hash, &ts.tags[1].tag_hash);
    try std.testing.expect(order == .lt or order == .eq);
}

test "tag_set: computeTagSetHash deterministisch" {
    const vh1 = [_]u8{0xAA} ** 32;
    const vh2 = [_]u8{0xBB} ** 32;
    const r1 = buildTagRecord(.domain_tag, vh1);
    const r2 = buildTagRecord(.capability, vh2);
    const arr = [_]TagRecord{ r1, r2 };
    const h1 = computeTagSetHash(&arr);
    const h2 = computeTagSetHash(&arr);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "tag_set: computeHash liefert gleichen Hash wie tag_set_hash" {
    var ts = TagSet.init();
    const vh = [_]u8{0xCC} ** 32;
    const rec = buildTagRecord(.source_family, vh);
    try ts.add(std.testing.allocator, rec);
    const computed = ts.computeHash();
    try std.testing.expectEqualSlices(u8, &ts.tag_set_hash, &computed);
}

test "tag_set: TagRecord hat kein authority-Feld (strukturell keine Authority)" {
    // Strukturprüfung: TagRecord hat nur domain_prefix, tag_hash, tag_kind, value_hash
    const vh = [_]u8{0xDD} ** 32;
    const rec = buildTagRecord(.evolution_role, vh);
    // Prüfe die Felder die vorhanden sind
    try std.testing.expectEqualSlices(u8, "BKGV", &rec.domain_prefix);
    try std.testing.expectEqual(TagKind.evolution_role, rec.tag_kind);
    // Keine authority / trust / weight Felder — Tag ist Tag, nicht Truth
    // (Dieser Test dokumentiert die Absenz durch erfolgreiche Kompilierung)
}

test "tag_set: tag_set_hash ist nicht ZERO nach Einfügung" {
    var ts = TagSet.init();
    const vh = [_]u8{0xEE} ** 32;
    const rec = buildTagRecord(.risk_class, vh);
    try ts.add(std.testing.allocator, rec);
    const zero = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &ts.tag_set_hash, &zero));
}

test "tag_set: alle TagKind-Werte haben explizite u8-Werte >= 1" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(TagKind.domain_tag));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(TagKind.capability));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(TagKind.source_family));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(TagKind.modality));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(TagKind.risk_class));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(TagKind.temporal_role));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(TagKind.evolution_role));
}
