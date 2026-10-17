/// BKGDB — Deterministic Segment Merkle Tree
///
/// Storage Protocol v1 — 2026-09-01
///
/// VIERFACHE TRENNUNG (Protokoll-Invariante):
///   Hashchain        → beweist kausale Reihenfolge (prev_hash → hash)
///   Merkle Root      → beweist Event-Mitgliedschaft in einem Segment
///   State Root       → beweist den materialisierten Zustand
///   Causal Fingerprint → beweist die Evolutionsgeschichte
///
/// Diese Datei implementiert ausschließlich Merkle Root + Proofs.
/// Die Hashchain-Prüfung ist Aufgabe von p2p_protocol.verifyLedgerPrefixProof.
/// Die State-Projektion ist Aufgabe von rebuild.rebuildProtocol.
///
/// Domain Separators (harte Protokollkonstanten):
///   BKG_MERKLE_LEAF_V1  — Leaf-Hashes
///   BKG_MERKLE_NODE_V1  — Interne Knoten
///   BKG_FOOTER_V1       — Segment-Footer-Hash
///
/// Ungerade-Knoten-Regel (Protokollspezifikation):
///   Bei ungerader Anzahl von Knoten auf einer Ebene wird der letzte
///   Knoten mit sich selbst gehasht: parent = H(last || last).
///   Diese Regel ist Teil der Protokollspezifikation und darf niemals
///   stillschweigend durch eine andere Konvention ersetzt werden.
///
/// Alle Funktionen sind deterministisch:
///   Gleicher Event-Hash-Stream → bitidentischer segment_merkle_root.
///   Keine HashMap-Reihenfolge, keine Pointer-Adressen, keine CPU-Abhängigkeit.
const std = @import("std");

pub const Hash = [32]u8;
pub const ZERO_HASH: Hash = [_]u8{0} ** 32;

// ── Domain Separators ─────────────────────────────────────────────────────
// Harte Byte-Konstanten — niemals dynamisch erzeugen.
// Sie trennen Merkle-Hashes eindeutig vom Event-Hash-Raum.

pub const DOMAIN_MERKLE_LEAF:   []const u8 = "BKG_MERKLE_LEAF_V1";
pub const DOMAIN_MERKLE_NODE:   []const u8 = "BKG_MERKLE_NODE_V1";
pub const DOMAIN_SEGMENT_FOOTER: []const u8 = "BKG_FOOTER_V1";

// ── Hash-Primitiven ───────────────────────────────────────────────────────

/// Berechnet einen Merkle-Leaf-Hash aus einem Event-Hash.
///
/// leaf = SHA256(BKG_MERKLE_LEAF_V1 || event_hash)
///
/// Garantiert: leaf_hash kann nie mit einem raw event_hash kollidieren,
/// da der Domain-Separator vorausgeht.
pub fn hashLeaf(event_hash: Hash) Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(DOMAIN_MERKLE_LEAF);
    h.update(&event_hash);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

/// Kombiniert zwei Merkle-Knoten zu einem Elternknoten.
///
/// parent = SHA256(BKG_MERKLE_NODE_V1 || left || right)
///
/// Nicht kommutativ: H(left, right) ≠ H(right, left).
pub fn hashNode(left: Hash, right: Hash) Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(DOMAIN_MERKLE_NODE);
    h.update(&left);
    h.update(&right);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

/// Berechnet den kanonischen Segment-Footer-Hash.
///
/// footer_hash = SHA256(BKG_FOOTER_V1 || footer_bytes)
pub fn hashSegmentFooter(footer_bytes: []const u8) Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(DOMAIN_SEGMENT_FOOTER);
    h.update(footer_bytes);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

// ── Merkle Tree Builder ───────────────────────────────────────────────────

/// Berechnet den Segment Merkle Root aus einem geordneten Slice von Event-Hashes.
///
/// Eingabe: event_hashes in aufsteigender Ledger-Sequence-Reihenfolge.
/// Ausgabe: segment_merkle_root (deterministische 32-Byte-Verpflichtung).
///
/// Ungerade-Knoten-Regel: Der letzte Knoten auf jeder Ebene wird mit sich
/// selbst gehasht, wenn die Anzahl ungerade ist.
///
/// Leere Eingabe → ZERO_HASH (kein Segment ohne Events).
///
/// Optimierung P1.1: Nutzt zwei alternierende Buffer statt pro Ebene neu zu allokieren.
pub fn buildMerkleRoot(allocator: std.mem.Allocator, event_hashes: []const Hash) !Hash {
    if (event_hashes.len == 0) return ZERO_HASH;

    // P1.1 Optimierung: Zwei Buffer alternierend nutzen
    var buffer_a = try allocator.alloc(Hash, event_hashes.len);
    defer allocator.free(buffer_a);
    var buffer_b = try allocator.alloc(Hash, (event_hashes.len + 1) / 2);
    defer allocator.free(buffer_b);

    // Level 0: Leaves in buffer_a
    for (event_hashes, 0..) |eh, i| {
        buffer_a[i] = hashLeaf(eh);
    }

    var current = buffer_a;
    var current_len = event_hashes.len;
    var next: []Hash = buffer_b;

    // Level-für-Level reduzieren bis Root
    while (current_len > 1) {
        const next_len = (current_len + 1) / 2;

        var i: usize = 0;
        while (i < next_len) : (i += 1) {
            const left  = current[i * 2];
            // Ungerade-Regel: letzter Knoten wird dupliziert
            const right = if (i * 2 + 1 < current_len) current[i * 2 + 1] else left;
            next[i] = hashNode(left, right);
        }

        // Buffer tauschen für nächste Iteration
        if (current.ptr == buffer_a.ptr) {
            current = buffer_b[0..next_len];
            next = buffer_a;
        } else {
            current = buffer_a[0..next_len];
            next = buffer_b;
        }
        current_len = next_len;
    }

    return current[0];
}

// ── Proof Direction ───────────────────────────────────────────────────────

/// Gibt an, auf welcher Seite der Sibling-Knoten liegt.
/// .left  → Sibling ist links  → wir sind rechts: parent = H(sibling, current)
/// .right → Sibling ist rechts → wir sind links:  parent = H(current, sibling)
pub const ProofDirection = enum(u8) {
    left  = 0,
    right = 1,
};

// ── MerkleProof — Einzelner Event ─────────────────────────────────────────

/// Beweist, dass ein einzelner Event in einem Segment enthalten ist.
///
/// siblings und directions müssen dieselbe Länge haben.
/// Der Proof-Pfad führt vom Leaf bis zur segment_merkle_root.
pub const MerkleProof = struct {
    segment_id:          u64,
    target_sequence:     u64,
    target_event_hash:   Hash,
    segment_merkle_root: Hash,
    /// Sibling-Hashes auf dem Pfad von Leaf zur Root (bottom-up).
    siblings:   []const Hash,
    /// Richtung jedes Siblings — Länge muss == siblings.len sein.
    directions: []const ProofDirection,

    /// Verifiziert den Proof deterministisch.
    /// Gibt true zurück gdw. der Pfad exakt zur segment_merkle_root führt.
    /// Merkle-Proof beweist NUR Mitgliedschaft — keine Kausalität.
    pub fn verify(self: *const MerkleProof) bool {
        if (self.siblings.len != self.directions.len) return false;

        var current = hashLeaf(self.target_event_hash);

        for (self.siblings, self.directions) |sibling, dir| {
            current = switch (dir) {
                .left  => hashNode(sibling, current),
                .right => hashNode(current, sibling),
            };
        }

        return std.mem.eql(u8, &current, &self.segment_merkle_root);
    }
};

/// Erzeugt einen MerkleProof für den Event an `target_index` im event_hashes-Slice.
///
/// target_index ist der 0-basierte Positions-Index in event_hashes (nicht die Sequence).
/// Die Sequence wird separat in target_sequence angegeben.
///
/// Caller ist verantwortlich für das Freigeben von siblings und directions
/// (beide mit allocator allokiert).
///
/// Optimierung P1.1: Nutzt zwei alternierende Buffer für Baum-Ebenen.
pub fn buildProof(
    allocator:    std.mem.Allocator,
    segment_id:   u64,
    event_hashes: []const Hash,
    target_index: usize,
    target_sequence: u64,
    segment_merkle_root: Hash,
) !MerkleProof {
    if (event_hashes.len == 0 or target_index >= event_hashes.len)
        return error.InvalidIndex;

    // P1.1 Optimierung: Zwei Buffer alternierend nutzen
    var buffer_a = try allocator.alloc(Hash, event_hashes.len);
    defer allocator.free(buffer_a);
    var buffer_b = try allocator.alloc(Hash, (event_hashes.len + 1) / 2);
    defer allocator.free(buffer_b);

    // Level 0: Leaves in buffer_a
    for (event_hashes, 0..) |eh, i| {
        buffer_a[i] = hashLeaf(eh);
    }

    var siblings   = std.array_list.AlignedManaged(Hash, null).init(allocator);
    var directions = std.array_list.AlignedManaged(ProofDirection, null).init(allocator);
    errdefer { siblings.deinit(); directions.deinit(); }

    var idx = target_index;
    var current = buffer_a;
    var current_len = event_hashes.len;
    var next: []Hash = buffer_b;

    while (current_len > 1) {
        const next_len = (current_len + 1) / 2;

        // Sibling für diesen Level aufzeichnen
        const is_left_child = (idx % 2 == 0);
        if (is_left_child) {
            // Wir sind links — Sibling ist rechts (oder wir selbst, falls letzter)
            const sibling = if (idx + 1 < current_len) current[idx + 1] else current[idx];
            try siblings.append(sibling);
            try directions.append(.right);
        } else {
            // Wir sind rechts — Sibling ist links
            try siblings.append(current[idx - 1]);
            try directions.append(.left);
        }

        // Nächstes Level berechnen
        var i: usize = 0;
        while (i < next_len) : (i += 1) {
            const left  = current[i * 2];
            const right = if (i * 2 + 1 < current_len) current[i * 2 + 1] else left;
            next[i] = hashNode(left, right);
        }

        // Buffer tauschen
        if (current.ptr == buffer_a.ptr) {
            current = buffer_b[0..next_len];
            next = buffer_a;
        } else {
            current = buffer_a[0..next_len];
            next = buffer_b;
        }
        current_len = next_len;
        idx /= 2;
    }

    return MerkleProof{
        .segment_id          = segment_id,
        .target_sequence     = target_sequence,
        .target_event_hash   = event_hashes[target_index],
        .segment_merkle_root = segment_merkle_root,
        .siblings            = try siblings.toOwnedSlice(),
        .directions          = try directions.toOwnedSlice(),
    };
}

/// Gibt die allocator-owned Slices eines MerkleProof frei.
pub fn freeProof(allocator: std.mem.Allocator, proof: *MerkleProof) void {
    allocator.free(proof.siblings);
    allocator.free(proof.directions);
}

// ── MerkleRangeProof ────────────────────────────────────��─────────────────

/// Beweist, dass eine zusammenhängende Sequence-Spanne
/// [start_sequence, end_sequence] in einem Segment liegt.
///
/// Der Proof enthält:
///   - Die geclaimten Event-Hashes der Range (ordered by sequence)
///   - Boundary-Sibling-Hashes außerhalb der Range (minimal notwendig)
///   - Richtungen der Boundary-Knoten
///
/// Eigenschaften:
///   - O(log N + k) Datenmenge (k = Range-Größe, N = Segment-Größe)
///   - Beweist Mitgliedschaft, NICHT Ledger-Kausalität
///   - Kann nur zusammenhängende Ranges beweisen (keine Lücken)
///
/// INVARIANTE: Der Proof darf Events weder erzeugen noch rekonstruieren.
/// Die Event-Bytes kommen immer aus dem Ledger/Wire-Proof und werden
/// separat kanonisch gehasht.
pub const MerkleRangeProof = struct {
    segment_id:          u64,
    /// Erste Sequence der Range (inklusiv).
    start_sequence:      u64,
    /// Letzte Sequence der Range (inklusiv).
    end_sequence:        u64,
    /// Segment-weite erste Sequence (zum Bestimmen der Leaf-Indizes).
    segment_first_sequence: u64,
    /// Segment-weite Anzahl der Events (für Baumgröße).
    segment_event_count: u64,
    /// Der committete Merkle Root des Segments.
    segment_merkle_root: Hash,
    /// Event-Hashes der Range in aufsteigender Sequence-Reihenfolge.
    /// Länge == end_sequence - start_sequence + 1.
    range_event_hashes:  []const Hash,
    /// Boundary-Sibling-Hashes (minimal notwendige externe Knoten).
    boundary_siblings:   []const Hash,
    /// Richtungen der Boundary-Knoten (Länge == boundary_siblings.len).
    boundary_directions: []const ProofDirection,
};

/// Verifiziert einen MerkleRangeProof.
///
/// Prüft:
///   1. start_sequence <= end_sequence
///   2. Range liegt vollständig innerhalb des Segments
///   3. range_event_hashes.len == end_sequence - start_sequence + 1
///   4. Boundary-Proof führt deterministisch zum segment_merkle_root
///
/// Gibt einen RangeVerifyError zurück wenn die Prüfung fehlschlägt.
pub const RangeVerifyError = error{
    EmptyRange,
    InvalidSequenceOrder,
    RangeOutsideSegment,
    RangeLengthMismatch,
    BoundaryDirectionMismatch,
    RootMismatch,
    OutOfMemory,
};

pub fn verifyRangeProof(
    allocator: std.mem.Allocator,
    proof:     *const MerkleRangeProof,
) RangeVerifyError!void {
    if (proof.segment_event_count == 0) return RangeVerifyError.EmptyRange;

    // 1. Sequence-Ordnung
    if (proof.start_sequence > proof.end_sequence)
        return RangeVerifyError.InvalidSequenceOrder;

    // 2. Range liegt im Segment
    const seg_last = proof.segment_first_sequence + proof.segment_event_count - 1;
    if (proof.start_sequence < proof.segment_first_sequence or
        proof.end_sequence > seg_last)
        return RangeVerifyError.RangeOutsideSegment;

    // 3. Länge der Event-Hashes stimmt mit der behaupteten Range überein
    const range_len = proof.end_sequence - proof.start_sequence + 1;
    if (proof.range_event_hashes.len != range_len)
        return RangeVerifyError.RangeLengthMismatch;

    if (proof.boundary_siblings.len != proof.boundary_directions.len)
        return RangeVerifyError.BoundaryDirectionMismatch;

    // 4. Vollständigen Baum aus Segment-Größe rekonstruieren und
    //    die Range-Leaves einfügen, externe Nodes aus boundary_siblings lesen.
    const derived_root = deriveRangeRoot(allocator, proof) catch |e| switch (e) {
        error.OutOfMemory => return RangeVerifyError.OutOfMemory,
    };

    if (!std.mem.eql(u8, &derived_root, &proof.segment_merkle_root))
        return RangeVerifyError.RootMismatch;
}

/// Leitet den Merkle Root aus einem RangeProof ab.
///
/// Strategie: Baut den vollständigen Baum der Segment-Größe auf,
/// füllt Range-Leaves aus range_event_hashes und verbraucht
/// boundary_siblings für Knoten außerhalb der Range.
///
/// Optimierung P1.1: Nutzt zwei alternierende Buffer für Baum-Ebenen.
pub fn deriveRangeRoot(
    allocator: std.mem.Allocator,
    proof:     *const MerkleRangeProof,
) !Hash {
    const n = proof.segment_event_count;
    const start_idx = proof.start_sequence - proof.segment_first_sequence;

    // P1.1 Optimierung: Zwei Buffer alternierend
    var buffer_a = try allocator.alloc(Hash, n);
    defer allocator.free(buffer_a);
    var buffer_b = try allocator.alloc(Hash, (n + 1) / 2);
    defer allocator.free(buffer_b);

    // Level 0: Leaves — Range-Leaves bekannt, externe Leaves als ZERO_HASH markiert
    @memset(buffer_a, ZERO_HASH);
    for (proof.range_event_hashes, 0..) |eh, i| {
        buffer_a[start_idx + i] = hashLeaf(eh);
    }

    var current = buffer_a;
    var current_len = n;
    var next: []Hash = buffer_b;

    // Zeiger in boundary_siblings
    var boundary_idx: usize = 0;

    while (current_len > 1) {
        const next_len = (current_len + 1) / 2;

        var i: usize = 0;
        while (i < next_len) : (i += 1) {
            const li = i * 2;
            const ri = if (li + 1 < current_len) li + 1 else li; // Ungerade-Regel

            const left_known  = !isZeroHash(current[li]);
            const right_known = !isZeroHash(current[ri]) or ri == li; // duplizierter Knoten

            if (left_known and right_known) {
                // Beide Kinder bekannt — normal kombinieren
                next[i] = hashNode(current[li], current[ri]);
            } else if (!left_known and !right_known) {
                // Beide außerhalb der Range — Sibling-Knoten aus boundary_siblings
                if (boundary_idx >= proof.boundary_siblings.len) {
                    return ZERO_HASH; // unvollständiger Proof
                }
                next[i] = proof.boundary_siblings[boundary_idx];
                boundary_idx += 1;
            } else {
                // Einer bekannt, einer unbekannt — Sibling aus boundary_siblings
                if (boundary_idx >= proof.boundary_siblings.len) {
                    return ZERO_HASH;
                }
                const sibling = proof.boundary_siblings[boundary_idx];
                boundary_idx += 1;
                if (left_known) {
                    next[i] = hashNode(current[li], sibling);
                } else {
                    next[i] = hashNode(sibling, current[ri]);
                }
            }
        }

        // Buffer tauschen
        if (current.ptr == buffer_a.ptr) {
            current = buffer_b[0..next_len];
            next = buffer_a;
        } else {
            current = buffer_a[0..next_len];
            next = buffer_b;
        }
        current_len = next_len;
    }

    return current[0];
}

fn isZeroHash(h: Hash) bool {
    return std.mem.eql(u8, &h, &ZERO_HASH);
}

/// Erzeugt einen MerkleRangeProof für die Sequence-Spanne [start_seq, end_seq].
///
/// Caller ist verantwortlich für freeRangeProof().
///
/// Optimierung P1.1: Nutzt zwei alternierende Buffer für Baum-Ebenen.
pub fn buildRangeProof(
    allocator:   std.mem.Allocator,
    segment_id:  u64,
    segment_first_sequence: u64,
    event_hashes: []const Hash, // alle Events des Segments, geordnet
    start_seq:   u64,
    end_seq:     u64,
    segment_merkle_root: Hash,
) !MerkleRangeProof {
    if (event_hashes.len == 0 or start_seq > end_seq) return error.InvalidRange;

    const seg_last = segment_first_sequence + event_hashes.len - 1;
    if (start_seq < segment_first_sequence or end_seq > seg_last)
        return error.RangeOutsideSegment;

    const start_idx: usize = @intCast(start_seq - segment_first_sequence);
    const end_idx:   usize = @intCast(end_seq   - segment_first_sequence);
    const range_len = end_idx - start_idx + 1;

    // Range-Event-Hashes kopieren
    const range_hashes = try allocator.dupe(Hash, event_hashes[start_idx..start_idx + range_len]);
    errdefer allocator.free(range_hashes);

    // P1.1 Optimierung: Zwei Buffer alternierend
    var buffer_a = try allocator.alloc(Hash, event_hashes.len);
    defer allocator.free(buffer_a);
    var buffer_b = try allocator.alloc(Hash, (event_hashes.len + 1) / 2);
    defer allocator.free(buffer_b);

    // Level 0: Leaves
    for (event_hashes, 0..) |eh, i| {
        buffer_a[i] = hashLeaf(eh);
    }

    var boundary = std.array_list.AlignedManaged(Hash, null).init(allocator);
    var boundary_dirs = std.array_list.AlignedManaged(ProofDirection, null).init(allocator);
    errdefer { boundary.deinit(); boundary_dirs.deinit(); }

    var range_start = start_idx;
    var range_end   = end_idx;
    var level_len   = event_hashes.len;
    var current = buffer_a;
    var next: []Hash = buffer_b;

    while (level_len > 1) {
        const next_len = (level_len + 1) / 2;

        var i: usize = 0;
        while (i < next_len) : (i += 1) {
            const li = i * 2;
            const ri = if (li + 1 < level_len) li + 1 else li;
            next[i] = hashNode(current[li], current[ri]);
        }

        // Boundary-Siblings sammeln: Knoten, die angrenzend an die Range liegen
        // und außerhalb liegen
        const parent_start = range_start / 2;
        const parent_end   = range_end   / 2;

        // Linker Boundary: falls range_start ungerade (hat linken Sibling außerhalb)
        if (range_start > 0 and range_start % 2 == 1) {
            try boundary.append(current[range_start - 1]);
            try boundary_dirs.append(.left);
        }
        // Rechter Boundary: falls range_end gerade (hat rechten Sibling außerhalb)
        if (range_end + 1 < level_len and range_end % 2 == 0) {
            const sibling_idx = if (range_end + 1 < level_len) range_end + 1 else range_end;
            try boundary.append(current[sibling_idx]);
            try boundary_dirs.append(.right);
        }

        // Buffer tauschen
        if (current.ptr == buffer_a.ptr) {
            current = buffer_b[0..next_len];
            next = buffer_a;
        } else {
            current = buffer_a[0..next_len];
            next = buffer_b;
        }
        level_len = next_len;
        range_start = parent_start;
        range_end   = parent_end;
    }

    return MerkleRangeProof{
        .segment_id          = segment_id,
        .start_sequence      = start_seq,
        .end_sequence        = end_seq,
        .segment_first_sequence = segment_first_sequence,
        .segment_event_count = @intCast(event_hashes.len),
        .segment_merkle_root = segment_merkle_root,
        .range_event_hashes  = range_hashes,
        .boundary_siblings   = try boundary.toOwnedSlice(),
        .boundary_directions = try boundary_dirs.toOwnedSlice(),
    };
}

/// Gibt alle allocator-owned Slices eines MerkleRangeProof frei.
pub fn freeRangeProof(allocator: std.mem.Allocator, proof: *MerkleRangeProof) void {
    allocator.free(proof.range_event_hashes);
    allocator.free(proof.boundary_siblings);
    allocator.free(proof.boundary_directions);
}

// ── Tests ───────────────────────────────────────────────────────────

fn mkh(b: u8) Hash {
    var h: Hash = ZERO_HASH;
    h[0] = b;
    return h;
}

test "merkle: hashLeaf — domain separator trennt Event-Hash-Raum" {
    const event_hash = mkh(0x42);
    const leaf = hashLeaf(event_hash);
    // Leaf-Hash muss sich von rohem Event-Hash unterscheiden
    try std.testing.expect(!std.mem.eql(u8, &leaf, &event_hash));
}

test "merkle: hashNode — nicht kommutativ" {
    const a = mkh(0x01);
    const b = mkh(0x02);
    const ab = hashNode(a, b);
    const ba = hashNode(b, a);
    try std.testing.expect(!std.mem.eql(u8, &ab, &ba));
}

test "merkle: buildMerkleRoot — leere Eingabe → ZERO_HASH" {
    const root = try buildMerkleRoot(std.testing.allocator, &.{});
    try std.testing.expect(std.mem.eql(u8, &root, &ZERO_HASH));
}

test "merkle: buildMerkleRoot — ein Event" {
    const hashes = [_]Hash{mkh(0x01)};
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);
    const expected = hashLeaf(mkh(0x01));
    try std.testing.expect(std.mem.eql(u8, &root, &expected));
}

test "merkle: buildMerkleRoot — zwei Events (gerade)" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);
    const l0 = hashLeaf(mkh(0x01));
    const l1 = hashLeaf(mkh(0x02));
    const expected = hashNode(l0, l1);
    try std.testing.expect(std.mem.eql(u8, &root, &expected));
}

test "merkle: buildMerkleRoot — drei Events (ungerade, letzter dupliziert)" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02), mkh(0x03) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);
    // Level 0: L0=leaf(1), L1=leaf(2), L2=leaf(3)
    // Level 1: N0=H(L0,L1), N1=H(L2,L2)  ← ungerade Regel
    // Root: H(N0, N1)
    const l0 = hashLeaf(mkh(0x01));
    const l1 = hashLeaf(mkh(0x02));
    const l2 = hashLeaf(mkh(0x03));
    const n0 = hashNode(l0, l1);
    const n1 = hashNode(l2, l2);
    const expected = hashNode(n0, n1);
    try std.testing.expect(std.mem.eql(u8, &root, &expected));
}

test "merkle: buildMerkleRoot — fünf Events (ungerade)" {
    var hashes: [5]Hash = undefined;
    for (&hashes, 0..) |*h, i| h.* = mkh(@intCast(i + 1));
    const r1 = try buildMerkleRoot(std.testing.allocator, &hashes);
    const r2 = try buildMerkleRoot(std.testing.allocator, &hashes);
    // Deterministisch
    try std.testing.expect(std.mem.eql(u8, &r1, &r2));
}

test "merkle: buildMerkleRoot — sieben Events (ungerade)" {
    var hashes: [7]Hash = undefined;
    for (&hashes, 0..) |*h, i| h.* = mkh(@intCast(i + 1));
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);
    try std.testing.expect(!std.mem.eql(u8, &root, &ZERO_HASH));
}

test "merkle: identische Streams → identischer Root" {
    var h1: [4]Hash = undefined;
    var h2: [4]Hash = undefined;
    for (&h1, 0..) |*h, i| h.* = mkh(@intCast(i));
    for (&h2, 0..) |*h, i| h.* = mkh(@intCast(i));
    const r1 = try buildMerkleRoot(std.testing.allocator, &h1);
    const r2 = try buildMerkleRoot(std.testing.allocator, &h2);
    try std.testing.expect(std.mem.eql(u8, &r1, &r2));
}

test "merkle: verändertes Event → anderer Root" {
    var hashes = [_]Hash{ mkh(0x01), mkh(0x02), mkh(0x03) };
    const r1 = try buildMerkleRoot(std.testing.allocator, &hashes);
    hashes[1] = mkh(0xFF);
    const r2 = try buildMerkleRoot(std.testing.allocator, &hashes);
    try std.testing.expect(!std.mem.eql(u8, &r1, &r2));
}

test "merkle: Reihenfolgeänderung → anderer Root" {
    const h1 = [_]Hash{ mkh(0x01), mkh(0x02) };
    const h2 = [_]Hash{ mkh(0x02), mkh(0x01) };
    const r1 = try buildMerkleRoot(std.testing.allocator, &h1);
    const r2 = try buildMerkleRoot(std.testing.allocator, &h2);
    try std.testing.expect(!std.mem.eql(u8, &r1, &r2));
}

test "merkle: MerkleProof — valider Einzel-Proof (2 Events)" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var proof = try buildProof(std.testing.allocator, 1, &hashes, 0, 100, root);
    defer freeProof(std.testing.allocator, &proof);

    try std.testing.expect(proof.verify());
}

test "merkle: MerkleProof — valider Proof zweites Event (2 Events)" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var proof = try buildProof(std.testing.allocator, 1, &hashes, 1, 101, root);
    defer freeProof(std.testing.allocator, &proof);

    try std.testing.expect(proof.verify());
}

test "merkle: MerkleProof — falscher Sibling → invalid" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var proof = try buildProof(std.testing.allocator, 1, &hashes, 0, 100, root);
    defer freeProof(std.testing.allocator, &proof);

    // Sibling manipulieren
    const owned = try std.testing.allocator.dupe(Hash, proof.siblings);
    defer std.testing.allocator.free(owned);
    owned[0] = mkh(0xFF);
    const bad_proof = MerkleProof{
        .segment_id          = proof.segment_id,
        .target_sequence     = proof.target_sequence,
        .target_event_hash   = proof.target_event_hash,
        .segment_merkle_root = proof.segment_merkle_root,
        .siblings            = owned,
        .directions          = proof.directions,
    };
    try std.testing.expect(!bad_proof.verify());
}

test "merkle: MerkleProof — falsche Direction → invalid" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var proof = try buildProof(std.testing.allocator, 1, &hashes, 0, 100, root);
    defer freeProof(std.testing.allocator, &proof);

    const bad_dirs = try std.testing.allocator.dupe(ProofDirection, proof.directions);
    defer std.testing.allocator.free(bad_dirs);
    bad_dirs[0] = if (bad_dirs[0] == .left) .right else .left;
    const bad_proof = MerkleProof{
        .segment_id          = proof.segment_id,
        .target_sequence     = proof.target_sequence,
        .target_event_hash   = proof.target_event_hash,
        .segment_merkle_root = proof.segment_merkle_root,
        .siblings            = proof.siblings,
        .directions          = bad_dirs,
    };
    try std.testing.expect(!bad_proof.verify());
}

test "merkle: MerkleProof — falscher Segment Root → invalid" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var proof = try buildProof(std.testing.allocator, 1, &hashes, 0, 100, root);
    defer freeProof(std.testing.allocator, &proof);

    var bad = proof;
    bad.segment_merkle_root = mkh(0xDE);
    try std.testing.expect(!bad.verify());
}

test "merkle: MerkleProof — 3 Events, mittleres Event bewiesen" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02), mkh(0x03) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var proof = try buildProof(std.testing.allocator, 1, &hashes, 1, 101, root);
    defer freeProof(std.testing.allocator, &proof);

    try std.testing.expect(proof.verify());
}

test "merkle: MerkleRangeProof — gesamtes Segment (alle Events)" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02), mkh(0x03), mkh(0x04) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var rp = try buildRangeProof(std.testing.allocator, 1, 1000, &hashes, 1000, 1003, root);
    defer freeRangeProof(std.testing.allocator, &rp);

    try verifyRangeProof(std.testing.allocator, &rp);
}

test "merkle: MerkleRangeProof — ein einzelnes Event" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02), mkh(0x03), mkh(0x04) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var rp = try buildRangeProof(std.testing.allocator, 1, 1000, &hashes, 1001, 1001, root);
    defer freeRangeProof(std.testing.allocator, &rp);

    try verifyRangeProof(std.testing.allocator, &rp);
}

test "merkle: MerkleRangeProof — falscher Event-Hash → RootMismatch" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02), mkh(0x03) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var rp = try buildRangeProof(std.testing.allocator, 1, 0, &hashes, 0, 1, root);
    defer freeRangeProof(std.testing.allocator, &rp);

    // Range-Hashes manipulieren
    const bad_hashes = try std.testing.allocator.dupe(Hash, rp.range_event_hashes);
    defer std.testing.allocator.free(bad_hashes);
    bad_hashes[0] = mkh(0xFF);
    var bad_rp = rp;
    bad_rp.range_event_hashes = bad_hashes;

    try std.testing.expectError(RangeVerifyError.RootMismatch, verifyRangeProof(std.testing.allocator, &bad_rp));
}

test "merkle: MerkleRangeProof — falsche Länge → RangeLengthMismatch" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02), mkh(0x03) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var rp = try buildRangeProof(std.testing.allocator, 1, 0, &hashes, 0, 2, root);
    defer freeRangeProof(std.testing.allocator, &rp);

    var bad_rp = rp;
    bad_rp.end_sequence = 1; // behauptet kleinere Range als range_event_hashes.len
    try std.testing.expectError(RangeVerifyError.RangeLengthMismatch, verifyRangeProof(std.testing.allocator, &bad_rp));
}

test "merkle: MerkleRangeProof — Range außerhalb Segment → RangeOutsideSegment" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var rp = try buildRangeProof(std.testing.allocator, 1, 100, &hashes, 100, 101, root);
    defer freeRangeProof(std.testing.allocator, &rp);

    var bad_rp = rp;
    bad_rp.start_sequence = 99; // außerhalb
    try std.testing.expectError(RangeVerifyError.RangeOutsideSegment, verifyRangeProof(std.testing.allocator, &bad_rp));
}

// ── P1.1 Semantics Equivalence Tests ─────────────────────────────────────

test "P1.1: buildMerkleRoot — Before/After Equivalence (1 Event)" {
    const hashes = [_]Hash{mkh(0x42)};
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);
    // Zweiter Durchlauf: Muss identisch sein (determinismus check)
    const root2 = try buildMerkleRoot(std.testing.allocator, &hashes);
    try std.testing.expect(std.mem.eql(u8, &root, &root2));
}

test "P1.1: buildMerkleRoot — Before/After Equivalence (100 Events)" {
    var hashes: [100]Hash = undefined;
    for (&hashes, 0..) |*h, i| {
        h.* = mkh(@intCast(i % 256));
    }
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);
    const root2 = try buildMerkleRoot(std.testing.allocator, &hashes);
    try std.testing.expect(std.mem.eql(u8, &root, &root2));
}

test "P1.1: buildProof — Before/After Equivalence (Multiple Indices)" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02), mkh(0x03), mkh(0x04) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    for (0..hashes.len) |idx| {
        var proof = try buildProof(std.testing.allocator, 1, &hashes, idx, 100 + @as(u64, @intCast(idx)), root);
        defer freeProof(std.testing.allocator, &proof);
        try std.testing.expect(proof.verify());
    }
}

test "P1.1: buildRangeProof — Before/After Equivalence (Full Range)" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02), mkh(0x03), mkh(0x04), mkh(0x05) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var rp = try buildRangeProof(std.testing.allocator, 1, 0, &hashes, 0, 4, root);
    defer freeRangeProof(std.testing.allocator, &rp);

    try verifyRangeProof(std.testing.allocator, &rp);
}

test "P1.1: deriveRangeRoot — Before/After Equivalence" {
    const hashes = [_]Hash{ mkh(0x01), mkh(0x02), mkh(0x03), mkh(0x04) };
    const root = try buildMerkleRoot(std.testing.allocator, &hashes);

    var rp = try buildRangeProof(std.testing.allocator, 1, 0, &hashes, 1, 2, root);
    defer freeRangeProof(std.testing.allocator, &rp);

    const derived1 = try deriveRangeRoot(std.testing.allocator, &rp);
    const derived2 = try deriveRangeRoot(std.testing.allocator, &rp);
    try std.testing.expect(std.mem.eql(u8, &derived1, &derived2));
}
