/// BKG Model Layer — Kanonisches Manifest und Serialisierung
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/MODEL_LAYER_v1.md
///
/// Das Manifest ist die kanonische, deterministisch serialisierbare Darstellung
/// eines `.bkg`-Artefakts.
///
/// Regeln:
///   - Gleiche semantische Struktur → gleicher Hash (kein HashMap, keine Pointer)
///   - Kein Padding, kein impliziter Struct-Layout
///   - Wire-Format: fixe Felder in definierter Reihenfolge
///   - SHA-256 über den vollständigen serialisierten Manifest-Puffer
///
/// PROTOKOLLREGEL M2 — KANONISCHE PARENT-SORTIERUNG:
///   Parent-Collections sind semantisch eine Menge.
///   Vor jeder Serialisierung werden parent_hashes[0..parent_count] nach
///   vollständiger 32-Byte-CID aufsteigend sortiert (lexikografisch).
///   `lineage_hash` und `content_hash` sehen damit immer dieselbe Reihenfolge.
///   Eine unsortierte Eingabe wird normalisiert — nicht als alternative Wire-Form
///   zugelassen. Gleiche Parent-Menge → gleicher content_hash, unabhängig von
///   der Einfügereihenfolge.
///
/// Wire-Reihenfolge (Byte-genaue Felder):
///   [0]     magic[4]            = "BKGM"
///   [4]     proto_version u8
///   [5]     kind u8
///   [6..37] content_hash[32]    (vorläufig ZERO bei Erstberechnung)
///   [38..69] lineage_hash[32]
///   [70..77] forge_epoch u64 LE
///   [78..85] forge_generation u64 LE
///   [86..117] forge_event_hash[32]
///   [118]   origin_node_tag u32 LE (4 Bytes)
///   [122]   name_len u8
///   [123..186] name[64]
///   [187]   algo_len u8
///   [188..315] algo[128]
///   [316..317] param_len u16 LE
///   [318..573] params[256]
///   [574]   parent_count u8
///   [575..830] parents[8][32]  ← kanonisch sortiert
///   [831]   tv_count u8
///   [832..] test_vectors (je 1+1+32+32 = 66 Bytes)
///   [...]   bench_count u8
///   [...]   bench_claims (je 1+8+8 = 17 Bytes)
///   [...]   policy (8+8+1+8+1+1 = 27 Bytes)
///   [...]   evidence (32+32+8+1 = 73 Bytes)
///
const std = @import("std");
const hash_mod    = @import("hash.zig");
const artifact_mod = @import("artifact.zig");

pub const Hash     = hash_mod.Hash;
pub const Artifact = artifact_mod.Artifact;

/// Magic-Bytes für das Manifest-Wire-Format.
pub const MANIFEST_MAGIC: [4]u8 = .{ 'B', 'K', 'G', 'M' };

/// Fehlertypen für Manifest-Operationen.
pub const ManifestError = error{
    /// Ungültige Magic-Bytes.
    InvalidMagic,
    /// Ungültige Protokollversion.
    UnsupportedVersion,
    /// Unbekannter Artefakt-Typ.
    UnknownKind,
    /// Puffer zu klein.
    BufferTooSmall,
    /// Ungültige Feld-Länge.
    InvalidLength,
    /// content_hash-Mismatch (bei Validierung).
    ContentHashMismatch,
};

/// Minimale Größe eines serialisierten Manifests.
/// = 4+1+1+32+32 + 8+8+32+4 + 1+64 + 1+128 + 2+256 + 1+8*32 + 1+16*66 + 1+3*17 + 27 + 73
pub const MANIFEST_MIN_SIZE: usize = 4 + 1 + 1 + 32 + 32 + 8 + 8 + 32 + 4 + 1 + 64 + 1 + 128 + 2 + 256 + 1 + 256 + 1 + 1056 + 1 + 51 + 27 + 73;

/// Maximale Puffer-Größe (großzügig).
pub const MANIFEST_MAX_SIZE: usize = 4096;

// ── Kanonische Parent-Sortierung (M2) ─────────────────────────────────────

/// Sortiert parent_hashes[0..count] in-place aufsteigend nach vollem 32-Byte-CID.
/// Insertion-Sort (MAX_PARENTS = 8 — klein und branchfrei genug).
/// Wird vor JEDER Serialisierung aufgerufen: gleiche Parent-Menge → gleicher Hash.
fn sortParentsCanonical(parents: []hash_mod.Hash) void {
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

/// Serialisiert ein Artefakt in den Puffer. Gibt die Byte-Anzahl zurück.
/// Der content_hash im Artefakt wird NICHT automatisch gesetzt —
/// verwende `computeContentHash` dafür.
///
/// PROTOKOLLREGEL M2: Parents werden vor der Serialisierung kanonisch sortiert.
/// Die übergebene Artefakt-Struktur wird dabei NICHT mutiert — eine lokale
/// sortierte Kopie der Parent-Slots wird für die Serialisierung verwendet.
pub fn serialize(a: *const Artifact, buf: []u8) ManifestError!usize {
    if (buf.len < MANIFEST_MIN_SIZE) return ManifestError.BufferTooSmall;

    // Kanonisch sortierte Parent-Kopie (M2: lokale Normalisierung, kein Mutieren von a)
    var sorted_parents: [artifact_mod.MAX_PARENTS]hash_mod.Hash = a.parents;
    sortParentsCanonical(sorted_parents[0..a.parent_count]);

    var pos: usize = 0;

    // magic
    @memcpy(buf[pos..pos + 4], &MANIFEST_MAGIC);
    pos += 4;
    // proto_version
    buf[pos] = a.proto_version;
    pos += 1;
    // kind
    buf[pos] = @intFromEnum(a.kind);
    pos += 1;
    // content_hash (was in Artefakt steht)
    @memcpy(buf[pos..pos + 32], &a.content_hash);
    pos += 32;
    // lineage_hash
    @memcpy(buf[pos..pos + 32], &a.lineage_hash);
    pos += 32;
    // provenance: forge_epoch (u64 LE)
    std.mem.writeInt(u64, buf[pos..][0..8], a.provenance.forge_epoch, .little);
    pos += 8;
    // provenance: forge_generation (u64 LE)
    std.mem.writeInt(u64, buf[pos..][0..8], a.provenance.forge_generation, .little);
    pos += 8;
    // provenance: forge_event_hash
    @memcpy(buf[pos..pos + 32], &a.provenance.forge_event_hash);
    pos += 32;
    // provenance: origin_node_tag (u32 LE)
    std.mem.writeInt(u32, buf[pos..][0..4], a.provenance.origin_node_tag, .little);
    pos += 4;
    // name
    buf[pos] = a.name.len;
    pos += 1;
    @memcpy(buf[pos..pos + artifact_mod.MAX_NAME_LEN], &a.name.data);
    pos += artifact_mod.MAX_NAME_LEN;
    // algo_desc
    buf[pos] = a.algo_desc.len;
    pos += 1;
    @memcpy(buf[pos..pos + artifact_mod.MAX_ALGO_DESC_LEN], &a.algo_desc.data);
    pos += artifact_mod.MAX_ALGO_DESC_LEN;
    // params
    std.mem.writeInt(u16, buf[pos..][0..2], a.params.len, .little);
    pos += 2;
    @memcpy(buf[pos..pos + artifact_mod.MAX_PARAM_BYTES], &a.params.data);
    pos += artifact_mod.MAX_PARAM_BYTES;
    // parents — kanonisch sortierte Kopie (M2)
    buf[pos] = a.parent_count;
    pos += 1;
    for (0..artifact_mod.MAX_PARENTS) |i| {
        @memcpy(buf[pos..pos + 32], &sorted_parents[i]);
        pos += 32;
    }
    // test_vectors
    buf[pos] = a.tv_count;
    pos += 1;
    for (0..artifact_mod.MAX_TEST_VECTORS) |i| {
        const tv = &a.test_vectors[i];
        buf[pos] = tv.id;
        pos += 1;
        buf[pos] = tv.expected_result;
        pos += 1;
        @memcpy(buf[pos..pos + 32], &tv.input_hash);
        pos += 32;
        @memcpy(buf[pos..pos + 32], &tv.expected_output_hash);
        pos += 32;
    }
    // bench_claims
    buf[pos] = a.bench_count;
    pos += 1;
    for (0..3) |i| {
        const bc = &a.bench_claims[i];
        buf[pos] = bc.kind;
        pos += 1;
        std.mem.writeInt(u64, buf[pos..][0..8], bc.claimed_value, .little);
        pos += 8;
        std.mem.writeInt(u64, buf[pos..][0..8], bc.measured_at_epoch, .little);
        pos += 8;
    }
    // policy
    std.mem.writeInt(u64, buf[pos..][0..8], a.policy.min_generation, .little);
    pos += 8;
    std.mem.writeInt(u64, buf[pos..][0..8], a.policy.max_generation, .little);
    pos += 8;
    buf[pos] = if (a.policy.requires_guardian_verdict) 0x01 else 0x00;
    pos += 1;
    std.mem.writeInt(u64, buf[pos..][0..8], a.policy.expires_at_epoch, .little);
    pos += 8;
    buf[pos] = if (a.policy.requires_lineage_verified) 0x01 else 0x00;
    pos += 1;
    buf[pos] = if (a.policy.requires_test_vectors) 0x01 else 0x00;
    pos += 1;
    // evidence
    @memcpy(buf[pos..pos + 32], &a.evidence.ledger_event_hash);
    pos += 32;
    @memcpy(buf[pos..pos + 32], &a.evidence.guardian_pubkey_hash);
    pos += 32;
    std.mem.writeInt(u64, buf[pos..][0..8], a.evidence.verdict_epoch, .little);
    pos += 8;
    buf[pos] = a.evidence.valid;
    pos += 1;

    return pos;
}

/// Berechnet den kanonischen Content-Hash des Artefakts.
/// content_hash im Artefakt wird dabei als ZERO_HASH behandelt (kein Selbstbezug).
pub fn computeContentHash(a: *const Artifact) ManifestError!Hash {
    // Temporäre Kopie mit ZERO content_hash
    var tmp = a.*;
    tmp.content_hash = hash_mod.ZERO_HASH;

    var buf: [MANIFEST_MAX_SIZE]u8 = undefined;
    const len = try serialize(&tmp, &buf);
    return hash_mod.hashBytes(buf[0..len]);
}

/// Deserialisiert einen Manifest-Puffer in ein Artifact.
/// Prüft Magic und Version, aber NICHT den content_hash (Aufgabe des Validators).
pub fn deserialize(buf: []const u8) ManifestError!Artifact {
    if (buf.len < MANIFEST_MIN_SIZE) return ManifestError.BufferTooSmall;

    var pos: usize = 0;

    // magic
    if (!std.mem.eql(u8, buf[pos..pos + 4], &MANIFEST_MAGIC))
        return ManifestError.InvalidMagic;
    pos += 4;
    // proto_version
    const proto_version = buf[pos];
    if (proto_version != 0x01) return ManifestError.UnsupportedVersion;
    pos += 1;
    // kind
    const kind_raw = buf[pos];
    pos += 1;
    // Manuell prüfen ob kind_raw einem gültigen ArtifactKind-Wert entspricht.
    const kind: artifact_mod.ArtifactKind = blk: {
        inline for (std.meta.fields(artifact_mod.ArtifactKind)) |f| {
            if (f.value == kind_raw) break :blk @enumFromInt(kind_raw);
        }
        return ManifestError.UnknownKind;
    };
    // content_hash
    var content_hash: Hash = undefined;
    @memcpy(&content_hash, buf[pos..pos + 32]);
    pos += 32;
    // lineage_hash
    var lineage_hash: Hash = undefined;
    @memcpy(&lineage_hash, buf[pos..pos + 32]);
    pos += 32;
    // provenance
    const forge_epoch      = std.mem.readInt(u64, buf[pos..][0..8], .little); pos += 8;
    const forge_generation = std.mem.readInt(u64, buf[pos..][0..8], .little); pos += 8;
    var forge_event_hash: Hash = undefined;
    @memcpy(&forge_event_hash, buf[pos..pos + 32]);
    pos += 32;
    const origin_node_tag  = std.mem.readInt(u32, buf[pos..][0..4], .little); pos += 4;
    // name
    const name_len = buf[pos]; pos += 1;
    var name_data: [artifact_mod.MAX_NAME_LEN]u8 = [_]u8{0} ** artifact_mod.MAX_NAME_LEN;
    @memcpy(&name_data, buf[pos..pos + artifact_mod.MAX_NAME_LEN]);
    pos += artifact_mod.MAX_NAME_LEN;
    // algo_desc
    const algo_len = buf[pos]; pos += 1;
    var algo_data: [artifact_mod.MAX_ALGO_DESC_LEN]u8 = [_]u8{0} ** artifact_mod.MAX_ALGO_DESC_LEN;
    @memcpy(&algo_data, buf[pos..pos + artifact_mod.MAX_ALGO_DESC_LEN]);
    pos += artifact_mod.MAX_ALGO_DESC_LEN;
    // params
    const param_len = std.mem.readInt(u16, buf[pos..][0..2], .little); pos += 2;
    var param_data: [artifact_mod.MAX_PARAM_BYTES]u8 = [_]u8{0} ** artifact_mod.MAX_PARAM_BYTES;
    @memcpy(&param_data, buf[pos..pos + artifact_mod.MAX_PARAM_BYTES]);
    pos += artifact_mod.MAX_PARAM_BYTES;
    // parents
    const parent_count = buf[pos]; pos += 1;
    var parents: [artifact_mod.MAX_PARENTS]Hash = [_]Hash{hash_mod.ZERO_HASH} ** artifact_mod.MAX_PARENTS;
    for (0..artifact_mod.MAX_PARENTS) |i| {
        @memcpy(&parents[i], buf[pos..pos + 32]);
        pos += 32;
    }
    // test_vectors
    const tv_count = buf[pos]; pos += 1;
    var tvs: [artifact_mod.MAX_TEST_VECTORS]artifact_mod.TestVector = undefined;
    for (0..artifact_mod.MAX_TEST_VECTORS) |i| {
        tvs[i].id              = buf[pos]; pos += 1;
        tvs[i].expected_result = buf[pos]; pos += 1;
        @memcpy(&tvs[i].input_hash,           buf[pos..pos + 32]); pos += 32;
        @memcpy(&tvs[i].expected_output_hash, buf[pos..pos + 32]); pos += 32;
    }
    // bench_claims
    const bench_count = buf[pos]; pos += 1;
    var benches: [3]artifact_mod.BenchmarkClaim = undefined;
    for (0..3) |i| {
        benches[i].kind              = buf[pos]; pos += 1;
        benches[i].claimed_value     = std.mem.readInt(u64, buf[pos..][0..8], .little); pos += 8;
        benches[i].measured_at_epoch = std.mem.readInt(u64, buf[pos..][0..8], .little); pos += 8;
    }
    // policy
    const min_gen   = std.mem.readInt(u64, buf[pos..][0..8], .little); pos += 8;
    const max_gen   = std.mem.readInt(u64, buf[pos..][0..8], .little); pos += 8;
    const req_guard = buf[pos] != 0;                                    pos += 1;
    const expires   = std.mem.readInt(u64, buf[pos..][0..8], .little); pos += 8;
    const req_lin   = buf[pos] != 0;                                    pos += 1;
    const req_tv    = buf[pos] != 0;                                    pos += 1;
    // evidence
    var ev_ledger: Hash = undefined; @memcpy(&ev_ledger, buf[pos..pos + 32]); pos += 32;
    var ev_guard:  Hash = undefined; @memcpy(&ev_guard,  buf[pos..pos + 32]); pos += 32;
    const ev_epoch = std.mem.readInt(u64, buf[pos..][0..8], .little);  pos += 8;
    const ev_valid = buf[pos];

    return Artifact{
        .content_hash  = content_hash,
        .kind          = kind,
        .proto_version = proto_version,
        .name          = .{ .len = name_len,  .data = name_data  },
        .provenance    = .{
            .forge_epoch      = forge_epoch,
            .forge_generation = forge_generation,
            .forge_event_hash = forge_event_hash,
            .origin_node_tag  = origin_node_tag,
        },
        .parent_count  = parent_count,
        .parents       = parents,
        .algo_desc     = .{ .len = algo_len, .data = algo_data },
        .params        = .{ .len = param_len, .data = param_data },
        .tv_count      = tv_count,
        .test_vectors  = tvs,
        .bench_count   = bench_count,
        .bench_claims  = benches,
        .policy        = .{
            .min_generation          = min_gen,
            .max_generation          = max_gen,
            .requires_guardian_verdict = req_guard,
            .expires_at_epoch        = expires,
            .requires_lineage_verified = req_lin,
            .requires_test_vectors   = req_tv,
        },
        .evidence      = .{
            .ledger_event_hash   = ev_ledger,
            .guardian_pubkey_hash = ev_guard,
            .verdict_epoch       = ev_epoch,
            .valid               = ev_valid,
        },
        .lineage_hash  = lineage_hash,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

fn makeBaseArtifact() Artifact {
    return Artifact{
        .content_hash  = hash_mod.ZERO_HASH,
        .kind          = .capability,
        .proto_version = 0x01,
        .name          = artifact_mod.makeArtifactName("base"),
        .provenance    = .{
            .forge_epoch = 42, .forge_generation = 1,
            .forge_event_hash = hash_mod.ZERO_HASH, .origin_node_tag = 0,
        },
        .parent_count  = 0,
        .parents       = [_]Hash{hash_mod.ZERO_HASH} ** artifact_mod.MAX_PARENTS,
        .algo_desc     = artifact_mod.makeAlgoDesc("noop"),
        .params        = .{ .len = 0, .data = [_]u8{0} ** artifact_mod.MAX_PARAM_BYTES },
        .tv_count      = 0,
        .test_vectors  = [_]artifact_mod.TestVector{.{
            .id = 0, .expected_result = 0,
            .input_hash = hash_mod.ZERO_HASH, .expected_output_hash = hash_mod.ZERO_HASH,
        }} ** artifact_mod.MAX_TEST_VECTORS,
        .bench_count   = 0,
        .bench_claims  = [_]artifact_mod.BenchmarkClaim{.{
            .kind = 0, .claimed_value = 0, .measured_at_epoch = 0,
        }} ** 3,
        .policy        = .{
            .min_generation = 0, .max_generation = 0,
            .requires_guardian_verdict = false, .expires_at_epoch = 0,
            .requires_lineage_verified = false, .requires_test_vectors = false,
        },
        .evidence      = .{
            .ledger_event_hash = hash_mod.ZERO_HASH,
            .guardian_pubkey_hash = hash_mod.ZERO_HASH,
            .verdict_epoch = 0, .valid = artifact_mod.EVIDENCE_VALID,
        },
        .lineage_hash  = hash_mod.ZERO_HASH,
    };
}

test "manifest: serialize Mindestgröße" {
    const a = makeBaseArtifact();
    var buf: [MANIFEST_MAX_SIZE]u8 = undefined;
    const len = try serialize(&a, &buf);
    try std.testing.expect(len >= MANIFEST_MIN_SIZE);
}

test "manifest: serialize deterministisch" {
    const a = makeBaseArtifact();
    var buf1: [MANIFEST_MAX_SIZE]u8 = undefined;
    var buf2: [MANIFEST_MAX_SIZE]u8 = undefined;
    const l1 = try serialize(&a, &buf1);
    const l2 = try serialize(&a, &buf2);
    try std.testing.expectEqual(l1, l2);
    try std.testing.expectEqualSlices(u8, buf1[0..l1], buf2[0..l2]);
}

test "manifest: computeContentHash deterministisch" {
    const a = makeBaseArtifact();
    const h1 = try computeContentHash(&a);
    const h2 = try computeContentHash(&a);
    try std.testing.expect(hash_mod.hashEqual(h1, h2));
}

test "manifest: computeContentHash — Änderung erzeugt anderen Hash" {
    var a = makeBaseArtifact();
    var b = makeBaseArtifact();
    b.provenance.forge_epoch = 99;
    const h_a = try computeContentHash(&a);
    const h_b = try computeContentHash(&b);
    try std.testing.expect(!hash_mod.hashEqual(h_a, h_b));
}

test "manifest: serialize/deserialize Roundtrip" {
    var a = makeBaseArtifact();
    a.provenance.forge_epoch = 7;
    a.parent_count = 1;
    a.parents[0] = hash_mod.hashBytes("parent0");

    var buf: [MANIFEST_MAX_SIZE]u8 = undefined;
    const len = try serialize(&a, &buf);
    const b = try deserialize(buf[0..len]);

    try std.testing.expectEqual(a.kind, b.kind);
    try std.testing.expectEqual(@as(u64, 7), b.provenance.forge_epoch);
    try std.testing.expectEqual(@as(u8, 1), b.parent_count);
    try std.testing.expect(hash_mod.hashEqual(a.parents[0], b.parents[0]));
}

test "manifest: deserialize — ungültige Magic → Fehler" {
    var a = makeBaseArtifact();
    var buf: [MANIFEST_MAX_SIZE]u8 = undefined;
    const len = try serialize(&a, &buf);
    buf[0] = 0xFF; // Magic beschädigen
    try std.testing.expectError(ManifestError.InvalidMagic, deserialize(buf[0..len]));
}

test "manifest: deserialize — BufferTooSmall" {
    var small: [10]u8 = undefined;
    try std.testing.expectError(ManifestError.BufferTooSmall, deserialize(&small));
}

test "manifest: computeContentHash — content_hash-Feld selbst ändert Hash nicht" {
    // Artefakt a hat content_hash = ZERO, b hat content_hash = hashBytes("x")
    // computeContentHash setzt es intern auf ZERO → beide sollten gleichen Hash liefern
    var a = makeBaseArtifact();
    var b = makeBaseArtifact();
    b.content_hash = hash_mod.hashBytes("other");
    const h_a = try computeContentHash(&a);
    const h_b = try computeContentHash(&b);
    // Beide identisch, weil content_hash beim Hashen auf ZERO gesetzt wird
    try std.testing.expect(hash_mod.hashEqual(h_a, h_b));
}

test "manifest: Artefakt mit Testvektoren serialisiert deterministisch" {
    var a = makeBaseArtifact();
    a.tv_count = 2;
    a.test_vectors[0] = .{
        .id = 0, .expected_result = 0x01,
        .input_hash = hash_mod.hashBytes("in0"),
        .expected_output_hash = hash_mod.hashBytes("out0"),
    };
    a.test_vectors[1] = .{
        .id = 1, .expected_result = 0x01,
        .input_hash = hash_mod.hashBytes("in1"),
        .expected_output_hash = hash_mod.hashBytes("out1"),
    };
    const h1 = try computeContentHash(&a);
    const h2 = try computeContentHash(&a);
    try std.testing.expect(hash_mod.hashEqual(h1, h2));
}

// ── M2: Kanonische Parent-Sortierung — Adversarial Tests ──────────────────

test "manifest M2: gleiche Parent-Menge, andere Reihenfolge → gleicher content_hash" {
    // Protokollregel M2: Parent-Menge ist semantisch ungeordnet.
    // Zwei Artefakte mit denselben Parents in verschiedener Reihenfolge
    // müssen denselben content_hash erzeugen.
    const p1 = hash_mod.hashBytes("parent-alpha");
    const p2 = hash_mod.hashBytes("parent-beta");

    var a = makeBaseArtifact();
    a.parent_count = 2;
    a.parents[0] = p1;
    a.parents[1] = p2;

    var b = makeBaseArtifact();
    b.parent_count = 2;
    b.parents[0] = p2; // umgekehrte Reihenfolge
    b.parents[1] = p1;

    const h_a = try computeContentHash(&a);
    const h_b = try computeContentHash(&b);
    // M2-Invariante: gleiche Menge → gleicher Hash
    try std.testing.expect(hash_mod.hashEqual(h_a, h_b));
}

test "manifest M2: drei Parents, alle Permutationen → gleicher content_hash" {
    const p1 = hash_mod.hashBytes("x");
    const p2 = hash_mod.hashBytes("y");
    const p3 = hash_mod.hashBytes("z");

    var base = makeBaseArtifact();
    base.parent_count = 3;
    base.parents[0] = p1; base.parents[1] = p2; base.parents[2] = p3;
    const h_base = try computeContentHash(&base);

    // Permutation 1: p1 p3 p2
    var a2 = makeBaseArtifact();
    a2.parent_count = 3;
    a2.parents[0] = p1; a2.parents[1] = p3; a2.parents[2] = p2;
    try std.testing.expect(hash_mod.hashEqual(h_base, try computeContentHash(&a2)));

    // Permutation 2: p2 p1 p3
    var a3 = makeBaseArtifact();
    a3.parent_count = 3;
    a3.parents[0] = p2; a3.parents[1] = p1; a3.parents[2] = p3;
    try std.testing.expect(hash_mod.hashEqual(h_base, try computeContentHash(&a3)));

    // Permutation 3: p3 p2 p1
    var a4 = makeBaseArtifact();
    a4.parent_count = 3;
    a4.parents[0] = p3; a4.parents[1] = p2; a4.parents[2] = p1;
    try std.testing.expect(hash_mod.hashEqual(h_base, try computeContentHash(&a4)));
}

test "manifest M2: verschiedene Parent-Mengen → verschiedene content_hashes" {
    const p1 = hash_mod.hashBytes("p1");
    const p2 = hash_mod.hashBytes("p2");
    const p3 = hash_mod.hashBytes("p3");

    var a = makeBaseArtifact();
    a.parent_count = 2;
    a.parents[0] = p1; a.parents[1] = p2;

    var b = makeBaseArtifact();
    b.parent_count = 2;
    b.parents[0] = p1; b.parents[1] = p3; // anderer zweiter Parent

    try std.testing.expect(!hash_mod.hashEqual(
        try computeContentHash(&a),
        try computeContentHash(&b),
    ));
}

test "manifest M2: serialize mutiert Artefakt nicht" {
    // Die Sortierung darf die übergebene Struct NICHT verändern.
    const p_high = hash_mod.hashBytes("zzz"); // lexikografisch höher
    const p_low  = hash_mod.hashBytes("aaa"); // lexikografisch tiefer

    var a = makeBaseArtifact();
    a.parent_count = 2;
    a.parents[0] = p_high; // bewusst falsche Reihenfolge
    a.parents[1] = p_low;

    var buf: [MANIFEST_MAX_SIZE]u8 = undefined;
    _ = try serialize(&a, &buf);

    // Nach serialize(): a.parents[0] muss noch p_high sein (kein Mutieren)
    try std.testing.expect(hash_mod.hashEqual(a.parents[0], p_high));
    try std.testing.expect(hash_mod.hashEqual(a.parents[1], p_low));
}

test "manifest M2: unabhängig konstruierte semantisch gleiche Artefakte → gleicher content_hash" {
    // M12-Adversarial: Zwei Artefakte unabhängig konstruiert, gleiche Semantik.
    // Kein uninitialisierter Byte darf den Hash beeinflussen.
    var a = makeBaseArtifact();
    a.parent_count = 1;
    a.parents[0] = hash_mod.hashBytes("sole-parent");

    var b = makeBaseArtifact();
    b.parent_count = 1;
    b.parents[0] = hash_mod.hashBytes("sole-parent");
    // Alle anderen Felder identisch durch makeBaseArtifact()

    try std.testing.expect(hash_mod.hashEqual(
        try computeContentHash(&a),
        try computeContentHash(&b),
    ));
}
