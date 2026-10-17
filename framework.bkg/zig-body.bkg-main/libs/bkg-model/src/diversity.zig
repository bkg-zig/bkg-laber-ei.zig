/// BKG Model Layer — Diversity Layer
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/MODEL_LAYER_v1.md
///
/// Deterministischer, zustandsloser Diversity-Layer.
///
/// Zweck:
///   Bewertung der Informationsdiversität eines Beitrags oder einer Beobachtung.
///   Wird von Guardian/Forge zur XP-/Evolutionspriorisierung verwendet.
///   Trifft KEINE wirtschaftlichen Entscheidungen. Gibt nur Merkmale zurück.
///
/// Invarianten:
///   - Alle Berechnungen deterministisch (gleicher Input → gleicher Output)
///   - Kein Zustand, kein Singleton, kein Allokator
///   - Diversity-Bewertung erzeugt keine Identität oder Authority
///   - Wiederholung soll langfristig weniger Evolutionswert erzeugen
///   - Neue Information, neue Lineages, unabhängige Evidence bevorzugt
///
/// Dimensionen:
///   1. Lineage-Diversität: wie weit sind die Lineages der Eltern voneinander entfernt?
///   2. Parent-Diversität: wie viele verschiedene Parents?
///   3. Node-/Gebiets-Diversität: wie viele verschiedene Origin-Tags?
///   4. Wiederholungsrate: wie oft wurde dieselbe Hash-Quelle gesehen?
///   5. Neu vs. bekannt: neue Artefakte vs. bereits absorbierte
///   6. Beitragshäufigkeit: wie oft hat dieselbe Lineage beigetragen?
///   7. Unabhängige Evidence: wie viele verschiedene Guardian-Evidence-Hashes?
const std = @import("std");
const hash_mod = @import("hash.zig");

pub const Hash = hash_mod.Hash;
pub const ZERO_HASH = hash_mod.ZERO_HASH;

// ── Diversitäts-Score ─────────────────────────────────────────────────────

/// Normalisierter Diversitäts-Score (0..255).
/// 255 = maximale Diversität, 0 = keine Diversität (vollständige Wiederholung).
pub const DiversityScore = u8;

/// Schwellenwert für "niedrige Diversität" (Guardian-Policy).
pub const LOW_DIVERSITY_THRESHOLD: DiversityScore  = 64;
/// Schwellenwert für "hohe Diversität".
pub const HIGH_DIVERSITY_THRESHOLD: DiversityScore = 192;

// ── Diversity-Kontext ─────────────────────────────────────────────────────

/// Maximale Anzahl von Lineages/Parents/Nodes/Evidence-Einträgen für Diversity-Berechnung.
pub const MAX_DIVERSITY_ENTRIES: usize = 32;

/// Eingabe für die Diversity-Berechnung eines einzelnen Beitrags.
pub const DiversityInput = struct {
    /// Parent-Lineage-Hashes (aus Artefakt-Lineage).
    parent_count:       u8,
    parent_hashes:      [hash_mod.MAX_PARENTS]Hash,
    /// Origin-Node-Tags (opak, für Gebiets-Diversität).
    origin_count:       u8,
    origin_tags:        [8]u32,
    /// Bisher gesehene Lineage-Hashes (aus dem bisherigen Verlauf, extern verwaltet).
    seen_lineage_count: u8,
    seen_lineages:      [MAX_DIVERSITY_ENTRIES]Hash,
    /// Bisher gesehene Artefakt-Hashes (bekannte Artefakte).
    known_artifact_count: u8,
    known_artifacts:    [MAX_DIVERSITY_ENTRIES]Hash,
    /// Neues Artefakt (das bewertet wird).
    new_artifact_hash:  Hash,
    /// Guardian-Evidence-Hashes (für unabhängige Evidence-Messung).
    evidence_count:     u8,
    evidence_hashes:    [MAX_DIVERSITY_ENTRIES]Hash,
    /// Aktueller Beitragszähler dieser Lineage in dieser Epoch.
    contribution_count: u32,
};

// ── Diversity-Ergebnis ─────────────────────────────────────────────────────

/// Vollständiges Diversity-Ergebnis mit allen Dimensionen.
pub const DiversityResult = struct {
    /// Gesamt-Score (0..255).
    total_score:           DiversityScore,
    /// Einzeldimensionen (0..255).
    lineage_diversity:     DiversityScore,
    parent_diversity:      DiversityScore,
    node_diversity:        DiversityScore,
    repetition_penalty:    DiversityScore, // 0 = viele Wiederholungen, 255 = keine
    novelty_score:         DiversityScore, // 255 = vollständig neu, 0 = bereits bekannt
    contribution_score:    DiversityScore, // 255 = erste Contribution, 0 = über-repetitiv
    independent_evidence:  DiversityScore, // 255 = viele unabhängige Guardians, 0 = keine
    /// Markierungen
    is_low_diversity:      bool,
    is_high_diversity:     bool,
    is_novel:              bool,
};

// ── Diversity-Berechnungen ─────────────────────────────────────────────────

/// Berechnet wie viele der `parents` bereits in `seen` vorhanden sind.
/// Gibt Anteil der NICHT gesehenen zurück (0..255).
fn parentNovelty(
    parents:      []const Hash,
    seen:         []const Hash,
) DiversityScore {
    if (parents.len == 0) return 128; // Neutral bei keinen Parents
    var new_count: u32 = 0;
    for (parents) |p| {
        var found = false;
        for (seen) |s| {
            if (hash_mod.hashEqual(p, s)) { found = true; break; }
        }
        if (!found) new_count += 1;
    }
    // Normalisieren: 0..parents.len → 0..255
    return @intCast((new_count * 255) / parents.len);
}

/// Berechnet Lineage-Diversität: Anteil verschiedener Lineage-Hashes.
fn lineageDiversity(parents: []const Hash) DiversityScore {
    if (parents.len == 0) return 128;
    if (parents.len == 1) return 128; // Ein Parent = neutral
    // Zähle unique Hashes
    var unique: u32 = 0;
    for (0..parents.len) |i| {
        var dup = false;
        for (0..i) |j| {
            if (hash_mod.hashEqual(parents[i], parents[j])) { dup = true; break; }
        }
        if (!dup) unique += 1;
    }
    return @intCast((unique * 255) / parents.len);
}

/// Berechnet Node-Diversität aus Origin-Tags.
fn nodeDiversity(tags: []const u32) DiversityScore {
    if (tags.len == 0) return 128;
    // Zähle unique Tags
    var unique: u32 = 0;
    for (0..tags.len) |i| {
        var dup = false;
        for (0..i) |j| {
            if (tags[i] == tags[j]) { dup = true; break; }
        }
        if (!dup) unique += 1;
    }
    return @intCast((unique * 255) / tags.len);
}

/// Repetitions-Penalty: höhere contribution_count → niedrigerer Score.
/// 0 contributions → 255 (maximal), linear fallend bis 255+ = 0.
fn repetitionPenalty(count: u32) DiversityScore {
    if (count == 0) return 255;
    if (count >= 255) return 0;
    return @intCast(255 - count);
}

/// Novelty: ist new_artifact_hash in known_artifacts?
fn artifactNovelty(h: Hash, known: []const Hash) DiversityScore {
    for (known) |k| {
        if (hash_mod.hashEqual(h, k)) return 0; // Bekannt
    }
    return 255; // Neu
}

/// Evidence-Diversität: wie viele verschiedene Guardian-Evidence-Hashes?
fn evidenceDiversity(evidence: []const Hash) DiversityScore {
    if (evidence.len == 0) return 0;
    var unique: u32 = 0;
    for (0..evidence.len) |i| {
        var dup = false;
        for (0..i) |j| {
            if (hash_mod.hashEqual(evidence[i], evidence[j])) { dup = true; break; }
        }
        if (!dup) unique += 1;
    }
    const capped: u32 = @min(unique, 8); // Sättigungsgrenze bei 8, explizit u32
    const result: u32 = (capped * 255) / 8;
    return @intCast(result);
}

/// Berechnet den Gesamt-Diversity-Score (gewichtetes Mittel der Dimensionen).
///
/// Gewichtung:
///   novelty_score         × 3  (wichtigste Dimension)
///   lineage_diversity     × 2
///   parent_diversity      × 2
///   repetition_penalty    × 2
///   node_diversity        × 1
///   contribution_score    × 1
///   independent_evidence  × 1
fn computeTotalScore(r: *const DiversityResult) DiversityScore {
    const sum: u32 =
        @as(u32, r.novelty_score)        * 3 +
        @as(u32, r.lineage_diversity)    * 2 +
        @as(u32, r.parent_diversity)     * 2 +
        @as(u32, r.repetition_penalty)   * 2 +
        @as(u32, r.node_diversity)       * 1 +
        @as(u32, r.contribution_score)   * 1 +
        @as(u32, r.independent_evidence) * 1;
    const total = sum / 12; // Summe der Gewichte
    return @intCast(@min(total, 255));
}

/// PROTOKOLLREGEL M8 — SEMANTISCHE GRENZE:
/// `computeDiversity()` kennt ausschließlich kanonisch vergleichbare Werte
/// (Hashes, Tags und Zähler). Die Funktion kann nicht erkennen, ob ein Hash
/// semantisch „neu“ oder „alt“ ist, außer der Caller liefert die entsprechende
/// Historie in `known_artifacts`/`seen_lineages`.
///
/// Qualität, Aktualität und Unabhängigkeit dieser Listen sind daher eine
/// Guardian-/Forge-Verantwortung. Der Diversity-Layer selbst erfindet keine
/// Semantik und liest keine Rohtelemetrie.
///
/// Hauptfunktion: berechnet vollständiges Diversity-Ergebnis.
///
/// Deterministisch: gleicher DiversityInput → gleicher DiversityResult.
/// Kein Allokator, kein Zustand, keine Seiteneffekte.
pub fn computeDiversity(input: *const DiversityInput) DiversityResult {
    const parents = input.parent_hashes[0..input.parent_count];
    const origins = input.origin_tags[0..input.origin_count];
    const seen    = input.seen_lineages[0..input.seen_lineage_count];
    const known   = input.known_artifacts[0..input.known_artifact_count];
    const evidence = input.evidence_hashes[0..input.evidence_count];

    const ld  = lineageDiversity(parents);
    const pd  = parentNovelty(parents, seen);
    const nd  = nodeDiversity(origins);
    const rp  = repetitionPenalty(input.contribution_count);
    const nov = artifactNovelty(input.new_artifact_hash, known);
    const cs  = repetitionPenalty(@min(input.contribution_count, 255));
    const ie  = evidenceDiversity(evidence);

    var result = DiversityResult{
        .total_score          = 0,
        .lineage_diversity    = ld,
        .parent_diversity     = pd,
        .node_diversity       = nd,
        .repetition_penalty   = rp,
        .novelty_score        = nov,
        .contribution_score   = cs,
        .independent_evidence = ie,
        .is_low_diversity  = false,
        .is_high_diversity = false,
        .is_novel          = nov >= HIGH_DIVERSITY_THRESHOLD,
    };
    result.total_score = computeTotalScore(&result);
    result.is_low_diversity  = result.total_score <= LOW_DIVERSITY_THRESHOLD;
    result.is_high_diversity = result.total_score >= HIGH_DIVERSITY_THRESHOLD;
    return result;
}

/// Convenience: Null-Input (vollständige Wiederholung eines bekannten Artefakts).
pub fn zeroInput(known_hash: Hash) DiversityInput {
    var inp = DiversityInput{
        .parent_count = 0,
        .parent_hashes = [_]Hash{ZERO_HASH} ** hash_mod.MAX_PARENTS,
        .origin_count = 0,
        .origin_tags = [_]u32{0} ** 8,
        .seen_lineage_count = 1,
        .seen_lineages = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .known_artifact_count = 1,
        .known_artifacts = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .new_artifact_hash = known_hash,
        .evidence_count = 0,
        .evidence_hashes = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .contribution_count = 100,
    };
    inp.known_artifacts[0] = known_hash;
    return inp;
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "diversity: deterministisch — gleicher Input → gleicher Output" {
    const inp = zeroInput(hash_mod.hashBytes("known"));
    const r1 = computeDiversity(&inp);
    const r2 = computeDiversity(&inp);
    try std.testing.expectEqual(r1.total_score, r2.total_score);
    try std.testing.expectEqual(r1.novelty_score, r2.novelty_score);
}

test "diversity: vollständig bekanntes Artefakt → novelty_score 0" {
    const h = hash_mod.hashBytes("known");
    const inp = zeroInput(h);
    const r = computeDiversity(&inp);
    // Bekanntes Artefakt → novelty_score = 0
    try std.testing.expect(r.novelty_score == 0);
    // is_novel = false
    try std.testing.expect(!r.is_novel);
    // Beitragszähler hoch (100) → repetition_penalty deutlich unter 255
    try std.testing.expect(r.repetition_penalty < 200);
}

test "diversity: neues Artefakt → novelty_score = 255" {
    const fresh = DiversityInput{
        .parent_count = 0,
        .parent_hashes = [_]Hash{ZERO_HASH} ** hash_mod.MAX_PARENTS,
        .origin_count = 0,
        .origin_tags = [_]u32{0} ** 8,
        .seen_lineage_count = 0,
        .seen_lineages = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .known_artifact_count = 0,
        .known_artifacts = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .new_artifact_hash = hash_mod.hashBytes("brand-new"),
        .evidence_count = 0,
        .evidence_hashes = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .contribution_count = 0,
    };
    const r = computeDiversity(&fresh);
    try std.testing.expectEqual(@as(DiversityScore, 255), r.novelty_score);
    try std.testing.expect(r.is_novel);
}

test "diversity: hohe Diversität — diverse Parents, neue Artefakte, multiple Nodes" {
    var inp = DiversityInput{
        .parent_count = 4,
        .parent_hashes = [_]Hash{ZERO_HASH} ** hash_mod.MAX_PARENTS,
        .origin_count = 4,
        .origin_tags = [_]u32{0} ** 8,
        .seen_lineage_count = 0,
        .seen_lineages = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .known_artifact_count = 0,
        .known_artifacts = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .new_artifact_hash = hash_mod.hashBytes("very-new"),
        .evidence_count = 8,
        .evidence_hashes = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .contribution_count = 0,
    };
    // Verschiedene Parents
    inp.parent_hashes[0] = hash_mod.hashBytes("p1");
    inp.parent_hashes[1] = hash_mod.hashBytes("p2");
    inp.parent_hashes[2] = hash_mod.hashBytes("p3");
    inp.parent_hashes[3] = hash_mod.hashBytes("p4");
    // Verschiedene Nodes
    inp.origin_tags[0] = 1; inp.origin_tags[1] = 2;
    inp.origin_tags[2] = 3; inp.origin_tags[3] = 4;
    // Verschiedene Evidence
    for (0..8) |i| {
        var eh: Hash = ZERO_HASH;
        eh[0] = @intCast(i + 1);
        inp.evidence_hashes[i] = eh;
    }
    const r = computeDiversity(&inp);
    try std.testing.expect(r.is_high_diversity);
    try std.testing.expect(!r.is_low_diversity);
}

test "diversity: niedrige Diversität — bekannte Artefakte, viele Contributions" {
    const h = hash_mod.hashBytes("known");
    // Extremer Fall: contribution_count maximal, kein novelty
    var inp = zeroInput(h);
    inp.contribution_count = 255; // maximale Wiederholung
    const r = computeDiversity(&inp);
    // novelty_score = 0 (bekanntes Artefakt)
    try std.testing.expect(r.novelty_score == 0);
    // repetition_penalty = 0 bei count=255
    try std.testing.expect(r.repetition_penalty == 0);
    // Gesamt-Score niedrig wegen novelty=0 und rep=0
    try std.testing.expect(r.total_score <= LOW_DIVERSITY_THRESHOLD);
    try std.testing.expect(r.is_low_diversity);
}

test "diversity: M8 — gleiche neue Hashes bleiben semantisch blind" {
    var a = zeroInput(hash_mod.hashBytes("alpha"));
    var b = zeroInput(hash_mod.hashBytes("beta"));
    a.known_artifact_count = 0;
    b.known_artifact_count = 0;
    a.seen_lineage_count = 0;
    b.seen_lineage_count = 0;

    const ra = computeDiversity(&a);
    const rb = computeDiversity(&b);
    try std.testing.expectEqual(@as(DiversityScore, 255), ra.novelty_score);
    try std.testing.expectEqual(@as(DiversityScore, 255), rb.novelty_score);
    try std.testing.expectEqual(ra.novelty_score, rb.novelty_score);
}

test "diversity: repetitionPenalty — steigende Counts → sinkender Score" {
    var inp0 = zeroInput(hash_mod.hashBytes("x"));
    inp0.contribution_count = 0;
    var inp100 = zeroInput(hash_mod.hashBytes("x"));
    inp100.contribution_count = 100;
    const r0   = computeDiversity(&inp0);
    const r100 = computeDiversity(&inp100);
    try std.testing.expect(r0.repetition_penalty > r100.repetition_penalty);
}

test "diversity: evidenceDiversity — mehr Guardians → höherer Score" {
    var inp_low  = DiversityInput{
        .parent_count = 0, .parent_hashes = [_]Hash{ZERO_HASH} ** hash_mod.MAX_PARENTS,
        .origin_count = 0, .origin_tags = [_]u32{0} ** 8,
        .seen_lineage_count = 0, .seen_lineages = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .known_artifact_count = 0, .known_artifacts = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .new_artifact_hash = hash_mod.hashBytes("z"),
        .evidence_count = 1, .evidence_hashes = [_]Hash{ZERO_HASH} ** MAX_DIVERSITY_ENTRIES,
        .contribution_count = 0,
    };
    inp_low.evidence_hashes[0] = hash_mod.hashBytes("e1");

    var inp_high = inp_low;
    inp_high.evidence_count = 8;
    for (0..8) |i| {
        var eh: Hash = ZERO_HASH; eh[0] = @intCast(i + 1);
        inp_high.evidence_hashes[i] = eh;
    }
    const r_low  = computeDiversity(&inp_low);
    const r_high = computeDiversity(&inp_high);
    try std.testing.expect(r_high.independent_evidence > r_low.independent_evidence);
}

test "diversity: Basis-Invariante — kein Authority aus Score" {
    // Dieser Test dokumentiert die Architekturinvariante:
    // DiversityResult erzeugt keine Identity, keine Authority, kein Trust.
    const inp = zeroInput(ZERO_HASH);
    const r = computeDiversity(&inp);
    // Score ist nur ein u8 — keine Identität ableitbar
    try std.testing.expect(r.total_score <= 255);
    // Kein is_high wenn bekanntes Artefakt mit vielen Contributions
    try std.testing.expect(!r.is_high_diversity);
}
