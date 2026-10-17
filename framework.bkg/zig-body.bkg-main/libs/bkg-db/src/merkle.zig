/// BKGDB — Merkle-Chain
///
/// SHA256-basierte Hash-Chain für den Immutable Ledger.
///
/// Entry N:  hash = SHA256(entry_data || prev_hash)
/// Entry 0:  prev_hash = [0]**32 (Genesis)
///
/// Der aktuelle merkle_root ist der Hash des letzten Ledger-Eintrags.
/// Verifikation: Hash-Kette vom gewünschten Eintrag bis zum bekannten Root nachrechnen.
const std = @import("std");

// ── Typen ─────────────────────────────────────────────────────────────────

/// 32-Byte SHA256-Hash
pub const Hash = [32]u8;

/// Der Genesis-Hash — alle Nullen
pub const GENESIS_HASH: Hash = [_]u8{0} ** 32;

// ── Hash-Funktionen ───────────────────────────────────────────────────────

/// Berechnet SHA256(data).
pub fn sha256(data: []const u8) Hash {
    var h: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    return h;
}

/// Berechnet den Ledger-Entry-Hash: SHA256(entry_data || prev_hash).
/// Das ist der kryptografische Kern der Merkle-Chain.
pub fn entryHash(entry_data: []const u8, prev_hash: *const Hash) Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(entry_data);
    hasher.update(prev_hash);
    var h: Hash = undefined;
    hasher.final(&h);
    return h;
}

/// Berechnet SHA256(a || b) — für Merkle-Tree-Knoten.
pub fn combineHashes(a: *const Hash, b: *const Hash) Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(a);
    hasher.update(b);
    var h: Hash = undefined;
    hasher.final(&h);
    return h;
}

/// Formatiert einen Hash als Hex-String in den gegebenen Buffer.
/// Buffer muss mindestens 64 Bytes groß sein.
pub fn hashToHex(hash: *const Hash, buf: *[64]u8) void {
    const hex = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        buf[i * 2] = hex[byte >> 4];
        buf[i * 2 + 1] = hex[byte & 0x0f];
    }
}

/// Prüft ob zwei Hashes identisch sind.
pub fn hashEql(a: *const Hash, b: *const Hash) bool {
    return std.mem.eql(u8, a, b);
}

/// Prüft ob ein Hash der Genesis-Hash ist.
pub fn isGenesis(h: *const Hash) bool {
    return hashEql(h, &GENESIS_HASH);
}

// ── MerkleChain ───────────────────────────────────────────────────────────

/// In-Memory Merkle-Chain-Zustand.
/// Wird vom Ledger gehalten und bei jedem Append aktualisiert.
pub const MerkleChain = struct {
    root: Hash,
    entry_count: u64,

    /// Initialisiert eine leere Chain mit Genesis-Hash.
    pub fn init() MerkleChain {
        return .{
            .root = GENESIS_HASH,
            .entry_count = 0,
        };
    }

    /// Fügt einen neuen Eintrag hinzu und gibt den neuen Hash zurück.
    /// Aktualisiert root und entry_count.
    pub fn append(self: *MerkleChain, entry_data: []const u8) Hash {
        const new_hash = entryHash(entry_data, &self.root);
        self.root = new_hash;
        self.entry_count += 1;
        return new_hash;
    }

    /// Gibt den aktuellen Merkle-Root zurück.
    pub fn merkleRoot(self: *const MerkleChain) *const Hash {
        return &self.root;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "sha256 is deterministic" {
    const h1 = sha256("hello");
    const h2 = sha256("hello");
    try std.testing.expect(hashEql(&h1, &h2));
}

test "sha256 different inputs produce different hashes" {
    const h1 = sha256("hello");
    const h2 = sha256("world");
    try std.testing.expect(!hashEql(&h1, &h2));
}

test "entryHash genesis" {
    const data = "first entry";
    const h = entryHash(data, &GENESIS_HASH);
    // Hash muss nicht-null sein und deterministisch
    try std.testing.expect(!isGenesis(&h));
    const h2 = entryHash(data, &GENESIS_HASH);
    try std.testing.expect(hashEql(&h, &h2));
}

test "entryHash chain: different prev_hash → different result" {
    const data = "entry";
    const h1 = entryHash(data, &GENESIS_HASH);
    const h2 = entryHash(data, &h1);
    try std.testing.expect(!hashEql(&h1, &h2));
}

test "MerkleChain starts with genesis" {
    const chain = MerkleChain.init();
    try std.testing.expect(isGenesis(chain.merkleRoot()));
    try std.testing.expectEqual(@as(u64, 0), chain.entry_count);
}

test "MerkleChain append updates root" {
    var chain = MerkleChain.init();
    const h1 = chain.append("entry one");
    try std.testing.expect(!isGenesis(&h1));
    try std.testing.expect(hashEql(&h1, chain.merkleRoot()));
    try std.testing.expectEqual(@as(u64, 1), chain.entry_count);

    const h2 = chain.append("entry two");
    try std.testing.expect(!hashEql(&h1, &h2));
    try std.testing.expect(hashEql(&h2, chain.merkleRoot()));
    try std.testing.expectEqual(@as(u64, 2), chain.entry_count);
}

test "MerkleChain is deterministic" {
    var c1 = MerkleChain.init();
    _ = c1.append("a");
    _ = c1.append("b");
    _ = c1.append("c");

    var c2 = MerkleChain.init();
    _ = c2.append("a");
    _ = c2.append("b");
    _ = c2.append("c");

    try std.testing.expect(hashEql(c1.merkleRoot(), c2.merkleRoot()));
}

test "MerkleChain order matters" {
    var c1 = MerkleChain.init();
    _ = c1.append("a");
    _ = c1.append("b");

    var c2 = MerkleChain.init();
    _ = c2.append("b");
    _ = c2.append("a");

    try std.testing.expect(!hashEql(c1.merkleRoot(), c2.merkleRoot()));
}

test "hashToHex" {
    const h = sha256("test");
    var buf: [64]u8 = undefined;
    hashToHex(&h, &buf);
    // Muss 64 Hex-Zeichen sein, alle lowercase hex
    for (buf) |c| {
        try std.testing.expect(std.ascii.isHex(c));
    }
}

test "combineHashes is deterministic" {
    const a = sha256("left");
    const b = sha256("right");
    const c1 = combineHashes(&a, &b);
    const c2 = combineHashes(&a, &b);
    try std.testing.expect(hashEql(&c1, &c2));
}

test "combineHashes is not commutative" {
    const a = sha256("left");
    const b = sha256("right");
    const ab = combineHashes(&a, &b);
    const ba = combineHashes(&b, &a);
    try std.testing.expect(!hashEql(&ab, &ba));
}
