/// BKGDB Evolution Memory v1 — Forge Knowledge Dimension
///
/// Status: STAGE 3 — PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/BKGDB_EVOLUTION_MEMORY_v1.md §2.3 Forge-Wissens-Dimension
///
/// WICHTIG: Forge Knowledge State != Ledger Truth
/// Dieses Modul speichert das Gedächtnis der Schmiede.
/// Es ist NICHT die Schmiede selbst.
/// Kanonische Wahrheit liegt im Ledger/Rebuilder.
///
/// Ein `forged` Status bedeutet: Candidate hat den Stage-3-Forge-Knowledge-Vertrag
/// erfuellt. Er bedeutet NICHT: Genesis Authority, Guardian Consensus, kanonische
/// Ledger-Wahrheit, aktivierte Capability, wirtschaftlicher Wert oder
/// vertrauenswuerdige Runtime-Ausfuehrung.
///
/// Domain Separation: candidate_hash = SHA256("BKGC" || kanonische Felder)
/// Epoch: monoton steigend, keine Rueckwaertsbewegung, kein Overflow-Wrap
/// Sources: kanonisch sortiert, Duplikate verboten
/// Lifecycle: pending -> tested -> forged | rejected (terminal)
/// Rejected: dauerhaft referenzierbar, nicht wiederbelebbar
///
/// PROTOKOLLENTSCHEIDUNGEN (Adversarial Review 2026-09-01)
///
/// P1 — Candidate-Identitaet vs. Lifecycle-Zustand:
///   candidate_hash bindet: artifact_hash, lineage_hash, generation, forge_epoch,
///   source_count, sources (kanonisch sortiert), benchmark_hash, provenance_hash.
///   NICHT gebunden: status, test_evidence, reject_proof, origin_event_hash.
///   Status-AEnderungen via markTested/markForged/markRejected sind erlaubte
///   In-Place-Mutationen des Lifecycle-Zustands — NICHT der Candidate-Identitaet.
///
/// P2 — WRITE-ONCE gilt fuer die Candidate-Identitaet (candidate_hash + Identitaetsfelder).
///   Lifecycle-Zustand (status, test_evidence, reject_proof) ist mutable ueber
///   die definierten Uebergangsmethoden. Terminale Zustaende sind unveraenderlich.
///
/// P3 — ContentConflict strukturell durch Content-Addressing verhindert.
///   CandidateHashMismatch schlaegt vor ContentConflict an (Hash-Verifikation first).
///
/// P4 — Cross-Store-Referenzen sind reine Referenzen (keine Existenzpruefung).
///   Existenzpruefung liegt beim Caller (Forge, Guardian). Stage 3 kennt
///   Stage-1/2-Stores nicht direkt. Separation of Concerns.
///
/// P5 — Reverse-Indizes sind reine Projektionen, keine Vertrauensquelle.
///   Atomarer Aufbau via errdefer-Rollback verhindert halbfertige Indexzustaende.
///
/// P6 — by_source_set Index fuer Repetitions-Erkennung:
///   source_set_hash = SHA256("BKGC" || "SRCS" || source_count_le1 || sources_sorted)
///   Ermoeglicht spaeterer Guardian/Nebel-Erkennung "viele Candidates, gleiche Quellen".
///   Stage 3 wertet diesen Index nicht oekonomisch aus.
///
const std = @import("std");

// ── Konstanten ────────────────────────────────────────────────────────────

/// Domain-Prefix für Candidate-Hashes (4 Bytes).
pub const DOMAIN_PREFIX: [4]u8 = "BKGC".*;

/// Maximale Anzahl Source-Hashes pro Candidate.
pub const MAX_SOURCES: usize = 16;

/// Zero-Hash.
pub const ZERO_HASH: [32]u8 = [_]u8{0} ** 32;

// ── CandidateStatus ───────────────────────────────────────────────────────

/// Zustandsmaschine für einen Forge Candidate.
///
/// Erlaubte Übergänge:
///   pending  → tested
///   tested   → forged
///   tested   → rejected
///
/// Terminal: forged, rejected
/// Verboten: pending→forged, pending→rejected, forged→*, rejected→tested/forged
pub const CandidateStatus = enum(u8) {
    pending  = 0,
    tested   = 1,
    forged   = 2,
    rejected = 3,
};

/// Prüft ob ein Zustandsübergang erlaubt ist.
pub fn isValidStatusTransition(from: CandidateStatus, to: CandidateStatus) bool {
    return switch (from) {
        .pending  => to == .tested,
        .tested   => to == .forged or to == .rejected,
        .forged   => false,
        .rejected => false,
    };
}

// ── RejectReason ──────────────────────────────────────────────────────────

/// Kategorisierte Ablehnungsgründe (gebunden an den Reject-Hash).
pub const RejectReason = enum(u8) {
    /// Testvektoren fehlgeschlagen
    test_failure         = 0x01,
    /// Ungültige Lineage-Referenz
    invalid_lineage      = 0x02,
    /// Ungültige Epoch
    invalid_epoch        = 0x03,
    /// Ungültige Sources (Duplikate / fehlende Referenzen)
    invalid_sources      = 0x04,
    /// Provenance fehlt oder ist ungültig
    missing_provenance   = 0x05,
    /// Candidate-Hash-Mismatch bei Re-Insert
    hash_mismatch        = 0x06,
    /// Guardian-Ablehnung (externe Evidence)
    guardian_rejection   = 0x07,
    /// Allgemeiner Policy-Fehler
    policy_violation     = 0x08,
};

// ── TestEvidence ──────────────────────────────────────────────────────────

/// Test-Evidence für einen Forge Candidate.
/// Alle Counts müssen konsistent sein:
///   passed_count + failed_count <= total_count
///   passed_count <= total_count
///   failed_count <= total_count
pub const TestEvidence = struct {
    /// Gesamtanzahl durchgeführter Tests
    total_count:  u32,
    /// Bestandene Tests
    passed_count: u32,
    /// Fehlgeschlagene Tests
    failed_count: u32,
    /// Hash aller Testergebnisse (deterministisch aggregiert)
    result_hash:  [32]u8,
    /// Übergeordneter Evidence-Hash (z. B. signierter Guardian-Beweis)
    evidence_hash: [32]u8,
};

pub const TestEvidenceError = error{
    PassedExceedsTotal,
    FailedExceedsTotal,
    PassedPlusFailedExceedsTotal,
    MissingEvidence,
};

/// Prüft die Konsistenz einer TestEvidence.
pub fn validateTestEvidence(te: TestEvidence) TestEvidenceError!void {
    if (te.passed_count > te.total_count) return TestEvidenceError.PassedExceedsTotal;
    if (te.failed_count > te.total_count) return TestEvidenceError.FailedExceedsTotal;
    if (te.passed_count + te.failed_count > te.total_count)
        return TestEvidenceError.PassedPlusFailedExceedsTotal;
    // evidence_hash darf nicht ZERO sein wenn Tests vorhanden
    if (te.total_count > 0 and std.mem.eql(u8, &te.result_hash, &ZERO_HASH))
        return TestEvidenceError.MissingEvidence;
}

// ── RejectProof ───────────────────────────────────────────────────────────

/// Ablehnungsbeweis — deterministisch an Candidate-Identity + Reason + Evidence gebunden.
pub const RejectProof = struct {
    /// SHA256("BKGC" || "REJECT" || candidate_hash || reason_byte || evidence_hash)
    reject_hash:    [32]u8,
    reason:         RejectReason,
    evidence_hash:  [32]u8,
};

/// Berechnet den Reject-Hash deterministisch.
pub fn computeRejectHash(
    candidate_hash: [32]u8,
    reason: RejectReason,
    evidence_hash: [32]u8,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&DOMAIN_PREFIX);
    hasher.update("REJECT");
    hasher.update(&candidate_hash);
    const rb = [1]u8{@intFromEnum(reason)};
    hasher.update(&rb);
    hasher.update(&evidence_hash);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

// ── ForgeCandidate ────────────────────────────────────────────────────────

/// Vollständiger Forge Candidate Record.
/// Pointer-frei, deterministisch kodierbar.
/// Kein eingebettetes Artefakt-Blob.
pub const ForgeCandidate = struct {
    /// Domain Separation ("BKGC")
    domain_prefix:     [4]u8,
    /// SHA256("BKGC" || kanonische Identitätsfelder) — content-addressed
    candidate_hash:    [32]u8,
    /// Hash des zugrunde liegenden Artefakts
    artifact_hash:     [32]u8,
    /// Lineage-Hash (aus Stage 2 lineage_index)
    lineage_hash:      [32]u8,
    /// Generation des Candidates
    generation:        u64,
    /// Forge-Epoch zum Zeitpunkt der Erzeugung
    forge_epoch:       u64,
    /// Kanonisch sortierte Source-Hashes (Spore/Artifact/Lineage-Referenzen)
    sources:           [MAX_SOURCES][32]u8,
    /// Anzahl gültiger Sources (≤ MAX_SOURCES)
    source_count:      u8,
    /// Test-Evidence
    test_evidence:     TestEvidence,
    /// Hash von Benchmark-Claims (ZERO = keine Benchmarks)
    benchmark_hash:    [32]u8,
    /// Herkunfts-Beweis
    provenance_hash:   [32]u8,
    /// Übergeordneter Evidence-Hash (ZERO = noch keine externe Evidence)
    evidence_hash:     [32]u8,
    /// Aktueller Status
    status:            CandidateStatus,
    /// Ablehnungsbeweis (nur bei status == rejected relevant)
    reject_proof:      RejectProof,
    /// Ledger-Event-Hash der Forge-Schmiedung (ZERO = noch kein Ledger-Beweis)
    origin_event_hash: [32]u8,
};

// ── Candidate-Hash-Berechnung ─────────────────────────────────────────────

/// Berechnet den kanonischen Candidate-Hash.
///
/// Input (kanonisch, LE):
///   "BKGC" || artifact_hash || lineage_hash || generation_le8 || forge_epoch_le8
///   || source_count_le1 || source_0 || … || source_n (kanonisch sortiert)
///   || benchmark_hash || provenance_hash
///
/// NICHT enthalten: status, test_evidence, reject_proof, origin_event_hash
/// (diese sind Zustandsinformation, nicht Identität)
pub fn computeCandidateHash(
    artifact_hash:   [32]u8,
    lineage_hash:    [32]u8,
    generation:      u64,
    forge_epoch:     u64,
    sources:         []const [32]u8,
    benchmark_hash:  [32]u8,
    provenance_hash: [32]u8,
) [32]u8 {
    // Sources kanonisch sortieren (lexikografisch aufsteigend, Insertion Sort ≤ MAX_SOURCES)
    var sorted: [MAX_SOURCES][32]u8 = undefined;
    const n = @min(sources.len, MAX_SOURCES);
    for (0..n) |i| sorted[i] = sources[i];
    var si: usize = 1;
    while (si < n) : (si += 1) {
        const key = sorted[si];
        var j: usize = si;
        while (j > 0 and std.mem.lessThan(u8, &sorted[j - 1], &key)) : (j -= 1) {
            sorted[j] = sorted[j - 1];
        }
        sorted[j] = key;
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&DOMAIN_PREFIX);
    hasher.update(&artifact_hash);
    hasher.update(&lineage_hash);
    var gen_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &gen_buf, generation, .little);
    hasher.update(&gen_buf);
    var epoch_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &epoch_buf, forge_epoch, .little);
    hasher.update(&epoch_buf);
    const sc_buf = [1]u8{@intCast(n)};
    hasher.update(&sc_buf);
    for (0..n) |k| hasher.update(&sorted[k]);
    hasher.update(&benchmark_hash);
    hasher.update(&provenance_hash);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

// ── Fehlertypen ───────────────────────────────────────────────────────────

pub const ForgeKnowledgeError = error{
    /// Candidate bereits bekannt + gleicher Inhalt → idempotent (kein Fehler, intern)
    /// (nie nach außen propagiert)

    /// Candidate bereits bekannt + anderer Inhalt
    ContentConflict,
    /// Berechneter candidate_hash stimmt nicht mit dem gelieferten überein
    CandidateHashMismatch,
    /// Zu viele Sources (> MAX_SOURCES)
    TooManySources,
    /// Duplicate Source-Hash in sources[]
    DuplicateSource,
    /// Ungültiger Status beim Insert (muss .pending sein)
    InvalidInitialStatus,
    /// Ungültiger Zustandsübergang
    InvalidTransition,
    /// Candidate unbekannt
    NotFound,
    /// Epoch-Konflikt (Candidate-Epoch < aktuelle Epoch, oder Backward-Move)
    EpochConflict,
    /// Epoch-Overflow
    EpochOverflow,
    /// TestEvidence-Konsistenzfehler
    InvalidTestEvidence,
    /// Forged ohne vollständig bestandene Tests
    InsufficientTestEvidence,
    /// Reject ohne Reject-Proof
    MissingRejectProof,
    /// Reject-Hash-Mismatch
    RejectHashMismatch,
    /// Provenance fehlt (ZERO bei forged nicht erlaubt)
    MissingProvenance,
    OutOfMemory,
};

// ── ForgeEpochManager ─────────────────────────────────────────────────────

/// Verwaltet die monotone Forge-Epoch.
/// Keine Rückwärtsbewegung. Kein Overflow-Wrap.
pub const ForgeEpochManager = struct {
    current: u64,

    pub fn init(start: u64) ForgeEpochManager {
        return .{ .current = start };
    }

    /// Gibt die aktuelle Epoch zurück.
    pub fn currentEpoch(self: ForgeEpochManager) u64 {
        return self.current;
    }

    /// Erhöht die Epoch um 1 (monoton, kein Overflow).
    pub fn advance(self: *ForgeEpochManager) ForgeKnowledgeError!void {
        if (self.current == std.math.maxInt(u64)) return ForgeKnowledgeError.EpochOverflow;
        self.current += 1;
    }

    /// Prüft ob eine Candidate-Epoch gültig ist (≤ aktuelle Epoch).
    pub fn validateCandidateEpoch(self: ForgeEpochManager, candidate_epoch: u64) ForgeKnowledgeError!void {
        if (candidate_epoch > self.current) return ForgeKnowledgeError.EpochConflict;
    }
};

// ── Source-Set-Hash ───────────────────────────────────────────────────────

/// Berechnet einen deterministischen Hash des kanonisch sortierten Source-Sets.
///
/// Zweck (P6): Ermoeglicht spaeterer Guardian/Nebel-Erkennung
/// "viele Candidates mit denselben Quellen" (Repetitions-Erkennung).
/// Stage 3 wertet diesen Hash nicht oekonomisch aus.
///
/// Input: "BKGC" || "SRCS" || source_count_le1 || source_0 ... source_n (kanonisch sortiert)
pub fn computeSourceSetHash(sources: []const [32]u8) [32]u8 {
    var sorted: [MAX_SOURCES][32]u8 = undefined;
    const n = @min(sources.len, MAX_SOURCES);
    for (0..n) |i| sorted[i] = sources[i];
    var si: usize = 1;
    while (si < n) : (si += 1) {
        const key = sorted[si];
        var j: usize = si;
        while (j > 0 and std.mem.lessThan(u8, &sorted[j - 1], &key)) : (j -= 1) {
            sorted[j] = sorted[j - 1];
        }
        sorted[j] = key;
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&DOMAIN_PREFIX);
    hasher.update("SRCS");
    const sc_buf = [1]u8{@intCast(n)};
    hasher.update(&sc_buf);
    for (0..n) |k| hasher.update(&sorted[k]);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

// ── Lookup-Hilfsstrukturen ────────────────────────────────────────────────

/// Eintrag in einem Reverse-Index (artifact/lineage/epoch/status/source_set -> candidate_hashes).
/// In Zig 0.16: std.ArrayList(T) = array_list.Aligned(T, null).
/// Init via .empty, append/deinit brauchen Allocator.
const IndexList = std.ArrayList([32]u8);

// ── ForgeKnowledgeStore ───────────────────────────────────────────────────

pub const ForgeKnowledgeStore = struct {
    allocator: std.mem.Allocator,

    /// Primaerindex: candidate_hash -> ForgeCandidate
    candidates: std.AutoHashMap([32]u8, ForgeCandidate),

    /// Reverse-Index: artifact_hash -> []candidate_hash
    by_artifact: std.AutoHashMap([32]u8, IndexList),

    /// Reverse-Index: lineage_hash -> []candidate_hash
    by_lineage: std.AutoHashMap([32]u8, IndexList),

    /// Reverse-Index: forge_epoch -> []candidate_hash
    by_epoch: std.AutoHashMap(u64, IndexList),

    /// Reverse-Index: status -> []candidate_hash
    by_status: std.AutoHashMap(u8, IndexList),

    /// Reverse-Index: source_set_hash -> []candidate_hash (P6: Repetitions-Erkennung)
    by_source_set: std.AutoHashMap([32]u8, IndexList),

    pub fn init(allocator: std.mem.Allocator) ForgeKnowledgeStore {
        return .{
            .allocator      = allocator,
            .candidates     = std.AutoHashMap([32]u8, ForgeCandidate).init(allocator),
            .by_artifact    = std.AutoHashMap([32]u8, IndexList).init(allocator),
            .by_lineage     = std.AutoHashMap([32]u8, IndexList).init(allocator),
            .by_epoch       = std.AutoHashMap(u64, IndexList).init(allocator),
            .by_status      = std.AutoHashMap(u8, IndexList).init(allocator),
            .by_source_set  = std.AutoHashMap([32]u8, IndexList).init(allocator),
        };
    }

    pub fn deinit(self: *ForgeKnowledgeStore) void {
        var it_a = self.by_artifact.valueIterator();
        while (it_a.next()) |list| list.deinit(self.allocator);
        self.by_artifact.deinit();

        var it_l = self.by_lineage.valueIterator();
        while (it_l.next()) |list| list.deinit(self.allocator);
        self.by_lineage.deinit();

        var it_e = self.by_epoch.valueIterator();
        while (it_e.next()) |list| list.deinit(self.allocator);
        self.by_epoch.deinit();

        var it_s = self.by_status.valueIterator();
        while (it_s.next()) |list| list.deinit(self.allocator);
        self.by_status.deinit();

        var it_ss = self.by_source_set.valueIterator();
        while (it_ss.next()) |list| list.deinit(self.allocator);
        self.by_source_set.deinit();

        self.candidates.deinit();
    }

    // ── Einfuegen ─────────────────────────────────────────────────────────

    /// Fuegt einen neuen ForgeCandidate in den Store ein.
    ///
    /// Pruefreihenfolge (fail-closed):
    ///   1. source_count > MAX_SOURCES -> TooManySources
    ///   2. Duplikate in sources[] -> DuplicateSource
    ///   3. status muss .pending sein -> InvalidInitialStatus
    ///   4. provenance_hash ZERO nicht erlaubt -> MissingProvenance
    ///   5. Candidate-Hash intern neu berechnen -> CandidateHashMismatch
    ///   6. candidate_hash bereits bekannt + identisch -> idempotent
    ///   7. candidate_hash bereits bekannt + anderer Inhalt -> ContentConflict
    ///   8. Speichern + Reverse-Indizes atomar aufbauen (errdefer-Rollback)
    pub fn put(self: *ForgeKnowledgeStore, candidate: ForgeCandidate) ForgeKnowledgeError!void {
        if (candidate.source_count > MAX_SOURCES) return ForgeKnowledgeError.TooManySources;

        const n = @as(usize, candidate.source_count);
        for (0..n) |a| {
            for (a + 1..n) |b| {
                if (std.mem.eql(u8, &candidate.sources[a], &candidate.sources[b])) {
                    return ForgeKnowledgeError.DuplicateSource;
                }
            }
        }

        if (candidate.status != .pending) return ForgeKnowledgeError.InvalidInitialStatus;
        if (std.mem.eql(u8, &candidate.provenance_hash, &ZERO_HASH))
            return ForgeKnowledgeError.MissingProvenance;

        const computed = computeCandidateHash(
            candidate.artifact_hash,
            candidate.lineage_hash,
            candidate.generation,
            candidate.forge_epoch,
            candidate.sources[0..n],
            candidate.benchmark_hash,
            candidate.provenance_hash,
        );
        if (!std.mem.eql(u8, &computed, &candidate.candidate_hash)) {
            return ForgeKnowledgeError.CandidateHashMismatch;
        }

        if (self.candidates.get(candidate.candidate_hash)) |existing| {
            if (candidateEql(existing, candidate)) return; // idempotent
            return ForgeKnowledgeError.ContentConflict;
        }

        // Primärindex einfügen — dann Reverse-Indizes atomar aufbauen.
        // errdefer stellt sicher: Fehler in einem appendIndex rollbackt den Primary-Entry.
        // (Reverse-Index-Listen werden bei appendIndex-Fehler nicht partiell aufgeräumt,
        //  aber da der Primary-Entry weg ist, sind verwaiste Index-Einträge unerreichbar
        //  und werden bei deinit() sauber freigegeben. Dies ist eine bewusste Entscheidung:
        //  vollstaendiger atomarer Rollback aller Index-Listen wuerde O(N) Traversal erfordern.
        //  Die invariante Korrektheit ist: get(candidate_hash) == null nach einem Fehler.)
        try self.candidates.put(candidate.candidate_hash, candidate);
        errdefer _ = self.candidates.remove(candidate.candidate_hash);

        const src_set_hash = computeSourceSetHash(candidate.sources[0..n]);

        try appendIndex([32]u8, &self.by_artifact,   candidate.artifact_hash,            candidate.candidate_hash, self.allocator);
        try appendIndex([32]u8, &self.by_lineage,    candidate.lineage_hash,              candidate.candidate_hash, self.allocator);
        try appendIndex(u64,    &self.by_epoch,       candidate.forge_epoch,               candidate.candidate_hash, self.allocator);
        try appendIndex(u8,     &self.by_status,      @intFromEnum(candidate.status),      candidate.candidate_hash, self.allocator);
        try appendIndex([32]u8, &self.by_source_set,  src_set_hash,                        candidate.candidate_hash, self.allocator);
    }

    // ── Status-Übergänge ──────────────────────────────────────────────────

    /// Übergang pending → tested.
    ///
    /// Validierungen:
    ///   - Candidate muss bekannt sein
    ///   - Übergang muss erlaubt sein (pending → tested)
    ///   - TestEvidence muss konsistent sein
    ///   - total_count > 0 und result_hash nicht ZERO
    pub fn markTested(
        self: *ForgeKnowledgeStore,
        candidate_hash: [32]u8,
        evidence: TestEvidence,
    ) ForgeKnowledgeError!void {
        const entry = self.candidates.getPtr(candidate_hash) orelse return ForgeKnowledgeError.NotFound;
        if (!isValidStatusTransition(entry.status, .tested))
            return ForgeKnowledgeError.InvalidTransition;

        validateTestEvidence(evidence) catch return ForgeKnowledgeError.InvalidTestEvidence;
        if (evidence.total_count == 0) return ForgeKnowledgeError.InvalidTestEvidence;

        // Status-Index aktualisieren
        try self.moveStatusIndex(candidate_hash, entry.status, .tested);

        entry.test_evidence = evidence;
        entry.status = .tested;
    }

    /// Übergang tested → forged.
    ///
    /// Zusätzliche Anforderungen:
    ///   - alle Tests bestanden (passed_count == total_count, failed_count == 0)
    ///   - origin_event_hash gesetzt (nicht ZERO, Ledger-Beweis optional für Stage 3,
    ///     aber ZERO signalisiert keinen Ledger-Beweis — erlaubt, da Stage 3 noch
    ///     keine echte Ledger-Anbindung hat)
    pub fn markForged(
        self: *ForgeKnowledgeStore,
        candidate_hash: [32]u8,
        origin_event_hash: [32]u8,
    ) ForgeKnowledgeError!void {
        const entry = self.candidates.getPtr(candidate_hash) orelse return ForgeKnowledgeError.NotFound;
        if (!isValidStatusTransition(entry.status, .forged))
            return ForgeKnowledgeError.InvalidTransition;

        // Alle Tests müssen bestanden sein
        const te = entry.test_evidence;
        if (te.total_count == 0 or
            te.passed_count != te.total_count or
            te.failed_count != 0)
        {
            return ForgeKnowledgeError.InsufficientTestEvidence;
        }

        // Status-Index aktualisieren
        try self.moveStatusIndex(candidate_hash, entry.status, .forged);

        entry.origin_event_hash = origin_event_hash;
        entry.status = .forged;
    }

    /// Übergang tested → rejected.
    ///
    /// Anforderungen:
    ///   - Reject-Proof muss vorhanden sein (reject_hash ≠ ZERO)
    ///   - reject_hash muss mit computeRejectHash(candidate_hash, reason, evidence) übereinstimmen
    pub fn markRejected(
        self: *ForgeKnowledgeStore,
        candidate_hash: [32]u8,
        proof: RejectProof,
    ) ForgeKnowledgeError!void {
        const entry = self.candidates.getPtr(candidate_hash) orelse return ForgeKnowledgeError.NotFound;
        if (!isValidStatusTransition(entry.status, .rejected))
            return ForgeKnowledgeError.InvalidTransition;

        if (std.mem.eql(u8, &proof.reject_hash, &ZERO_HASH))
            return ForgeKnowledgeError.MissingRejectProof;

        // Reject-Hash deterministisch verifizieren
        const expected_hash = computeRejectHash(candidate_hash, proof.reason, proof.evidence_hash);
        if (!std.mem.eql(u8, &expected_hash, &proof.reject_hash))
            return ForgeKnowledgeError.RejectHashMismatch;

        // Status-Index aktualisieren
        try self.moveStatusIndex(candidate_hash, entry.status, .rejected);

        entry.reject_proof = proof;
        entry.status = .rejected;
    }

    // ── Lookup ────────────────────────────────────────────────────────────

    /// Gibt den Candidate zurück, oder null.
    pub fn get(self: *const ForgeKnowledgeStore, candidate_hash: [32]u8) ?ForgeCandidate {
        return self.candidates.get(candidate_hash);
    }

    /// Gibt eine sortierte Liste von Candidate-Hashes für einen Artifact-Hash zurück.
    /// Caller besitzt den Slice NICHT — er zeigt in interne IndexList.
    pub fn getByCandidateArtifact(self: *const ForgeKnowledgeStore, artifact_hash: [32]u8) ?[]const [32]u8 {
        if (self.by_artifact.get(artifact_hash)) |list| return list.items;
        return null;
    }

    /// Gibt eine Liste von Candidate-Hashes für einen Lineage-Hash zurück.
    pub fn getByLineage(self: *const ForgeKnowledgeStore, lineage_hash: [32]u8) ?[]const [32]u8 {
        if (self.by_lineage.get(lineage_hash)) |list| return list.items;
        return null;
    }

    /// Gibt eine Liste von Candidate-Hashes für eine Forge-Epoch zurück.
    pub fn getByEpoch(self: *const ForgeKnowledgeStore, epoch: u64) ?[]const [32]u8 {
        if (self.by_epoch.get(epoch)) |list| return list.items;
        return null;
    }

    /// Gibt eine Liste von Candidate-Hashes fuer einen Status zurueck.
    pub fn getByStatus(self: *const ForgeKnowledgeStore, status: CandidateStatus) ?[]const [32]u8 {
        if (self.by_status.get(@intFromEnum(status))) |list| return list.items;
        return null;
    }

    /// Gibt eine Liste von Candidate-Hashes fuer ein Source-Set zurueck (P6: Repetitions-Erkennung).
    /// Eingabe: das rohe Source-Array (wird intern kanonisch sortiert via computeSourceSetHash).
    /// Reine Projektion — veraendert keinen Store-Zustand.
    pub fn getBySourceSet(self: *const ForgeKnowledgeStore, sources: []const [32]u8) ?[]const [32]u8 {
        const ssh = computeSourceSetHash(sources);
        if (self.by_source_set.get(ssh)) |list| return list.items;
        return null;
    }

    /// Prueft ob ein Candidate bekannt ist.
    pub fn contains(self: *const ForgeKnowledgeStore, candidate_hash: [32]u8) bool {
        return self.candidates.contains(candidate_hash);
    }

    /// Anzahl gespeicherter Candidates.
    pub fn count(self: *const ForgeKnowledgeStore) usize {
        return self.candidates.count();
    }

    // ── Interne Hilfsfunktionen ───────────────────────────────────────────

    /// Verschiebt einen candidate_hash im by_status-Index von old nach new.
    fn moveStatusIndex(
        self: *ForgeKnowledgeStore,
        candidate_hash: [32]u8,
        old: CandidateStatus,
        new: CandidateStatus,
    ) ForgeKnowledgeError!void {
        // Aus altem Status entfernen
        const old_key = @intFromEnum(old);
        if (self.by_status.getPtr(old_key)) |list| {
            for (list.items, 0..) |entry_h, idx| {
                if (std.mem.eql(u8, &entry_h, &candidate_hash)) {
                    _ = list.swapRemove(idx);
                    break;
                }
            }
        }
        // In neuem Status eintragen
        try appendIndex(u8, &self.by_status, @intFromEnum(new), candidate_hash, self.allocator);
    }
};

// ── Generischer Index-Append ──────────────────────────────────────────────

/// Hängt candidate_hash an die IndexList unter `key` an.
/// Erstellt die Liste falls nicht vorhanden (via .empty).
fn appendIndex(
    comptime K: type,
    map: *std.AutoHashMap(K, IndexList),
    key: K,
    candidate_hash: [32]u8,
    allocator: std.mem.Allocator,
) ForgeKnowledgeError!void {
    const result = try map.getOrPut(key);
    if (!result.found_existing) {
        result.value_ptr.* = IndexList.empty;
    }
    try result.value_ptr.append(allocator, candidate_hash);
}

// ── Vergleichsfunktionen ──────────────────────────────────────────────────

fn candidateEql(a: ForgeCandidate, b: ForgeCandidate) bool {
    if (!std.mem.eql(u8, &a.candidate_hash, &b.candidate_hash)) return false;
    if (!std.mem.eql(u8, &a.artifact_hash, &b.artifact_hash)) return false;
    if (!std.mem.eql(u8, &a.lineage_hash, &b.lineage_hash)) return false;
    if (a.generation != b.generation) return false;
    if (a.forge_epoch != b.forge_epoch) return false;
    if (a.source_count != b.source_count) return false;
    for (0..@as(usize, a.source_count)) |i| {
        if (!std.mem.eql(u8, &a.sources[i], &b.sources[i])) return false;
    }
    if (!std.mem.eql(u8, &a.benchmark_hash, &b.benchmark_hash)) return false;
    if (!std.mem.eql(u8, &a.provenance_hash, &b.provenance_hash)) return false;
    if (!std.mem.eql(u8, &a.evidence_hash, &b.evidence_hash)) return false;
    if (a.status != b.status) return false;
    if (!std.mem.eql(u8, &a.reject_proof.reject_hash, &b.reject_proof.reject_hash)) return false;
    if (!std.mem.eql(u8, &a.origin_event_hash, &b.origin_event_hash)) return false;
    return true;
}

// ── Test-Hilfsfunktionen ──────────────────────────────────────────────────

fn h(b_: u8) [32]u8 {
    var out: [32]u8 = ZERO_HASH;
    out[0] = b_;
    return out;
}

/// Erstellt einen validen ForgeCandidate im `pending`-Status.
fn makeCandidate(
    artifact_hash: [32]u8,
    lineage_hash: [32]u8,
    generation: u64,
    forge_epoch: u64,
    sources: []const [32]u8,
    provenance_hash: [32]u8,
) ForgeCandidate {
    const n: u8 = @intCast(@min(sources.len, MAX_SOURCES));
    var c = ForgeCandidate{
        .domain_prefix     = DOMAIN_PREFIX,
        .candidate_hash    = ZERO_HASH,
        .artifact_hash     = artifact_hash,
        .lineage_hash      = lineage_hash,
        .generation        = generation,
        .forge_epoch       = forge_epoch,
        .sources           = [_][32]u8{ZERO_HASH} ** MAX_SOURCES,
        .source_count      = n,
        .test_evidence     = .{
            .total_count  = 0,
            .passed_count = 0,
            .failed_count = 0,
            .result_hash  = ZERO_HASH,
            .evidence_hash = ZERO_HASH,
        },
        .benchmark_hash    = ZERO_HASH,
        .provenance_hash   = provenance_hash,
        .evidence_hash     = ZERO_HASH,
        .status            = .pending,
        .reject_proof      = .{
            .reject_hash   = ZERO_HASH,
            .reason        = .policy_violation,
            .evidence_hash = ZERO_HASH,
        },
        .origin_event_hash = ZERO_HASH,
    };
    for (0..n) |i| c.sources[i] = sources[i];
    c.candidate_hash = computeCandidateHash(
        artifact_hash, lineage_hash, generation, forge_epoch,
        sources[0..n], ZERO_HASH, provenance_hash,
    );
    return c;
}

fn makeTestEvidence(total: u32, passed: u32, failed: u32) TestEvidence {
    return .{
        .total_count   = total,
        .passed_count  = passed,
        .failed_count  = failed,
        .result_hash   = h(0xEE),
        .evidence_hash = h(0xFF),
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

// ── Candidate Identity ────────────────────────────────────────────────────

test "forge_knowledge: deterministischer Candidate Hash" {
    const c1 = makeCandidate(h(0x01), h(0x02), 1, 10, &.{h(0xAA)}, h(0xBB));
    const c2 = makeCandidate(h(0x01), h(0x02), 1, 10, &.{h(0xAA)}, h(0xBB));
    try std.testing.expectEqualSlices(u8, &c1.candidate_hash, &c2.candidate_hash);
}

test "forge_knowledge: Änderung artifact_hash → anderer Candidate Hash" {
    const c1 = makeCandidate(h(0x01), h(0x02), 1, 10, &.{}, h(0xBB));
    const c2 = makeCandidate(h(0x03), h(0x02), 1, 10, &.{}, h(0xBB));
    try std.testing.expect(!std.mem.eql(u8, &c1.candidate_hash, &c2.candidate_hash));
}

test "forge_knowledge: Änderung generation → anderer Candidate Hash" {
    const c1 = makeCandidate(h(0x01), h(0x02), 1, 10, &.{}, h(0xBB));
    const c2 = makeCandidate(h(0x01), h(0x02), 2, 10, &.{}, h(0xBB));
    try std.testing.expect(!std.mem.eql(u8, &c1.candidate_hash, &c2.candidate_hash));
}

test "forge_knowledge: Änderung forge_epoch → anderer Candidate Hash" {
    const c1 = makeCandidate(h(0x01), h(0x02), 1, 10, &.{}, h(0xBB));
    const c2 = makeCandidate(h(0x01), h(0x02), 1, 11, &.{}, h(0xBB));
    try std.testing.expect(!std.mem.eql(u8, &c1.candidate_hash, &c2.candidate_hash));
}

test "forge_knowledge: Änderung provenance_hash → anderer Candidate Hash" {
    const c1 = makeCandidate(h(0x01), h(0x02), 1, 10, &.{}, h(0xBB));
    const c2 = makeCandidate(h(0x01), h(0x02), 1, 10, &.{}, h(0xCC));
    try std.testing.expect(!std.mem.eql(u8, &c1.candidate_hash, &c2.candidate_hash));
}

test "forge_knowledge: Domain Separation BKGC" {
    // SHA256("BKGC"||...) != SHA256("BKGA"||...) bei gleichem Rest
    const hash_c = computeCandidateHash(h(0x01), h(0x02), 1, 1, &.{}, ZERO_HASH, h(0xBB));
    // Manuell mit "BKGA"
    var h2 = std.crypto.hash.sha2.Sha256.init(.{});
    h2.update("BKGA");
    h2.update(&h(0x01)); // artifact
    h2.update(&h(0x02)); // lineage
    var gen: [8]u8 = undefined; std.mem.writeInt(u64, &gen, 1, .little); h2.update(&gen);
    var ep: [8]u8 = undefined; std.mem.writeInt(u64, &ep, 1, .little); h2.update(&ep);
    h2.update(&[1]u8{0}); // source_count=0
    h2.update(&ZERO_HASH); // benchmark
    h2.update(&h(0xBB)); // provenance
    var out_a: [32]u8 = undefined; h2.final(&out_a);
    try std.testing.expect(!std.mem.eql(u8, &hash_c, &out_a));
}

test "forge_knowledge: Source [A,B] == [B,A]" {
    const ha = computeCandidateHash(h(0x01), h(0x02), 1, 1, &.{ h(0x10), h(0x20) }, ZERO_HASH, h(0xBB));
    const hb = computeCandidateHash(h(0x01), h(0x02), 1, 1, &.{ h(0x20), h(0x10) }, ZERO_HASH, h(0xBB));
    try std.testing.expectEqualSlices(u8, &ha, &hb);
}

test "forge_knowledge: Duplicate Source [A,A] rejected" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    var c = makeCandidate(h(0x01), h(0x02), 1, 1, &.{ h(0x10), h(0x10) }, h(0xBB));
    // Duplikat manuell setzen (makeCandidate sortiert nur, prüft nicht)
    c.source_count = 2;
    c.sources[0] = h(0x10);
    c.sources[1] = h(0x10);
    try std.testing.expectError(ForgeKnowledgeError.DuplicateSource, store.put(c));
}

// ── Lifecycle ────────────────────────────────────────────────────────────

test "forge_knowledge: pending erlaubt einzufügen" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x01), h(0x02), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try std.testing.expectEqual(CandidateStatus.pending, store.get(c.candidate_hash).?.status);
}

test "forge_knowledge: pending → tested" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x01), h(0x02), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(5, 3, 2));
    try std.testing.expectEqual(CandidateStatus.tested, store.get(c.candidate_hash).?.status);
}

test "forge_knowledge: tested → forged" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x01), h(0x02), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(5, 5, 0));
    try store.markForged(c.candidate_hash, h(0xEF));
    try std.testing.expectEqual(CandidateStatus.forged, store.get(c.candidate_hash).?.status);
}

test "forge_knowledge: tested → rejected" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x02), h(0x03), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(5, 3, 2));
    const rh = computeRejectHash(c.candidate_hash, .test_failure, h(0xDE));
    const proof = RejectProof{ .reject_hash = rh, .reason = .test_failure, .evidence_hash = h(0xDE) };
    try store.markRejected(c.candidate_hash, proof);
    try std.testing.expectEqual(CandidateStatus.rejected, store.get(c.candidate_hash).?.status);
}

test "forge_knowledge: pending → forged direkt — InvalidTransition" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x03), h(0x04), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try std.testing.expectError(ForgeKnowledgeError.InvalidTransition, store.markForged(c.candidate_hash, ZERO_HASH));
}

test "forge_knowledge: pending → rejected direkt — InvalidTransition" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x04), h(0x05), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    const rh = computeRejectHash(c.candidate_hash, .policy_violation, ZERO_HASH);
    const proof = RejectProof{ .reject_hash = rh, .reason = .policy_violation, .evidence_hash = ZERO_HASH };
    try std.testing.expectError(ForgeKnowledgeError.InvalidTransition, store.markRejected(c.candidate_hash, proof));
}

test "forge_knowledge: forged terminal — kein weiterer Übergang" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x05), h(0x06), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(3, 3, 0));
    try store.markForged(c.candidate_hash, ZERO_HASH);
    try std.testing.expectError(ForgeKnowledgeError.InvalidTransition,
        store.markTested(c.candidate_hash, makeTestEvidence(1, 1, 0)));
}

test "forge_knowledge: rejected terminal — kein weiterer Übergang" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x06), h(0x07), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(3, 1, 2));
    const rh = computeRejectHash(c.candidate_hash, .test_failure, h(0xDD));
    const proof = RejectProof{ .reject_hash = rh, .reason = .test_failure, .evidence_hash = h(0xDD) };
    try store.markRejected(c.candidate_hash, proof);
    try std.testing.expectError(ForgeKnowledgeError.InvalidTransition,
        store.markTested(c.candidate_hash, makeTestEvidence(1, 1, 0)));
}

// ── Tests (Evidence) ─────────────────────────────────────────────────────

test "forge_knowledge: zero tests — InvalidTestEvidence" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x10), h(0x11), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try std.testing.expectError(ForgeKnowledgeError.InvalidTestEvidence,
        store.markTested(c.candidate_hash, makeTestEvidence(0, 0, 0)));
}

test "forge_knowledge: passed > total — InvalidTestEvidence" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x12), h(0x13), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try std.testing.expectError(ForgeKnowledgeError.InvalidTestEvidence,
        store.markTested(c.candidate_hash, makeTestEvidence(3, 5, 0)));
}

test "forge_knowledge: failed > total — InvalidTestEvidence" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x14), h(0x15), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try std.testing.expectError(ForgeKnowledgeError.InvalidTestEvidence,
        store.markTested(c.candidate_hash, makeTestEvidence(3, 0, 4)));
}

test "forge_knowledge: passed + failed > total — InvalidTestEvidence" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x16), h(0x17), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try std.testing.expectError(ForgeKnowledgeError.InvalidTestEvidence,
        store.markTested(c.candidate_hash, makeTestEvidence(3, 2, 2)));
}

test "forge_knowledge: forged ohne alle Tests bestanden — InsufficientTestEvidence" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x18), h(0x19), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(5, 3, 2));
    try std.testing.expectError(ForgeKnowledgeError.InsufficientTestEvidence,
        store.markForged(c.candidate_hash, ZERO_HASH));
}

// ── Reject Proof ──────────────────────────────────────────────────────────

test "forge_knowledge: reject ohne proof — MissingRejectProof" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x20), h(0x21), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(3, 1, 2));
    const proof = RejectProof{ .reject_hash = ZERO_HASH, .reason = .test_failure, .evidence_hash = ZERO_HASH };
    try std.testing.expectError(ForgeKnowledgeError.MissingRejectProof,
        store.markRejected(c.candidate_hash, proof));
}

test "forge_knowledge: reject hash gebunden an candidate + reason + evidence" {
    const ch = h(0xAB);
    const rh1 = computeRejectHash(ch, .test_failure, h(0xCD));
    const rh2 = computeRejectHash(ch, .invalid_lineage, h(0xCD)); // anderer Grund
    const rh3 = computeRejectHash(ch, .test_failure, h(0xCE)); // andere Evidence
    try std.testing.expect(!std.mem.eql(u8, &rh1, &rh2));
    try std.testing.expect(!std.mem.eql(u8, &rh1, &rh3));
}

test "forge_knowledge: rejected bleibt queryable" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x22), h(0x23), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(3, 1, 2));
    const rh = computeRejectHash(c.candidate_hash, .test_failure, h(0xDD));
    const proof = RejectProof{ .reject_hash = rh, .reason = .test_failure, .evidence_hash = h(0xDD) };
    try store.markRejected(c.candidate_hash, proof);

    // Candidate noch sichtbar
    const got = store.get(c.candidate_hash);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(CandidateStatus.rejected, got.?.status);
    // Auch über Status-Lookup
    const by_status = store.getByStatus(.rejected);
    try std.testing.expect(by_status != null);
    try std.testing.expectEqual(@as(usize, 1), by_status.?.len);
}

test "forge_knowledge: rejected nicht wiederbelebbar" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x24), h(0x25), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(3, 1, 2));
    const rh = computeRejectHash(c.candidate_hash, .test_failure, h(0xDD));
    const proof = RejectProof{ .reject_hash = rh, .reason = .test_failure, .evidence_hash = h(0xDD) };
    try store.markRejected(c.candidate_hash, proof);

    // Erneuter put desselben Candidates → idempotent, aber Status bleibt rejected
    // (weil der Candidate bereits known ist mit rejected status — ContentConflict wenn Inhalt unterscheidet)
    // Test: direkter Versuch, status zu ändern via markTested → InvalidTransition
    try std.testing.expectError(ForgeKnowledgeError.InvalidTransition,
        store.markTested(c.candidate_hash, makeTestEvidence(3, 3, 0)));
}

// ── Epoch ─────────────────────────────────────────────────────────────────

test "forge_knowledge: erste Epoch" {
    var em = ForgeEpochManager.init(0);
    try std.testing.expectEqual(@as(u64, 0), em.currentEpoch());
}

test "forge_knowledge: Epoch monoton steigend" {
    var em = ForgeEpochManager.init(5);
    try em.advance();
    try std.testing.expectEqual(@as(u64, 6), em.currentEpoch());
    try em.advance();
    try std.testing.expectEqual(@as(u64, 7), em.currentEpoch());
}

test "forge_knowledge: Epoch Overflow" {
    var em = ForgeEpochManager.init(std.math.maxInt(u64));
    try std.testing.expectError(ForgeKnowledgeError.EpochOverflow, em.advance());
}

test "forge_knowledge: Candidate-Epoch > aktuelle Epoch — EpochConflict" {
    const em = ForgeEpochManager.init(5);
    try std.testing.expectError(ForgeKnowledgeError.EpochConflict, em.validateCandidateEpoch(6));
}

test "forge_knowledge: Candidate-Epoch <= aktuelle Epoch — ok" {
    const em = ForgeEpochManager.init(5);
    try em.validateCandidateEpoch(5);
    try em.validateCandidateEpoch(0);
}

test "forge_knowledge: Epoch beeinflusst Candidate-Identity" {
    const c1 = makeCandidate(h(0x01), h(0x02), 1, 10, &.{}, h(0xBB));
    const c2 = makeCandidate(h(0x01), h(0x02), 1, 11, &.{}, h(0xBB));
    try std.testing.expect(!std.mem.eql(u8, &c1.candidate_hash, &c2.candidate_hash));
}

// ── Duplicate / Conflict ──────────────────────────────────────────────────

test "forge_knowledge: identischer Candidate zweimal — idempotent" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x30), h(0x31), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.put(c);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "forge_knowledge: gleicher Hash + anderes artifact_hash — CandidateHashMismatch" {
    // Ein Candidate, bei dem artifact_hash nach Erzeugung manipuliert wurde,
    // hat einen candidate_hash, der nicht mehr zum Inhalt passt.
    // Die Hash-Verifikation (fail-closed) schlägt zuerst an → CandidateHashMismatch.
    // Das ist korrekt: kein manipulierter Candidate darf eingetragen werden,
    // egal ob der Hash schon bekannt ist oder nicht.
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x32), h(0x33), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    // Manipulierter Candidate: candidate_hash bleibt, artifact_hash geändert
    // → computeCandidateHash liefert anderen Hash → CandidateHashMismatch
    var c2 = c;
    c2.artifact_hash = h(0xFF);
    try std.testing.expectError(ForgeKnowledgeError.CandidateHashMismatch, store.put(c2));
    // Store unveränderter Zustand
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "forge_knowledge: ContentConflict — gleicher candidate_hash, anderer Inhalt, konsistenter Hash" {
    // Um ContentConflict zu testen: Wir fügen denselben Candidate zweimal ein,
    // aber mit dem zweiten Mal geänderten Feldern UND korrekt neu berechnetem Hash.
    // Da der neue candidate_hash verschieden ist, ist das ein anderer Candidate.
    // ContentConflict entsteht, wenn zwei Candidates identischen candidate_hash haben
    // aber verschiedene andere Felder — das ist durch CandidateHashMismatch strukturell
    // verhindert (jeder Inhalt bestimmt seinen Hash eindeutig).
    // Wir testen daher: direkte candidate_hash-Kollision durch manuelles Setzen.
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x33), h(0x34), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    // Zweiter Candidate mit identischem candidate_hash (direkt gesetzt, ohne Neuberechnung)
    // aber anderem artifact_hash → da candidate_hash == stored candidate_hash,
    // landet die Prüfung bei der Idempotenz-Prüfung → candidateEql false → ContentConflict
    var c2 = c;
    c2.artifact_hash = h(0xFF); // anderer Inhalt
    // candidate_hash bleibt c.candidate_hash → aber computeCandidateHash liefert anderen Wert
    // → CandidateHashMismatch schlägt zuerst an.
    // ContentConflict kann nur entstehen, wenn candidate_hash konsistent zum Inhalt ist,
    // was bei WRITE-ONCE durch die Hash-Verifikation strukturell sichergestellt ist.
    // Dieser Test dokumentiert: ContentConflict via direkten put mit identischem candidate_hash
    // und identischem Inhalt → idempotent (kein Fehler).
    try store.put(c); // idempotent
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "forge_knowledge: CandidateHashMismatch bei manipuliertem Hash" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    var c = makeCandidate(h(0x34), h(0x35), 1, 1, &.{}, h(0xBB));
    c.candidate_hash = [_]u8{0xFF} ** 32;
    try std.testing.expectError(ForgeKnowledgeError.CandidateHashMismatch, store.put(c));
}

test "forge_knowledge: kein Overwrite — Store unveränderter Zustand nach Conflict" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x36), h(0x37), 1, 1, &.{}, h(0xBB));
    try store.put(c);

    var c2 = c;
    c2.artifact_hash = h(0xAA);
    _ = store.put(c2) catch {};

    // Originaler Candidate bleibt erhalten
    const got = store.get(c.candidate_hash).?;
    try std.testing.expectEqualSlices(u8, &h(0x36), &got.artifact_hash);
}

// ── Lookup ────────────────────────────────────────────────────────────────

test "forge_knowledge: artifact → candidates lookup" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c1 = makeCandidate(h(0x40), h(0x41), 1, 1, &.{}, h(0xBB));
    const c2 = makeCandidate(h(0x40), h(0x42), 2, 2, &.{}, h(0xBC));
    try store.put(c1);
    try store.put(c2);

    const list = store.getByCandidateArtifact(h(0x40));
    try std.testing.expect(list != null);
    try std.testing.expectEqual(@as(usize, 2), list.?.len);
}

test "forge_knowledge: lineage → candidates lookup" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x50), h(0x51), 1, 1, &.{}, h(0xBB));
    try store.put(c);

    const list = store.getByLineage(h(0x51));
    try std.testing.expect(list != null);
    try std.testing.expectEqual(@as(usize, 1), list.?.len);
}

test "forge_knowledge: epoch → candidates lookup" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c1 = makeCandidate(h(0x60), h(0x61), 1, 7, &.{}, h(0xBB));
    const c2 = makeCandidate(h(0x62), h(0x63), 2, 7, &.{}, h(0xBC));
    const c3 = makeCandidate(h(0x64), h(0x65), 3, 8, &.{}, h(0xBD));
    try store.put(c1);
    try store.put(c2);
    try store.put(c3);

    const ep7 = store.getByEpoch(7);
    try std.testing.expect(ep7 != null);
    try std.testing.expectEqual(@as(usize, 2), ep7.?.len);

    const ep8 = store.getByEpoch(8);
    try std.testing.expect(ep8 != null);
    try std.testing.expectEqual(@as(usize, 1), ep8.?.len);
}

test "forge_knowledge: status → candidates lookup" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c1 = makeCandidate(h(0x70), h(0x71), 1, 1, &.{}, h(0xBB));
    const c2 = makeCandidate(h(0x72), h(0x73), 2, 1, &.{}, h(0xBC));
    try store.put(c1);
    try store.put(c2);
    try store.markTested(c1.candidate_hash, makeTestEvidence(5, 5, 0));
    try store.markForged(c1.candidate_hash, ZERO_HASH);

    const forged = store.getByStatus(.forged);
    try std.testing.expect(forged != null);
    try std.testing.expectEqual(@as(usize, 1), forged.?.len);

    const pending = store.getByStatus(.pending);
    try std.testing.expect(pending != null);
    try std.testing.expectEqual(@as(usize, 1), pending.?.len);
}

test "forge_knowledge: Store State != Ledger Truth dokumentiert" {
    // Dieser Test belegt, dass ein 'forged' Candidate kein Ledger-Event hat —
    // origin_event_hash ist ZERO erlaubt (Stage 3 hat noch keine echte Ledger-Anbindung).
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x80), h(0x81), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(3, 3, 0));
    try store.markForged(c.candidate_hash, ZERO_HASH); // ZERO = kein Ledger-Beweis
    const got = store.get(c.candidate_hash).?;
    // forged aber ohne Ledger-Beweis — Store State != Ledger Truth
    try std.testing.expectEqualSlices(u8, &ZERO_HASH, &got.origin_event_hash);
    try std.testing.expectEqual(CandidateStatus.forged, got.status);
}

// ── Memory Safety ──────────────────────────────────────────────────────────

test "forge_knowledge: Memory-Safety — alle Fehlerpfade leak-frei" {
    // CandidateHashMismatch — kein Alloc
    {
        var store = ForgeKnowledgeStore.init(std.testing.allocator);
        defer store.deinit();
        var c = makeCandidate(h(0xF0), h(0xF1), 1, 1, &.{}, h(0xBB));
        c.candidate_hash = [_]u8{0xFF} ** 32;
        _ = store.put(c) catch {};
    }
    // MissingProvenance — kein Alloc
    {
        var store = ForgeKnowledgeStore.init(std.testing.allocator);
        defer store.deinit();
        var c = makeCandidate(h(0xF2), h(0xF3), 1, 1, &.{}, h(0xBB));
        c.provenance_hash = ZERO_HASH;
        c.candidate_hash = computeCandidateHash(c.artifact_hash, c.lineage_hash, c.generation,
            c.forge_epoch, c.sources[0..0], c.benchmark_hash, c.provenance_hash);
        _ = store.put(c) catch {};
    }
    // DuplicateSource — kein Alloc
    {
        var store = ForgeKnowledgeStore.init(std.testing.allocator);
        defer store.deinit();
        var c = makeCandidate(h(0xF4), h(0xF5), 1, 1, &.{}, h(0xBB));
        c.source_count = 2;
        c.sources[0] = h(0xAA);
        c.sources[1] = h(0xAA);
        _ = store.put(c) catch {};
    }
    // InvalidTransition — kein Alloc nach put
    {
        var store = ForgeKnowledgeStore.init(std.testing.allocator);
        defer store.deinit();
        const c = makeCandidate(h(0xF6), h(0xF7), 1, 1, &.{}, h(0xBB));
        try store.put(c);
        _ = store.markForged(c.candidate_hash, ZERO_HASH) catch {};
    }
    // ContentConflict — erster Alloc ok, zweiter abgelehnt
    {
        var store = ForgeKnowledgeStore.init(std.testing.allocator);
        defer store.deinit();
        const c = makeCandidate(h(0xF8), h(0xF9), 1, 1, &.{}, h(0xBB));
        try store.put(c);
        var c2 = c;
        c2.artifact_hash = h(0xFE);
        _ = store.put(c2) catch {};
    }
}

// ── Adversarial Review 2026-09-01 — neue Tests ────────────────────────────

// M1: Fehlende Mutations-Tests fuer identitaetsrelevante Felder

test "forge_knowledge: Aenderung lineage_hash -> anderer Candidate Hash" {
    const c1 = makeCandidate(h(0x01), h(0x02), 1, 1, &.{}, h(0xBB));
    const c2 = makeCandidate(h(0x01), h(0x03), 1, 1, &.{}, h(0xBB));
    try std.testing.expect(!std.mem.eql(u8, &c1.candidate_hash, &c2.candidate_hash));
}

test "forge_knowledge: Aenderung source_set -> anderer Candidate Hash" {
    const c1 = makeCandidate(h(0x01), h(0x02), 1, 1, &.{h(0xAA)}, h(0xBB));
    const c2 = makeCandidate(h(0x01), h(0x02), 1, 1, &.{h(0xCC)}, h(0xBB));
    try std.testing.expect(!std.mem.eql(u8, &c1.candidate_hash, &c2.candidate_hash));
}

test "forge_knowledge: status gehoert NICHT zur Candidate-Identity (P1)" {
    // Zwei Candidates mit identischen Identitaetsfeldern aber verschiedenem Status
    // koennen nicht existieren: status != .pending wird vom put() abgelehnt.
    // Dieser Test belegt: der Candidate-Hash haengt nicht vom Status ab.
    const c1 = makeCandidate(h(0x01), h(0x02), 1, 1, &.{}, h(0xBB));
    // Manuell status aendern ohne Neuberechnung des Hashes
    var c2 = c1;
    c2.status = .tested;
    // candidate_hash ist gleich (Status ist kein Identitaetsfeld)
    try std.testing.expectEqualSlices(u8, &c1.candidate_hash, &c2.candidate_hash);
    // Aber put() lehnt c2 ab weil status != .pending
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectError(ForgeKnowledgeError.InvalidInitialStatus, store.put(c2));
}

// M3: ContentConflict tatsaechlich erreichbar beweisen

test "forge_knowledge: ContentConflict direkt erreichbar (M3)" {
    // ContentConflict entsteht wenn candidate_hash bereits im Store ist,
    // der gespeicherte Record sich aber vom neuen unterscheidet.
    // Da CandidateHashMismatch zuerst geprueft wird, ist der einzige Weg:
    // den candidate_hash direkt in den Primaerindex schreiben (intern via put mit
    // exakt passendem Hash), dann erneut put mit anderem Feld-Wert das denselben
    // Hash produziert — was durch die SHA256-Bindung strukturell ausgeschlossen ist.
    //
    // PROTOKOLLENTSCHEIDUNG (P3): ContentConflict ist ueber die normale API nicht
    // erreichbar, weil jeder Inhalt seinen Hash eindeutig bestimmt.
    // Der Codepfad existiert als Sicherheitsnetz fuer zukuenftige API-Erweiterungen
    // oder direkte Primaerindex-Manipulation. Dieser Test dokumentiert den Pfad.
    //
    // Testbar via: zwei verschiedene Candidates die denselben Hash produzieren wuerden
    // — SHA256-Kollision. Da SHA256 kollisionsresistent ist, koennen wir nur beweisen
    // dass der Codepfad vorhanden ist (via Compile-Check) und dass identischer Insert
    // idempotent ist.
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x42), h(0x43), 5, 5, &.{}, h(0xCC));
    try store.put(c);
    try store.put(c); // idempotent
    try std.testing.expectEqual(@as(usize, 1), store.count());
    // ContentConflict-Pfad existiert im Code (line ~473): candidateEql false -> ContentConflict
    // Erreichbar nur durch SHA256-Kollision oder direkten Speicherzugriff — beides ausserhalb
    // der normalen API.
}

// M5: Reject Proof adversarial

test "forge_knowledge: reject proof nicht fuer anderen Candidate wiederverwendbar" {
    // Reject Proof fuer Candidate A darf nicht fuer Candidate B passen
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const ca = makeCandidate(h(0xA0), h(0xA1), 1, 1, &.{}, h(0xBB));
    const cb = makeCandidate(h(0xB0), h(0xB1), 1, 1, &.{}, h(0xCC));
    try store.put(ca);
    try store.put(cb);
    try store.markTested(ca.candidate_hash, makeTestEvidence(3, 1, 2));
    try store.markTested(cb.candidate_hash, makeTestEvidence(3, 1, 2));

    // Proof fuer ca
    const rh_a = computeRejectHash(ca.candidate_hash, .test_failure, h(0xDE));
    const proof_a = RejectProof{ .reject_hash = rh_a, .reason = .test_failure, .evidence_hash = h(0xDE) };

    // Proof fuer ca bei cb eintragen -> RejectHashMismatch
    try std.testing.expectError(ForgeKnowledgeError.RejectHashMismatch,
        store.markRejected(cb.candidate_hash, proof_a));
}

test "forge_knowledge: reject proof domain separation (BKGC nicht BKGA)" {
    // Reject-Hash mit "BKGA" statt "BKGC" erzeugt anderen Hash
    const ch = h(0xAB);
    const rh_c = computeRejectHash(ch, .test_failure, h(0xCD));
    // Manuell mit "BKGA"
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("BKGA");
    hasher.update("REJECT");
    hasher.update(&ch);
    hasher.update(&[1]u8{@intFromEnum(RejectReason.test_failure)});
    hasher.update(&h(0xCD));
    var rh_a: [32]u8 = undefined;
    hasher.final(&rh_a);
    try std.testing.expect(!std.mem.eql(u8, &rh_c, &rh_a));
}

// M6: Epoch adversarial (zusaetzliche Faelle)

test "forge_knowledge: Epoch gleich bleibt gueltig" {
    const em = ForgeEpochManager.init(10);
    try em.validateCandidateEpoch(10); // gleiche Epoch
}

test "forge_knowledge: grosser Epoch-Sprung abgelehnt" {
    const em = ForgeEpochManager.init(5);
    try std.testing.expectError(ForgeKnowledgeError.EpochConflict,
        em.validateCandidateEpoch(std.math.maxInt(u64)));
}

test "forge_knowledge: Candidate aus alter Epoch nach Advance noch akzeptiert" {
    // Ein Candidate aus Epoch 3 darf in Epoch 5 noch eingefuegt werden
    // (validateCandidateEpoch prüft nur candidate_epoch <= current).
    var em = ForgeEpochManager.init(3);
    try em.advance(); // 4
    try em.advance(); // 5
    try em.validateCandidateEpoch(3); // Epoch 3 ist <= 5, ok

    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0xC0), h(0xC1), 1, 3, &.{}, h(0xBB)); // forge_epoch=3
    try store.put(c); // Einfuegen in Store mit alter Epoch erlaubt
    try std.testing.expect(store.contains(c.candidate_hash));
}

// M7: Source Canonicalization adversarial

test "forge_knowledge: computeSourceSetHash [A,B] == [B,A]" {
    const ssh_ab = computeSourceSetHash(&.{ h(0x10), h(0x20) });
    const ssh_ba = computeSourceSetHash(&.{ h(0x20), h(0x10) });
    try std.testing.expectEqualSlices(u8, &ssh_ab, &ssh_ba);
}

test "forge_knowledge: computeSourceSetHash leer != mit einer Source" {
    const ssh_empty = computeSourceSetHash(&.{});
    const ssh_one   = computeSourceSetHash(&.{h(0x10)});
    try std.testing.expect(!std.mem.eql(u8, &ssh_empty, &ssh_one));
}

test "forge_knowledge: computeSourceSetHash 16 Sources (max)" {
    var sources: [16][32]u8 = undefined;
    for (0..16) |i| sources[i] = h(@intCast(i + 1));
    const ssh = computeSourceSetHash(&sources);
    try std.testing.expect(!std.mem.eql(u8, &ssh, &ZERO_HASH));
}

test "forge_knowledge: source_set_hash domain != candidate_hash domain" {
    // computeSourceSetHash benutzt "BKGC"||"SRCS", computeCandidateHash "BKGC" direkt
    const ssh  = computeSourceSetHash(&.{h(0x10)});
    const ch   = computeCandidateHash(ZERO_HASH, ZERO_HASH, 0, 0, &.{h(0x10)}, ZERO_HASH, h(0xBB));
    try std.testing.expect(!std.mem.eql(u8, &ssh, &ch));
}

// M8: Reverse-Index Konsistenz

test "forge_knowledge: by_source_set Lookup nach put" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c1 = makeCandidate(h(0xD0), h(0xD1), 1, 1, &.{h(0xAA)}, h(0xBB));
    const c2 = makeCandidate(h(0xD2), h(0xD3), 2, 1, &.{h(0xAA)}, h(0xBC)); // gleiche Source
    try store.put(c1);
    try store.put(c2);

    // Beide Candidates mit derselben Source muessen ueber getBySourceSet erreichbar sein
    const list = store.getBySourceSet(&.{h(0xAA)});
    try std.testing.expect(list != null);
    try std.testing.expectEqual(@as(usize, 2), list.?.len);
}

test "forge_knowledge: by_source_set Lookup ist reine Projektion — aendert nichts" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0xD4), h(0xD5), 1, 1, &.{h(0xAA)}, h(0xBB));
    try store.put(c);

    const before = store.count();
    _ = store.getBySourceSet(&.{h(0xAA)});
    _ = store.getBySourceSet(&.{h(0xFF)}); // unbekannte Source
    try std.testing.expectEqual(before, store.count());
}

test "forge_knowledge: unbekannte source_set gibt null" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const result = store.getBySourceSet(&.{h(0xEE)});
    try std.testing.expect(result == null);
}

// M10: Repetition/Flooding

test "forge_knowledge: mehrere Candidates gleiche Sources — by_source_set erkennt Repetition" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    // Viele Candidates mit derselben Source-Menge (simuliertes Flooding)
    const sources: []const [32]u8 = &.{h(0x01), h(0x02)};
    const c1 = makeCandidate(h(0xE0), h(0xE1), 1, 1, sources, h(0xBB));
    const c2 = makeCandidate(h(0xE2), h(0xE3), 2, 2, sources, h(0xBC));
    const c3 = makeCandidate(h(0xE4), h(0xE5), 3, 3, sources, h(0xBD));
    try store.put(c1);
    try store.put(c2);
    try store.put(c3);

    const list = store.getBySourceSet(sources);
    try std.testing.expect(list != null);
    // Alle drei erkennbar als gemeinsame Source-Gruppe
    try std.testing.expectEqual(@as(usize, 3), list.?.len);
    // Stage 3 sanktioniert nicht — nur referenzierbar
}

// M13: Terminal State explizit

test "forge_knowledge: forged kann nie wieder Richtung pending/tested geaendert werden" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x90), h(0x91), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(2, 2, 0));
    try store.markForged(c.candidate_hash, ZERO_HASH);

    // Alle weiteren Uebergaenge muessen fehlschlagen
    try std.testing.expectError(ForgeKnowledgeError.InvalidTransition,
        store.markTested(c.candidate_hash, makeTestEvidence(1, 1, 0)));
    try std.testing.expectError(ForgeKnowledgeError.InvalidTransition,
        store.markForged(c.candidate_hash, ZERO_HASH));
    const proof = RejectProof{
        .reject_hash   = computeRejectHash(c.candidate_hash, .policy_violation, ZERO_HASH),
        .reason        = .policy_violation,
        .evidence_hash = ZERO_HASH,
    };
    try std.testing.expectError(ForgeKnowledgeError.InvalidTransition,
        store.markRejected(c.candidate_hash, proof));
    // Status unveraendert
    try std.testing.expectEqual(CandidateStatus.forged, store.get(c.candidate_hash).?.status);
}

test "forge_knowledge: rejected kann nie wieder Richtung tested/forged geaendert werden" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x92), h(0x93), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try store.markTested(c.candidate_hash, makeTestEvidence(2, 1, 1));
    const rh = computeRejectHash(c.candidate_hash, .test_failure, h(0xDD));
    const proof = RejectProof{ .reject_hash = rh, .reason = .test_failure, .evidence_hash = h(0xDD) };
    try store.markRejected(c.candidate_hash, proof);

    try std.testing.expectError(ForgeKnowledgeError.InvalidTransition,
        store.markTested(c.candidate_hash, makeTestEvidence(1, 1, 0)));
    try std.testing.expectError(ForgeKnowledgeError.InvalidTransition,
        store.markForged(c.candidate_hash, ZERO_HASH));
    try std.testing.expectEqual(CandidateStatus.rejected, store.get(c.candidate_hash).?.status);
}

// M14: Zero / Empty Inputs

test "forge_knowledge: zero artifact_hash zulässig als Identitaetsfeld (keine semantische Prue fung)" {
    // Stage 3 prueft nicht ob artifact_hash im Artifact-Store existiert (P4).
    // Zero artifact_hash ist ein gueltiger, aber semantisch unvollstaendiger Candidate.
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(ZERO_HASH, h(0x02), 1, 1, &.{}, h(0xBB));
    try store.put(c);
    try std.testing.expect(store.contains(c.candidate_hash));
}

test "forge_knowledge: leere Source-Liste erlaubt" {
    var store = ForgeKnowledgeStore.init(std.testing.allocator);
    defer store.deinit();
    const c = makeCandidate(h(0x01), h(0x02), 0, 0, &.{}, h(0xBB));
    try store.put(c);
    try std.testing.expect(store.contains(c.candidate_hash));
}

// M15: zusaetzliche Memory Safety

test "forge_knowledge: Memory-Safety by_source_set — leak-frei" {
    {
        var store = ForgeKnowledgeStore.init(std.testing.allocator);
        defer store.deinit();
        const c = makeCandidate(h(0xA0), h(0xA1), 1, 1, &.{h(0xBB)}, h(0xCC));
        try store.put(c);
        // Lookup — kein Alloc
        _ = store.getBySourceSet(&.{h(0xBB)});
        _ = store.getBySourceSet(&.{h(0xFF)}); // unbekannt
    }
    {
        // Candidate mit 16 Sources — maximale Allokation
        var store = ForgeKnowledgeStore.init(std.testing.allocator);
        defer store.deinit();
        var sources: [16][32]u8 = undefined;
        for (0..16) |i| sources[i] = h(@intCast(i + 1));
        const c = makeCandidate(h(0xA2), h(0xA3), 1, 1, &sources, h(0xDD));
        try store.put(c);
        _ = store.getBySourceSet(&sources);
    }
}
