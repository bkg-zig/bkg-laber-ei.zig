/// BKGDB Evolution Memory v1 — Agent Lineage Projection
///
/// Status: STAGE 4 — PROVEN & FROZEN — 2026-09-01
/// SHA256: 94f7a083c35c57b003aa74a83e5bd06f368ca94849b3ec174ee7caf16d8743cc
/// Spec:   docs/BKGDB_EVOLUTION_MEMORY_v1.md §2.4 Agenten-Lineage-Dimension
///
/// SOUL-CID ist WRITE ONCE.
/// Kein Agent kann seine Ursprungs-Identität wechseln. Manifestationen dürfen wechseln.
///
/// WICHTIG: Agent Lineage State != Ledger Truth
/// Dieses Modul ist eine reine Projektion aus Ledger-Events.
/// Kanonische Wahrheit liegt im Ledger/Rebuilder.
/// Kein Schreibendpunkt hier gilt als primäre Quelle.
///
/// Domain Separation:
///   agent_lineage_hash = SHA256("BKGE" || soul_cid || latest_harness_id || latest_boot_ts_le8)
///
/// Protokollentscheidungen:
///   P1: SOUL-CID ist WRITE ONCE — Zweites `applySoulAnchored` mit ANDEREM soul_cid-Wert
///       ist nur ein neuer Record. Dieselbe SOUL mit demselben soul_cid ist idempotent.
///       Es gibt keine Situation, wo derselbe HashMap-Key einen anderen soul_cid-Wert im
///       Record produziert — WRITE-ONCE ist durch SHA256-Kollisionsresistenz strukturell
///       abgesichert. `SoulCidAlreadySet` ist für die Spore-Semantik reserviert (not used).
///   P2: Idempotentes Hinzufügen: gleicher Event-Hash wird still ignoriert (kein Duplikat)
///   P3: C2-Bindungen: `establish` und `revoke` müssen für denselben demon_id erfolgen.
///       Bei mehreren historischen Bindungen für denselben demon_id (revoked + active)
///       trifft `revoke` immer die aktive Bindung (letzte in der Liste).
///   P4: `last_minting_event` = letzter `artifact_forged`-Event-Hash in zeitlicher Reihenfolge
///   P5: Cross-Store-Referenzen (artifact_cid, spore_cid, event_hash) sind reine Referenzen —
///       Existenzprüfung liegt beim Caller
///   P6: Ein harness_id ist immer genau einer SOUL zugeordnet. Ein zweites
///       `applyManifestationBooted` mit identischer harness_id von einer anderen SOUL
///       schlägt mit `HarnessIdConflict` fehl.
///
const std = @import("std");

// ── Konstanten ────────────────────────────────────────────────────────────

/// Maximale Anzahl Manifestationen (boot-Events) pro Agent.
pub const MAX_MANIFESTATIONS: usize = 32;

/// Maximale Anzahl gespeicherter Capability-Events (forged + absorbed) pro Agent.
pub const MAX_CAPABILITY_EVENTS: usize = 128;

/// Maximale Anzahl aktiver C2-Bindungen gleichzeitig.
pub const MAX_C2_BINDINGS: usize = 16;

/// Domain-Prefix für Agent-Lineage-Hashes (4 Bytes).
pub const DOMAIN_PREFIX: [4]u8 = "BKGE".*;

/// Zero-Hash (kein Event / kein Referenz-Nachweis).
pub const ZERO_HASH: [32]u8 = [_]u8{0} ** 32;

// ── ManifestationRecord ───────────────────────────────────────────────────

/// Ein boot-Event: Harness entsteht aus einer Spore.
/// Enthält alle Felder von EventManifestationBootedFromSpore.
pub const ManifestationRecord = struct {
    /// Eindeutige ID dieser Manifestation (Harness)
    harness_id: [32]u8,
    /// Die Spore, aus der gebootet wurde
    spore_cid: [32]u8,
    /// Erster Codekörper dieser Manifestation
    initial_artifact_cid: [32]u8,
    /// Ledger-Event-Hash dieses Boot-Events (Beweis)
    ledger_event_hash: [32]u8,
    /// Timestamp aus dem Ledger-Event
    boot_ts: i64,
};

// ── CapabilityEventKind ───────────────────────────────────────────────────

/// Art des Capability-Events in der Entwicklungs-Historie.
pub const CapabilityEventKind = enum(u8) {
    /// artifact_forged: Neues Artefakt geschmiedet (Schmiedungs-Event)
    forged   = 1,
    /// artifact_absorbed: Artefakt absorbiert (Resonanz-Event)
    absorbed = 2,
};

// ── CapabilityEvent ───────────────────────────────────────────────────────

/// Eintrag in der Capability-Entwicklungs-Sequenz eines Agenten.
pub const CapabilityEvent = struct {
    /// forged oder absorbed
    kind: CapabilityEventKind,
    /// CID des Artefakts (new_artifact_cid bei forged, absorbed_artifact_cid bei absorbed)
    artifact_cid: [32]u8,
    /// Ledger-Event-Hash dieses Events (Beweis)
    ledger_event_hash: [32]u8,
    /// Forge-Epoch zum Zeitpunkt des Events (0 bei absorbed)
    forge_epoch: u64,
    /// Timestamp aus dem Ledger-Event
    event_ts: i64,
};

// ── C2BindingStatus ───────────────────────────────────────────────────────

/// Zustand einer C2-Bindung.
pub const C2BindingStatus = enum(u8) {
    /// Aktiv: Demon darf im Namen des Harness handeln
    active  = 1,
    /// Widerrufen: Bindung aufgehoben, historisch erhalten
    revoked = 2,
};

// ── C2Binding ─────────────────────────────────────────────────────────────

/// Eine C2-Bindung (Command & Control) zwischen Harness und Demon/Agent.
pub const C2Binding = struct {
    /// ID des Demons (Command & Control Agent)
    demon_id: [32]u8,
    /// Capability Policy CID
    capability_policy_cid: [32]u8,
    /// Ledger-Event-Hash des `c2_binding_established`-Events
    establish_event_hash: [32]u8,
    /// Timestamp der Etablierung
    binding_ts: i64,
    /// Aktiv oder widerrufen
    status: C2BindingStatus,
    /// Ledger-Event-Hash des `c2_binding_revoked`-Events (ZERO = nicht widerrufen)
    revoke_event_hash: [32]u8,
};

// ── AgentLineageRecord ────────────────────────────────────────────────────

/// Vollständiger Lineage-Eintrag für einen Agenten (SOUL-verankert).
///
/// Alle Felder entstehen aus Ledger-Events (Projektion).
/// SOUL-CID ist WRITE ONCE — kann nach dem ersten Setzen nicht mehr geändert werden.
pub const AgentLineageRecord = struct {
    /// Domain Separation ("BKGE")
    domain_prefix: [4]u8,

    /// SOUL-CID — unveränderliche Anker-Identität (WRITE ONCE).
    /// ZERO = noch nicht gesetzt (kein soul_anchored-Event verarbeitet).
    soul_cid: [32]u8,

    /// Alle Manifestations-Boot-Events dieser SOUL (zeitlich sortiert, älteste zuerst).
    manifestations: [MAX_MANIFESTATIONS]ManifestationRecord,
    /// Anzahl gültiger Einträge in manifestations.
    manifestation_count: u8,

    /// Capability-Entwicklungs-Sequenz (forged + absorbed, chronologisch).
    capability_events: [MAX_CAPABILITY_EVENTS]CapabilityEvent,
    /// Anzahl gültiger Einträge in capability_events.
    capability_event_count: u16,

    /// Letzter `artifact_forged`-Event-Hash (Minting-Anker).
    /// ZERO = noch kein forged-Event.
    last_minting_event: [32]u8,

    /// Letztes gemintetes Artefakt-CID (new_artifact_cid des letzten forged-Events).
    /// ZERO = noch kein forged-Event.
    last_minted_artifact_cid: [32]u8,

    /// Aktive und historische C2-Bindungen.
    c2_bindings: [MAX_C2_BINDINGS]C2Binding,
    /// Anzahl gültiger Einträge in c2_bindings.
    c2_binding_count: u8,

    /// Deterministischer Lineage-Hash dieser Projektion.
    /// SHA256("BKGE" || soul_cid || latest_harness_id || latest_boot_ts_le8)
    /// Wird bei jeder Änderung neuberechnet.
    lineage_hash: [32]u8,
};

// ── Fehlertypen ───────────────────────────────────────────────────────────

pub const AgentLineageError = error{
    /// Speicherallokation fehlgeschlagen
    OutOfMemory,
    /// SOUL-CID nicht gesetzt — Operation erfordert eine gültige SOUL
    SoulCidNotSet,
    /// Kein Platz für weitere Manifestationen (MAX_MANIFESTATIONS erreicht)
    ManifestationsFull,
    /// Kein Platz für weitere Capability-Events (MAX_CAPABILITY_EVENTS erreicht)
    CapabilityEventsFull,
    /// Kein Platz für weitere C2-Bindungen (MAX_C2_BINDINGS erreicht)
    C2BindingsFull,
    /// C2-Bindung für diesen demon_id existiert bereits (aktiv)
    C2BindingAlreadyActive,
    /// C2-Bindung für diesen demon_id existiert nicht (Revoke ohne Establish)
    C2BindingNotFound,
    /// C2-Bindung ist bereits widerrufen (Revoke auf bereits revoked)
    C2BindingAlreadyRevoked,
    /// Ungültiger Ledger-Event-Hash (ZERO ist kein gültiger Nachweis)
    InvalidEventHash,
    /// harness_id ist bereits einer anderen SOUL zugeordnet (P6)
    HarnessIdConflict,
};

// ── AgentLineageStore ─────────────────────────────────────────────────────

/// In-Memory-Projektion der Agent-Lineage-Dimension.
///
/// Schreibhoheit liegt beim Ledger/Rebuilder.
/// Kein Eintrag darf ohne einen gültigen Ledger-Event-Hash entstehen.
///
/// Indizes für effiziente Lookups:
///   - by_soul_cid:   soul_cid → Index in records[]
///   - by_harness_id: harness_id → Index in records[]
///   (beide sind reine Projektionen aus records[])
pub const AgentLineageStore = struct {
    allocator: std.mem.Allocator,

    /// Alle bekannten Agent-Lineage-Records (unmanaged ArrayList).
    records: std.ArrayList(AgentLineageRecord),

    /// Sekundärindex: soul_cid → Index in records (reine Projektion).
    by_soul_cid: std.AutoHashMap([32]u8, usize),

    /// Sekundärindex: harness_id → Index in records (reine Projektion).
    /// Ein Harness ist immer genau einer SOUL zugeordnet.
    by_harness_id: std.AutoHashMap([32]u8, usize),

    // ── Lifecycle ─────────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator) AgentLineageStore {
        return .{
            .allocator     = allocator,
            .records       = std.ArrayList(AgentLineageRecord).empty,
            .by_soul_cid   = std.AutoHashMap([32]u8, usize).init(allocator),
            .by_harness_id = std.AutoHashMap([32]u8, usize).init(allocator),
        };
    }

    pub fn deinit(self: *AgentLineageStore) void {
        self.records.deinit(self.allocator);
        self.by_soul_cid.deinit();
        self.by_harness_id.deinit();
    }

    // ── soul_anchored ──────────────────────────────────────────────────────

    /// Verarbeitet ein `soul_anchored`-Event: Erzeugt oder verifiziert den SOUL-Eintrag.
    ///
    /// Idempotenz: Wenn soul_cid bereits bekannt → kein Fehler (P2).
    /// WRITE ONCE: soul_cid als solcher ändert sich nie — SOUL-Identität ist SHA256-gebunden.
    pub fn applySoulAnchored(
        self: *AgentLineageStore,
        soul_cid: [32]u8,
        ledger_event_hash: [32]u8,
    ) AgentLineageError!void {
        if (isZeroHash(ledger_event_hash)) return error.InvalidEventHash;

        // Idempotenz (P2): bereits bekannte SOUL → still ignorieren
        if (self.by_soul_cid.contains(soul_cid)) return;

        // Neuen Record anlegen — Enums explizit initialisieren (kein std.mem.zeroes)
        const zero_manifestation = ManifestationRecord{
            .harness_id           = ZERO_HASH,
            .spore_cid            = ZERO_HASH,
            .initial_artifact_cid = ZERO_HASH,
            .ledger_event_hash    = ZERO_HASH,
            .boot_ts              = 0,
        };
        const zero_cap_event = CapabilityEvent{
            .kind              = .forged,
            .artifact_cid      = ZERO_HASH,
            .ledger_event_hash = ZERO_HASH,
            .forge_epoch       = 0,
            .event_ts          = 0,
        };
        const zero_c2_binding = C2Binding{
            .demon_id              = ZERO_HASH,
            .capability_policy_cid = ZERO_HASH,
            .establish_event_hash  = ZERO_HASH,
            .binding_ts            = 0,
            .status                = .active,
            .revoke_event_hash     = ZERO_HASH,
        };
        const new_record = AgentLineageRecord{
            .domain_prefix            = DOMAIN_PREFIX,
            .soul_cid                 = soul_cid,
            .manifestations           = [_]ManifestationRecord{zero_manifestation} ** MAX_MANIFESTATIONS,
            .manifestation_count      = 0,
            .capability_events        = [_]CapabilityEvent{zero_cap_event} ** MAX_CAPABILITY_EVENTS,
            .capability_event_count   = 0,
            .last_minting_event       = ZERO_HASH,
            .last_minted_artifact_cid = ZERO_HASH,
            .c2_bindings              = [_]C2Binding{zero_c2_binding} ** MAX_C2_BINDINGS,
            .c2_binding_count         = 0,
            .lineage_hash             = computeLineageHash(soul_cid, ZERO_HASH, 0),
        };

        const idx = self.records.items.len;
        // Beide Schreiboperationen atomar via errdefer:
        // 1. append → bei Fehler in put: pop() rollback
        try self.records.append(self.allocator, new_record);
        errdefer _ = self.records.pop();
        // 2. Index eintragen (kann OOM auslösen)
        try self.by_soul_cid.put(soul_cid, idx);
    }

    // ── manifestation_booted_from_spore ────────────────────────────────────

    /// Verarbeitet ein `manifestation_booted_from_spore`-Event.
    ///
    /// P2: Idempotenz — gleicher ledger_event_hash wird still ignoriert.
    /// P5: harness_id wird im by_harness_id-Index registriert.
    pub fn applyManifestationBooted(
        self: *AgentLineageStore,
        soul_cid: [32]u8,
        harness_id: [32]u8,
        spore_cid: [32]u8,
        initial_artifact_cid: [32]u8,
        ledger_event_hash: [32]u8,
        boot_ts: i64,
    ) AgentLineageError!void {
        if (isZeroHash(ledger_event_hash)) return error.InvalidEventHash;

        const idx = self.by_soul_cid.get(soul_cid) orelse return error.SoulCidNotSet;
        const record = &self.records.items[idx];

        // P2: Idempotenz — prüfe ob event_hash bereits enthalten
        for (record.manifestations[0..record.manifestation_count]) |*m| {
            if (std.mem.eql(u8, &m.ledger_event_hash, &ledger_event_hash)) return;
        }

        if (record.manifestation_count >= MAX_MANIFESTATIONS) return error.ManifestationsFull;

        // P6: harness_id darf nur genau einer SOUL zugeordnet sein
        if (self.by_harness_id.get(harness_id)) |existing_soul_idx| {
            if (existing_soul_idx != idx) return error.HarnessIdConflict;
            // Gleiche SOUL, gleiche harness_id (re-boot-Scenario): erlaubt (kein Fehler)
        }

        // Erst den Index eintragen (kann OOM auslösen) — BEVOR der Slot beschrieben wird,
        // damit bei Fehler kein halb-beschriebener Slot entsteht.
        try self.by_harness_id.put(harness_id, idx);
        errdefer _ = self.by_harness_id.remove(harness_id);

        const man_idx = record.manifestation_count;
        record.manifestations[man_idx] = .{
            .harness_id           = harness_id,
            .spore_cid            = spore_cid,
            .initial_artifact_cid = initial_artifact_cid,
            .ledger_event_hash    = ledger_event_hash,
            .boot_ts              = boot_ts,
        };
        record.manifestation_count += 1;

        // Lineage-Hash aktualisieren (neueste Manifestation)
        record.lineage_hash = computeLineageHash(soul_cid, harness_id, boot_ts);
    }

    // ── artifact_forged ────────────────────────────────────────────────────

    /// Verarbeitet ein `artifact_forged`-Event.
    ///
    /// P2: Idempotenz — gleicher ledger_event_hash wird still ignoriert.
    /// P4: last_minting_event und last_minted_artifact_cid werden aktualisiert.
    pub fn applyArtifactForged(
        self: *AgentLineageStore,
        soul_cid: [32]u8,
        new_artifact_cid: [32]u8,
        ledger_event_hash: [32]u8,
        forge_epoch: u64,
        event_ts: i64,
    ) AgentLineageError!void {
        if (isZeroHash(ledger_event_hash)) return error.InvalidEventHash;

        const idx = self.by_soul_cid.get(soul_cid) orelse return error.SoulCidNotSet;
        const record = &self.records.items[idx];

        // P2: Idempotenz
        for (record.capability_events[0..record.capability_event_count]) |*ce| {
            if (std.mem.eql(u8, &ce.ledger_event_hash, &ledger_event_hash)) return;
        }

        if (record.capability_event_count >= MAX_CAPABILITY_EVENTS) return error.CapabilityEventsFull;

        const ev_idx = record.capability_event_count;
        record.capability_events[ev_idx] = .{
            .kind              = .forged,
            .artifact_cid      = new_artifact_cid,
            .ledger_event_hash = ledger_event_hash,
            .forge_epoch       = forge_epoch,
            .event_ts          = event_ts,
        };
        record.capability_event_count += 1;

        // P4: letztes Minting aktualisieren
        record.last_minting_event       = ledger_event_hash;
        record.last_minted_artifact_cid = new_artifact_cid;
    }

    // ── artifact_absorbed ──────────────────────────────────────────────────

    /// Verarbeitet ein `artifact_absorbed`-Event.
    ///
    /// P2: Idempotenz — gleicher ledger_event_hash wird still ignoriert.
    pub fn applyArtifactAbsorbed(
        self: *AgentLineageStore,
        soul_cid: [32]u8,
        absorbed_artifact_cid: [32]u8,
        ledger_event_hash: [32]u8,
        event_ts: i64,
    ) AgentLineageError!void {
        if (isZeroHash(ledger_event_hash)) return error.InvalidEventHash;

        const idx = self.by_soul_cid.get(soul_cid) orelse return error.SoulCidNotSet;
        const record = &self.records.items[idx];

        // P2: Idempotenz
        for (record.capability_events[0..record.capability_event_count]) |*ce| {
            if (std.mem.eql(u8, &ce.ledger_event_hash, &ledger_event_hash)) return;
        }

        if (record.capability_event_count >= MAX_CAPABILITY_EVENTS) return error.CapabilityEventsFull;

        const ev_idx = record.capability_event_count;
        record.capability_events[ev_idx] = .{
            .kind              = .absorbed,
            .artifact_cid      = absorbed_artifact_cid,
            .ledger_event_hash = ledger_event_hash,
            .forge_epoch       = 0,
            .event_ts          = event_ts,
        };
        record.capability_event_count += 1;
    }

    // ── c2_binding_established ─────────────────────────────────────────────

    /// Verarbeitet ein `c2_binding_established`-Event.
    ///
    /// P3: Fehler wenn bereits eine aktive Bindung für diesen demon_id existiert.
    pub fn applyC2BindingEstablished(
        self: *AgentLineageStore,
        soul_cid: [32]u8,
        demon_id: [32]u8,
        capability_policy_cid: [32]u8,
        ledger_event_hash: [32]u8,
        binding_ts: i64,
    ) AgentLineageError!void {
        if (isZeroHash(ledger_event_hash)) return error.InvalidEventHash;

        const idx = self.by_soul_cid.get(soul_cid) orelse return error.SoulCidNotSet;
        const record = &self.records.items[idx];

        // P2: Idempotenz auf event_hash-Ebene
        for (record.c2_bindings[0..record.c2_binding_count]) |*b| {
            if (std.mem.eql(u8, &b.establish_event_hash, &ledger_event_hash)) return;
        }

        // P3: Keine Duplikat-Bindung (aktiv) für denselben demon_id
        for (record.c2_bindings[0..record.c2_binding_count]) |*b| {
            if (std.mem.eql(u8, &b.demon_id, &demon_id) and b.status == .active) {
                return error.C2BindingAlreadyActive;
            }
        }

        if (record.c2_binding_count >= MAX_C2_BINDINGS) return error.C2BindingsFull;

        const b_idx = record.c2_binding_count;
        record.c2_bindings[b_idx] = .{
            .demon_id              = demon_id,
            .capability_policy_cid = capability_policy_cid,
            .establish_event_hash  = ledger_event_hash,
            .binding_ts            = binding_ts,
            .status                = .active,
            .revoke_event_hash     = ZERO_HASH,
        };
        record.c2_binding_count += 1;
    }

    // ── c2_binding_revoked ─────────────────────────────────────────────────

    /// Verarbeitet ein `c2_binding_revoked`-Event.
    ///
    /// P3: Fehler wenn keine aktive Bindung für diesen demon_id existiert.
    /// Bei mehreren historischen Bindungen für denselben demon_id (revoked + active)
    /// wird immer die aktive getroffen — Iteration sucht die neueste aktive.
    pub fn applyC2BindingRevoked(
        self: *AgentLineageStore,
        soul_cid: [32]u8,
        demon_id: [32]u8,
        ledger_event_hash: [32]u8,
    ) AgentLineageError!void {
        if (isZeroHash(ledger_event_hash)) return error.InvalidEventHash;

        const idx = self.by_soul_cid.get(soul_cid) orelse return error.SoulCidNotSet;
        const record = &self.records.items[idx];

        // P2: Idempotenz auf event_hash-Ebene (revoke bereits verarbeitet)
        for (record.c2_bindings[0..record.c2_binding_count]) |*b| {
            if (std.mem.eql(u8, &b.revoke_event_hash, &ledger_event_hash)) return;
        }

        // P3: Aktive Bindung für demon_id finden.
        // Explizit nach status==active suchen (nicht first-match) damit historisch
        // widerrufene Einträge für denselben demon_id nicht fälschlich getroffen werden.
        for (record.c2_bindings[0..record.c2_binding_count]) |*b| {
            if (std.mem.eql(u8, &b.demon_id, &demon_id) and b.status == .active) {
                b.status = .revoked;
                b.revoke_event_hash = ledger_event_hash;
                return;
            }
        }

        // Kein aktiver Eintrag gefunden — prüfe ob demon_id bekannt aber revoked
        for (record.c2_bindings[0..record.c2_binding_count]) |*b| {
            if (std.mem.eql(u8, &b.demon_id, &demon_id)) {
                // demon_id existiert, aber keine aktive Bindung
                return error.C2BindingAlreadyRevoked;
            }
        }
        return error.C2BindingNotFound;
    }

    // ── Lookup ─────────────────────────────────────────────────────────────

    /// Sucht einen Record per soul_cid. Gibt null zurück wenn nicht gefunden.
    pub fn getBySoulCid(self: *const AgentLineageStore, soul_cid: [32]u8) ?*const AgentLineageRecord {
        const idx = self.by_soul_cid.get(soul_cid) orelse return null;
        return &self.records.items[idx];
    }

    /// Sucht einen Record per harness_id. Gibt null zurück wenn nicht gefunden.
    pub fn getByHarnessId(self: *const AgentLineageStore, harness_id: [32]u8) ?*const AgentLineageRecord {
        const idx = self.by_harness_id.get(harness_id) orelse return null;
        return &self.records.items[idx];
    }

    /// Gibt die Anzahl bekannter SOUL-Einträge zurück.
    pub fn count(self: *const AgentLineageStore) usize {
        return self.records.items.len;
    }
};

// ── computeLineageHash ────────────────────────────────────────────────────

/// Berechnet den deterministischen Lineage-Hash einer Agent-Projektion.
/// SHA256("BKGE" || soul_cid || latest_harness_id || latest_boot_ts_le8)
pub fn computeLineageHash(
    soul_cid: [32]u8,
    latest_harness_id: [32]u8,
    latest_boot_ts: i64,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&DOMAIN_PREFIX);
    hasher.update(&soul_cid);
    hasher.update(&latest_harness_id);
    var ts_buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &ts_buf, latest_boot_ts, .little);
    hasher.update(&ts_buf);
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

// ── Tests ─────────────────────────────────────────────────────────────────

test "agent_lineage: computeLineageHash Domain-Separation" {
    const soul = h(0x01);
    const harness = h(0x02);
    const hash_with = computeLineageHash(soul, harness, 1000);
    const hash_diff_ts = computeLineageHash(soul, harness, 1001);
    const hash_diff_harness = computeLineageHash(soul, h(0x03), 1000);
    const hash_diff_soul = computeLineageHash(h(0x02), harness, 1000);
    try std.testing.expect(!std.mem.eql(u8, &hash_with, &hash_diff_ts));
    try std.testing.expect(!std.mem.eql(u8, &hash_with, &hash_diff_harness));
    try std.testing.expect(!std.mem.eql(u8, &hash_with, &hash_diff_soul));
}

test "agent_lineage: computeLineageHash deterministisch" {
    const soul = h(0x10);
    const harness = h(0x20);
    const a = computeLineageHash(soul, harness, 42);
    const b = computeLineageHash(soul, harness, 42);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "agent_lineage: applySoulAnchored WRITE ONCE" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul = h(0x01);
    const event1 = h(0xAA);
    const event2 = h(0xBB);

    // Erstes Setzen — OK
    try store.applySoulAnchored(soul, event1);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    // Idempotent: selber soul_cid, anderer event → kein Fehler
    try store.applySoulAnchored(soul, event2);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    // WRITE ONCE verletzt: anderer soul_cid ist kein Fehlerfall (neuer Record)
    const soul2 = h(0x02);
    try store.applySoulAnchored(soul2, event1);
    try std.testing.expectEqual(@as(usize, 2), store.count());
}

test "agent_lineage: applySoulAnchored ZERO event_hash verboten" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul = h(0x01);
    try std.testing.expectError(
        error.InvalidEventHash,
        store.applySoulAnchored(soul, ZERO_HASH),
    );
}

test "agent_lineage: getBySoulCid lookup" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul = h(0x05);
    try store.applySoulAnchored(soul, h(0xAA));

    const rec = store.getBySoulCid(soul);
    try std.testing.expect(rec != null);
    try std.testing.expectEqualSlices(u8, &soul, &rec.?.soul_cid);
    try std.testing.expectEqualSlices(u8, &DOMAIN_PREFIX, &rec.?.domain_prefix);

    const missing = store.getBySoulCid(h(0xFF));
    try std.testing.expect(missing == null);
}

test "agent_lineage: applyManifestationBooted Grundfall" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul    = h(0x01);
    const harness = h(0x02);
    const spore   = h(0x03);
    const artifact = h(0x04);
    const ev      = h(0xAB);

    try store.applySoulAnchored(soul, h(0xAA));
    try store.applyManifestationBooted(soul, harness, spore, artifact, ev, 1000);

    const rec = store.getBySoulCid(soul).?;
    try std.testing.expectEqual(@as(u8, 1), rec.manifestation_count);
    try std.testing.expectEqualSlices(u8, &harness, &rec.manifestations[0].harness_id);
    try std.testing.expectEqualSlices(u8, &spore, &rec.manifestations[0].spore_cid);
    try std.testing.expectEqual(@as(i64, 1000), rec.manifestations[0].boot_ts);
}

test "agent_lineage: applyManifestationBooted Idempotenz" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul    = h(0x01);
    const harness = h(0x02);
    const ev      = h(0xAB);

    try store.applySoulAnchored(soul, h(0xAA));
    try store.applyManifestationBooted(soul, harness, h(0x03), h(0x04), ev, 1000);
    // Gleicher event_hash → still ignoriert
    try store.applyManifestationBooted(soul, harness, h(0x03), h(0x04), ev, 1000);

    const rec = store.getBySoulCid(soul).?;
    try std.testing.expectEqual(@as(u8, 1), rec.manifestation_count);
}

test "agent_lineage: getByHarnessId index" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul    = h(0x01);
    const harness = h(0x02);

    try store.applySoulAnchored(soul, h(0xAA));
    try store.applyManifestationBooted(soul, harness, h(0x03), h(0x04), h(0xAB), 500);

    const by_harness = store.getByHarnessId(harness);
    try std.testing.expect(by_harness != null);
    try std.testing.expectEqualSlices(u8, &soul, &by_harness.?.soul_cid);

    const missing = store.getByHarnessId(h(0xFF));
    try std.testing.expect(missing == null);
}

test "agent_lineage: applyManifestationBooted SoulCidNotSet" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(
        error.SoulCidNotSet,
        store.applyManifestationBooted(h(0x99), h(0x02), h(0x03), h(0x04), h(0xAB), 0),
    );
}

test "agent_lineage: applyArtifactForged Grundfall" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul    = h(0x01);
    const artifact = h(0x10);
    const ev      = h(0xF1);

    try store.applySoulAnchored(soul, h(0xAA));
    try store.applyArtifactForged(soul, artifact, ev, 42, 9999);

    const rec = store.getBySoulCid(soul).?;
    try std.testing.expectEqual(@as(u16, 1), rec.capability_event_count);
    try std.testing.expectEqual(CapabilityEventKind.forged, rec.capability_events[0].kind);
    try std.testing.expectEqualSlices(u8, &artifact, &rec.capability_events[0].artifact_cid);
    try std.testing.expectEqual(@as(u64, 42), rec.capability_events[0].forge_epoch);
    // P4: last_minting_event gesetzt
    try std.testing.expectEqualSlices(u8, &ev, &rec.last_minting_event);
    try std.testing.expectEqualSlices(u8, &artifact, &rec.last_minted_artifact_cid);
}

test "agent_lineage: applyArtifactForged last_minting überschreibt bei neuem Event" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul = h(0x01);
    try store.applySoulAnchored(soul, h(0xAA));

    try store.applyArtifactForged(soul, h(0x10), h(0xF1), 1, 1000);
    try store.applyArtifactForged(soul, h(0x20), h(0xF2), 2, 2000);

    const rec = store.getBySoulCid(soul).?;
    try std.testing.expectEqual(@as(u16, 2), rec.capability_event_count);
    // P4: letztes forged-Event
    try std.testing.expectEqualSlices(u8, &h(0xF2), &rec.last_minting_event);
    try std.testing.expectEqualSlices(u8, &h(0x20), &rec.last_minted_artifact_cid);
}

test "agent_lineage: applyArtifactForged Idempotenz" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul = h(0x01);
    try store.applySoulAnchored(soul, h(0xAA));

    try store.applyArtifactForged(soul, h(0x10), h(0xF1), 1, 1000);
    try store.applyArtifactForged(soul, h(0x10), h(0xF1), 1, 1000); // Duplikat

    const rec = store.getBySoulCid(soul).?;
    try std.testing.expectEqual(@as(u16, 1), rec.capability_event_count);
}

test "agent_lineage: applyArtifactAbsorbed Grundfall" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul     = h(0x01);
    const artifact = h(0x30);
    const ev       = h(0xC1);

    try store.applySoulAnchored(soul, h(0xAA));
    try store.applyArtifactAbsorbed(soul, artifact, ev, 5000);

    const rec = store.getBySoulCid(soul).?;
    try std.testing.expectEqual(@as(u16, 1), rec.capability_event_count);
    try std.testing.expectEqual(CapabilityEventKind.absorbed, rec.capability_events[0].kind);
    try std.testing.expectEqualSlices(u8, &artifact, &rec.capability_events[0].artifact_cid);
    try std.testing.expectEqual(@as(u64, 0), rec.capability_events[0].forge_epoch);
    // last_minting_event bleibt ZERO (absorbed ändert es nicht)
    try std.testing.expect(isZeroHash(rec.last_minting_event));
}

test "agent_lineage: gemischte forged+absorbed Sequenz" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul = h(0x01);
    try store.applySoulAnchored(soul, h(0xAA));

    try store.applyArtifactForged(soul, h(0x10), h(0xF1), 1, 100);
    try store.applyArtifactAbsorbed(soul, h(0x20), h(0xC1), 200);
    try store.applyArtifactForged(soul, h(0x30), h(0xF2), 2, 300);
    try store.applyArtifactAbsorbed(soul, h(0x40), h(0xC2), 400);

    const rec = store.getBySoulCid(soul).?;
    try std.testing.expectEqual(@as(u16, 4), rec.capability_event_count);
    try std.testing.expectEqual(CapabilityEventKind.forged,   rec.capability_events[0].kind);
    try std.testing.expectEqual(CapabilityEventKind.absorbed,  rec.capability_events[1].kind);
    try std.testing.expectEqual(CapabilityEventKind.forged,   rec.capability_events[2].kind);
    try std.testing.expectEqual(CapabilityEventKind.absorbed,  rec.capability_events[3].kind);
    // P4: letztes forged
    try std.testing.expectEqualSlices(u8, &h(0xF2), &rec.last_minting_event);
}

test "agent_lineage: applyC2BindingEstablished Grundfall" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul  = h(0x01);
    const demon = h(0xD1);
    const ev    = h(0xE1);

    try store.applySoulAnchored(soul, h(0xAA));
    try store.applyC2BindingEstablished(soul, demon, h(0xA5), ev, 1234);

    const rec = store.getBySoulCid(soul).?;
    try std.testing.expectEqual(@as(u8, 1), rec.c2_binding_count);
    try std.testing.expectEqual(C2BindingStatus.active, rec.c2_bindings[0].status);
    try std.testing.expectEqualSlices(u8, &demon, &rec.c2_bindings[0].demon_id);
}

test "agent_lineage: applyC2BindingEstablished Duplikat-Fehler" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul  = h(0x01);
    const demon = h(0xD1);

    try store.applySoulAnchored(soul, h(0xAA));
    try store.applyC2BindingEstablished(soul, demon, h(0xA5), h(0xE1), 100);

    try std.testing.expectError(
        error.C2BindingAlreadyActive,
        store.applyC2BindingEstablished(soul, demon, h(0xA6), h(0xE2), 200),
    );
}

test "agent_lineage: applyC2BindingRevoked Grundfall" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul  = h(0x01);
    const demon = h(0xD1);

    try store.applySoulAnchored(soul, h(0xAA));
    try store.applyC2BindingEstablished(soul, demon, h(0xA5), h(0xE1), 100);
    try store.applyC2BindingRevoked(soul, demon, h(0xE2));

    const rec = store.getBySoulCid(soul).?;
    try std.testing.expectEqual(C2BindingStatus.revoked, rec.c2_bindings[0].status);
    try std.testing.expectEqualSlices(u8, &h(0xE2), &rec.c2_bindings[0].revoke_event_hash);
}

test "agent_lineage: applyC2BindingRevoked NotFound" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul = h(0x01);
    try store.applySoulAnchored(soul, h(0xAA));

    try std.testing.expectError(
        error.C2BindingNotFound,
        store.applyC2BindingRevoked(soul, h(0xD9), h(0xEE)),
    );
}

test "agent_lineage: applyC2BindingRevoked AlreadyRevoked" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul  = h(0x01);
    const demon = h(0xD1);

    try store.applySoulAnchored(soul, h(0xAA));
    try store.applyC2BindingEstablished(soul, demon, h(0xA5), h(0xE1), 100);
    try store.applyC2BindingRevoked(soul, demon, h(0xE2));

    try std.testing.expectError(
        error.C2BindingAlreadyRevoked,
        store.applyC2BindingRevoked(soul, demon, h(0xE3)),
    );
}

test "agent_lineage: C2 Revoke Idempotenz per event_hash" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul  = h(0x01);
    const demon = h(0xD1);
    const ev_revoke = h(0xE2);

    try store.applySoulAnchored(soul, h(0xAA));
    try store.applyC2BindingEstablished(soul, demon, h(0xA5), h(0xE1), 100);
    try store.applyC2BindingRevoked(soul, demon, ev_revoke);
    // Gleicher Revoke-Event-Hash → still ignoriert
    try store.applyC2BindingRevoked(soul, demon, ev_revoke);

    const rec = store.getBySoulCid(soul).?;
    try std.testing.expectEqual(C2BindingStatus.revoked, rec.c2_bindings[0].status);
}

test "agent_lineage: Mehrere SOULs unabhängig" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul1 = h(0x01);
    const soul2 = h(0x02);
    const soul3 = h(0x03);

    try store.applySoulAnchored(soul1, h(0xA1));
    try store.applySoulAnchored(soul2, h(0xA2));
    try store.applySoulAnchored(soul3, h(0xA3));

    try std.testing.expectEqual(@as(usize, 3), store.count());

    // Jede SOUL hat eigenen Record
    try std.testing.expect(store.getBySoulCid(soul1) != null);
    try std.testing.expect(store.getBySoulCid(soul2) != null);
    try std.testing.expect(store.getBySoulCid(soul3) != null);

    // Manifestation auf soul1 beeinflusst soul2 nicht
    try store.applyArtifactForged(soul1, h(0x10), h(0xF1), 1, 100);
    const rec1 = store.getBySoulCid(soul1).?;
    const rec2 = store.getBySoulCid(soul2).?;
    try std.testing.expectEqual(@as(u16, 1), rec1.capability_event_count);
    try std.testing.expectEqual(@as(u16, 0), rec2.capability_event_count);
}

test "agent_lineage: lineage_hash nach Manifestation aktualisiert" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul    = h(0x01);
    const harness = h(0x02);

    try store.applySoulAnchored(soul, h(0xAA));
    const rec_before = store.getBySoulCid(soul).?;
    const hash_before = rec_before.lineage_hash;

    try store.applyManifestationBooted(soul, harness, h(0x03), h(0x04), h(0xAB), 1000);
    const rec_after = store.getBySoulCid(soul).?;
    const hash_after = rec_after.lineage_hash;

    // Hash muss sich nach Boot ändern
    try std.testing.expect(!std.mem.eql(u8, &hash_before, &hash_after));
}

test "agent_lineage: ZERO event_hash bei allen apply-Methoden verboten" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul = h(0x01);
    try store.applySoulAnchored(soul, h(0xAA));

    try std.testing.expectError(error.InvalidEventHash,
        store.applyManifestationBooted(soul, h(0x02), h(0x03), h(0x04), ZERO_HASH, 0));
    try std.testing.expectError(error.InvalidEventHash,
        store.applyArtifactForged(soul, h(0x10), ZERO_HASH, 1, 100));
    try std.testing.expectError(error.InvalidEventHash,
        store.applyArtifactAbsorbed(soul, h(0x20), ZERO_HASH, 200));
    try std.testing.expectError(error.InvalidEventHash,
        store.applyC2BindingEstablished(soul, h(0xD1), h(0xA5), ZERO_HASH, 300));
    try std.testing.expectError(error.InvalidEventHash,
        store.applyC2BindingRevoked(soul, h(0xD1), ZERO_HASH));
}

test "agent_lineage: ManifestationsFull" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul = h(0x01);
    try store.applySoulAnchored(soul, h(0xAA));

    var i: u8 = 0;
    while (i < MAX_MANIFESTATIONS) : (i += 1) {
        var harness: [32]u8 = ZERO_HASH;
        harness[0] = i + 1;
        var ev: [32]u8 = ZERO_HASH;
        ev[1] = i + 1;
        ev[0] = 0xFF;
        try store.applyManifestationBooted(soul, harness, h(0x03), h(0x04), ev, @as(i64, i));
    }

    var overflow_harness: [32]u8 = ZERO_HASH;
    overflow_harness[0] = 0xFE;
    var overflow_ev: [32]u8 = ZERO_HASH;
    overflow_ev[0] = 0xFE;
    overflow_ev[1] = 0xFE;
    try std.testing.expectError(
        error.ManifestationsFull,
        store.applyManifestationBooted(soul, overflow_harness, h(0x03), h(0x04), overflow_ev, 999),
    );
}

test "agent_lineage: deinit gibt Speicher frei" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    try store.applySoulAnchored(h(0x01), h(0xA1));
    try store.applySoulAnchored(h(0x02), h(0xA2));
    try store.applyManifestationBooted(h(0x01), h(0x10), h(0x11), h(0x12), h(0xB1), 100);
    // deinit via defer — kein Leak unter std.testing.allocator
}

test "agent_lineage: CapabilityEventsFull" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul = h(0x01);
    try store.applySoulAnchored(soul, h(0xAA));

    var i: u16 = 0;
    while (i < MAX_CAPABILITY_EVENTS) : (i += 1) {
        var ev: [32]u8 = ZERO_HASH;
        ev[0] = @as(u8, @truncate(i >> 8));
        ev[1] = @as(u8, @truncate(i));
        ev[2] = 0xCA;
        try store.applyArtifactForged(soul, h(0x10), ev, @as(u64, i), @as(i64, i));
    }

    // Event 129 muss CapabilityEventsFull auslösen
    var overflow_ev: [32]u8 = ZERO_HASH;
    overflow_ev[0] = 0xFE;
    overflow_ev[1] = 0xFE;
    overflow_ev[2] = 0xFE;
    try std.testing.expectError(
        error.CapabilityEventsFull,
        store.applyArtifactForged(soul, h(0x20), overflow_ev, 999, 999),
    );
}

test "agent_lineage: C2BindingsFull" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul = h(0x01);
    try store.applySoulAnchored(soul, h(0xAA));

    var i: u8 = 0;
    while (i < MAX_C2_BINDINGS) : (i += 1) {
        var demon: [32]u8 = ZERO_HASH;
        demon[0] = i + 1;
        var ev: [32]u8 = ZERO_HASH;
        ev[0] = 0xCC;
        ev[1] = i + 1;
        try store.applyC2BindingEstablished(soul, demon, h(0xA5), ev, @as(i64, i));
    }

    var overflow_demon: [32]u8 = ZERO_HASH;
    overflow_demon[0] = 0xFF;
    overflow_demon[1] = 0xFF;
    var overflow_ev: [32]u8 = ZERO_HASH;
    overflow_ev[0] = 0xFF;
    overflow_ev[1] = 0xFF;
    overflow_ev[2] = 0xFF;
    try std.testing.expectError(
        error.C2BindingsFull,
        store.applyC2BindingEstablished(soul, overflow_demon, h(0xA5), overflow_ev, 9999),
    );
}

test "agent_lineage: applyArtifactAbsorbed SoulCidNotSet" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(
        error.SoulCidNotSet,
        store.applyArtifactAbsorbed(h(0x99), h(0x10), h(0xAB), 0),
    );
}

test "agent_lineage: applyArtifactForged SoulCidNotSet" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(
        error.SoulCidNotSet,
        store.applyArtifactForged(h(0x99), h(0x10), h(0xAB), 1, 0),
    );
}

test "agent_lineage: C2BindingRevoked mit revoked+active demselben demon_id" {
    // Adversarial: historisch revoked + aktive Bindung für denselben demon_id.
    // Revoke muss die AKTIVE treffen, nicht die revoked.
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul  = h(0x01);
    const demon = h(0xD1);

    try store.applySoulAnchored(soul, h(0xAA));

    // Erste Bindung etablieren und widerrufen
    try store.applyC2BindingEstablished(soul, demon, h(0xA1), h(0xE1), 100);
    try store.applyC2BindingRevoked(soul, demon, h(0xE2));

    // Zweite Bindung für denselben demon_id etablieren (nach Widerruf erlaubt)
    try store.applyC2BindingEstablished(soul, demon, h(0xA2), h(0xE3), 200);

    // Revoke der zweiten Bindung muss erfolgreich sein (nicht C2BindingAlreadyRevoked)
    try store.applyC2BindingRevoked(soul, demon, h(0xE4));

    const rec = store.getBySoulCid(soul).?;
    try std.testing.expectEqual(@as(u8, 2), rec.c2_binding_count);
    // Beide Bindungen revoked
    try std.testing.expectEqual(C2BindingStatus.revoked, rec.c2_bindings[0].status);
    try std.testing.expectEqual(C2BindingStatus.revoked, rec.c2_bindings[1].status);
    try std.testing.expectEqualSlices(u8, &h(0xE4), &rec.c2_bindings[1].revoke_event_hash);
}

test "agent_lineage: HarnessIdConflict bei zwei SOULs mit gleichem harness" {
    // Adversarial: P6 — harness_id darf nur einer SOUL gehören.
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul1   = h(0x01);
    const soul2   = h(0x02);
    const harness = h(0xAB);

    try store.applySoulAnchored(soul1, h(0xA1));
    try store.applySoulAnchored(soul2, h(0xA2));

    // soul1 bootet harness — OK
    try store.applyManifestationBooted(soul1, harness, h(0x03), h(0x04), h(0xB1), 100);

    // soul2 versucht denselben harness zu booten — muss HarnessIdConflict auslösen
    try std.testing.expectError(
        error.HarnessIdConflict,
        store.applyManifestationBooted(soul2, harness, h(0x05), h(0x06), h(0xB2), 200),
    );

    // soul1 kann denselben harness erneut booten (re-boot) — kein Fehler
    try store.applyManifestationBooted(soul1, harness, h(0x03), h(0x04), h(0xB3), 300);
    const rec1 = store.getBySoulCid(soul1).?;
    try std.testing.expectEqual(@as(u8, 2), rec1.manifestation_count);
}

test "agent_lineage: by_harness_id zeigt nach HarnessIdConflict noch auf soul1" {
    const allocator = std.testing.allocator;
    var store = AgentLineageStore.init(allocator);
    defer store.deinit();

    const soul1   = h(0x01);
    const soul2   = h(0x02);
    const harness = h(0xAB);

    try store.applySoulAnchored(soul1, h(0xA1));
    try store.applySoulAnchored(soul2, h(0xA2));
    try store.applyManifestationBooted(soul1, harness, h(0x03), h(0x04), h(0xB1), 100);

    // Konflikt-Versuch
    _ = store.applyManifestationBooted(soul2, harness, h(0x05), h(0x06), h(0xB2), 200)
        catch {};

    // by_harness_id muss noch auf soul1 zeigen
    const by_h = store.getByHarnessId(harness).?;
    try std.testing.expectEqualSlices(u8, &soul1, &by_h.soul_cid);
}

