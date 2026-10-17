/// BKG Model Layer — Hash Primitives
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/MODEL_LAYER_v1.md
///
/// Kanonischer 32-Byte SHA-256 Hash-Typ für alle Model-Layer-Objekte.
/// Deterministisch, pointer-frei, kein HashMap-Reihenfolge-Problem.
///
/// Verwendung:
///   - ArtifactId    (Content-Hash des Artefakts)
///   - LineageHash   (kanonischer Parent-Chain-Hash)
///   - SnapshotRoot  (Merkle-artiger Root über Snapshot-Einträge)
///   - ProvenanceHash
///   - EvidenceHash
const std = @import("std");

// ── Typen ──────────────────────────────────────────────────────────────────

/// 32-Byte SHA-256 Hash — die universelle Identität im Model Layer.
pub const Hash = [32]u8;

/// Zero-Hash: semantisch "kein Hash" / Wurzel-Lineage.
pub const ZERO_HASH: Hash = [_]u8{0x00} ** 32;

/// Maximale Anzahl von Elternhashes in einer Lineage (verhindert Zyklen/Bomben).
pub const MAX_PARENTS: usize = 8;

/// Maximale Anzahl von Artefakten in einem Snapshot.
pub const MAX_SNAPSHOT_ARTIFACTS: usize = 64;

/// Maximale Anzahl von Testvektoren pro Artefakt.
pub const MAX_TEST_VECTORS: usize = 16;

/// Maximale Anzahl von Capabilities pro Artefakt.
pub const MAX_CAPABILITIES: usize = 32;

/// Maximale Byte-Länge eines Artefakt-Parameters-Blobs.
pub const MAX_PARAM_BYTES: usize = 256;

/// Maximale Länge eines kanonischen Artefakt-Namens.
pub const MAX_NAME_LEN: usize = 64;

/// Maximale Länge einer Algorithmusbeschreibung.
pub const MAX_ALGO_DESC_LEN: usize = 128;

// ── Hash-Helferfunktionen ──────────────────────────────────────────────────

/// Berechnet SHA-256 über einen einzelnen Byte-Slice.
pub fn hashBytes(data: []const u8) Hash {
    var out: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

/// Kombiniert zwei Hashes kanonisch: SHA-256(left || right).
/// Deterministisch — kein HashMap, keine Pointer.
pub fn combineHashes(left: Hash, right: Hash) Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&left);
    hasher.update(&right);
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

/// Berechnet einen Merkle-artigen Root-Hash über eine geordnete Liste von Hashes.
/// Leere Liste → ZERO_HASH.
/// Einzelner Hash → der Hash selbst.
/// Bei ungerader Anzahl wird der letzte Hash dupliziert (Standard-Merkle).
pub fn merkleRoot(hashes: []const Hash) Hash {
    if (hashes.len == 0) return ZERO_HASH;
    if (hashes.len == 1) return hashes[0];

    // Iterativer Merkle-Algorithmus ohne Allokation (maximale Tiefe: MAX_SNAPSHOT_ARTIFACTS)
    var layer: [MAX_SNAPSHOT_ARTIFACTS]Hash = undefined;
    var count = hashes.len;
    if (count > MAX_SNAPSHOT_ARTIFACTS) count = MAX_SNAPSHOT_ARTIFACTS;

    for (0..count) |i| layer[i] = hashes[i];

    while (count > 1) {
        const pairs = count / 2;
        const rem = count % 2;
        for (0..pairs) |i| {
            layer[i] = combineHashes(layer[i * 2], layer[i * 2 + 1]);
        }
        if (rem != 0) {
            // Letzten duplizieren
            layer[pairs] = combineHashes(layer[count - 1], layer[count - 1]);
            count = pairs + 1;
        } else {
            count = pairs;
        }
    }
    return layer[0];
}

/// Prüft ob zwei Hashes byte-identisch sind (constant-time-ähnlich über @memcmp).
pub fn hashEqual(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Gibt true zurück wenn der Hash der ZERO_HASH ist.
pub fn isZero(h: Hash) bool {
    return hashEqual(h, ZERO_HASH);
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "hash: hashBytes ist deterministisch" {
    const a = hashBytes("hello world");
    const b = hashBytes("hello world");
    try std.testing.expect(hashEqual(a, b));
}

test "hash: hashBytes unterschiedliche Inputs → unterschiedliche Hashes" {
    const a = hashBytes("hello");
    const b = hashBytes("world");
    try std.testing.expect(!hashEqual(a, b));
}

test "hash: combineHashes ist deterministisch" {
    const h1 = hashBytes("left");
    const h2 = hashBytes("right");
    const c1 = combineHashes(h1, h2);
    const c2 = combineHashes(h1, h2);
    try std.testing.expect(hashEqual(c1, c2));
}

test "hash: combineHashes ist nicht kommutativ" {
    const h1 = hashBytes("left");
    const h2 = hashBytes("right");
    const lr = combineHashes(h1, h2);
    const rl = combineHashes(h2, h1);
    try std.testing.expect(!hashEqual(lr, rl));
}

test "hash: merkleRoot — leer → ZERO_HASH" {
    const root = merkleRoot(&[_]Hash{});
    try std.testing.expect(hashEqual(root, ZERO_HASH));
}

test "hash: merkleRoot — einzelner Eintrag → Eintrag selbst" {
    const h = hashBytes("single");
    const root = merkleRoot(&[_]Hash{h});
    try std.testing.expect(hashEqual(root, h));
}

test "hash: merkleRoot — zwei Einträge → deterministisch" {
    const h1 = hashBytes("a");
    const h2 = hashBytes("b");
    const r1 = merkleRoot(&[_]Hash{ h1, h2 });
    const r2 = merkleRoot(&[_]Hash{ h1, h2 });
    try std.testing.expect(hashEqual(r1, r2));
}

test "hash: merkleRoot — Reihenfolge relevant" {
    const h1 = hashBytes("a");
    const h2 = hashBytes("b");
    const r_ab = merkleRoot(&[_]Hash{ h1, h2 });
    const r_ba = merkleRoot(&[_]Hash{ h2, h1 });
    try std.testing.expect(!hashEqual(r_ab, r_ba));
}

test "hash: merkleRoot — vier Einträge deterministisch" {
    const hashes = [_]Hash{
        hashBytes("a"),
        hashBytes("b"),
        hashBytes("c"),
        hashBytes("d"),
    };
    const r1 = merkleRoot(&hashes);
    const r2 = merkleRoot(&hashes);
    try std.testing.expect(hashEqual(r1, r2));
}

test "hash: isZero — ZERO_HASH erkannt" {
    try std.testing.expect(isZero(ZERO_HASH));
}

test "hash: isZero — non-zero nicht erkannt" {
    const h = hashBytes("x");
    try std.testing.expect(!isZero(h));
}

test "hash: merkleRoot — Tampering an einem Eintrag → anderer Root" {
    const h1 = hashBytes("a");
    const h2 = hashBytes("b");
    const h2_bad = hashBytes("B"); // anderes Byte
    const r_good = merkleRoot(&[_]Hash{ h1, h2 });
    const r_bad  = merkleRoot(&[_]Hash{ h1, h2_bad });
    try std.testing.expect(!hashEqual(r_good, r_bad));
}
