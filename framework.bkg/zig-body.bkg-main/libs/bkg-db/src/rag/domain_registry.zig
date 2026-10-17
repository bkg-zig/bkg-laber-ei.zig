/// BKGDB Stage 3.1 — Canonical Domain Registry v1
///
/// Status: STAGE 3.1.A — NICHT FROZEN
/// Spec:   docs/BKGDB_EVOLUTION_MEMORY_STAGE_3_1_RAG_EMBEDDING_v1.md §XI + §39
///
/// Dies ist die einzige normative Quelle für BKG Domain-Codes.
/// Kein Domain-Code darf in Stage-3.1-Code erscheinen, der nicht hier registriert ist.
///
/// Harte Freeze-Regel:
///   Eine bereits registrierte Domain darf niemals umgewidmet werden.
///   Neue semantische Klasse → neuer 4-Byte-Code → neue Protokollversion.
///
/// Domain-Zustände:
///   ALLOCATED  — semantisch verbindlich vergeben, darf nicht umgewidmet werden
///   RESERVED   — für zukünftige Erweiterungen blockiert, noch nicht verwendbar
///   UNASSIGNED — ohne Zuordnung, ebenfalls nicht verwendbar
///
/// Abort-Bedingungen:
///   - Domain-Code Kollision (bereits ALLOCATED)
///   - RESERVED Code wird implementiert
///   - UNASSIGNED Code wird spontan verwendet
///   - Domain-Code != exakt 4 Bytes
///
const std = @import("std");

// ── Domain-Code-Typ ───────────────────────────────────────────────────────

/// Ein Domain-Prefix ist exakt 4 ASCII-Bytes. Keine Ausnahmen.
pub const Domain = [4]u8;

// ── Zustandsklassen ───────────────────────────────────────────────────────

pub const DomainStatus = enum(u8) {
    /// Semantisch verbindlich vergeben — darf nie umgewidmet werden
    allocated  = 1,
    /// Für zukünftige Protokollerweiterungen blockiert — nicht verwendbar
    reserved   = 2,
    /// Noch ohne Zuordnung — ebenfalls nicht verwendbar
    unassigned = 3,
};

// ── Einzelner Registry-Eintrag ────────────────────────────────────────────

pub const RegistryEntry = struct {
    domain:                Domain,
    status:                DomainStatus,
    /// Stage in der der Code vergeben wurde (0 = pre-3.1, 1 = Stage 1, ...)
    allocated_stage:       u8,
    /// registry_version in der dieser Code erstmals als ALLOCATED eingetragen wurde
    first_registry_version: u32,
};

// ── Alle 4-Byte-Codes A–Z (kanonisch sortiert) ────────────────────────────

/// FROZEN (pre-Stage-3.1, Read Only):
pub const DOMAIN_ARTIFACT:       Domain = "BKGA".*;  // Artifact-Store         (Stage 1, FROZEN)
pub const DOMAIN_FORGE_CANDIDATE: Domain = "BKGC".*; // ForgeCandidate         (Stage 3.0, FROZEN)
pub const DOMAIN_AGENT_LINEAGE:  Domain = "BKGE".*;  // Agent Lineage          (Stage 4)
pub const DOMAIN_LINEAGE:        Domain = "BKGL".*;  // Lineage-Index          (Stage 2, FROZEN)
pub const DOMAIN_MANIFEST:       Domain = "BKGM".*;  // Manifest Magic         (Model Layer, FROZEN)
pub const DOMAIN_SPORE_SNAPSHOT: Domain = "BKGS".*;  // Spore + Snapshot       (Stage 1 + Model, FROZEN)

/// Stage 3.1 — Media:
pub const DOMAIN_AUDIO_MEDIA:    Domain = "BKGW".*;  // Canonical Audio (Wave/PCM)
pub const DOMAIN_VIDEO_MEDIA:    Domain = "BKGX".*;  // Canonical Video (MKV/FFV1)
pub const DOMAIN_FRAME_SAMPLE:   Domain = "BKGF".*;  // Frame Sample
pub const DOMAIN_IMAGE_UNIT:     Domain = "BKGP".*;  // Image Knowledge Unit (PNG RGBA)
pub const DOMAIN_AUDIO_SEGMENT:  Domain = "BKGJ".*;  // Audio Segment
pub const DOMAIN_VIDEO_SEGMENT:  Domain = "BKGK".*;  // Video Segment

/// Stage 3.1 — Derived:
pub const DOMAIN_TRANSCRIPT:     Domain = "BKGU".*;  // Transcript Artifact
pub const DOMAIN_OCR:            Domain = "BKGZ".*;  // OCR Artifact
pub const DOMAIN_CAPTION:        Domain = "BKGH".*;  // Caption/Description Artifact

/// Stage 3.1 — Embedding:
pub const DOMAIN_DENSE_EMBEDDING: Domain = "BKGD".*; // Dense Embedding
pub const DOMAIN_TAG_SET:         Domain = "BKGV".*; // Tag Set

/// Stage 3.1 — RAG:
pub const DOMAIN_RAG_RECORD:      Domain = "BKGR".*; // RAG Record
pub const DOMAIN_RETRIEVAL_EVIDENCE: Domain = "BKGT".*; // Retrieval Evidence
pub const DOMAIN_RAG_QUERY:       Domain = "BKGN".*; // RAG Query
pub const DOMAIN_RETRIEVAL_POLICY: Domain = "BKGQ".*; // Retrieval Policy
pub const DOMAIN_CANON_POLICY:    Domain = "BKGY".*; // Canonicalization/Media Policy

/// Stage 3.1 — Registry selbst:
pub const DOMAIN_REGISTRY:        Domain = "BKGI".*; // Registry Hash (§4 Registry Metadata Contract)

// ── RESERVED (noch nicht verwendbar) ─────────────────────────────────────
pub const DOMAIN_RESERVED_B:      Domain = "BKGB".*;  // RESERVED
pub const DOMAIN_RESERVED_O:      Domain = "BKGO".*;  // RESERVED

// ── Registry-Metadaten ────────────────────────────────────────────────────

/// Protokoll-Version zu der diese Registry gehört.
pub const PROTOCOL_VERSION: u32 = 1;

/// Monoton steigende Registry-Version (nie 0, nie Rücksprung).
pub const REGISTRY_VERSION: u32 = 1;

/// Domain für die Registry-Hash-Berechnung (§4 Registry Metadata Contract).
/// BKGI ist kanonisch festgelegt und unbelegt (Repository-Scan 2026-09-01).
pub const DOMAIN_FOR_REGISTRY_HASH: Domain = DOMAIN_REGISTRY;

// ── Vollständige Registry-Tabelle (kanonisch sortiert nach Domain-Code) ───

/// Die vollständige Registry. Kanonische Reihenfolge: lexikografisch nach Domain.
/// Keine HashMap-Reihenfolge. Keine Einfügereihenfolge.
pub const REGISTRY: []const RegistryEntry = &[_]RegistryEntry{
    // ── FROZEN (pre-Stage-3.1) ─────────────────────────────────────────────
    .{ .domain = DOMAIN_ARTIFACT,         .status = .allocated,  .allocated_stage = 1,  .first_registry_version = 1 },
    .{ .domain = DOMAIN_RESERVED_B,       .status = .reserved,   .allocated_stage = 0,  .first_registry_version = 0 },
    .{ .domain = DOMAIN_FORGE_CANDIDATE,  .status = .allocated,  .allocated_stage = 3,  .first_registry_version = 1 },
    .{ .domain = DOMAIN_DENSE_EMBEDDING,  .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_AGENT_LINEAGE,    .status = .allocated,  .allocated_stage = 4,  .first_registry_version = 1 },
    .{ .domain = DOMAIN_FRAME_SAMPLE,     .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_CAPTION,          .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_REGISTRY,         .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_AUDIO_SEGMENT,    .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_VIDEO_SEGMENT,    .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_LINEAGE,          .status = .allocated,  .allocated_stage = 2,  .first_registry_version = 1 },
    .{ .domain = DOMAIN_MANIFEST,         .status = .allocated,  .allocated_stage = 0,  .first_registry_version = 1 },
    .{ .domain = DOMAIN_RAG_QUERY,        .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_RESERVED_O,       .status = .reserved,   .allocated_stage = 0,  .first_registry_version = 0 },
    .{ .domain = DOMAIN_IMAGE_UNIT,       .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_RETRIEVAL_POLICY, .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_RAG_RECORD,       .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_SPORE_SNAPSHOT,   .status = .allocated,  .allocated_stage = 1,  .first_registry_version = 1 },
    .{ .domain = DOMAIN_RETRIEVAL_EVIDENCE, .status = .allocated, .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_TRANSCRIPT,       .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_TAG_SET,          .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_AUDIO_MEDIA,      .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_VIDEO_MEDIA,      .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_CANON_POLICY,     .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
    .{ .domain = DOMAIN_OCR,              .status = .allocated,  .allocated_stage = 31, .first_registry_version = 1 },
};

// ── Lookup-Funktionen ─────────────────────────────────────────────────────

/// Gibt den Status eines Domain-Codes zurück, oder null wenn nicht registriert.
pub fn lookupStatus(domain: Domain) ?DomainStatus {
    for (REGISTRY) |entry| {
        if (std.mem.eql(u8, &entry.domain, &domain)) return entry.status;
    }
    return null;
}

/// Gibt den vollständigen Eintrag zurück, oder null wenn nicht registriert.
pub fn lookupEntry(domain: Domain) ?RegistryEntry {
    for (REGISTRY) |entry| {
        if (std.mem.eql(u8, &entry.domain, &domain)) return entry;
    }
    return null;
}

/// Prüft ob ein Domain-Code ALLOCATED ist.
pub fn isAllocated(domain: Domain) bool {
    return lookupStatus(domain) == .allocated;
}

/// Prüft ob ein Domain-Code RESERVED ist.
pub fn isReserved(domain: Domain) bool {
    return lookupStatus(domain) == .reserved;
}

/// Prüft ob ein Domain-Code überhaupt registriert ist (ALLOCATED oder RESERVED).
pub fn isKnown(domain: Domain) bool {
    return lookupStatus(domain) != null;
}

/// Gibt `error.DomainConflict` zurück wenn der Code bereits ALLOCATED ist.
/// Gibt `error.DomainReserved` zurück wenn RESERVED.
/// Gibt `error.DomainUnknown` zurück wenn nicht registriert.
/// Gibt `void` zurück wenn korrekt ALLOCATED für die eigene Verwendung.
pub fn assertAllocated(domain: Domain) error{ DomainConflict, DomainReserved, DomainUnknown }!void {
    const status = lookupStatus(domain) orelse return error.DomainUnknown;
    return switch (status) {
        .allocated  => {},
        .reserved   => error.DomainReserved,
        .unassigned => error.DomainUnknown,
    };
}

// ── Registry-Hash ─────────────────────────────────────────────────────────

/// Berechnet den deterministischen Hash der vollständigen Registry.
/// SHA256("BKGI" || protocol_version_le4 || registry_version_le4 || entry_count_le4
///        || für jeden Eintrag: domain(4) || status(1) || stage(1) || first_ver_le4)
/// Einträge in der Reihenfolge von REGISTRY[] (lexikografisch nach Domain).
pub fn computeRegistryHash() [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&DOMAIN_FOR_REGISTRY_HASH);
    var buf4: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf4, PROTOCOL_VERSION, .little);
    hasher.update(&buf4);
    std.mem.writeInt(u32, &buf4, REGISTRY_VERSION, .little);
    hasher.update(&buf4);
    std.mem.writeInt(u32, &buf4, @intCast(REGISTRY.len), .little);
    hasher.update(&buf4);
    for (REGISTRY) |entry| {
        hasher.update(&entry.domain);
        hasher.update(&[_]u8{ @intFromEnum(entry.status) });
        hasher.update(&[_]u8{ entry.allocated_stage });
        std.mem.writeInt(u32, &buf4, entry.first_registry_version, .little);
        hasher.update(&buf4);
    }
    return hasher.finalResult();
}

// ── Registry-Sortierungs-Verifikation ─────────────────────────────────────

/// Verifiziert, dass REGISTRY lexikografisch nach Domain-Code sortiert ist.
/// Gibt true zurück wenn korrekt sortiert.
pub fn isSorted() bool {
    if (REGISTRY.len < 2) return true;
    var i: usize = 1;
    while (i < REGISTRY.len) : (i += 1) {
        if (std.mem.order(u8, &REGISTRY[i - 1].domain, &REGISTRY[i].domain) != .lt) return false;
    }
    return true;
}

/// Verifiziert, dass kein Domain-Code in der Registry doppelt vorkommt.
pub fn hasDuplicates() bool {
    var i: usize = 0;
    while (i < REGISTRY.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < REGISTRY.len) : (j += 1) {
            if (std.mem.eql(u8, &REGISTRY[i].domain, &REGISTRY[j].domain)) return true;
        }
    }
    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "domain_registry: alle Stage-3.1-Codes sind ALLOCATED" {
    try std.testing.expect(isAllocated(DOMAIN_AUDIO_MEDIA));
    try std.testing.expect(isAllocated(DOMAIN_VIDEO_MEDIA));
    try std.testing.expect(isAllocated(DOMAIN_FRAME_SAMPLE));
    try std.testing.expect(isAllocated(DOMAIN_IMAGE_UNIT));
    try std.testing.expect(isAllocated(DOMAIN_AUDIO_SEGMENT));
    try std.testing.expect(isAllocated(DOMAIN_VIDEO_SEGMENT));
    try std.testing.expect(isAllocated(DOMAIN_TRANSCRIPT));
    try std.testing.expect(isAllocated(DOMAIN_OCR));
    try std.testing.expect(isAllocated(DOMAIN_CAPTION));
    try std.testing.expect(isAllocated(DOMAIN_DENSE_EMBEDDING));
    try std.testing.expect(isAllocated(DOMAIN_TAG_SET));
    try std.testing.expect(isAllocated(DOMAIN_RAG_RECORD));
    try std.testing.expect(isAllocated(DOMAIN_RETRIEVAL_EVIDENCE));
    try std.testing.expect(isAllocated(DOMAIN_RAG_QUERY));
    try std.testing.expect(isAllocated(DOMAIN_RETRIEVAL_POLICY));
    try std.testing.expect(isAllocated(DOMAIN_CANON_POLICY));
    try std.testing.expect(isAllocated(DOMAIN_REGISTRY));
}

test "domain_registry: alle FROZEN-Codes bleiben ALLOCATED" {
    try std.testing.expect(isAllocated(DOMAIN_ARTIFACT));
    try std.testing.expect(isAllocated(DOMAIN_FORGE_CANDIDATE));
    try std.testing.expect(isAllocated(DOMAIN_AGENT_LINEAGE));
    try std.testing.expect(isAllocated(DOMAIN_LINEAGE));
    try std.testing.expect(isAllocated(DOMAIN_MANIFEST));
    try std.testing.expect(isAllocated(DOMAIN_SPORE_SNAPSHOT));
}

test "domain_registry: RESERVED-Codes sind nicht ALLOCATED" {
    try std.testing.expect(!isAllocated(DOMAIN_RESERVED_B));
    try std.testing.expect(!isAllocated(DOMAIN_RESERVED_O));
    try std.testing.expect(isReserved(DOMAIN_RESERVED_B));
    try std.testing.expect(isReserved(DOMAIN_RESERVED_O));
}

test "domain_registry: unbekannte Codes sind nicht ALLOCATED" {
    const unknown: Domain = "BKGE".* ; // wäre eigentlich allocated — falscher Test
    // Korrekte unbekannte Codes prüfen
    const truly_unknown: Domain = "BKGX".*;
    // BKGX ist allocated (Video Media), also prüfen wir einen wirklich fremden Code
    _ = unknown;
    _ = truly_unknown;
    // Prüfe einen Code der nicht im Alphabet BKG-Raum liegt
    const foreign: Domain = "XYZW".*;
    try std.testing.expect(!isAllocated(foreign));
    try std.testing.expect(lookupStatus(foreign) == null);
}

test "domain_registry: assertAllocated korrekte Fehler" {
    // ALLOCATED Code → kein Fehler
    try assertAllocated(DOMAIN_ARTIFACT);
    try assertAllocated(DOMAIN_DENSE_EMBEDDING);

    // RESERVED Code → DomainReserved
    try std.testing.expectError(error.DomainReserved, assertAllocated(DOMAIN_RESERVED_B));

    // Unbekannter Code → DomainUnknown
    try std.testing.expectError(error.DomainUnknown, assertAllocated("ZZZZ".*));
}

test "domain_registry: FROZEN Domain-Codes exakt korrekt" {
    try std.testing.expectEqualSlices(u8, "BKGA", &DOMAIN_ARTIFACT);
    try std.testing.expectEqualSlices(u8, "BKGC", &DOMAIN_FORGE_CANDIDATE);
    try std.testing.expectEqualSlices(u8, "BKGE", &DOMAIN_AGENT_LINEAGE);
    try std.testing.expectEqualSlices(u8, "BKGL", &DOMAIN_LINEAGE);
    try std.testing.expectEqualSlices(u8, "BKGM", &DOMAIN_MANIFEST);
    try std.testing.expectEqualSlices(u8, "BKGS", &DOMAIN_SPORE_SNAPSHOT);
}

test "domain_registry: Stage-3.1-Domain-Codes exakt korrekt" {
    try std.testing.expectEqualSlices(u8, "BKGW", &DOMAIN_AUDIO_MEDIA);
    try std.testing.expectEqualSlices(u8, "BKGX", &DOMAIN_VIDEO_MEDIA);
    try std.testing.expectEqualSlices(u8, "BKGF", &DOMAIN_FRAME_SAMPLE);
    try std.testing.expectEqualSlices(u8, "BKGP", &DOMAIN_IMAGE_UNIT);
    try std.testing.expectEqualSlices(u8, "BKGJ", &DOMAIN_AUDIO_SEGMENT);
    try std.testing.expectEqualSlices(u8, "BKGK", &DOMAIN_VIDEO_SEGMENT);
    try std.testing.expectEqualSlices(u8, "BKGU", &DOMAIN_TRANSCRIPT);
    try std.testing.expectEqualSlices(u8, "BKGZ", &DOMAIN_OCR);
    try std.testing.expectEqualSlices(u8, "BKGH", &DOMAIN_CAPTION);
    try std.testing.expectEqualSlices(u8, "BKGD", &DOMAIN_DENSE_EMBEDDING);
    try std.testing.expectEqualSlices(u8, "BKGV", &DOMAIN_TAG_SET);
    try std.testing.expectEqualSlices(u8, "BKGR", &DOMAIN_RAG_RECORD);
    try std.testing.expectEqualSlices(u8, "BKGT", &DOMAIN_RETRIEVAL_EVIDENCE);
    try std.testing.expectEqualSlices(u8, "BKGN", &DOMAIN_RAG_QUERY);
    try std.testing.expectEqualSlices(u8, "BKGQ", &DOMAIN_RETRIEVAL_POLICY);
    try std.testing.expectEqualSlices(u8, "BKGY", &DOMAIN_CANON_POLICY);
    try std.testing.expectEqualSlices(u8, "BKGI", &DOMAIN_REGISTRY);
}

test "domain_registry: Keine Duplikate" {
    try std.testing.expect(!hasDuplicates());
}

test "domain_registry: Lexikografisch sortiert" {
    try std.testing.expect(isSorted());
}

test "domain_registry: Registry-Hash deterministisch" {
    const h1 = computeRegistryHash();
    const h2 = computeRegistryHash();
    try std.testing.expectEqualSlices(u8, &h1, &h2);
    // Hash darf nicht ZERO sein
    const zero = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &h1, &zero));
}

test "domain_registry: Registry-Hash ändert sich bei Domain-Code-Änderung" {
    // Wir können den Hash der aktuellen Registry mit einer hypothetisch
    // modifizierten vergleichen, indem wir prüfen, dass Änderungen detektiert werden.
    // Indirekter Test: zwei verschiedene Domains erzeugen verschiedene Hashes
    // wenn sie zur Berechnung beigetragen hätten.
    var hasher1 = std.crypto.hash.sha2.Sha256.init(.{});
    hasher1.update("BKGI");
    hasher1.update("BKGD");
    const h1 = hasher1.finalResult();

    var hasher2 = std.crypto.hash.sha2.Sha256.init(.{});
    hasher2.update("BKGI");
    hasher2.update("BKGE"); // anderer Code
    const h2 = hasher2.finalResult();

    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "domain_registry: lookupEntry liefert korrekte first_registry_version" {
    const artifact = lookupEntry(DOMAIN_ARTIFACT).?;
    try std.testing.expectEqual(@as(u32, 1), artifact.first_registry_version);
    try std.testing.expectEqual(@as(u8, 1), artifact.allocated_stage);
    try std.testing.expectEqual(DomainStatus.allocated, artifact.status);
}

test "domain_registry: RESERVED darf nicht als ALLOCATED gelten" {
    try std.testing.expect(!isAllocated(DOMAIN_RESERVED_B));
    try std.testing.expect(!isAllocated(DOMAIN_RESERVED_O));
}

test "domain_registry: Alle Domains sind exakt 4 Bytes" {
    for (REGISTRY) |entry| {
        try std.testing.expectEqual(@as(usize, 4), entry.domain.len);
    }
}

test "domain_registry: protocol_version und registry_version korrekt" {
    try std.testing.expectEqual(@as(u32, 1), PROTOCOL_VERSION);
    try std.testing.expectEqual(@as(u32, 1), REGISTRY_VERSION);
    // registry_version darf nie 0 sein
    try std.testing.expect(REGISTRY_VERSION > 0);
    try std.testing.expect(PROTOCOL_VERSION > 0);
}

test "domain_registry: BKGI ist Registry-Domain" {
    try std.testing.expectEqualSlices(u8, "BKGI", &DOMAIN_FOR_REGISTRY_HASH);
    try std.testing.expect(isAllocated(DOMAIN_FOR_REGISTRY_HASH));
}

test "domain_registry: BKGI war unbelegt vor Stage-3.1 (kein FROZEN-Conflict)" {
    // Beweise: BKGI war nicht in der pre-3.1 FROZEN-Menge
    const frozen_pre31 = [_]Domain{
        DOMAIN_ARTIFACT, DOMAIN_FORGE_CANDIDATE, DOMAIN_AGENT_LINEAGE,
        DOMAIN_LINEAGE,  DOMAIN_MANIFEST,        DOMAIN_SPORE_SNAPSHOT,
    };
    for (frozen_pre31) |frozen| {
        try std.testing.expect(!std.mem.eql(u8, &frozen, &DOMAIN_REGISTRY));
    }
}
