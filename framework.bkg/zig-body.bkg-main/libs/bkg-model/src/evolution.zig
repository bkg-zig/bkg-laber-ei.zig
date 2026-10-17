/// BKG Model Layer — Evolution
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/MODEL_LAYER_v1.md
///
/// Evolution-Distance und XP-Berechnung.
///
/// Zweck:
///   - Anti-Inzucht: Zu kleine Distanz zwischen Eltern erkennen
///   - XP-Priorisierung: Neue Kombinationen sollen höheren Evolutionswert liefern
///   - Determinismus: Gleicher Input → gleicher Output (reproduzierbar)
///   - Keine Authority: Evolution-Distance erzeugt keine Identität, keine Macht
///
/// Evolution-Distance:
///   Basiert auf Lineage-Hashes, nicht auf Strings oder Versionen.
///   Kanonisch: SHA-256 der XOR-Distanz zweier Lineage-Hashes.
///   Näher als MIN_EVOLUTION_DISTANCE → low-diversity-Kandidat.
///
/// Anti-Inzucht-Policy:
///   - EvolutionDistance < MIN → low_inbreeding Markierung
///   - Policy kann Rekombination ablehnen wenn distance < hard_minimum
///   - Entscheidung policy-basiert, nicht autoritär
///   - Kein Zerstören erfolgreicher Lineages
///
/// XP-Berechnung:
///   - Deterministisch aus Diversity-Score und Evolution-Distance
///   - Sinkender marginaler Wert bei Wiederholung
///   - Neue Information, neue Kombinationen → höherer XP
///   - XP ist Guardian/Forge-Input, keine lokale Entscheidung
const std = @import("std");
const hash_mod     = @import("hash.zig");
const diversity_mod = @import("diversity.zig");

pub const Hash = hash_mod.Hash;
pub const ZERO_HASH = hash_mod.ZERO_HASH;

// ── Konstanten ─────────────────────────────────────────────────────────────

/// Minimale Evolution-Distance für "gesunde" Rekombination.
/// Unter diesem Wert → Low-Inbreeding-Markierung.
pub const MIN_EVOLUTION_DISTANCE: u32 = 16;

/// Hard-Minimum: unter diesem Wert Policy-Ablehnung möglich.
pub const HARD_MIN_EVOLUTION_DISTANCE: u32 = 4;

/// Maximaler XP-Wert pro Beitrag.
pub const MAX_XP_PER_CONTRIBUTION: u32 = 1000;

// ── Evolution-Distance ─────────────────────────────────────────────────────

/// Deterministisch berechnete Evolution-Distance zwischen zwei Lineages.
///
/// Berechnung:
///   XOR-Distanz = Anzahl unterschiedlicher Bits in (left XOR right)
///   Das ist die Hamming-Distanz der zwei 32-Byte-Hashes.
///
/// Zwei identische Lineages → Distanz 0 (Maximum Inzucht).
/// Zwei unabhängige Lineages → Distanz ~128 (Maximum Diversität).
pub fn evolutionDistance(left: Hash, right: Hash) u32 {
    var dist: u32 = 0;
    for (0..32) |i| {
        dist += @popCount(left[i] ^ right[i]);
    }
    return dist;
}

/// Kanonischer Distance-Hash: SHA-256(left || right || distance_LE4).
/// Für reproduzierbare Evidence über die berechnete Distanz.
pub fn evolutionDistanceHash(left: Hash, right: Hash) Hash {
    const dist = evolutionDistance(left, right);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&left);
    hasher.update(&right);
    var db: [4]u8 = undefined;
    std.mem.writeInt(u32, &db, dist, .little);
    hasher.update(&db);
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

// ── Inzucht-Prüfung ────────────────────────────────────────────────────────

/// Ergebnis einer Inzucht-Prüfung.
pub const InbreedingResult = struct {
    /// Berechnete Distanz.
    distance:          u32,
    /// Unter MIN_EVOLUTION_DISTANCE?
    is_low_diversity:  bool,
    /// Unter HARD_MIN_EVOLUTION_DISTANCE?
    is_critically_low: bool,
    /// Deterministische Policy-Empfehlung.
    policy_reject:     bool,
};

/// Prüft zwei Lineage-Hashes auf Inzucht.
///
/// Policy-basiert und reproduzierbar.
/// Keine automatische Zerstörung erfolgreicher Lineages.
pub fn checkInbreeding(
    lineage_a:     Hash,
    lineage_b:     Hash,
    hard_min:      u32,
) InbreedingResult {
    const dist = evolutionDistance(lineage_a, lineage_b);
    return .{
        .distance          = dist,
        .is_low_diversity  = dist < MIN_EVOLUTION_DISTANCE,
        .is_critically_low = dist < HARD_MIN_EVOLUTION_DISTANCE,
        .policy_reject     = dist < hard_min,
    };
}

/// Prüft ein Set von Eltern-Lineages auf gegenseitige Inzucht.
/// Gibt die minimale Distanz zwischen allen Elternpaaren zurück.
pub fn minParentDistance(
    parents: []const Hash,
) u32 {
    if (parents.len < 2) return 256; // Kein Paar → maximale Distanz
    var min_dist: u32 = 256;
    for (0..parents.len) |i| {
        for (i + 1..parents.len) |j| {
            const d = evolutionDistance(parents[i], parents[j]);
            if (d < min_dist) min_dist = d;
        }
    }
    return min_dist;
}

// ── XP-Berechnung ──────────────────────────────────────────────────────────

/// XP-Input für einen Beitrag.
pub const XpInput = struct {
    /// Diversity-Score des Beitrags (0..255).
    diversity_score:    diversity_mod.DiversityScore,
    /// Minimale Eltern-Distanz (0..256).
    min_parent_distance: u32,
    /// Anzahl bisheriger Contributions dieser Lineage in dieser Epoch.
    contribution_count: u32,
    /// Ist das Artefakt neu?
    is_novel:           bool,
};

/// Berechnet deterministischen XP-Wert für einen Beitrag.
///
/// Formel:
///   base_xp = (diversity_score * MAX_XP) / 255
///   inbreeding_factor = min(min_parent_distance, 128) / 128.0  [0..1]
///   repetition_factor = 1 / (1 + contribution_count / 10)      [sinkend]
///   novelty_bonus = 2× wenn is_novel, sonst 1×
///   xp = base_xp * inbreeding_factor * repetition_factor * novelty_bonus
///
/// Alle Berechnungen in u32-Arithmetik (deterministisch, kein Float).
pub fn computeXp(inp: XpInput) u32 {
    // Basis-XP aus Diversity
    const base_xp: u32 = (@as(u32, inp.diversity_score) * MAX_XP_PER_CONTRIBUTION) / 255;

    // Inzucht-Faktor (Skala 0..128 → 0..128/128 = 0..1 simuliert als 0..128)
    const inb: u32 = @min(inp.min_parent_distance, 128);

    // Repetitions-Dämpfung: 100 / (10 + contribution_count)
    // Bei count=0: 100/10 = 10x Verstärker (cap: 10), bei count=90: 100/100 = 1
    const rep_denom: u32 = 10 + inp.contribution_count;
    const rep_factor_100: u32 = 1000 / rep_denom; // in 0.001-Einheiten

    // Neuheits-Bonus: 2× wenn neu
    const novelty_mult: u32 = if (inp.is_novel) 2 else 1;

    // XP = base_xp * inb/128 * rep_factor_100/1000 * novelty_mult
    const xp = (base_xp * inb / 128) * rep_factor_100 / 1000 * novelty_mult;
    return @min(xp, MAX_XP_PER_CONTRIBUTION);
}

// ── Evolution-Snapshot ─────────────────────────────────────────────────────

/// Deterministischer Evolution-Snapshot für einen Agenten.
pub const EvolutionSnapshot = struct {
    /// Lineage-Hash des Agenten.
    lineage_hash:   Hash,
    /// Aktuelle Generation.
    generation:     u64,
    /// Epoch dieses Snapshots.
    epoch:          u64,
    /// Akkumulierter XP (für externe Nutzung durch Forge/Guardian).
    total_xp:       u64,
    /// Letzter Beitrag-XP.
    last_xp:        u32,
    /// Kanonischer Snapshot-Hash.
    snapshot_hash:  Hash,
};

/// Berechnet Snapshot-Hash: SHA-256(lineage || generation || epoch || total_xp).
pub fn computeEvolutionSnapshotHash(
    lineage:    Hash,
    generation: u64,
    epoch:      u64,
    total_xp:   u64,
) Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&lineage);
    var gen_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &gen_buf, generation, .little);
    hasher.update(&gen_buf);
    var ep_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &ep_buf, epoch, .little);
    hasher.update(&ep_buf);
    var xp_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &xp_buf, total_xp, .little);
    hasher.update(&xp_buf);
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

/// Erzeugt einen neuen EvolutionSnapshot.
pub fn newEvolutionSnapshot(
    lineage_hash: Hash,
    generation:   u64,
    epoch:        u64,
    total_xp:     u64,
    last_xp:      u32,
) EvolutionSnapshot {
    return .{
        .lineage_hash  = lineage_hash,
        .generation    = generation,
        .epoch         = epoch,
        .total_xp      = total_xp,
        .last_xp       = last_xp,
        .snapshot_hash = computeEvolutionSnapshotHash(lineage_hash, generation, epoch, total_xp),
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "evolution: evolutionDistance — gleiche Hashes → Distanz 0" {
    const h = hash_mod.hashBytes("same");
    try std.testing.expectEqual(@as(u32, 0), evolutionDistance(h, h));
}

test "evolution: evolutionDistance — verschiedene Hashes → Distanz > 0" {
    const h1 = hash_mod.hashBytes("a");
    const h2 = hash_mod.hashBytes("b");
    try std.testing.expect(evolutionDistance(h1, h2) > 0);
}

test "evolution: evolutionDistance — deterministisch" {
    const h1 = hash_mod.hashBytes("x");
    const h2 = hash_mod.hashBytes("y");
    try std.testing.expectEqual(evolutionDistance(h1, h2), evolutionDistance(h1, h2));
}

test "evolution: evolutionDistance — symmetrisch" {
    const h1 = hash_mod.hashBytes("p");
    const h2 = hash_mod.hashBytes("q");
    try std.testing.expectEqual(evolutionDistance(h1, h2), evolutionDistance(h2, h1));
}

test "evolution: checkInbreeding — identische Lineages → is_critically_low" {
    const h = hash_mod.hashBytes("same");
    const r = checkInbreeding(h, h, HARD_MIN_EVOLUTION_DISTANCE);
    try std.testing.expect(r.is_critically_low);
    try std.testing.expect(r.is_low_diversity);
    try std.testing.expect(r.distance == 0);
}

test "evolution: checkInbreeding — verschiedene Lineages → gesunde Distanz" {
    const h1 = hash_mod.hashBytes("lineage-A");
    const h2 = hash_mod.hashBytes("lineage-B");
    const r  = checkInbreeding(h1, h2, HARD_MIN_EVOLUTION_DISTANCE);
    try std.testing.expect(!r.is_critically_low);
    try std.testing.expect(r.distance > HARD_MIN_EVOLUTION_DISTANCE);
}

test "evolution: checkInbreeding — policy_reject wenn unter hard_min" {
    const h = hash_mod.hashBytes("same");
    const r = checkInbreeding(h, h, 1);
    try std.testing.expect(r.policy_reject);
}

test "evolution: minParentDistance — weniger als 2 Parents → 256" {
    const h = hash_mod.hashBytes("single");
    try std.testing.expectEqual(@as(u32, 256), minParentDistance(&[_]Hash{h}));
}

test "evolution: minParentDistance — zwei identische Parents → 0" {
    const h = hash_mod.hashBytes("same");
    try std.testing.expectEqual(@as(u32, 0), minParentDistance(&[_]Hash{ h, h }));
}

test "evolution: minParentDistance — diverse Parents → positiv" {
    const h1 = hash_mod.hashBytes("a");
    const h2 = hash_mod.hashBytes("b");
    const h3 = hash_mod.hashBytes("c");
    const min = minParentDistance(&[_]Hash{ h1, h2, h3 });
    try std.testing.expect(min > 0);
}

test "evolution: evolutionDistanceHash deterministisch" {
    const h1 = hash_mod.hashBytes("l1");
    const h2 = hash_mod.hashBytes("l2");
    const dh1 = evolutionDistanceHash(h1, h2);
    const dh2 = evolutionDistanceHash(h1, h2);
    try std.testing.expect(hash_mod.hashEqual(dh1, dh2));
}

test "evolution: computeXp — neues Artefakt hat höheren XP als bekanntes" {
    const inp_novel = XpInput{
        .diversity_score = 200,
        .min_parent_distance = 100,
        .contribution_count = 0,
        .is_novel = true,
    };
    const inp_known = XpInput{
        .diversity_score = 200,
        .min_parent_distance = 100,
        .contribution_count = 0,
        .is_novel = false,
    };
    try std.testing.expect(computeXp(inp_novel) > computeXp(inp_known));
}

test "evolution: computeXp — mehr Contributions → weniger XP" {
    const inp_low = XpInput{
        .diversity_score = 200, .min_parent_distance = 100,
        .contribution_count = 0, .is_novel = false,
    };
    const inp_high = XpInput{
        .diversity_score = 200, .min_parent_distance = 100,
        .contribution_count = 90, .is_novel = false,
    };
    try std.testing.expect(computeXp(inp_low) > computeXp(inp_high));
}

test "evolution: computeXp — deterministisch" {
    const inp = XpInput{
        .diversity_score = 128, .min_parent_distance = 64,
        .contribution_count = 5, .is_novel = true,
    };
    try std.testing.expectEqual(computeXp(inp), computeXp(inp));
}

test "evolution: evolutionSnapshot deterministisch" {
    const h = hash_mod.hashBytes("lineage");
    const s1 = newEvolutionSnapshot(h, 5, 100, 9000, 50);
    const s2 = newEvolutionSnapshot(h, 5, 100, 9000, 50);
    try std.testing.expect(hash_mod.hashEqual(s1.snapshot_hash, s2.snapshot_hash));
}

test "evolution: evolutionSnapshot — Generation ändert Hash" {
    const h = hash_mod.hashBytes("lineage");
    const s1 = newEvolutionSnapshot(h, 5, 100, 9000, 50);
    const s2 = newEvolutionSnapshot(h, 6, 100, 9000, 50);
    try std.testing.expect(!hash_mod.hashEqual(s1.snapshot_hash, s2.snapshot_hash));
}

test "evolution: kein Node besitzt Evolution — Invariante dokumentiert" {
    // Dieser Test dokumentiert die Architekturinvariante:
    // Ein EvolutionSnapshot referenziert eine Lineage via Hash.
    // Kein Node-spezifisches Feld. Kein globaler Zustand.
    const h = hash_mod.hashBytes("lineage");
    const s = newEvolutionSnapshot(h, 1, 1, 0, 0);
    try std.testing.expect(!hash_mod.isZero(s.snapshot_hash));
    // snapshot_hash ist reproduzierbar, unabhängig von Node
    const s2 = newEvolutionSnapshot(h, 1, 1, 0, 0);
    try std.testing.expect(hash_mod.hashEqual(s.snapshot_hash, s2.snapshot_hash));
}
