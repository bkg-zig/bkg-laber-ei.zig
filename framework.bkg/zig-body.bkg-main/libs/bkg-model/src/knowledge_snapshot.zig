/// BKG Model Layer — Knowledge Snapshot
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/MODEL_LAYER_v1.md
///
/// Ein KnowledgeSnapshot ist ein verifizierbares, read-only gebündeltes
/// Wissensobjekt für Watcher und Guardian.
///
/// Watcher laden kein Wissen bei jeder Beobachtung neu aus BKGDB.
/// Stattdessen arbeiten sie mit einem verifizierten Snapshot, der:
///   - Artefakt-Hashes referenziert (keine Artefakte einbettet)
///   - Policies, Invarianten und Testvektoren-Referenzen trägt
///   - einen eigenen kanonischen Root-Hash besitzt
///   - selbst ein verifizierbares Objekt ist
///
/// Lokale Materialisierung darf nur nach erfolgreicher Snapshot-Validierung erfolgen.
///
/// Snapshot-Root-Hash:
///   Merkle-Root über:
///   [ artifact_hashes[0..count], policy_hash, invariant_hash,
///     epoch_LE8, version_LE8, provenance_hash, evidence_hash ]
const std = @import("std");
const hash_mod    = @import("hash.zig");
const artifact_mod = @import("artifact.zig");

pub const Hash = hash_mod.Hash;
pub const ZERO_HASH = hash_mod.ZERO_HASH;

/// Maximale Anzahl von Policies in einem Snapshot.
pub const MAX_SNAPSHOT_POLICIES: usize = 8;
/// Maximale Anzahl von Invarianten in einem Snapshot.
pub const MAX_SNAPSHOT_INVARIANTS: usize = 16;

// ── Policy-Referenz ────────────────────────────────────────────────────────

/// Referenz auf eine Policy (gespeichert in BKGDB, hier nur Hash).
pub const PolicyRef = struct {
    policy_hash: Hash,
    kind:        u8,
    epoch:       u64,
};

// ── Invarianten-Referenz ───────────────────────────────────────────────────

/// Referenz auf eine verifizierte Invariante.
pub const InvariantRef = struct {
    invariant_hash: Hash,
    kind:           u8,
};

// ── Snapshot-Struktur ──────────────────────────────────────────────────────

/// Ein vollständiger, verifizierbarer Knowledge Snapshot.
pub const KnowledgeSnapshot = struct {
    /// Kanonischer Root-Hash dieses Snapshots.
    root_hash:          Hash,
    /// Snapshot-Version (monoton steigend).
    version:            u64,
    /// Epoch dieses Snapshots.
    epoch:              u64,
    /// Anzahl referenzierter Artefakt-Hashes.
    artifact_count:     u8,
    /// Geordnete Artefakt-Hashes (keine eingebetteten Artefakte).
    artifact_hashes:    [hash_mod.MAX_SNAPSHOT_ARTIFACTS]Hash,
    /// Anzahl Policy-Referenzen.
    policy_count:       u8,
    policies:           [MAX_SNAPSHOT_POLICIES]PolicyRef,
    /// Anzahl Invarianten-Referenzen.
    invariant_count:    u8,
    invariants:         [MAX_SNAPSHOT_INVARIANTS]InvariantRef,
    /// Provenance-Hash (aus Forge-Daten abgeleitet).
    provenance_hash:    Hash,
    /// Authority-Evidence-Hash (referenziert Guardian-Verdict).
    evidence_hash:      Hash,
};

// ── Root-Hash-Berechnung ───────────────────────────────────────────────────

/// PROTOKOLLREGEL M3 — HASH-DOMAIN-SEPARATION:
///   Der Snapshot-Root-Hash beginnt mit dem Domain-Präfix "BKGS" (4 Bytes).
///   Damit kann ein gültiger Snapshot-Root-Hash niemals als Manifest-Hash
///   (Präfix "BKGM") oder als anderer BKG-Objekttyp interpretiert werden.
///
/// PROTOKOLLREGEL M4 — SNAPSHOT-INDEX ≠ VERTRAUENSQUELLE:
///   `containsArtifact()` prüft nur ob ein Hash im Index enthalten ist.
///   Ein enthaltener Hash bedeutet KEIN Vertrauen — das Artefakt muss separat
///   durch den Validator validiert werden.
///   Die Reihenfolge des Caller-Vertrags:
///     1. verifySnapshot() → Root-Hash stimmt
///     2. containsArtifact() → Hash im Index
///     3. materialize() → vollständige Validierungspipeline
///   Kein Schritt darf übersprungen werden.
pub const SNAPSHOT_DOMAIN_PREFIX: [4]u8 = .{ 'B', 'K', 'G', 'S' };

/// Berechnet den kanonischen Root-Hash eines Snapshots.
///
///   SHA-256("BKGS" || artifact_hashes[0..count] || policy_hashes ||
///           invariant_hashes || epoch_LE8 || version_LE8 ||
///           provenance_hash || evidence_hash)
///
/// "BKGS"-Domain-Präfix (M3) trennt diesen Hash von allen anderen BKG-Hashes.
/// Reihenfolge ist Teil des Protokolls — Änderung = neuer Hash.
pub fn computeSnapshotRootHash(
    artifact_hashes: []const Hash,
    policies:        []const PolicyRef,
    invariants:      []const InvariantRef,
    epoch:           u64,
    version:         u64,
    provenance_hash: Hash,
    evidence_hash:   Hash,
) Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Domain-Separation (M3)
    hasher.update(&SNAPSHOT_DOMAIN_PREFIX);
    // Artefakt-Hashes (geordnet)
    const n = @min(artifact_hashes.len, hash_mod.MAX_SNAPSHOT_ARTIFACTS);
    for (0..n) |i| hasher.update(&artifact_hashes[i]);
    // Policy-Hashes (geordnet)
    for (policies) |p| hasher.update(&p.policy_hash);
    // Invarianten-Hashes (geordnet)
    for (invariants) |inv| hasher.update(&inv.invariant_hash);
    // Epoch
    var ep_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &ep_buf, epoch, .little);
    hasher.update(&ep_buf);
    // Version
    var ver_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &ver_buf, version, .little);
    hasher.update(&ver_buf);
    // Provenance + Evidence
    hasher.update(&provenance_hash);
    hasher.update(&evidence_hash);
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

/// Baut einen neuen Snapshot und berechnet den Root-Hash.
pub fn buildSnapshot(
    artifact_hashes: []const Hash,
    policies:        []const PolicyRef,
    invariants:      []const InvariantRef,
    epoch:           u64,
    version:         u64,
    provenance_hash: Hash,
    evidence_hash:   Hash,
) KnowledgeSnapshot {
    var s = KnowledgeSnapshot{
        .root_hash       = ZERO_HASH,
        .version         = version,
        .epoch           = epoch,
        .artifact_count  = 0,
        .artifact_hashes = [_]Hash{ZERO_HASH} ** hash_mod.MAX_SNAPSHOT_ARTIFACTS,
        .policy_count    = 0,
        .policies        = [_]PolicyRef{.{ .policy_hash = ZERO_HASH, .kind = 0, .epoch = 0 }} ** MAX_SNAPSHOT_POLICIES,
        .invariant_count = 0,
        .invariants      = [_]InvariantRef{.{ .invariant_hash = ZERO_HASH, .kind = 0 }} ** MAX_SNAPSHOT_INVARIANTS,
        .provenance_hash = provenance_hash,
        .evidence_hash   = evidence_hash,
    };
    // Artefakte
    const ac = @min(artifact_hashes.len, hash_mod.MAX_SNAPSHOT_ARTIFACTS);
    for (0..ac) |i| s.artifact_hashes[i] = artifact_hashes[i];
    s.artifact_count = @intCast(ac);
    // Policies
    const pc = @min(policies.len, MAX_SNAPSHOT_POLICIES);
    for (0..pc) |i| s.policies[i] = policies[i];
    s.policy_count = @intCast(pc);
    // Invarianten
    const ic = @min(invariants.len, MAX_SNAPSHOT_INVARIANTS);
    for (0..ic) |i| s.invariants[i] = invariants[i];
    s.invariant_count = @intCast(ic);
    // Root-Hash berechnen
    s.root_hash = computeSnapshotRootHash(
        artifact_hashes, policies, invariants, epoch, version, provenance_hash, evidence_hash,
    );
    return s;
}

/// Verifiziert den root_hash eines bestehenden Snapshots.
/// Gibt true zurück wenn der gespeicherte root_hash korrekt ist.
pub fn verifySnapshot(s: *const KnowledgeSnapshot) bool {
    const expected = computeSnapshotRootHash(
        s.artifact_hashes[0..s.artifact_count],
        s.policies[0..s.policy_count],
        s.invariants[0..s.invariant_count],
        s.epoch,
        s.version,
        s.provenance_hash,
        s.evidence_hash,
    );
    return hash_mod.hashEqual(expected, s.root_hash);
}

// ── Snapshot-Fehler ────────────────────────────────────────────────────────

pub const SnapshotError = error{
    /// Root-Hash stimmt nicht.
    RootHashMismatch,
    /// Zu viele Artefakte.
    TooManyArtifacts,
    /// Artefakt nicht im Snapshot enthalten.
    ArtifactNotInSnapshot,
};

/// Prüft ob ein Artefakt-Hash im Snapshot enthalten ist.
pub fn containsArtifact(s: *const KnowledgeSnapshot, h: Hash) bool {
    for (0..s.artifact_count) |i| {
        if (hash_mod.hashEqual(s.artifact_hashes[i], h)) return true;
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "snapshot: buildSnapshot deterministisch" {
    const hashes = [_]Hash{ hash_mod.hashBytes("a"), hash_mod.hashBytes("b") };
    const s1 = buildSnapshot(&hashes, &[_]PolicyRef{}, &[_]InvariantRef{}, 10, 1, ZERO_HASH, ZERO_HASH);
    const s2 = buildSnapshot(&hashes, &[_]PolicyRef{}, &[_]InvariantRef{}, 10, 1, ZERO_HASH, ZERO_HASH);
    try std.testing.expect(hash_mod.hashEqual(s1.root_hash, s2.root_hash));
}

test "snapshot: verifySnapshot — gültiger Snapshot" {
    const hashes = [_]Hash{ hash_mod.hashBytes("x") };
    const s = buildSnapshot(&hashes, &[_]PolicyRef{}, &[_]InvariantRef{}, 5, 1, ZERO_HASH, ZERO_HASH);
    try std.testing.expect(verifySnapshot(&s));
}

test "snapshot: Tampering an root_hash → verifySnapshot false" {
    const hashes = [_]Hash{ hash_mod.hashBytes("x") };
    var s = buildSnapshot(&hashes, &[_]PolicyRef{}, &[_]InvariantRef{}, 5, 1, ZERO_HASH, ZERO_HASH);
    s.root_hash[0] ^= 0xFF;
    try std.testing.expect(!verifySnapshot(&s));
}

test "snapshot: Tampering an artifact_hash → verifySnapshot false" {
    const hashes = [_]Hash{ hash_mod.hashBytes("x") };
    var s = buildSnapshot(&hashes, &[_]PolicyRef{}, &[_]InvariantRef{}, 5, 1, ZERO_HASH, ZERO_HASH);
    s.artifact_hashes[0][0] ^= 0xFF;
    try std.testing.expect(!verifySnapshot(&s));
}

test "snapshot: Tampering an epoch → verifySnapshot false" {
    const hashes = [_]Hash{ hash_mod.hashBytes("x") };
    var s = buildSnapshot(&hashes, &[_]PolicyRef{}, &[_]InvariantRef{}, 5, 1, ZERO_HASH, ZERO_HASH);
    s.epoch = 99;
    try std.testing.expect(!verifySnapshot(&s));
}

test "snapshot: containsArtifact — vorhanden" {
    const h = hash_mod.hashBytes("present");
    const s = buildSnapshot(&[_]Hash{h}, &[_]PolicyRef{}, &[_]InvariantRef{}, 1, 1, ZERO_HASH, ZERO_HASH);
    try std.testing.expect(containsArtifact(&s, h));
}

test "snapshot: containsArtifact — nicht vorhanden" {
    const h = hash_mod.hashBytes("present");
    const h2 = hash_mod.hashBytes("absent");
    const s = buildSnapshot(&[_]Hash{h}, &[_]PolicyRef{}, &[_]InvariantRef{}, 1, 1, ZERO_HASH, ZERO_HASH);
    try std.testing.expect(!containsArtifact(&s, h2));
}

test "snapshot: leerer Snapshot verifizierbar" {
    const s = buildSnapshot(&[_]Hash{}, &[_]PolicyRef{}, &[_]InvariantRef{}, 0, 0, ZERO_HASH, ZERO_HASH);
    try std.testing.expect(verifySnapshot(&s));
}

test "snapshot: unterschiedliche Versionen → unterschiedliche Root-Hashes" {
    const h = hash_mod.hashBytes("a");
    const s1 = buildSnapshot(&[_]Hash{h}, &[_]PolicyRef{}, &[_]InvariantRef{}, 1, 1, ZERO_HASH, ZERO_HASH);
    const s2 = buildSnapshot(&[_]Hash{h}, &[_]PolicyRef{}, &[_]InvariantRef{}, 1, 2, ZERO_HASH, ZERO_HASH);
    try std.testing.expect(!hash_mod.hashEqual(s1.root_hash, s2.root_hash));
}

test "snapshot: provenance_hash Änderung → anderer Root-Hash" {
    const h = hash_mod.hashBytes("a");
    const ph1 = ZERO_HASH;
    const ph2 = hash_mod.hashBytes("prov");
    const s1 = buildSnapshot(&[_]Hash{h}, &[_]PolicyRef{}, &[_]InvariantRef{}, 1, 1, ph1, ZERO_HASH);
    const s2 = buildSnapshot(&[_]Hash{h}, &[_]PolicyRef{}, &[_]InvariantRef{}, 1, 1, ph2, ZERO_HASH);
    try std.testing.expect(!hash_mod.hashEqual(s1.root_hash, s2.root_hash));
}

test "snapshot: mit Policy-Referenz deterministisch" {
    const h = hash_mod.hashBytes("a");
    const p = PolicyRef{ .policy_hash = hash_mod.hashBytes("policy"), .kind = 1, .epoch = 5 };
    const s1 = buildSnapshot(&[_]Hash{h}, &[_]PolicyRef{p}, &[_]InvariantRef{}, 1, 1, ZERO_HASH, ZERO_HASH);
    const s2 = buildSnapshot(&[_]Hash{h}, &[_]PolicyRef{p}, &[_]InvariantRef{}, 1, 1, ZERO_HASH, ZERO_HASH);
    try std.testing.expect(hash_mod.hashEqual(s1.root_hash, s2.root_hash));
}

test "snapshot: M3 — BKGS Domain-Prefix verändert Hash aktiv" {
    const h = hash_mod.hashBytes("domain-test");
    const rooted = computeSnapshotRootHash(&[_]Hash{h}, &[_]PolicyRef{}, &[_]InvariantRef{}, 1, 1, ZERO_HASH, ZERO_HASH);

    var legacy = std.crypto.hash.sha2.Sha256.init(.{});
    legacy.update(&h);
    var ep: [8]u8 = undefined;
    std.mem.writeInt(u64, &ep, 1, .little);
    legacy.update(&ep);
    var ver: [8]u8 = undefined;
    std.mem.writeInt(u64, &ver, 1, .little);
    legacy.update(&ver);
    legacy.update(&ZERO_HASH);
    legacy.update(&ZERO_HASH);
    var legacy_hash: Hash = undefined;
    legacy.final(&legacy_hash);

    try std.testing.expect(!hash_mod.hashEqual(rooted, legacy_hash));
}

test "snapshot: M4 — containsArtifact ist keine Vertrauensentscheidung" {
    const h = hash_mod.hashBytes("artifact");
    var s = buildSnapshot(&[_]Hash{h}, &[_]PolicyRef{}, &[_]InvariantRef{}, 1, 1, ZERO_HASH, ZERO_HASH);
    try std.testing.expect(containsArtifact(&s, h));
    s.artifact_hashes[0][0] ^= 0xFF;
    try std.testing.expect(!verifySnapshot(&s));
    try std.testing.expect(!containsArtifact(&s, h));
}
