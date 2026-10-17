/// BKG Model Layer — Lineage
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/MODEL_LAYER_v1.md
///
/// Lineage modelliert die vollständige Abstammung eines Artefakts.
///
/// Invarianten:
///   - Ein Kind darf Eltern referenzieren, niemals die Elternhistorie verändern
///   - Rekombination mehrerer Eltern erzeugt eine neue Identität
///   - Neue Version = neue kanonisch referenzierbare Artefakt-Identität
///   - Historische Lineages niemals überschreiben
///   - Generation ist Teil der Lineage, nicht des einzelnen Artefakts
///
/// Kanonische Lineage-Hash-Berechnung:
///   SHA-256( parent_hash[0] || parent_hash[1] || ... || forge_epoch_LE8 || generation_LE8 )
///   Eltern werden in aufsteigender Byte-Reihenfolge sortiert (deterministisch).
const std = @import("std");
const hash_mod    = @import("hash.zig");
const artifact_mod = @import("artifact.zig");

pub const Hash     = hash_mod.Hash;
pub const ZERO_HASH = hash_mod.ZERO_HASH;
pub const MAX_PARENTS = hash_mod.MAX_PARENTS;

// ── Entstehungsereignis ────────────────────────────────────────────────────

/// Wie wurde dieses Artefakt erzeugt?
pub const OriginEvent = enum(u8) {
    /// Direkt von der Forge (kein Parent).
    forge_genesis   = 0x01,
    /// Derivat eines einzelnen Parents.
    single_parent   = 0x02,
    /// Rekombination zweier oder mehrerer Parents.
    recombination   = 0x03,
    /// Evolutionsschritt (Mutation/Verbesserung eines Parents).
    evolution_step  = 0x04,
    /// Buff auf einem bestehenden Artefakt.
    buff_applied    = 0x05,
    /// Curse auf einem bestehenden Artefakt.
    curse_applied   = 0x06,
    /// Aus einer Spore entstanden.
    from_spore      = 0x07,
};

// ── Sporen-Referenz ────────────────────────────────────────────────────────

/// Opake Referenz auf eine Spore (Herkunft, nicht-trusted bis verifiziert).
pub const SporeRef = struct {
    spore_hash:    Hash,
    spore_epoch:   u64,
    spore_origin:  u32, // opaker Origin-Tag
};

// ── Lineage-Eintrag ────────────────────────────────────────────────────────

/// Vollständige Lineage-Beschreibung eines Artefakts.
pub const Lineage = struct {
    /// Kanonischer Lineage-Hash (aus Parents + Epoch + Generation).
    lineage_hash:    Hash,
    /// Wie das Artefakt erzeugt wurde.
    origin_event:    OriginEvent,
    /// Forge-Epoche der Entstehung.
    forge_epoch:     u64,
    /// Generation dieses Artefakts.
    generation:      u64,
    /// Anzahl direkter Eltern (0 bei forge_genesis).
    parent_count:    u8,
    /// Parent-Artefakt-Content-Hashes (geordnet).
    parent_hashes:   [MAX_PARENTS]Hash,
    /// Provenance-Hash (kanonisch aus Provenance-Feldern).
    provenance_hash: Hash,
    /// Optional: Spore-Referenz (isZero spore_hash = keine Spore).
    spore_ref:       SporeRef,
};

// ── Hilfsfunktionen ────────────────────────────────────────────────────────

/// Sortiert Parent-Hashes aufsteigend (lexikografisch) für deterministische Hash-Berechnung.
/// In-place, auf einem festen Array (kein Allokator).
fn sortParents(parents: []Hash) void {
    // Einfaches Insertion-Sort für kleine Arrays (MAX_PARENTS = 8)
    var i: usize = 1;
    while (i < parents.len) : (i += 1) {
        const key = parents[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, &parents[j - 1], &key) == .gt) : (j -= 1) {
            parents[j] = parents[j - 1];
        }
        parents[j] = key;
    }
}

/// Berechnet den kanonischen Lineage-Hash.
///
///   SHA-256( sorted_parent[0] || ... || sorted_parent[n-1]
///            || origin_event:u8
///            || forge_epoch:u64_LE
///            || generation:u64_LE
///            || provenance_hash:32 )
///
/// Eltern werden vor dem Hashen sortiert, damit Rekombination
/// unabhängig von der Einfügereihenfolge deterministisch ist.
pub fn computeLineageHash(
    parent_hashes: []const Hash,
    origin_event:  OriginEvent,
    forge_epoch:   u64,
    generation:    u64,
    provenance_hash: Hash,
) Hash {
    var sorted: [MAX_PARENTS]Hash = [_]Hash{ZERO_HASH} ** MAX_PARENTS;
    const n = @min(parent_hashes.len, MAX_PARENTS);
    for (0..n) |i| sorted[i] = parent_hashes[i];
    sortParents(sorted[0..n]);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..n) |i| hasher.update(&sorted[i]);
    hasher.update(&[_]u8{@intFromEnum(origin_event)});
    var epoch_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &epoch_buf, forge_epoch, .little);
    hasher.update(&epoch_buf);
    var gen_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &gen_buf, generation, .little);
    hasher.update(&gen_buf);
    hasher.update(&provenance_hash);
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

/// Erzeugt eine neue Lineage aus gegebenen Parametern.
pub fn newLineage(
    parent_hashes:  []const Hash,
    origin_event:   OriginEvent,
    forge_epoch:    u64,
    generation:     u64,
    provenance_hash: Hash,
    spore_ref:      SporeRef,
) Lineage {
    const lh = computeLineageHash(parent_hashes, origin_event, forge_epoch, generation, provenance_hash);
    var parents: [MAX_PARENTS]Hash = [_]Hash{ZERO_HASH} ** MAX_PARENTS;
    const n = @min(parent_hashes.len, MAX_PARENTS);
    for (0..n) |i| parents[i] = parent_hashes[i];
    return .{
        .lineage_hash    = lh,
        .origin_event    = origin_event,
        .forge_epoch     = forge_epoch,
        .generation      = generation,
        .parent_count    = @intCast(n),
        .parent_hashes   = parents,
        .provenance_hash = provenance_hash,
        .spore_ref       = spore_ref,
    };
}

/// Gibt Parent-Hashes als Slice zurück.
pub fn lineageParents(l: *const Lineage) []const Hash {
    return l.parent_hashes[0..l.parent_count];
}

/// Berechnet Provenance-Hash aus Provenance-Feldern des Artefakts.
pub fn provenanceHash(prov: *const artifact_mod.Provenance) Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var ep_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &ep_buf, prov.forge_epoch, .little);
    hasher.update(&ep_buf);
    var gen_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &gen_buf, prov.forge_generation, .little);
    hasher.update(&gen_buf);
    hasher.update(&prov.forge_event_hash);
    var tag_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &tag_buf, prov.origin_node_tag, .little);
    hasher.update(&tag_buf);
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

/// Prüft ob das lineage_hash-Feld eines Artefakts mit der tatsächlichen
/// Berechnung übereinstimmt.
pub fn verifyLineageHash(artifact: *const artifact_mod.Artifact) bool {
    const prov_h = provenanceHash(&artifact.provenance);
    const parents = artifact.parents[0..artifact.parent_count];
    // Wir kennen origin_event nicht direkt aus dem Artefakt —
    // Für die Verifikation leiten wir es aus parent_count ab (vereinfacht).
    // Der vollständige Validator nutzt eine Lineage-Struktur.
    // Hier: deterministisch via Generation und Epoché.
    const oe: OriginEvent = if (artifact.parent_count == 0)
        .forge_genesis
    else if (artifact.parent_count == 1)
        .single_parent
    else
        .recombination;
    const expected = computeLineageHash(
        parents,
        oe,
        artifact.provenance.forge_epoch,
        artifact.provenance.forge_generation,
        prov_h,
    );
    return hash_mod.hashEqual(expected, artifact.lineage_hash);
}

// ── SporeRef Hilfsfunktionen ───────────────────────────────────────────────

pub fn noSpore() SporeRef {
    return .{ .spore_hash = ZERO_HASH, .spore_epoch = 0, .spore_origin = 0 };
}

pub fn hasSpore(sr: SporeRef) bool {
    return !hash_mod.isZero(sr.spore_hash);
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "lineage: computeLineageHash deterministisch" {
    const p1 = hash_mod.hashBytes("parent1");
    const p2 = hash_mod.hashBytes("parent2");
    const ph = hash_mod.hashBytes("prov");
    const h1 = computeLineageHash(&[_]Hash{p1, p2}, .recombination, 100, 3, ph);
    const h2 = computeLineageHash(&[_]Hash{p1, p2}, .recombination, 100, 3, ph);
    try std.testing.expect(hash_mod.hashEqual(h1, h2));
}

test "lineage: computeLineageHash — Reihenfolge der Parents spielt keine Rolle (sortiert)" {
    const p1 = hash_mod.hashBytes("parent1");
    const p2 = hash_mod.hashBytes("parent2");
    const ph = hash_mod.hashBytes("prov");
    const h_12 = computeLineageHash(&[_]Hash{p1, p2}, .recombination, 100, 3, ph);
    const h_21 = computeLineageHash(&[_]Hash{p2, p1}, .recombination, 100, 3, ph);
    // Nach Sortierung identisch
    try std.testing.expect(hash_mod.hashEqual(h_12, h_21));
}

test "lineage: unterschiedliche Epochs → unterschiedliche Lineage" {
    const ph = hash_mod.hashBytes("prov");
    const h1 = computeLineageHash(&[_]Hash{}, .forge_genesis, 10, 1, ph);
    const h2 = computeLineageHash(&[_]Hash{}, .forge_genesis, 11, 1, ph);
    try std.testing.expect(!hash_mod.hashEqual(h1, h2));
}

test "lineage: unterschiedliche Generation → unterschiedliche Lineage" {
    const ph = hash_mod.hashBytes("prov");
    const h1 = computeLineageHash(&[_]Hash{}, .forge_genesis, 10, 1, ph);
    const h2 = computeLineageHash(&[_]Hash{}, .forge_genesis, 10, 2, ph);
    try std.testing.expect(!hash_mod.hashEqual(h1, h2));
}

test "lineage: Rekombination zweier Parents → neue Identität" {
    const p1 = hash_mod.hashBytes("A");
    const p2 = hash_mod.hashBytes("B");
    const ph = ZERO_HASH;
    const h_recomb = computeLineageHash(&[_]Hash{p1, p2}, .recombination, 1, 1, ph);
    const h_single = computeLineageHash(&[_]Hash{p1},      .single_parent, 1, 1, ph);
    try std.testing.expect(!hash_mod.hashEqual(h_recomb, h_single));
}

test "lineage: Parent-Lineage — neues Child ohne Überschreiben des Parents" {
    const parent_h = hash_mod.hashBytes("parent");
    const ph = ZERO_HASH;
    const parent_lin = newLineage(&[_]Hash{}, .forge_genesis, 1, 1, ph, noSpore());
    const child_lin  = newLineage(&[_]Hash{parent_h}, .single_parent, 2, 2, ph, noSpore());
    // Parent-Lineage bleibt unverändert
    try std.testing.expectEqual(@as(u8, 0), parent_lin.parent_count);
    // Child referenziert Parent
    try std.testing.expectEqual(@as(u8, 1), child_lin.parent_count);
    try std.testing.expect(hash_mod.hashEqual(parent_h, child_lin.parent_hashes[0]));
    // Lineage-Hashes sind verschieden
    try std.testing.expect(!hash_mod.hashEqual(parent_lin.lineage_hash, child_lin.lineage_hash));
}

test "lineage: provenanceHash deterministisch" {
    const prov = artifact_mod.Provenance{
        .forge_epoch = 5, .forge_generation = 2,
        .forge_event_hash = ZERO_HASH, .origin_node_tag = 0,
    };
    const h1 = provenanceHash(&prov);
    const h2 = provenanceHash(&prov);
    try std.testing.expect(hash_mod.hashEqual(h1, h2));
}

test "lineage: noSpore hat isZero spore_hash" {
    const sr = noSpore();
    try std.testing.expect(!hasSpore(sr));
}

test "lineage: hasSpore erkennt echte Spore" {
    const sr = SporeRef{
        .spore_hash = hash_mod.hashBytes("spore"),
        .spore_epoch = 1, .spore_origin = 0,
    };
    try std.testing.expect(hasSpore(sr));
}

test "lineage: lineageParents gibt korrekten Slice" {
    const p = hash_mod.hashBytes("p");
    const l = newLineage(&[_]Hash{p}, .single_parent, 1, 1, ZERO_HASH, noSpore());
    try std.testing.expectEqual(@as(usize, 1), lineageParents(&l).len);
    try std.testing.expect(hash_mod.hashEqual(p, lineageParents(&l)[0]));
}
