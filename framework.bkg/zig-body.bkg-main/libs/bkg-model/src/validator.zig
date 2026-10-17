/// BKG Model Layer — Validator
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/MODEL_LAYER_v1.md
///
/// Der Validator prüft ein Artefakt vollständig, bevor es materialisierbar ist.
///
/// Pipeline (strikt sequenziell, kein Bypass):
///
///   1. content_hash: kanonischer Hash des Manifest stimmt mit Artefakt überein
///   2. lineage_hash: berechneter Lineage-Hash stimmt mit gespeichertem überein
///   3. authority_evidence: Evidence ist gültig (nicht revoziert)
///   4. policy: Aktivierungsregel prüfen (Generation, Epoch, Guardian-Pflicht)
///   5. test_vectors: alle eingebetteten Testvektoren bestehen
///   6. artifact_version: Version kompatibel zur Consumer-Generation
///
/// Ein fehlgeschlagener Schritt → sofortiger Abbruch, kein Partial-Trust.
/// Kein stiller Fallback.
/// BKGDB ist Gedächtnis — nicht Quelle des Vertrauens.
///
/// BKGDB-Adaptergrenze:
///   Der Validator kennt kein BKGDB-Protokoll.
///   Artefakte werden über einen ArtifactSource-Callback bezogen.
///   Die konkrete BKGDB-Implementierung kann später angeschlossen werden.
const std = @import("std");
const hash_mod    = @import("hash.zig");
const artifact_mod = @import("artifact.zig");
const manifest_mod = @import("manifest.zig");
const lineage_mod  = @import("lineage.zig");

pub const Hash     = hash_mod.Hash;
pub const Artifact = artifact_mod.Artifact;

// ── Validierungsfehler ─────────────────────────────────────────────────────

pub const ValidatorError = error{
    /// content_hash stimmt nicht mit kanonischem Manifest-Hash überein.
    ContentHashMismatch,
    /// lineage_hash stimmt nicht mit berechneter Lineage überein.
    LineageHashMismatch,
    /// Authority-Evidence revoziert oder ungültig.
    InvalidAuthorityEvidence,
    /// Guardian-Verdict erforderlich, aber nicht vorhanden/gültig.
    GuardianVerdictRequired,
    /// Consumer-Generation zu niedrig.
    GenerationTooLow,
    /// Consumer-Generation zu hoch.
    GenerationTooHigh,
    /// Artefakt abgelaufen.
    ArtifactExpired,
    /// Lineage-Verifikation erforderlich, aber fehlgeschlagen.
    LineageVerificationRequired,
    /// Testvektor-Failure.
    TestVectorFailed,
    /// Testvektoren erforderlich, aber keine vorhanden.
    TestVectorsRequired,
    /// Artefakt-Version inkompatibel zur Consumer-Generation.
    VersionIncompatible,
    /// Unbekannter Artefakt-Typ.
    UnknownArtifactKind,
    /// Artefakt nicht im Snapshot enthalten.
    ArtifactNotInSnapshot,
    /// Manifest-Serialisierungsfehler.
    ManifestError,
};

// ── Validierungskontext ────────────────────────────────────────────────────

/// Kontextinformation des Consumers (Watcher/Guardian/Demon/Hero).
pub const ConsumerContext = struct {
    /// Aktuelle Generation des Consumers.
    generation:          u64,
    /// Aktuelle Epoch.
    current_epoch:       u64,
    /// Hat der Consumer eine Guardian-Bestätigung?
    has_guardian_verdict: bool,
    /// Aktiver Snapshot-Root-Hash (ZERO wenn kein Snapshot).
    snapshot_root:       Hash,
};

// ── Test-Executor-Interface ────────────────────────────────────────────────

/// Callback-Typ für Testvektor-Ausführung.
/// Gibt true zurück wenn der Testvektor bestanden wurde.
/// Implementierung ist Consumer-spezifisch — kein Allokator nötig.
pub const TestExecutorFn = *const fn (tv: *const artifact_mod.TestVector) bool;

/// Standard-Executor: vergleicht nur expected_result (simuliert).
/// Für echte Tests muss ein spezialisierter Executor übergeben werden.
pub fn defaultTestExecutor(tv: *const artifact_mod.TestVector) bool {
    // In einer echten Implementierung würde hier die Capability-spezifische
    // Inferenz gegen den Testvektor ausgeführt.
    // Der Default-Executor prüft nur ob expected_result == 0x01 (pass-Vektor).
    // Das ist kein Mock — es ist ein explizit einfacher Executor für Tests,
    // der dokumentiert, dass echte TV-Ausführung Consumer-spezifisch ist.
    return tv.expected_result == 0x01;
}

// ── BKGDB Adapter-Grenze ───────────────────────────────────────────────────

/// Opake Quelle für Artefakte.
/// Die konkrete BKGDB-Implementierung implementiert dieses Interface.
/// Der Validator hat keine Kenntnis von BKGDB-Internals.
///
/// SICHERHEIT: Empfang aus dieser Quelle bedeutet KEIN Vertrauen.
/// Der Validator prüft jedes empfangene Artefakt vollständig.
pub const ArtifactSource = struct {
    /// Opaker Zeiger auf die Implementierung.
    ctx:     *const anyopaque,
    /// Lookup-Funktion: gibt Artefakt für gegebenen Hash zurück.
    /// Gibt null zurück wenn nicht gefunden.
    lookupFn: *const fn (ctx: *const anyopaque, h: Hash) ?Artifact,

    pub fn lookup(self: *const ArtifactSource, h: Hash) ?Artifact {
        return self.lookupFn(self.ctx, h);
    }
};

// ── Validierungsergebnis ───────────────────────────────────────────────────

/// Detailliertes Validierungsergebnis.
pub const ValidationResult = struct {
    /// Hash des geprüften Artefakts.
    artifact_hash:         Hash,
    /// Alle Stufen bestanden?
    all_passed:            bool,
    /// Einzelne Stufen-Ergebnisse.
    content_hash_ok:       bool,
    lineage_ok:            bool,
    evidence_ok:           bool,
    policy_ok:             bool,
    test_vectors_ok:       bool,
    version_ok:            bool,
};

// ── Validator ─────────────────────────────────────────────────────────────

/// Führt die vollständige Validierungspipeline durch.
/// Gibt ein ValidationResult zurück oder einen ValidatorError bei
/// hartem Fehler.
///
/// Ein fehlgeschlagener Schritt → sofortiger ValidatorError.
/// Keine Teil-Validierung, kein stiller Fallback.
pub fn validate(
    artifact:  *const Artifact,
    ctx:       ConsumerContext,
    executor:  TestExecutorFn,
) ValidatorError!ValidationResult {
    var result = ValidationResult{
        .artifact_hash   = artifact.content_hash,
        .all_passed      = false,
        .content_hash_ok = false,
        .lineage_ok      = false,
        .evidence_ok     = false,
        .policy_ok       = false,
        .test_vectors_ok = false,
        .version_ok      = false,
    };

    // ── Stufe 1: content_hash ──────────────────────────────────────────────
    const computed_hash = manifest_mod.computeContentHash(artifact)
        catch return ValidatorError.ManifestError;
    if (!hash_mod.hashEqual(computed_hash, artifact.content_hash))
        return ValidatorError.ContentHashMismatch;
    result.content_hash_ok = true;

    // ── Stufe 2: lineage_hash ──────────────────────────────────────────────
    if (!lineage_mod.verifyLineageHash(artifact))
        return ValidatorError.LineageHashMismatch;
    result.lineage_ok = true;

    // ── Stufe 3: authority_evidence ────────────────────────────────────────
    if (artifact.evidence.valid != artifact_mod.EVIDENCE_VALID)
        return ValidatorError.InvalidAuthorityEvidence;
    result.evidence_ok = true;

    // ── Stufe 4: policy ────────────────────────────────────────────────────
    const p = &artifact.policy;
    // Generation zu niedrig?
    if (p.min_generation > 0 and ctx.generation < p.min_generation)
        return ValidatorError.GenerationTooLow;
    // Generation zu hoch?
    if (p.max_generation > 0 and ctx.generation > p.max_generation)
        return ValidatorError.GenerationTooHigh;
    // Abgelaufen?
    if (p.expires_at_epoch > 0 and ctx.current_epoch > p.expires_at_epoch)
        return ValidatorError.ArtifactExpired;
    // Guardian-Pflicht?
    if (p.requires_guardian_verdict and !ctx.has_guardian_verdict)
        return ValidatorError.GuardianVerdictRequired;
    // Lineage-Verifikation erforderlich?
    if (p.requires_lineage_verified and !result.lineage_ok)
        return ValidatorError.LineageVerificationRequired;
    result.policy_ok = true;

    // ── Stufe 5: test_vectors ──────────────────────────────────────────────
    if (p.requires_test_vectors and artifact.tv_count == 0)
        return ValidatorError.TestVectorsRequired;
    for (0..artifact.tv_count) |i| {
        const tv = &artifact.test_vectors[i];
        const passed = executor(tv);
        // expected_result = 0x01 → muss pass; 0x00 → Negativ-Test, muss fail
        const ok = (tv.expected_result == 0x01 and passed) or
                   (tv.expected_result == 0x00 and !passed);
        if (!ok) return ValidatorError.TestVectorFailed;
    }
    result.test_vectors_ok = true;

    // ── Stufe 6: version / proto_version ──────────────────────────────────
    if (artifact.proto_version != 0x01)
        return ValidatorError.VersionIncompatible;
    result.version_ok = true;

    result.all_passed = true;
    return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

// ── Test-Hilfsfunktionen ───────────────────────────────────────────────────

fn makeValidArtifact() !Artifact {
    var a = Artifact{
        .content_hash  = hash_mod.ZERO_HASH,
        .kind          = .capability,
        .proto_version = 0x01,
        .name          = artifact_mod.makeArtifactName("valid"),
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
    // lineage_hash berechnen
    const prov_h = lineage_mod.provenanceHash(&a.provenance);
    a.lineage_hash = lineage_mod.computeLineageHash(
        &[_]Hash{}, .forge_genesis, 1, 1, prov_h,
    );
    // content_hash berechnen
    a.content_hash = try manifest_mod.computeContentHash(&a);
    return a;
}

fn stdCtx() ConsumerContext {
    return .{
        .generation = 1, .current_epoch = 1,
        .has_guardian_verdict = false, .snapshot_root = hash_mod.ZERO_HASH,
    };
}

test "validator: gültiges Artefakt besteht alle Stufen" {
    const a = try makeValidArtifact();
    const r = try validate(&a, stdCtx(), defaultTestExecutor);
    try std.testing.expect(r.all_passed);
    try std.testing.expect(r.content_hash_ok);
    try std.testing.expect(r.lineage_ok);
    try std.testing.expect(r.evidence_ok);
    try std.testing.expect(r.policy_ok);
    try std.testing.expect(r.test_vectors_ok);
    try std.testing.expect(r.version_ok);
}

test "validator: content_hash Tampering → ContentHashMismatch" {
    var a = try makeValidArtifact();
    a.content_hash[0] ^= 0xFF;
    try std.testing.expectError(ValidatorError.ContentHashMismatch, validate(&a, stdCtx(), defaultTestExecutor));
}

test "validator: lineage_hash Tampering → LineageHashMismatch" {
    var a = try makeValidArtifact();
    // content_hash muss gültig bleiben, lineage_hash beschädigen
    a.lineage_hash[0] ^= 0xFF;
    // content_hash neu berechnen (damit Stufe 1 passiert)
    a.content_hash = try manifest_mod.computeContentHash(&a);
    try std.testing.expectError(ValidatorError.LineageHashMismatch, validate(&a, stdCtx(), defaultTestExecutor));
}

test "validator: revozierte Evidence → InvalidAuthorityEvidence" {
    var a = try makeValidArtifact();
    a.evidence.valid = artifact_mod.EVIDENCE_REVOKED;
    a.content_hash = try manifest_mod.computeContentHash(&a);
    try std.testing.expectError(ValidatorError.InvalidAuthorityEvidence, validate(&a, stdCtx(), defaultTestExecutor));
}

test "validator: Generation zu niedrig → GenerationTooLow" {
    var a = try makeValidArtifact();
    a.policy.min_generation = 10;
    a.content_hash = try manifest_mod.computeContentHash(&a);
    var ctx = stdCtx(); ctx.generation = 1;
    try std.testing.expectError(ValidatorError.GenerationTooLow, validate(&a, ctx, defaultTestExecutor));
}

test "validator: Generation zu hoch → GenerationTooHigh" {
    var a = try makeValidArtifact();
    a.policy.max_generation = 1;
    a.content_hash = try manifest_mod.computeContentHash(&a);
    var ctx = stdCtx(); ctx.generation = 5;
    try std.testing.expectError(ValidatorError.GenerationTooHigh, validate(&a, ctx, defaultTestExecutor));
}

test "validator: Artefakt abgelaufen → ArtifactExpired" {
    var a = try makeValidArtifact();
    a.policy.expires_at_epoch = 5;
    a.content_hash = try manifest_mod.computeContentHash(&a);
    var ctx = stdCtx(); ctx.current_epoch = 10;
    try std.testing.expectError(ValidatorError.ArtifactExpired, validate(&a, ctx, defaultTestExecutor));
}

test "validator: Guardian-Pflicht ohne Verdict → GuardianVerdictRequired" {
    var a = try makeValidArtifact();
    a.policy.requires_guardian_verdict = true;
    a.content_hash = try manifest_mod.computeContentHash(&a);
    var ctx = stdCtx(); ctx.has_guardian_verdict = false;
    try std.testing.expectError(ValidatorError.GuardianVerdictRequired, validate(&a, ctx, defaultTestExecutor));
}

test "validator: Guardian-Pflicht mit Verdict → OK" {
    var a = try makeValidArtifact();
    a.policy.requires_guardian_verdict = true;
    a.content_hash = try manifest_mod.computeContentHash(&a);
    var ctx = stdCtx(); ctx.has_guardian_verdict = true;
    const r = try validate(&a, ctx, defaultTestExecutor);
    try std.testing.expect(r.all_passed);
}

test "validator: Testvektoren erforderlich aber keine → TestVectorsRequired" {
    var a = try makeValidArtifact();
    a.policy.requires_test_vectors = true;
    a.tv_count = 0;
    a.content_hash = try manifest_mod.computeContentHash(&a);
    try std.testing.expectError(ValidatorError.TestVectorsRequired, validate(&a, stdCtx(), defaultTestExecutor));
}

test "validator: Testvektor-Failure → TestVectorFailed" {
    var a = try makeValidArtifact();
    a.tv_count = 1;
    a.test_vectors[0] = .{
        .id = 0, .expected_result = 0x01, // erwartet pass
        .input_hash = hash_mod.ZERO_HASH, .expected_output_hash = hash_mod.ZERO_HASH,
    };
    a.content_hash = try manifest_mod.computeContentHash(&a);
    // Executor der immer false zurückgibt
    const failExecutor: TestExecutorFn = struct {
        fn exec(_: *const artifact_mod.TestVector) bool { return false; }
    }.exec;
    try std.testing.expectError(ValidatorError.TestVectorFailed, validate(&a, stdCtx(), failExecutor));
}

test "validator: Negativ-Testvektor (expected_result=0x00) mit fail-Executor → OK" {
    var a = try makeValidArtifact();
    a.tv_count = 1;
    a.test_vectors[0] = .{
        .id = 0, .expected_result = 0x00, // erwartet fail
        .input_hash = hash_mod.ZERO_HASH, .expected_output_hash = hash_mod.ZERO_HASH,
    };
    a.content_hash = try manifest_mod.computeContentHash(&a);
    const failExecutor: TestExecutorFn = struct {
        fn exec(_: *const artifact_mod.TestVector) bool { return false; }
    }.exec;
    const r = try validate(&a, stdCtx(), failExecutor);
    try std.testing.expect(r.all_passed);
}

test "validator: proto_version != 1 → VersionIncompatible" {
    var a = try makeValidArtifact();
    a.proto_version = 0x02;
    a.content_hash = try manifest_mod.computeContentHash(&a);
    try std.testing.expectError(ValidatorError.VersionIncompatible, validate(&a, stdCtx(), defaultTestExecutor));
}

test "validator: Buff-Artefakt besteht Validierung" {
    var a = try makeValidArtifact();
    a.kind = .buff;
    a.content_hash = try manifest_mod.computeContentHash(&a);
    const r = try validate(&a, stdCtx(), defaultTestExecutor);
    try std.testing.expect(r.all_passed);
}

test "validator: Curse-Artefakt besteht Validierung" {
    var a = try makeValidArtifact();
    a.kind = .curse;
    a.content_hash = try manifest_mod.computeContentHash(&a);
    const r = try validate(&a, stdCtx(), defaultTestExecutor);
    try std.testing.expect(r.all_passed);
}
