/// BKGDB Evolution Memory v1 — Evidence Store
///
/// Status: STAGE 5 — PROVEN & FROZEN — 2026-09-01
/// SHA256: 64f0eb234fc0e0819552fad5c6a2ab0ff300c6086adb4674716426e1ea8f2bc7
/// Spec:   docs/BKGDB_EVOLUTION_MEMORY_v1.md §2.5 Evolutionsevidence-Dimension
///
/// WICHTIG: Evidence Store State != Ledger Truth
/// Dieses Modul ist eine reine APPEND-ONLY-Projektion aus Ledger-Events.
/// Kanonische Wahrheit liegt im Ledger/Rebuilder.
/// Keine Evidence darf nach dem Schreiben geändert oder gelöscht werden.
///
/// Enthält:
///   - Watcher-Evidence (`watcher_evidence_submitted`-Events)
///   - Guardian-Evidence (`guardian_authorization_granted`-Events)
///   - Verifikationsresultate (Testergebnis-Referenzen pro Artefakt + Validator-Lauf)
///   - Causal Fingerprints (State-Fingerprints für Challenge-Vergleich)
///
/// Domain Separation:
///   evidence_hash = SHA256("BKCEV" || evidence_cid || kind_byte || ledger_event_hash)
///
/// Protokollentscheidungen:
///   P1: Evidence ist APPEND-ONLY. Kein Update, kein Delete.
///   P2: Idempotenz: gleicher ledger_event_hash wird still ignoriert (kein Duplikat).
///   P3: Jeder Evidence-Eintrag MUSS einen nicht-zero ledger_event_hash haben.
///   P4: EvidenceKind::verification_result ist kein externes Ledger-Event,
///       sondern eine lokale Derive-Projektion — darf zero ledger_event_hash haben.
///       Wird mit `applyVerificationResult()` eingetragen.
///   P5: Causal Fingerprints sind Rebuilder-erzeugt. Dürfen überschrieben werden
///       wenn ein neuerer Fingerprint für denselben State vorliegt (Derive-Schicht).
///   P6: Cross-Store-Referenzen (evidence_cid, subject_artifact_cid) sind reine Referenzen —
///       Existenzprüfung liegt beim Caller.
///
const std = @import("std");

// ── Konstanten ────────────────────────────────────────────────────────────

/// Maximale Anzahl Evidence-Einträge im Store.
pub const MAX_EVIDENCE_ENTRIES: usize = 512;

/// Maximale Anzahl Fingerprints im Store.
pub const MAX_FINGERPRINTS: usize = 64;

/// Domain-Prefix für Evidence-Hashes (5 Bytes).
pub const DOMAIN_PREFIX: [5]u8 = "BKCEV".*;

/// Zero-Hash (kein Event / kein Referenz-Nachweis).
pub const ZERO_HASH: [32]u8 = [_]u8{0} ** 32;

// ── EvidenceKind ──────────────────────────────────────────────────────────

/// Art der Evidence.
pub const EvidenceKind = enum(u8) {
    /// Watcher-Beobachtung: `watcher_evidence_submitted`-Event
    watcher_observation   = 0x01,
    /// Guardian-Autorisierung: `guardian_authorization_granted`-Event
    guardian_authorization = 0x02,
    /// Verifikationsresultat: lokale Derive-Projektion (kein Ledger-Event)
    verification_result   = 0x03,
    /// Diversity-Signal: vorberechneter Score (Derive-Schicht)
    diversity_signal      = 0x04,
};

// ── EvidenceRecord ────────────────────────────────────────────────────────

/// Ein Evidence-Eintrag in der Evolutionsevidence-Dimension.
/// APPEND-ONLY — wird nach dem Schreiben nie verändert.
pub const EvidenceRecord = struct {
    /// Domain-Prefix ("BKCEV")
    domain_prefix: [5]u8,
    /// Art der Evidence
    kind: EvidenceKind,
    /// CID des Evidence-Blobs (content-addressed, via IdType::evidence)
    evidence_cid: [32]u8,
    /// Ledger-Event-Hash (ZERO bei verification_result / diversity_signal)
    ledger_event_hash: [32]u8,
    /// Subject: Artefakt-CID oder Work-Context-CID, auf das sich die Evidence bezieht
    subject_cid: [32]u8,
    /// SOUL-CID des einreichenden Watchers / Guardian (ZERO wenn nicht relevant)
    submitter_soul_cid: [32]u8,
    /// Forge-Epoch zum Zeitpunkt der Einreichung (0 wenn nicht relevant)
    epoch: u64,
    /// Timestamp aus dem Ledger-Event (0 bei lokalen Derive-Einträgen)
    event_ts: i64,
    /// Deterministischer Evidence-Hash dieser Projektion.
    /// SHA256("BKCEV" || evidence_cid || kind_byte || ledger_event_hash)
    evidence_hash: [32]u8,
};

// ── VerificationResultRecord ──────────────────────────────────────────────

/// Ergebnis eines Validator-Laufs für ein bestimmtes Artefakt.
/// Lokale Derive-Projektion — kein Ledger-Event erforderlich.
pub const VerificationResultRecord = struct {
    /// Artefakt-CID, das validiert wurde
    artifact_cid: [32]u8,
    /// 0x01 = pass, 0x00 = fail
    result: u8,
    /// Testvektoren insgesamt
    tv_total: u8,
    /// Testvektoren bestanden
    tv_passed: u8,
    /// Epoch des Validierungs-Laufs
    validated_at_epoch: u64,
    /// Timestamp des Validierungs-Laufs
    validated_at_ts: i64,
    /// Validator-Lauf-ID (opak, z.B. SHA256 des Validator-Inputs)
    run_id: [32]u8,
};

// ── CausalFingerprint ─────────────────────────────────────────────────────

/// State-Fingerprint für Challenge-Vergleich.
/// Rebuilder-erzeugt. Darf bei neuem Rebuilder-Lauf überschrieben werden (P5).
pub const CausalFingerprint = struct {
    /// Harness-ID, auf das sich der Fingerprint bezieht
    harness_id: [32]u8,
    /// Epoch des Fingerprints
    epoch: u64,
    /// Deterministischer Fingerprint-Hash (SHA256 über relevante State-Felder)
    fingerprint: [32]u8,
    /// Ledger-Event-Hash des letzten State-Events, aus dem der Fingerprint berechnet wurde
    source_event_hash: [32]u8,
};

// ── Fehlertypen ───────────────────────────────────────────────────────────

pub const EvidenceError = error{
    /// Speicherallokation fehlgeschlagen
    OutOfMemory,
    /// Kein Platz für weitere Evidence-Einträge (MAX_EVIDENCE_ENTRIES erreicht)
    StoreFull,
    /// Kein Platz für weitere Fingerprints (MAX_FINGERPRINTS erreicht)
    FingerprintsFull,
    /// Ungültiger Ledger-Event-Hash (ZERO für Ledger-Events verboten)
    InvalidEventHash,
    /// Ungültige Evidence-CID (ZERO verboten)
    InvalidEvidenceCid,
    /// Ungültige subject_cid (ZERO verboten)
    InvalidSubjectCid,
};

// ── EvidenceStore ─────────────────────────────────────────────────────────

/// In-Memory-APPEND-ONLY-Store der Evolutionsevidence-Dimension.
///
/// Schreibhoheit:
///   - Watcher: applyWatcherEvidence()
///   - Guardian: applyGuardianEvidence()
///   - Derive: applyVerificationResult(), applyDiversitySignal()
///   - Rebuilder: upsertCausalFingerprint()
pub const EvidenceStore = struct {
    allocator: std.mem.Allocator,

    /// Alle Evidence-Einträge (APPEND-ONLY, kein Delete).
    entries: std.ArrayList(EvidenceRecord),

    /// Sekundärindex: ledger_event_hash → Index in entries (nur für Ledger-Events).
    by_event_hash: std.AutoHashMap([32]u8, usize),

    /// Sekundärindex: evidence_cid → Index in entries.
    by_evidence_cid: std.AutoHashMap([32]u8, usize),

    /// Causal Fingerprints (Rebuilder-erzeugt, darf überschrieben werden).
    fingerprints: std.ArrayList(CausalFingerprint),

    /// Index: harness_id → Index in fingerprints.
    fingerprint_by_harness: std.AutoHashMap([32]u8, usize),

    // ── Lifecycle ─────────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator) EvidenceStore {
        return .{
            .allocator             = allocator,
            .entries               = std.ArrayList(EvidenceRecord).empty,
            .by_event_hash         = std.AutoHashMap([32]u8, usize).init(allocator),
            .by_evidence_cid       = std.AutoHashMap([32]u8, usize).init(allocator),
            .fingerprints          = std.ArrayList(CausalFingerprint).empty,
            .fingerprint_by_harness = std.AutoHashMap([32]u8, usize).init(allocator),
        };
    }

    pub fn deinit(self: *EvidenceStore) void {
        self.entries.deinit(self.allocator);
        self.by_event_hash.deinit();
        self.by_evidence_cid.deinit();
        self.fingerprints.deinit(self.allocator);
        self.fingerprint_by_harness.deinit();
    }

    // ── Watcher Evidence ──────────────────────────────────────────────────

    /// Verarbeitet ein `watcher_evidence_submitted`-Event.
    ///
    /// P2: Idempotenz — gleicher ledger_event_hash wird still ignoriert.
    /// P3: ledger_event_hash darf nicht ZERO sein.
    pub fn applyWatcherEvidence(
        self: *EvidenceStore,
        evidence_cid: [32]u8,
        ledger_event_hash: [32]u8,
        subject_cid: [32]u8,
        submitter_soul_cid: [32]u8,
        epoch: u64,
        event_ts: i64,
    ) EvidenceError!void {
        if (isZeroHash(ledger_event_hash)) return error.InvalidEventHash;
        if (isZeroHash(evidence_cid)) return error.InvalidEvidenceCid;
        if (isZeroHash(subject_cid)) return error.InvalidSubjectCid;
        try self.appendEntry(.{
            .kind              = .watcher_observation,
            .evidence_cid      = evidence_cid,
            .ledger_event_hash = ledger_event_hash,
            .subject_cid       = subject_cid,
            .submitter_soul_cid = submitter_soul_cid,
            .epoch             = epoch,
            .event_ts          = event_ts,
        });
    }

    // ── Guardian Evidence ─────────────────────────────────────────────────

    /// Verarbeitet ein `guardian_authorization_granted`-Event.
    ///
    /// P2: Idempotenz — gleicher ledger_event_hash wird still ignoriert.
    /// P3: ledger_event_hash darf nicht ZERO sein.
    pub fn applyGuardianEvidence(
        self: *EvidenceStore,
        evidence_cid: [32]u8,
        ledger_event_hash: [32]u8,
        subject_cid: [32]u8,
        guardian_soul_cid: [32]u8,
        epoch: u64,
        event_ts: i64,
    ) EvidenceError!void {
        if (isZeroHash(ledger_event_hash)) return error.InvalidEventHash;
        if (isZeroHash(evidence_cid)) return error.InvalidEvidenceCid;
        if (isZeroHash(subject_cid)) return error.InvalidSubjectCid;
        try self.appendEntry(.{
            .kind              = .guardian_authorization,
            .evidence_cid      = evidence_cid,
            .ledger_event_hash = ledger_event_hash,
            .subject_cid       = subject_cid,
            .submitter_soul_cid = guardian_soul_cid,
            .epoch             = epoch,
            .event_ts          = event_ts,
        });
    }

    // ── Verification Result ───────────────────────────────────────────────

    /// Speichert ein Verifikationsresultat (lokale Derive-Projektion).
    ///
    /// P4: ledger_event_hash = ZERO ist bei verification_result erlaubt.
    /// P2: Idempotenz per run_id (als evidence_cid verwendet).
    pub fn applyVerificationResult(
        self: *EvidenceStore,
        result: VerificationResultRecord,
    ) EvidenceError!void {
        if (isZeroHash(result.artifact_cid)) return error.InvalidSubjectCid;
        // run_id dient als evidence_cid für Idempotenz
        if (isZeroHash(result.run_id)) return error.InvalidEvidenceCid;
        try self.appendEntry(.{
            .kind              = .verification_result,
            .evidence_cid      = result.run_id,
            .ledger_event_hash = ZERO_HASH, // kein Ledger-Event (P4)
            .subject_cid       = result.artifact_cid,
            .submitter_soul_cid = ZERO_HASH,
            .epoch             = result.validated_at_epoch,
            .event_ts          = result.validated_at_ts,
        });
    }

    // ── Diversity Signal ──────────────────────────────────────────────────

    /// Speichert ein Diversity-Signal (Derive-Schicht).
    ///
    /// P4: ledger_event_hash = ZERO erlaubt (lokale Ableitung).
    /// evidence_cid wird als Score-ID verwendet (nicht ZERO).
    pub fn applyDiversitySignal(
        self: *EvidenceStore,
        score_id: [32]u8,
        subject_cid: [32]u8,
        epoch: u64,
        event_ts: i64,
    ) EvidenceError!void {
        if (isZeroHash(score_id)) return error.InvalidEvidenceCid;
        if (isZeroHash(subject_cid)) return error.InvalidSubjectCid;
        try self.appendEntry(.{
            .kind              = .diversity_signal,
            .evidence_cid      = score_id,
            .ledger_event_hash = ZERO_HASH,
            .subject_cid       = subject_cid,
            .submitter_soul_cid = ZERO_HASH,
            .epoch             = epoch,
            .event_ts          = event_ts,
        });
    }

    // ── Causal Fingerprint ────────────────────────────────────────────────

    /// Speichert oder aktualisiert einen Causal Fingerprint für eine Harness-ID.
    ///
    /// P5: Erlaubt Überschreiben bei neuem Fingerprint für dieselbe harness_id.
    pub fn upsertCausalFingerprint(
        self: *EvidenceStore,
        harness_id: [32]u8,
        epoch: u64,
        fingerprint: [32]u8,
        source_event_hash: [32]u8,
    ) EvidenceError!void {
        if (isZeroHash(harness_id)) return error.InvalidSubjectCid;
        if (isZeroHash(source_event_hash)) return error.InvalidEventHash;

        const fp = CausalFingerprint{
            .harness_id        = harness_id,
            .epoch             = epoch,
            .fingerprint       = fingerprint,
            .source_event_hash = source_event_hash,
        };

        if (self.fingerprint_by_harness.get(harness_id)) |idx| {
            // P5: Überschreiben erlaubt
            self.fingerprints.items[idx] = fp;
        } else {
            if (self.fingerprints.items.len >= MAX_FINGERPRINTS) return error.FingerprintsFull;
            const idx = self.fingerprints.items.len;
            try self.fingerprints.append(self.allocator, fp);
            errdefer _ = self.fingerprints.pop();
            try self.fingerprint_by_harness.put(harness_id, idx);
        }
    }

    // ── Lookup ─────────────────────────────────────────────────────────────

    /// Sucht Evidence per ledger_event_hash. Gibt null zurück wenn nicht gefunden.
    pub fn getByEventHash(self: *const EvidenceStore, event_hash: [32]u8) ?*const EvidenceRecord {
        const idx = self.by_event_hash.get(event_hash) orelse return null;
        return &self.entries.items[idx];
    }

    /// Sucht Evidence per evidence_cid. Gibt null zurück wenn nicht gefunden.
    pub fn getByEvidenceCid(self: *const EvidenceStore, evidence_cid: [32]u8) ?*const EvidenceRecord {
        const idx = self.by_evidence_cid.get(evidence_cid) orelse return null;
        return &self.entries.items[idx];
    }

    /// Sucht Causal Fingerprint per harness_id. Gibt null zurück wenn nicht gefunden.
    pub fn getFingerprintByHarness(self: *const EvidenceStore, harness_id: [32]u8) ?*const CausalFingerprint {
        const idx = self.fingerprint_by_harness.get(harness_id) orelse return null;
        return &self.fingerprints.items[idx];
    }

    /// Gibt die Gesamtzahl der Evidence-Einträge zurück.
    pub fn count(self: *const EvidenceStore) usize {
        return self.entries.items.len;
    }

    /// Gibt alle Einträge eines bestimmten Typs zurück (gefiltert auf Slice).
    /// Schreibt in `out` und gibt die Anzahl der gefundenen Einträge zurück.
    /// `out` muss groß genug sein.
    pub fn collectByKind(
        self: *const EvidenceStore,
        kind: EvidenceKind,
        out: []EvidenceRecord,
    ) usize {
        var n: usize = 0;
        for (self.entries.items) |*e| {
            if (e.kind == kind and n < out.len) {
                out[n] = e.*;
                n += 1;
            }
        }
        return n;
    }

    // ── Interne Hilfsfunktion ─────────────────────────────────────────────

    const EntryInput = struct {
        kind: EvidenceKind,
        evidence_cid: [32]u8,
        ledger_event_hash: [32]u8,
        subject_cid: [32]u8,
        submitter_soul_cid: [32]u8,
        epoch: u64,
        event_ts: i64,
    };

    fn appendEntry(self: *EvidenceStore, input: EntryInput) EvidenceError!void {
        // P2: Idempotenz per evidence_cid
        if (self.by_evidence_cid.contains(input.evidence_cid)) return;
        // P2: Idempotenz per ledger_event_hash (nur für Ledger-Events)
        if (!isZeroHash(input.ledger_event_hash) and
            self.by_event_hash.contains(input.ledger_event_hash)) return;

        if (self.entries.items.len >= MAX_EVIDENCE_ENTRIES) return error.StoreFull;

        const rec = EvidenceRecord{
            .domain_prefix      = DOMAIN_PREFIX,
            .kind               = input.kind,
            .evidence_cid       = input.evidence_cid,
            .ledger_event_hash  = input.ledger_event_hash,
            .subject_cid        = input.subject_cid,
            .submitter_soul_cid = input.submitter_soul_cid,
            .epoch              = input.epoch,
            .event_ts           = input.event_ts,
            .evidence_hash      = computeEvidenceHash(
                input.evidence_cid,
                input.kind,
                input.ledger_event_hash,
            ),
        };

        const idx = self.entries.items.len;
        // 1. Record appenden
        try self.entries.append(self.allocator, rec);
        errdefer _ = self.entries.pop();
        // 2. evidence_cid-Index (kann OOM auslösen → entries rollback via errdefer oben)
        try self.by_evidence_cid.put(input.evidence_cid, idx);
        errdefer _ = self.by_evidence_cid.remove(input.evidence_cid);
        // 3. Ledger-Event-Index nur wenn nicht ZERO
        //    Fehler hier → errdefer oben rollt entries + evidence_cid zurück
        if (!isZeroHash(input.ledger_event_hash)) {
            try self.by_event_hash.put(input.ledger_event_hash, idx);
        }
    }
};

// ── computeEvidenceHash ───────────────────────────────────────────────────

/// Berechnet den deterministischen Evidence-Hash.
/// SHA256("BKCEV" || evidence_cid || kind_byte || ledger_event_hash)
pub fn computeEvidenceHash(
    evidence_cid: [32]u8,
    kind: EvidenceKind,
    ledger_event_hash: [32]u8,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&DOMAIN_PREFIX);
    hasher.update(&evidence_cid);
    const kind_byte = [1]u8{@intFromEnum(kind)};
    hasher.update(&kind_byte);
    hasher.update(&ledger_event_hash);
    return hasher.finalResult();
}

// ── Hilfsfunktionen ───────────────────────────────────────────────────────

fn isZeroHash(hash: [32]u8) bool {
    return std.mem.eql(u8, &hash, &ZERO_HASH);
}

fn h(comptime prefix: u8) [32]u8 {
    var hash: [32]u8 = ZERO_HASH;
    hash[0] = prefix;
    return hash;
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "evidence_store: computeEvidenceHash deterministisch" {
    const cid = h(0x01);
    const ev  = h(0x02);
    const a = computeEvidenceHash(cid, .watcher_observation, ev);
    const b = computeEvidenceHash(cid, .watcher_observation, ev);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "evidence_store: computeEvidenceHash Domain-Separation" {
    const cid = h(0x01);
    const ev  = h(0x02);
    const h1 = computeEvidenceHash(cid, .watcher_observation,   ev);
    const h2 = computeEvidenceHash(cid, .guardian_authorization, ev);
    const h3 = computeEvidenceHash(cid, .verification_result,   ev);
    // Verschiedene kinds → verschiedene Hashes
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
    try std.testing.expect(!std.mem.eql(u8, &h1, &h3));
    try std.testing.expect(!std.mem.eql(u8, &h2, &h3));
}

test "evidence_store: computeEvidenceHash verschiedene evidence_cid" {
    const ev = h(0x02);
    const a = computeEvidenceHash(h(0x01), .watcher_observation, ev);
    const b = computeEvidenceHash(h(0x03), .watcher_observation, ev);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "evidence_store: applyWatcherEvidence Grundfall" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.applyWatcherEvidence(h(0x01), h(0xAA), h(0x02), h(0x03), 10, 1000);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    const rec = store.getByEventHash(h(0xAA));
    try std.testing.expect(rec != null);
    try std.testing.expectEqual(EvidenceKind.watcher_observation, rec.?.kind);
    try std.testing.expectEqualSlices(u8, &h(0x01), &rec.?.evidence_cid);
    try std.testing.expectEqualSlices(u8, &h(0x02), &rec.?.subject_cid);
}

test "evidence_store: applyWatcherEvidence Idempotenz per evidence_cid" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.applyWatcherEvidence(h(0x01), h(0xAA), h(0x02), h(0x03), 10, 1000);
    // Selber evidence_cid (anderer event_hash) → still ignoriert
    try store.applyWatcherEvidence(h(0x01), h(0xBB), h(0x02), h(0x03), 10, 1001);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "evidence_store: applyWatcherEvidence Idempotenz per ledger_event_hash" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.applyWatcherEvidence(h(0x01), h(0xAA), h(0x02), h(0x03), 10, 1000);
    // Selber event_hash (anderer evidence_cid) → still ignoriert (P2)
    try store.applyWatcherEvidence(h(0x05), h(0xAA), h(0x02), h(0x03), 10, 1000);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "evidence_store: applyWatcherEvidence ZERO event_hash verboten" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidEventHash,
        store.applyWatcherEvidence(h(0x01), ZERO_HASH, h(0x02), h(0x03), 10, 1000));
}

test "evidence_store: applyWatcherEvidence ZERO evidence_cid verboten" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidEvidenceCid,
        store.applyWatcherEvidence(ZERO_HASH, h(0xAA), h(0x02), h(0x03), 10, 1000));
}

test "evidence_store: applyWatcherEvidence ZERO subject_cid verboten" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidSubjectCid,
        store.applyWatcherEvidence(h(0x01), h(0xAA), ZERO_HASH, h(0x03), 10, 1000));
}

test "evidence_store: applyGuardianEvidence Grundfall" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.applyGuardianEvidence(h(0x10), h(0xBB), h(0x20), h(0x30), 5, 2000);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    const rec = store.getByEventHash(h(0xBB));
    try std.testing.expect(rec != null);
    try std.testing.expectEqual(EvidenceKind.guardian_authorization, rec.?.kind);
    try std.testing.expectEqualSlices(u8, &h(0x10), &rec.?.evidence_cid);
}

test "evidence_store: applyGuardianEvidence ZERO event_hash verboten" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidEventHash,
        store.applyGuardianEvidence(h(0x10), ZERO_HASH, h(0x20), h(0x30), 5, 2000));
}

test "evidence_store: applyVerificationResult Grundfall" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    const result = VerificationResultRecord{
        .artifact_cid       = h(0x42),
        .result             = 0x01,
        .tv_total           = 3,
        .tv_passed          = 3,
        .validated_at_epoch = 7,
        .validated_at_ts    = 5000,
        .run_id             = h(0xCC),
    };

    try store.applyVerificationResult(result);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    const rec = store.getByEvidenceCid(h(0xCC));
    try std.testing.expect(rec != null);
    try std.testing.expectEqual(EvidenceKind.verification_result, rec.?.kind);
    // P4: ledger_event_hash darf ZERO sein
    try std.testing.expectEqualSlices(u8, &ZERO_HASH, &rec.?.ledger_event_hash);
    try std.testing.expectEqualSlices(u8, &h(0x42), &rec.?.subject_cid);
}

test "evidence_store: applyVerificationResult ZERO run_id verboten" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    const result = VerificationResultRecord{
        .artifact_cid       = h(0x42),
        .result             = 0x01,
        .tv_total           = 3,
        .tv_passed          = 3,
        .validated_at_epoch = 7,
        .validated_at_ts    = 5000,
        .run_id             = ZERO_HASH,
    };

    try std.testing.expectError(error.InvalidEvidenceCid,
        store.applyVerificationResult(result));
}

test "evidence_store: applyDiversitySignal Grundfall" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.applyDiversitySignal(h(0x77), h(0x88), 3, 3000);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    const rec = store.getByEvidenceCid(h(0x77));
    try std.testing.expect(rec != null);
    try std.testing.expectEqual(EvidenceKind.diversity_signal, rec.?.kind);
    // P4: ZERO event_hash erlaubt
    try std.testing.expectEqualSlices(u8, &ZERO_HASH, &rec.?.ledger_event_hash);
}

test "evidence_store: upsertCausalFingerprint Grundfall" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.upsertCausalFingerprint(h(0x01), 1, h(0xF0), h(0xEE));
    const fp = store.getFingerprintByHarness(h(0x01));
    try std.testing.expect(fp != null);
    try std.testing.expectEqualSlices(u8, &h(0xF0), &fp.?.fingerprint);
    try std.testing.expectEqualSlices(u8, &h(0xEE), &fp.?.source_event_hash);
    try std.testing.expectEqual(@as(u64, 1), fp.?.epoch);
}

test "evidence_store: upsertCausalFingerprint P5 Überschreiben" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.upsertCausalFingerprint(h(0x01), 1, h(0xF1), h(0xE1));
    // P5: Überschreiben mit neuerem Fingerprint erlaubt
    try store.upsertCausalFingerprint(h(0x01), 2, h(0xF2), h(0xE2));

    const fp = store.getFingerprintByHarness(h(0x01));
    try std.testing.expect(fp != null);
    try std.testing.expectEqualSlices(u8, &h(0xF2), &fp.?.fingerprint);
    try std.testing.expectEqual(@as(u64, 2), fp.?.epoch);
}

test "evidence_store: upsertCausalFingerprint ZERO harness_id verboten" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidSubjectCid,
        store.upsertCausalFingerprint(ZERO_HASH, 1, h(0xF1), h(0xE1)));
}

test "evidence_store: upsertCausalFingerprint ZERO source_event_hash verboten" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidEventHash,
        store.upsertCausalFingerprint(h(0x01), 1, h(0xF1), ZERO_HASH));
}

test "evidence_store: gemischte Einträge mehrere Typen" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.applyWatcherEvidence(h(0x01), h(0xA1), h(0x10), h(0x20), 1, 100);
    try store.applyGuardianEvidence(h(0x02), h(0xA2), h(0x10), h(0x30), 1, 200);
    try store.applyVerificationResult(.{
        .artifact_cid = h(0x10), .result = 0x01, .tv_total = 2, .tv_passed = 2,
        .validated_at_epoch = 1, .validated_at_ts = 300, .run_id = h(0x03),
    });
    try store.applyDiversitySignal(h(0x04), h(0x10), 1, 400);

    try std.testing.expectEqual(@as(usize, 4), store.count());

    // collectByKind
    var watcher_out: [16]EvidenceRecord = undefined;
    var guardian_out: [16]EvidenceRecord = undefined;
    const n_watcher = store.collectByKind(.watcher_observation, &watcher_out);
    const n_guardian = store.collectByKind(.guardian_authorization, &guardian_out);
    try std.testing.expectEqual(@as(usize, 1), n_watcher);
    try std.testing.expectEqual(@as(usize, 1), n_guardian);
}

test "evidence_store: StoreFull — adversarial" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    // Fülle den Store bis auf MAX_EVIDENCE_ENTRIES
    var i: usize = 0;
    while (i < MAX_EVIDENCE_ENTRIES) : (i += 1) {
        var ev_cid: [32]u8 = ZERO_HASH;
        ev_cid[0] = @as(u8, @truncate(i >> 8));
        ev_cid[1] = @as(u8, @truncate(i));
        ev_cid[2] = 0xAA;
        var ev_hash: [32]u8 = ZERO_HASH;
        ev_hash[0] = @as(u8, @truncate(i >> 8));
        ev_hash[1] = @as(u8, @truncate(i));
        ev_hash[2] = 0xBB;
        try store.applyWatcherEvidence(ev_cid, ev_hash, h(0x10), h(0x20), 1, @as(i64, @intCast(i)));
    }

    try std.testing.expectEqual(MAX_EVIDENCE_ENTRIES, store.count());

    // Nächster Eintrag muss StoreFull auslösen
    try std.testing.expectError(error.StoreFull,
        store.applyWatcherEvidence(h(0xFF), h(0xFE), h(0x10), h(0x20), 1, 99999));
}

test "evidence_store: deinit gibt Speicher frei" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.applyWatcherEvidence(h(0x01), h(0xA1), h(0x02), h(0x03), 1, 100);
    try store.applyGuardianEvidence(h(0x04), h(0xA4), h(0x05), h(0x06), 1, 200);
    try store.upsertCausalFingerprint(h(0x10), 1, h(0xF0), h(0xEE));
    // deinit via defer — kein Leak unter std.testing.allocator
}

test "evidence_store: EvidenceRecord hat korrekten domain_prefix" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.applyWatcherEvidence(h(0x01), h(0xA1), h(0x02), h(0x03), 1, 100);
    const rec = store.getByEventHash(h(0xA1)).?;
    try std.testing.expectEqualSlices(u8, &DOMAIN_PREFIX, &rec.domain_prefix);
}

test "evidence_store: evidence_hash ist deterministisch berechnet" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.applyWatcherEvidence(h(0x01), h(0xA1), h(0x02), h(0x03), 1, 100);
    const rec = store.getByEventHash(h(0xA1)).?;

    const expected = computeEvidenceHash(h(0x01), .watcher_observation, h(0xA1));
    try std.testing.expectEqualSlices(u8, &expected, &rec.evidence_hash);
}

test "evidence_store: FingerprintsFull" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    var i: u8 = 0;
    while (i < MAX_FINGERPRINTS) : (i += 1) {
        var harness: [32]u8 = ZERO_HASH;
        harness[0] = i + 1;
        var ev: [32]u8 = ZERO_HASH;
        ev[0] = 0xFF;
        ev[1] = i + 1;
        try store.upsertCausalFingerprint(harness, @as(u64, i), h(0xF0), ev);
    }

    var overflow_harness: [32]u8 = ZERO_HASH;
    overflow_harness[0] = 0xFE;
    overflow_harness[1] = 0xFE;
    try std.testing.expectError(error.FingerprintsFull,
        store.upsertCausalFingerprint(overflow_harness, 9999, h(0xF0), h(0xEE)));
}

test "evidence_store: APPEND-ONLY — kein Update nach Eintrag" {
    // Adversarial: Einmal eingetragen, kann ein Evidence-Eintrag nicht überschrieben werden.
    // Idempotenz per evidence_cid: zweiter Aufruf mit gleicher evidence_cid wird ignoriert.
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.applyWatcherEvidence(h(0x01), h(0xAA), h(0x02), h(0x03), 10, 1000);
    // Gleiche evidence_cid, anderen event_hash → wird ignoriert (APPEND-ONLY)
    try store.applyWatcherEvidence(h(0x01), h(0xBB), h(0x99), h(0x03), 20, 2000);

    try std.testing.expectEqual(@as(usize, 1), store.count());
    const rec = store.getByEventHash(h(0xAA)).?;
    // Original-subject_cid erhalten
    try std.testing.expectEqualSlices(u8, &h(0x02), &rec.subject_cid);
    // Neuer event_hash nicht im Index
    try std.testing.expect(store.getByEventHash(h(0xBB)) == null);
}

test "evidence_store: by_event_hash nur für Ledger-Events gesetzt" {
    // Verification-Result und Diversity-Signal haben ZERO event_hash → kein Index.
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    try store.applyVerificationResult(.{
        .artifact_cid = h(0x42), .result = 0x01, .tv_total = 1, .tv_passed = 1,
        .validated_at_epoch = 1, .validated_at_ts = 100, .run_id = h(0xCC),
    });
    try store.applyDiversitySignal(h(0x77), h(0x88), 2, 200);

    // ZERO event_hash darf nicht im by_event_hash-Index stehen
    try std.testing.expect(store.getByEventHash(ZERO_HASH) == null);
    // evidence_cid-Lookups funktionieren
    try std.testing.expect(store.getByEvidenceCid(h(0xCC)) != null);
    try std.testing.expect(store.getByEvidenceCid(h(0x77)) != null);
}

test "evidence_store: Watcher + Guardian für selbe subject_cid unabhängig" {
    const allocator = std.testing.allocator;
    var store = EvidenceStore.init(allocator);
    defer store.deinit();

    const subject = h(0x50);
    try store.applyWatcherEvidence(h(0x01), h(0xA1), subject, h(0x10), 1, 100);
    try store.applyGuardianEvidence(h(0x02), h(0xA2), subject, h(0x20), 1, 200);

    try std.testing.expectEqual(@as(usize, 2), store.count());

    var watcher_buf: [4]EvidenceRecord = undefined;
    var guardian_buf: [4]EvidenceRecord = undefined;
    const nw = store.collectByKind(.watcher_observation, &watcher_buf);
    const ng = store.collectByKind(.guardian_authorization, &guardian_buf);
    try std.testing.expectEqual(@as(usize, 1), nw);
    try std.testing.expectEqual(@as(usize, 1), ng);
    try std.testing.expectEqualSlices(u8, &subject, &watcher_buf[0].subject_cid);
    try std.testing.expectEqualSlices(u8, &subject, &guardian_buf[0].subject_cid);
}
