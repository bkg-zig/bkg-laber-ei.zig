/// BKG Model Layer — Artefakt-Typen
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/MODEL_LAYER_v1.md
///
/// Ein `.bkg`-Artefakt ist kein beliebiger Blob und kein ausführbarer Fremdcode.
/// Es beschreibt eine portable, versionierte BKG-Fähigkeit mit vollständiger
/// Verifikationskette: Hash → Lineage → Authority-Evidence → Capability → Policy.
///
/// Alle Strukturen sind:
///   - Pointer-frei
///   - Deterministisch serialisierbar (kein HashMap-Reihenfolge-Problem)
///   - Ohne implizite Struct-Layouts (alle Felder explizit)
///   - Maximal-begrenzt (keine unbeschränkten Slices)
const std = @import("std");
const hash_mod = @import("hash.zig");

pub const Hash = hash_mod.Hash;
pub const ZERO_HASH = hash_mod.ZERO_HASH;
pub const MAX_PARENTS = hash_mod.MAX_PARENTS;
pub const MAX_TEST_VECTORS = hash_mod.MAX_TEST_VECTORS;
pub const MAX_CAPABILITIES = hash_mod.MAX_CAPABILITIES;
pub const MAX_PARAM_BYTES = hash_mod.MAX_PARAM_BYTES;
pub const MAX_NAME_LEN = hash_mod.MAX_NAME_LEN;
pub const MAX_ALGO_DESC_LEN = hash_mod.MAX_ALGO_DESC_LEN;

// ── Artefakt-Typ ───────────────────────────────────────────────────────────

/// Typ eines `.bkg`-Artefakts.
/// Kein catch-all "Unknown" — unbekannte Typen werden abgelehnt.
pub const ArtifactKind = enum(u8) {
    /// Allgemeine Wissensfähigkeit (Inference, Erkennung, etc.)
    capability     = 0x01,
    /// Buff: erweitert eine bestehende Capability
    buff           = 0x02,
    /// Curse: begrenzt oder blockiert Capability / Evolutionspfad
    curse          = 0x03,
    /// Spore-Kandidat: noch nicht vollständig verifiziert
    spore_candidate = 0x04,
    /// Evolution-Gate: Bedingung für einen Evolutionsschritt
    evolution_gate = 0x05,
    /// Policy: steuert Aktivierungsregeln
    policy         = 0x06,
    /// Snapshot-Referenz: zeigt auf einen verifizierten KnowledgeSnapshot
    snapshot_ref   = 0x07,
};

// ── Capability-ID ──────────────────────────────────────────────────────────

/// Opaker 16-Byte Capability-Bezeichner (CID-ähnlich, aus Hash abgeleitet).
pub const CapabilityId = [16]u8;
pub const ZERO_CAP_ID: CapabilityId = [_]u8{0x00} ** 16;

/// Leitet eine CapabilityId aus einem Hash ab (erste 16 Bytes).
pub fn capIdFromHash(h: Hash) CapabilityId {
    var id: CapabilityId = undefined;
    @memcpy(&id, h[0..16]);
    return id;
}

// ── Provenance ─────────────────────────────────────────────────────────────

/// Herkunfts-Beschreibung eines Artefakts.
pub const Provenance = struct {
    /// Forge-Epoche, in der das Artefakt erzeugt wurde.
    forge_epoch:    u64,
    /// Generation des erzeugenden Agenten.
    forge_generation: u64,
    /// Hash des Forge-Autorität-Events (kann ZERO sein bei Genesis).
    forge_event_hash: Hash,
    /// Optional: Node-ID des Forge-Ursprungs (opak, nicht-identifizierend).
    origin_node_tag: u32,
};

// ── Testvektor ─────────────────────────────────────────────────────────────

/// Ein einzelner eingebetteter Testvektor für Capability-Validierung.
/// Input + erwarteter Output sind fix-size Byte-Arrays (kein Heap).
pub const MAX_TV_IO_SIZE: usize = 128;

pub const TestVector = struct {
    /// Kennung dieses Testvektors innerhalb des Artefakts.
    id:              u8,
    /// Erwartetes Ergebnis: 0x01 = pass, 0x00 = fail (negativ-Test).
    expected_result: u8,
    /// Kanonischer SHA-256 Hash des Input-Byte-Arrays.
    input_hash:      Hash,
    /// Kanonischer SHA-256 Hash des erwarteten Output-Byte-Arrays.
    expected_output_hash: Hash,
};

// ── Benchmark-Claim ────────────────────────────────────────────────────────

pub const BenchmarkClaim = struct {
    /// Typ des Benchmarks (opak, interpretiert durch den Validator).
    kind:          u8,
    /// Beanspruchte Performance-Metrik (Einheit: Anwendungsabhängig).
    claimed_value: u64,
    /// Epoch bei der Messung.
    measured_at_epoch: u64,
};

// ── Aktivierungsregel ──────────────────────────────────────────────────────

/// Policy-Schalter für die Capability-Aktivierung.
pub const ActivationPolicy = struct {
    /// Minimale Generation des Consumers (0 = keine Beschränkung).
    min_generation:          u64,
    /// Maximale Generation des Consumers (0 = keine Beschränkung).
    max_generation:          u64,
    /// Muss der Consumer eine Guardian-Bestätigung vorweisen?
    requires_guardian_verdict: bool,
    /// Ist das Artefakt nach Ablauf dieser Epoch ungültig? (0 = kein Ablauf)
    expires_at_epoch:        u64,
    /// Muss die Lineage verifiziert sein?
    requires_lineage_verified: bool,
    /// Muss mindestens ein Testvektor erfolgreich sein?
    requires_test_vectors:   bool,
};

// ── Parameter-Block ────────────────────────────────────────────────────────

/// Fester Parameter-Blob (kein Heap, kein Pointer).
pub const ParamBlock = struct {
    len:  u16,
    data: [MAX_PARAM_BYTES]u8,

    pub fn slice(self: *const ParamBlock) []const u8 {
        return self.data[0..self.len];
    }
};

// ── Algorithmus-Beschreibung ───────────────────────────────────────────────

pub const AlgoDesc = struct {
    len:  u8,
    data: [MAX_ALGO_DESC_LEN]u8,

    pub fn slice(self: *const AlgoDesc) []const u8 {
        return self.data[0..self.len];
    }
};

// ── Artefakt-Name ──────────────────────────────────────────────────────────

pub const ArtifactName = struct {
    len:  u8,
    data: [MAX_NAME_LEN]u8,

    pub fn slice(self: *const ArtifactName) []const u8 {
        return self.data[0..self.len];
    }
};

pub fn makeArtifactName(s: []const u8) ArtifactName {
    var n = ArtifactName{ .len = 0, .data = [_]u8{0} ** MAX_NAME_LEN };
    const copy_len = @min(s.len, MAX_NAME_LEN);
    @memcpy(n.data[0..copy_len], s[0..copy_len]);
    n.len = @intCast(copy_len);
    return n;
}

pub fn makeAlgoDesc(s: []const u8) AlgoDesc {
    var d = AlgoDesc{ .len = 0, .data = [_]u8{0} ** MAX_ALGO_DESC_LEN };
    const copy_len = @min(s.len, MAX_ALGO_DESC_LEN);
    @memcpy(d.data[0..copy_len], s[0..copy_len]);
    d.len = @intCast(copy_len);
    return d;
}

// ── Authority Evidence ─────────────────────────────────────────────────────

/// Kompakte Authority-Evidence: Hash + Guardian-Signatur-Commitment.
/// Kein echter Signaturpfad hier — das ist eine Referenz auf ein Ledger-Event.
pub const AuthorityEvidence = struct {
    /// Hash des authorisierenden Ledger-Events (Guardian-Verdict o.ä.).
    ledger_event_hash: Hash,
    /// Guardian-Öffentlichschlüssel-Hash (opak).
    guardian_pubkey_hash: Hash,
    /// Epoch des Verdicts.
    verdict_epoch: u64,
    /// Ist diese Evidence gültig (0x01) oder revoziert (0x00)?
    valid: u8,
};

pub const EVIDENCE_VALID: u8   = 0x01;
pub const EVIDENCE_REVOKED: u8 = 0x00;

// ── Haupt-Artefakt-Struktur ────────────────────────────────────────────────

/// Ein vollständiges `.bkg`-Artefakt.
///
/// Pointer-frei. Deterministisch. Alle Arrays sind fix-size.
/// Der content_hash MUSS mit dem kanonischen Hash des Manifest-Serialisierungs-
/// Inputs übereinstimmen (wird durch Validator geprüft).
pub const Artifact = struct {
    /// Kanonischer Content-Hash dieses Artefakts (SHA-256 über Manifest).
    content_hash:   Hash,
    /// Artefakt-Typ.
    kind:           ArtifactKind,
    /// Protokollversion (aktuell 0x01).
    proto_version:  u8,
    /// Artefakt-Name (menschenlesbar, nicht eindeutig).
    name:           ArtifactName,
    /// Provenance-Daten.
    provenance:     Provenance,
    /// Direkte Parent-Artefakt-Hashes (geordnet, deterministisch).
    parent_count:   u8,
    parents:        [MAX_PARENTS]Hash,
    /// Algorithmus-Beschreibung (semantisch, nicht ausführbar).
    algo_desc:      AlgoDesc,
    /// Parameter-Block (opak für den Model Layer).
    params:         ParamBlock,
    /// Eingebettete Testvektoren.
    tv_count:       u8,
    test_vectors:   [MAX_TEST_VECTORS]TestVector,
    /// Benchmark-Claims.
    bench_count:    u8,
    bench_claims:   [3]BenchmarkClaim,
    /// Aktivierungs-Policy.
    policy:         ActivationPolicy,
    /// Authority-Evidence (ein primäres Guardian-Verdict).
    evidence:       AuthorityEvidence,
    /// Lineage-Hash (kanonisch aus Parents berechnet, nicht selbst-deklariert).
    lineage_hash:   Hash,
};

// ── Hilfsfunktionen ────────────────────────────────────────────────────────

/// Gibt die Parent-Hashes als Slice zurück.
pub fn artifactParents(a: *const Artifact) []const Hash {
    return a.parents[0..a.parent_count];
}

/// Gibt Testvektoren als Slice zurück.
pub fn artifactTestVectors(a: *const Artifact) []const TestVector {
    return a.test_vectors[0..a.tv_count];
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

fn zeroProvenance() Provenance {
    return .{
        .forge_epoch      = 1_000,
        .forge_generation = 1,
        .forge_event_hash = ZERO_HASH,
        .origin_node_tag  = 0,
    };
}

fn zeroPolicy() ActivationPolicy {
    return .{
        .min_generation          = 0,
        .max_generation          = 0,
        .requires_guardian_verdict = false,
        .expires_at_epoch        = 0,
        .requires_lineage_verified = false,
        .requires_test_vectors   = false,
    };
}

fn zeroEvidence() AuthorityEvidence {
    return .{
        .ledger_event_hash   = ZERO_HASH,
        .guardian_pubkey_hash = ZERO_HASH,
        .verdict_epoch       = 0,
        .valid               = EVIDENCE_VALID,
    };
}

fn makeTestArtifact(ch: Hash, kind: ArtifactKind) Artifact {
    return Artifact{
        .content_hash  = ch,
        .kind          = kind,
        .proto_version = 0x01,
        .name          = makeArtifactName("test-artifact"),
        .provenance    = zeroProvenance(),
        .parent_count  = 0,
        .parents       = [_]Hash{ZERO_HASH} ** MAX_PARENTS,
        .algo_desc     = makeAlgoDesc("noop"),
        .params        = ParamBlock{ .len = 0, .data = [_]u8{0} ** MAX_PARAM_BYTES },
        .tv_count      = 0,
        .test_vectors  = [_]TestVector{.{
            .id = 0, .expected_result = 0,
            .input_hash = ZERO_HASH, .expected_output_hash = ZERO_HASH,
        }} ** MAX_TEST_VECTORS,
        .bench_count   = 0,
        .bench_claims  = [_]BenchmarkClaim{.{
            .kind = 0, .claimed_value = 0, .measured_at_epoch = 0,
        }} ** 3,
        .policy        = zeroPolicy(),
        .evidence      = zeroEvidence(),
        .lineage_hash  = ZERO_HASH,
    };
}

test "artifact: kind enum Werte eindeutig" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(ArtifactKind.capability));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(ArtifactKind.buff));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(ArtifactKind.curse));
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(ArtifactKind.spore_candidate));
}

test "artifact: makeArtifactName kürzt auf MAX_NAME_LEN" {
    const long = "x" ** (MAX_NAME_LEN + 10);
    const n = makeArtifactName(long);
    try std.testing.expectEqual(@as(u8, MAX_NAME_LEN), n.len);
}

test "artifact: makeArtifactName kurzer String" {
    const n = makeArtifactName("hello");
    try std.testing.expectEqual(@as(u8, 5), n.len);
    try std.testing.expectEqualSlices(u8, "hello", n.slice());
}

test "artifact: ParamBlock slice korrekt" {
    var pb = ParamBlock{ .len = 3, .data = [_]u8{0} ** MAX_PARAM_BYTES };
    pb.data[0] = 0xAA; pb.data[1] = 0xBB; pb.data[2] = 0xCC;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, pb.slice());
}

test "artifact: capIdFromHash nimmt erste 16 Bytes" {
    var h: Hash = ZERO_HASH;
    h[0] = 0x42;
    const id = capIdFromHash(h);
    try std.testing.expectEqual(@as(u8, 0x42), id[0]);
    try std.testing.expectEqual(@as(u8, 0x00), id[1]);
}

test "artifact: artifactParents — leere Liste" {
    const a = makeTestArtifact(ZERO_HASH, .capability);
    try std.testing.expectEqual(@as(usize, 0), artifactParents(&a).len);
}

test "artifact: artifactParents — zwei Eltern" {
    var a = makeTestArtifact(ZERO_HASH, .capability);
    a.parent_count = 2;
    a.parents[0] = hash_mod.hashBytes("p1");
    a.parents[1] = hash_mod.hashBytes("p2");
    try std.testing.expectEqual(@as(usize, 2), artifactParents(&a).len);
}

test "artifact: buff und curse sind gültige kinds" {
    const b = makeTestArtifact(ZERO_HASH, .buff);
    const c = makeTestArtifact(ZERO_HASH, .curse);
    try std.testing.expect(b.kind == .buff);
    try std.testing.expect(c.kind == .curse);
}

test "artifact: AuthorityEvidence valid/revoked Konstanten" {
    try std.testing.expectEqual(@as(u8, 0x01), EVIDENCE_VALID);
    try std.testing.expectEqual(@as(u8, 0x00), EVIDENCE_REVOKED);
}

test "artifact: TestVector Struktur" {
    const tv = TestVector{
        .id = 1,
        .expected_result = 0x01,
        .input_hash  = hash_mod.hashBytes("input"),
        .expected_output_hash = hash_mod.hashBytes("output"),
    };
    try std.testing.expectEqual(@as(u8, 1), tv.id);
    try std.testing.expectEqual(@as(u8, 0x01), tv.expected_result);
}
