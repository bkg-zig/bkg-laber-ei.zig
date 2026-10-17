/// BKGDB Evolution Memory v1 — ArtifactSource Adapter
///
/// Status: STAGE 7 — PROVEN & FROZEN — 2026-09-01
/// SHA256: c2425eb595bffe257158265ac6bbc5930d2701cd4442d796ee63a6015e6f5b96
/// Spec:   docs/BKGDB_EVOLUTION_MEMORY_v1.md §4 Schnittstellen zum Model Layer
///
/// Dieser Adapter verbindet den BKGDB ArtifactStore (rohe Blobs) mit der
/// ArtifactSource-Schnittstelle des Model Layers (validator.zig, PROVEN & FROZEN).
///
/// WICHTIG: Empfang aus BKGDB bedeutet KEIN Vertrauen.
/// Der Model Layer prüft jedes Artefakt vollständig (Hash → Lineage → Evidence → Policy → Tests).
/// Dieser Adapter ist nur ein Transportmechanismus.
///
/// Protokollentscheidungen:
///   P1: Der Adapter deserialisiert den Blob via manifest.zig (PROVEN & FROZEN).
///       Bei Deserialisierungsfehler gibt lookupFn null zurück (kein Panic).
///   P2: Der Adapter prüft NICHT die Validität des Artefakts — das ist Aufgabe des Validators.
///   P3: Der Adapter nutzt ausschließlich den ArtifactStore als Datenquelle.
///       Kein direkter BKGDB-Zugriff, kein Netzwerkaufruf.
///   P4: Kein globaler Zustand. Der Adapter hält einen Pointer auf den ArtifactStore.
///
/// Import-Struktur:
///   artifact_source_adapter.zig importiert:
///     - artifact_store.zig  (BKGDB-seitig, FROZEN)
///     - manifest.zig        (Model Layer, FROZEN)
///     - artifact.zig        (Model Layer, FROZEN)
///     - hash.zig            (Model Layer, FROZEN)
///     - validator.zig       (für ArtifactSource typedef, FROZEN)
///
const std = @import("std");

const artifact_store_mod = @import("artifact_store.zig");
const manifest_mod       = @import("manifest.zig");
const artifact_mod       = @import("artifact.zig");
const hash_mod           = @import("hash.zig");
const validator_mod      = @import("validator.zig");

pub const ArtifactStore  = artifact_store_mod.ArtifactStore;
pub const Artifact       = artifact_mod.Artifact;
pub const Hash           = hash_mod.Hash;
pub const ArtifactSource = validator_mod.ArtifactSource;

// ── BkgdbArtifactSourceCtx ────────────────────────────────────────────────

/// Kontext für den BKGDB-ArtifactSource-Adapter.
/// Hält einen nicht-owning Pointer auf den ArtifactStore.
pub const BkgdbArtifactSourceCtx = struct {
    store: *const ArtifactStore,
};

// ── Lookup-Funktion ───────────────────────────────────────────────────────

/// Implementierung der ArtifactSource.lookupFn für BKGDB.
///
/// Sucht den Blob im ArtifactStore und deserialisiert ihn via manifest.zig.
/// Bei Fehler (nicht gefunden, Deserialisierungsfehler) → null.
/// P1: Kein Panic, kein unreachable für externe Fehler.
fn bkgdbLookupFn(ctx: *const anyopaque, hash: Hash) ?Artifact {
    const self: *const BkgdbArtifactSourceCtx = @ptrCast(@alignCast(ctx));

    // Blob aus ArtifactStore holen (verwendet BKGA-Domain-Hash)
    const blob = self.store.get(hash) orelse return null;

    // Blob via manifest.zig deserialisieren
    const artifact = manifest_mod.deserialize(blob) catch return null;
    return artifact;
}

// ── Konstruktor ───────────────────────────────────────────────────────────

/// Erzeugt einen ArtifactSource-Adapter für BKGDB.
///
/// Der Caller ist verantwortlich, dass `ctx` für die Lebenszeit des Adapters gültig bleibt.
pub fn makeArtifactSource(ctx: *const BkgdbArtifactSourceCtx) ArtifactSource {
    return ArtifactSource{
        .ctx      = @ptrCast(ctx),
        .lookupFn = bkgdbLookupFn,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "artifact_source_adapter: lookup nicht gefunden → null" {
    const allocator = std.testing.allocator;
    var store = ArtifactStore.init(allocator);
    defer store.deinit();

    const ctx = BkgdbArtifactSourceCtx{ .store = &store };
    const source = makeArtifactSource(&ctx);

    const missing_hash: Hash = [_]u8{0x42} ** 32;
    const result = source.lookup(missing_hash);
    try std.testing.expect(result == null);
}

test "artifact_source_adapter: lookup gefunden + deserialisiert" {
    const allocator = std.testing.allocator;
    var store = ArtifactStore.init(allocator);
    defer store.deinit();

    // Erzeuge ein echtes serialisiertes Artefakt
    const artifact_in = makeTestArtifact();
    var buf: [manifest_mod.MANIFEST_MAX_SIZE]u8 = undefined;
    const n = try manifest_mod.serialize(&artifact_in, &buf);
    const blob = buf[0..n];

    // Berechne den BKGA-Domain-Hash (wie artifact_store.put ihn erwartet)
    const bkga_hash = artifact_store_mod.domainHashForTest(blob);
    try store.put(bkga_hash, blob, 1);

    const ctx = BkgdbArtifactSourceCtx{ .store = &store };
    const source = makeArtifactSource(&ctx);

    // Lookup per BKGA-Hash
    const result = source.lookup(bkga_hash);
    try std.testing.expect(result != null);
    // content_hash muss mit dem gesetzten content_hash des Artefakts übereinstimmen
    // (Hinweis: nach deserialize ist content_hash das aus dem Manifest gelesene)
    try std.testing.expectEqualSlices(u8, &artifact_in.content_hash, &result.?.content_hash);
}

test "artifact_source_adapter: korrupter Blob → null (P1 kein Panic)" {
    const allocator = std.testing.allocator;
    var store = ArtifactStore.init(allocator);
    defer store.deinit();

    // Füge einen invaliden Blob ein (falsche Magic-Bytes)
    var bad_blob: [manifest_mod.MANIFEST_MIN_SIZE]u8 = [_]u8{0xDE} ** manifest_mod.MANIFEST_MIN_SIZE;
    bad_blob[0] = 'X'; // falsche Magic

    const bkga_hash = artifact_store_mod.domainHashForTest(&bad_blob);
    try store.put(bkga_hash, &bad_blob, 1);

    const ctx = BkgdbArtifactSourceCtx{ .store = &store };
    const source = makeArtifactSource(&ctx);

    // Deserialisierung muss fehlschlagen → null, kein Panic
    const result = source.lookup(bkga_hash);
    try std.testing.expect(result == null);
}

test "artifact_source_adapter: verschiedene Hashes liefern verschiedene Artefakte" {
    const allocator = std.testing.allocator;
    var store = ArtifactStore.init(allocator);
    defer store.deinit();

    // Artefakt 1
    var art1 = makeTestArtifact();
    art1.name = artifact_mod.makeArtifactName("artifact-one");
    var buf1: [manifest_mod.MANIFEST_MAX_SIZE]u8 = undefined;
    const n1 = try manifest_mod.serialize(&art1, &buf1);
    const hash1 = artifact_store_mod.domainHashForTest(buf1[0..n1]);
    try store.put(hash1, buf1[0..n1], 1);

    // Artefakt 2 (anderer Name → anderer Manifest-Blob → anderer BKGA-Hash)
    var art2 = makeTestArtifact();
    art2.name = artifact_mod.makeArtifactName("artifact-two");
    var buf2: [manifest_mod.MANIFEST_MAX_SIZE]u8 = undefined;
    const n2 = try manifest_mod.serialize(&art2, &buf2);
    const hash2 = artifact_store_mod.domainHashForTest(buf2[0..n2]);
    try store.put(hash2, buf2[0..n2], 2);

    const ctx = BkgdbArtifactSourceCtx{ .store = &store };
    const source = makeArtifactSource(&ctx);

    const r1 = source.lookup(hash1);
    const r2 = source.lookup(hash2);
    try std.testing.expect(r1 != null);
    try std.testing.expect(r2 != null);

    // Verschiedene Hashes → verschiedene Lookups liefern verschiedene Artefakte.
    // Wir prüfen den Namen via .slice() (content_hash ist in makeTestArtifact bewusst
    // ZERO_HASH — der Name unterscheidet die Artefakte semantisch).
    try std.testing.expect(!std.mem.eql(u8, r1.?.name.slice(), r2.?.name.slice()));
    // Die BKGA-Store-Hashes selbst müssen verschieden sein
    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

// ── Test-Hilfsfunktionen ──────────────────────────────────────────────────

fn makeTestArtifact() Artifact {
    return Artifact{
        .content_hash  = hash_mod.ZERO_HASH,
        .kind          = .capability,
        .proto_version = 0x01,
        .name          = artifact_mod.makeArtifactName("test"),
        .provenance    = .{
            .forge_epoch      = 1,
            .forge_generation = 1,
            .forge_event_hash = hash_mod.ZERO_HASH,
            .origin_node_tag  = 0,
        },
        .parent_count  = 0,
        .parents       = [_]Hash{hash_mod.ZERO_HASH} ** artifact_mod.MAX_PARENTS,
        .algo_desc     = artifact_mod.makeAlgoDesc("noop"),
        .params        = artifact_mod.ParamBlock{ .len = 0, .data = [_]u8{0} ** artifact_mod.MAX_PARAM_BYTES },
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
            .min_generation          = 0,
            .max_generation          = 0,
            .requires_guardian_verdict = false,
            .expires_at_epoch        = 0,
            .requires_lineage_verified = false,
            .requires_test_vectors   = false,
        },
        .evidence      = .{
            .ledger_event_hash    = hash_mod.ZERO_HASH,
            .guardian_pubkey_hash = hash_mod.ZERO_HASH,
            .verdict_epoch        = 0,
            .valid                = artifact_mod.EVIDENCE_VALID,
        },
        .lineage_hash  = hash_mod.ZERO_HASH,
    };
}
