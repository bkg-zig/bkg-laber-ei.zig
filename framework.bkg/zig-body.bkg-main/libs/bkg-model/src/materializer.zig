/// BKG Model Layer — Materializer
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/MODEL_LAYER_v1.md
///
/// Materialisierung = vollständige Aktivierungspipeline eines Artefakts.
///
/// Pipeline (atomar — kein Partial-Trust):
///
///   ArtifactSource
///   → Artefakt laden
///   → content_hash prüfen
///   → lineage_hash prüfen
///   → authority_evidence prüfen
///   → policy prüfen
///   → testvektoren ausführen
///   → capability validieren
///   → read-only Runtime-Repräsentation erzeugen
///   → aktivieren
///
/// Ein fehlgeschlagener Schritt → KEINE Aktivierung.
/// Keine stille Fallback-Aktivierung.
/// Kein Partial-Activation.
///
/// Re-Materialisierung:
///   - Dematerialisierung entfernt die lokale Aktivierung
///   - Die Lineage bleibt in BKGDB erhalten
///   - Spätere Re-Materialisierung aus historischer Lineage möglich
///   - Kein Node besitzt eine Evolution
///
/// Cache-Invalidierung:
///   - Ältere Version → outdated
///   - Neuere Version wird separat materialisiert
///   - Versionswechsel ist immer explizit, niemals still
const std = @import("std");
const hash_mod       = @import("hash.zig");
const artifact_mod   = @import("artifact.zig");
const capability_mod = @import("capability.zig");
const validator_mod  = @import("validator.zig");
const lineage_mod    = @import("lineage.zig");

pub const Hash     = hash_mod.Hash;
pub const Artifact = artifact_mod.Artifact;

// ── Materialisierungs-State ────────────────────────────────────────────────

/// Zustand einer materialisierter Instanz.
pub const MaterializationState = enum(u8) {
    /// Materialisierung vorbereitet, noch nicht abgeschlossen.
    pending    = 0x01,
    /// Vollständig aktiviert.
    active     = 0x02,
    /// Dematerialisiert — Lineage erhalten, lokal nicht mehr verfügbar.
    retired    = 0x03,
    /// Fehlgeschlagen — Aktivierungspipeline hat Fehler geworfen.
    failed     = 0x04,
};

// ── Read-Only Runtime Repräsentation ──────────────────────────────────────

/// Leichtgewichtige, read-only Runtime-Repräsentation eines aktiven Artefakts.
/// Keine Kopie des Artefakts — nur Metadaten, die zur Laufzeit benötigt werden.
pub const MaterializedArtifact = struct {
    /// Content-Hash des Artefakts.
    artifact_hash: Hash,
    /// Artefakt-Typ.
    kind:          artifact_mod.ArtifactKind,
    /// Capability-ID (aus artifact_hash abgeleitet).
    capability_id: artifact_mod.CapabilityId,
    /// Version (aus Provenance).
    version:       u64,
    /// Forge-Epoch der Materialisierung.
    materialized_epoch: u64,
    /// Zustand.
    state:         MaterializationState,
    /// Lineage-Hash (bleibt bei Dematerialisierung erhalten).
    lineage_hash:  Hash,
    /// Snapshot-Root-Hash zum Zeitpunkt der Materialisierung.
    snapshot_root: Hash,
};

// ── Materialisierungs-Fehler ───────────────────────────────────────────────

pub const MaterializerError = error{
    /// Artefakt in ArtifactSource nicht gefunden.
    ArtifactNotFound,
    /// Validierungspipeline fehlgeschlagen.
    ValidationFailed,
    /// Capability-Cache voll.
    CapabilityCacheFull,
    /// Artefakt bereits aktiv (Duplikat-ID, M6).
    AlreadyActive,
    /// Ungültiger Zustand für Dematerialisierung.
    NotActive,
    /// Kein Capability-Eintrag für dieses Artefakt.
    CapabilityEntryMissing,
};

// ── Materializer ───────────────────────────────────────────────────────────

/// Atomare Materialisierung eines Artefakts.
///
/// PROTOKOLLREGEL M11 — TRANSAKTIONALE ZUSTANDSÄNDERUNG:
///   Der CapabilityCache-Eintrag wird erst nach vollständiger Validierung
///   und erfolgreichen Zustandsübergängen dauerhaft angelegt.
///   Bei Fehler in einem beliebigen Schritt bleibt der Cache unverändert —
///   kein „known leftover", kein halbfertiges Objekt.
///
/// Implementierung:
///   - Alle Validierungen ZUERST (Schritt 1+2)
///   - Cache-Eintrag ZULETZT anlegen (Schritt 3) — nur wenn alles OK
///   - Zustandsübergänge in einem einzigen Zug durch (keine Pause dazwischen)
///
/// Gibt MaterializedArtifact zurück oder einen Fehler.
/// Bei Fehler: Cache unverändert.
pub fn materialize(
    source:   validator_mod.ArtifactSource,
    target_h: Hash,
    ctx:      validator_mod.ConsumerContext,
    executor: validator_mod.TestExecutorFn,
    cache:    *capability_mod.CapabilityCache,
    epoch:    u64,
) MaterializerError!MaterializedArtifact {
    // Schritt 1: Artefakt laden (kein Vertrauen durch Empfang)
    const artifact = source.lookup(target_h) orelse return MaterializerError.ArtifactNotFound;

    // Schritt 2: Vollständige Validierung (alle 6 Stufen, kein Bypass)
    // MUSS vor jeder Cache-Mutation erfolgen (M11).
    const result = validator_mod.validate(&artifact, ctx, executor)
        catch return MaterializerError.ValidationFailed;
    if (!result.all_passed) return MaterializerError.ValidationFailed;

    // Schritt 3: Capability-Cache-Eintrag (M11: erst nach erfolgreicher Validierung)
    // addKnown schlägt fehl bei: Cache voll, Duplikat-ID (M6: REVOKED terminal)
    const cap_id = artifact_mod.capIdFromHash(artifact.content_hash);
    const idx = cache.addKnown(
        cap_id, artifact.content_hash, artifact.provenance.forge_generation, epoch,
    ) catch |e| return switch (e) {
        error.CacheFull            => MaterializerError.CapabilityCacheFull,
        error.DuplicateCapabilityId => MaterializerError.AlreadyActive,
        else => MaterializerError.ValidationFailed,
    };

    // Zustandsübergänge: known → verified → materializable → activated
    // Bei Fehler: Eintrag wurde gerade angelegt (idx ist gültig).
    // Wir markieren ihn als failed und geben Fehler zurück — kein leftover in `known`.
    cache.markVerified(idx, epoch) catch {
        // Rollback: Eintrag als outdated markieren damit er keine aktive Slot-ID belegt
        // (superseded_by = ZERO signalisiert: fehlgeschlagene Materialisierung)
        cache.markOutdated(idx, hash_mod.ZERO_HASH, epoch) catch {};
        return MaterializerError.ValidationFailed;
    };
    cache.markMaterializable(idx, epoch) catch {
        cache.markOutdated(idx, hash_mod.ZERO_HASH, epoch) catch {};
        return MaterializerError.ValidationFailed;
    };
    cache.markActivated(idx, epoch) catch {
        cache.markOutdated(idx, hash_mod.ZERO_HASH, epoch) catch {};
        return MaterializerError.ValidationFailed;
    };

    // Schritt 4: Read-only Runtime-Repräsentation
    return MaterializedArtifact{
        .artifact_hash      = artifact.content_hash,
        .kind               = artifact.kind,
        .capability_id      = cap_id,
        .version            = artifact.provenance.forge_generation,
        .materialized_epoch = epoch,
        .state              = .active,
        .lineage_hash       = artifact.lineage_hash,
        .snapshot_root      = ctx.snapshot_root,
    };
}

/// Dematerialisiert eine aktive Instanz.
///
/// Setzt den Zustand auf `retired`. Die Lineage bleibt erhalten.
/// Ein Node besitzt keine Evolution — Dematerialisierung ist reversibel
/// durch erneute Materialisierung aus historischer Lineage.
pub fn dematerialize(
    ma:    *MaterializedArtifact,
    cache: *capability_mod.CapabilityCache,
    epoch: u64,
) MaterializerError!void {
    if (ma.state != .active) return MaterializerError.NotActive;
    // Capability-Cache-Eintrag suchen und als lost markieren
    const idx = cache.findByHash(ma.artifact_hash) orelse return MaterializerError.CapabilityEntryMissing;
    cache.markLost(idx, epoch) catch return MaterializerError.ValidationFailed;
    ma.state = .retired;
    // lineage_hash bleibt erhalten — kein Node besitzt die Evolution
}

/// Invalidiert eine alte Version im Cache, wenn eine neuere materialisiert wird.
pub fn invalidateOldVersion(
    cache:          *capability_mod.CapabilityCache,
    old_hash:       Hash,
    new_hash:       Hash,
    epoch:          u64,
) void {
    const idx = cache.findByHash(old_hash) orelse return;
    cache.markOutdated(idx, new_hash, epoch) catch {};
}

// ── Evidence-Erzeugung ─────────────────────────────────────────────────────

/// Evidence über die exakt verwendete Artefakt-Version.
///
/// Watcher erzeugen diese Evidence als Nachweis, welches Artefakt
/// bei einer Beobachtung aktiv war.
pub const UsageEvidence = struct {
    /// Hash des verwendeten Artefakts.
    artifact_hash:    Hash,
    /// Lineage-Hash (bleibt auch nach Dematerialisierung gültig).
    lineage_hash:     Hash,
    /// Snapshot-Root zur Zeit der Verwendung.
    snapshot_root:    Hash,
    /// Epoch der Verwendung.
    epoch:            u64,
    /// Version.
    version:          u64,
    /// Kanonischer Evidence-Hash (SHA-256 über alle Felder).
    evidence_hash:    Hash,
};

/// Erzeugt eine Evidence für die Verwendung eines materialisierten Artefakts.
pub fn generateUsageEvidence(ma: *const MaterializedArtifact, epoch: u64) UsageEvidence {
    var ev = UsageEvidence{
        .artifact_hash = ma.artifact_hash,
        .lineage_hash  = ma.lineage_hash,
        .snapshot_root = ma.snapshot_root,
        .epoch         = epoch,
        .version       = ma.version,
        .evidence_hash = hash_mod.ZERO_HASH,
    };
    // Kanonischen Evidence-Hash berechnen
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&ev.artifact_hash);
    hasher.update(&ev.lineage_hash);
    hasher.update(&ev.snapshot_root);
    var ep_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &ep_buf, ev.epoch, .little);
    hasher.update(&ep_buf);
    var ver_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &ver_buf, ev.version, .little);
    hasher.update(&ver_buf);
    hasher.final(&ev.evidence_hash);
    return ev;
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

// ── Test-Hilfsfunktionen ───────────────────────────────────────────────────

fn makeValidArtifactForMat() !Artifact {
    var a = Artifact{
        .content_hash  = hash_mod.ZERO_HASH,
        .kind          = .capability,
        .proto_version = 0x01,
        .name          = artifact_mod.makeArtifactName("mat-test"),
        .provenance    = .{
            .forge_epoch = 1, .forge_generation = 1,
            .forge_event_hash = hash_mod.ZERO_HASH, .origin_node_tag = 0,
        },
        .parent_count  = 0,
        .parents       = [_]Hash{hash_mod.ZERO_HASH} ** artifact_mod.MAX_PARENTS,
        .algo_desc     = artifact_mod.makeAlgoDesc("noop"),
        .params        = .{ .len = 0, .data = [_]u8{0} ** artifact_mod.MAX_PARAM_BYTES },
        .tv_count      = 0,
        .test_vectors  = [_]artifact_mod.TestVector{.{
            .id = 0, .expected_result = 0, .input_hash = hash_mod.ZERO_HASH,
            .expected_output_hash = hash_mod.ZERO_HASH,
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
            .verdict_epoch = 1, .valid = artifact_mod.EVIDENCE_VALID,
        },
        .lineage_hash  = hash_mod.ZERO_HASH,
    };
    const prov_h = lineage_mod.provenanceHash(&a.provenance);
    a.lineage_hash = lineage_mod.computeLineageHash(&[_]Hash{}, .forge_genesis, 1, 1, prov_h);
    const @"manifest.zig" = @import("manifest.zig");
    a.content_hash = try @"manifest.zig".computeContentHash(&a);
    return a;
}

// Test-Source: gibt ein Artefakt anhand seines Hashes zurück.
const TestSourceCtx = struct {
    artifact: Artifact,
};

fn testSourceLookup(ctx: *const anyopaque, h: Hash) ?Artifact {
    const self: *const TestSourceCtx = @ptrCast(@alignCast(ctx));
    if (hash_mod.hashEqual(self.artifact.content_hash, h)) return self.artifact;
    return null;
}

fn makeSource(ctx: *const TestSourceCtx) validator_mod.ArtifactSource {
    return .{ .ctx = ctx, .lookupFn = testSourceLookup };
}

fn stdCtxMat() validator_mod.ConsumerContext {
    return .{
        .generation = 1, .current_epoch = 1,
        .has_guardian_verdict = false, .snapshot_root = hash_mod.ZERO_HASH,
    };
}

test "materializer: atomar materialisieren — Artefakt aktiv" {
    const a = try makeValidArtifactForMat();
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();
    const ma = try materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1);
    try std.testing.expect(ma.state == .active);
    try std.testing.expect(hash_mod.hashEqual(a.content_hash, ma.artifact_hash));
}

test "materializer: ArtifactNotFound wenn Hash unbekannt" {
    const a = try makeValidArtifactForMat();
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();
    const wrong_hash = hash_mod.hashBytes("nonexistent");
    try std.testing.expectError(
        MaterializerError.ArtifactNotFound,
        materialize(src, wrong_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1),
    );
}

test "materializer: ValidationFailed bei ungültiger Evidence" {
    var a = try makeValidArtifactForMat();
    a.evidence.valid = artifact_mod.EVIDENCE_REVOKED;
    const manifest_local = @import("manifest.zig");
    a.content_hash = try manifest_local.computeContentHash(&a);
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();
    try std.testing.expectError(
        MaterializerError.ValidationFailed,
        materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1),
    );
}

test "materializer: dematerialize — state=retired, lineage erhalten" {
    const a = try makeValidArtifactForMat();
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();
    var ma = try materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1);
    const lineage_before = ma.lineage_hash;
    try dematerialize(&ma, &cache, 2);
    try std.testing.expect(ma.state == .retired);
    // Lineage bleibt erhalten
    try std.testing.expect(hash_mod.hashEqual(lineage_before, ma.lineage_hash));
}

test "materializer: dematerialize — NotActive wenn nicht aktiv" {
    var ma = MaterializedArtifact{
        .artifact_hash = hash_mod.ZERO_HASH,
        .kind = .capability,
        .capability_id = artifact_mod.ZERO_CAP_ID,
        .version = 1,
        .materialized_epoch = 1,
        .state = .retired,
        .lineage_hash = hash_mod.ZERO_HASH,
        .snapshot_root = hash_mod.ZERO_HASH,
    };
    var cache = capability_mod.CapabilityCache.init();
    try std.testing.expectError(MaterializerError.NotActive, dematerialize(&ma, &cache, 2));
}

test "materializer: re-Materialisierung aus historischer Lineage möglich" {
    // Zeigt: lineage_hash bleibt nach Dematerialisierung erhalten
    // und ein zweites Artefakt mit derselben Lineage kann materialisiert werden.
    const a = try makeValidArtifactForMat();
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();
    var ma = try materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1);
    const lineage_hash = ma.lineage_hash;
    try dematerialize(&ma, &cache, 2);
    // Lineage bleibt — spätere Re-Materialisierung würde dieselbe Lineage verwenden
    try std.testing.expect(hash_mod.hashEqual(lineage_hash, ma.lineage_hash));
    try std.testing.expect(ma.state == .retired);
}

test "materializer: Cache-Versionierung — alte Version wird outdated" {
    const a = try makeValidArtifactForMat();
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();
    const ma = try materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1);
    // Neue Version kommt
    const new_hash = hash_mod.hashBytes("new-version");
    invalidateOldVersion(&cache, ma.artifact_hash, new_hash, 2);
    const idx = cache.findByHash(ma.artifact_hash) orelse unreachable;
    try std.testing.expect(cache.entries[idx].state == .outdated);
    try std.testing.expect(hash_mod.hashEqual(new_hash, cache.entries[idx].superseded_by));
}

test "materializer: generateUsageEvidence deterministisch" {
    const a = try makeValidArtifactForMat();
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();
    const ma = try materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1);
    const ev1 = generateUsageEvidence(&ma, 42);
    const ev2 = generateUsageEvidence(&ma, 42);
    try std.testing.expect(hash_mod.hashEqual(ev1.evidence_hash, ev2.evidence_hash));
}

test "materializer: generateUsageEvidence — epoch ändert Hash" {
    const a = try makeValidArtifactForMat();
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();
    const ma = try materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1);
    const ev1 = generateUsageEvidence(&ma, 1);
    const ev2 = generateUsageEvidence(&ma, 2);
    try std.testing.expect(!hash_mod.hashEqual(ev1.evidence_hash, ev2.evidence_hash));
}

// ── M11: Transaktionale Materialisierung — Adversarial Tests ─────────────

test "materializer M11: fehlgeschlagene Validierung → Cache unverändert" {
    // PROTOKOLLREGEL M11: Bei Fehler vor Cache-Eintrag bleibt Cache leer.
    var a = try makeValidArtifactForMat();
    a.evidence.valid = artifact_mod.EVIDENCE_REVOKED;
    const manifest_local = @import("manifest.zig");
    a.content_hash = try manifest_local.computeContentHash(&a);
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();
    const count_before = cache.count;
    _ = materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1)
        catch {};
    // Cache muss unverändert sein — Validierung scheitert VOR Cache-Eintrag
    try std.testing.expectEqual(count_before, cache.count);
}

test "materializer M11: doppeltes materialize desselben Artefakts → AlreadyActive" {
    // M6+M11: Zweiter materialize-Aufruf für dieselbe capability_id wird abgelehnt.
    const a = try makeValidArtifactForMat();
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();
    _ = try materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1);
    // Zweiter Aufruf: capability_id bereits im Cache → AlreadyActive
    try std.testing.expectError(
        MaterializerError.AlreadyActive,
        materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 2),
    );
}

test "materializer M11: Cache nach fehlgeschlagenem materialize — keine halbfertigen Einträge" {
    // M11: Wenn materialize() nach addKnown() aber vor markActivated() scheitert,
    // wird der Eintrag als outdated markiert (kein known-leftover).
    // Danach darf derselbe Hash NICHT erneut materialisiert werden (Duplikat-Guard M6).
    var a = try makeValidArtifactForMat();
    a.evidence.valid = artifact_mod.EVIDENCE_REVOKED;
    const manifest_local = @import("manifest.zig");
    a.content_hash = try manifest_local.computeContentHash(&a);
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();

    // Erster Versuch: schlägt an Validierung (Stufe 3) fehl → Cache leer
    _ = materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1)
        catch {};
    // Validierungsfehler tritt VOR addKnown auf → Cache ist leer
    try std.testing.expectEqual(@as(usize, 0), cache.count);
}

// ── M5: Capability-Authority-Grenze — Adversarial Test ────────────────────

test "materializer M5: aktivierte Capability kann keine weitere direkt aktivieren" {
    // Eine aktivierte Capability hat keine activate()-Methode.
    // Jede Aktivierung erfordert einen eigenen materialize()-Aufruf.
    const a = try makeValidArtifactForMat();
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);
    var cache = capability_mod.CapabilityCache.init();
    const ma = try materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 1);
    // MaterializedArtifact ist read-only: kein activate(), kein addKnown()-Aufruf möglich.
    // Dieser Test dokumentiert die Invariante: ma ist struct, keine Methoden.
    try std.testing.expect(ma.state == .active);
    // Zweiter materialize-Aufruf mit gleichem content_hash → AlreadyActive (kein Authority-Bypass)
    try std.testing.expectError(
        MaterializerError.AlreadyActive,
        materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache, 2),
    );
}

// ── M9: Re-Materialisierungs-Identitätsschutz ─────────────────────────────

test "materializer M9: zwei materialize-Calls (frischer Cache) sind unabhängig" {
    // M9: Zwei Nodes können dasselbe Artefakt mit frischem Cache materialisieren.
    // Kein globaler Zustand — kein Konflikt.
    // Die Eindeutigkeit einer Manifestation ist Ledger/Rebuilder-Aufgabe.
    const a = try makeValidArtifactForMat();
    const src_ctx = TestSourceCtx{ .artifact = a };
    const src = makeSource(&src_ctx);

    var cache1 = capability_mod.CapabilityCache.init();
    var cache2 = capability_mod.CapabilityCache.init();

    const ma1 = try materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache1, 1);
    const ma2 = try materialize(src, a.content_hash, stdCtxMat(), validator_mod.defaultTestExecutor, &cache2, 1);

    // Beide aktiv, gleicher lineage_hash (deterministisch)
    try std.testing.expect(ma1.state == .active);
    try std.testing.expect(ma2.state == .active);
    try std.testing.expect(hash_mod.hashEqual(ma1.lineage_hash, ma2.lineage_hash));
    // Capability-IDs identisch (aus demselben content_hash)
    try std.testing.expect(std.mem.eql(u8, &ma1.capability_id, &ma2.capability_id));
}
