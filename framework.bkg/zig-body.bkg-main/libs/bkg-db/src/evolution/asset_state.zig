/// BKGDB Evolution Memory v1 — Asset State Projection
///
/// Status: STAGE 6 — PROVEN & FROZEN — 2026-09-01
/// SHA256: f3b325624a89612f47d7bfea77b9dc7a097889e510480705a2695400d873f17f
/// Spec:   docs/BKGDB_EVOLUTION_MEMORY_v1.md §2.6 Asset-State-Dimension
///
/// WICHTIG: Asset State != Ledger Truth
/// Dieses Modul ist eine reine Projektion aus Ledger-Events.
/// Kanonische Wahrheit liegt im Ledger/Rebuilder.
/// Kein Asset-Wert ist ohne kausalen Ledger-Beweis gültig.
///
/// Enthält:
///   - XP-Konten: aktueller XP-Stand pro Harness
///   - ALGO-Konten: aktueller ALGO-Stand pro Harness
///   - NFT-Besitz: referenzierte NFT-CIDs pro Harness
///   - Capability-Asset-Zustand: aktiv / veraltet / widerrufen
///   - Zustandsbeweise: Ledger-Event-Hash als kausaler Beweis
///
/// Domain Separation:
///   asset_state_hash = SHA256("BKGAS" || harness_id || xp_le8 || algo_le8 || causality_hash)
///
/// Protokollentscheidungen:
///   P1: Jeder Asset-Wert hat genau einen kausalen Ledger-Event-Hash.
///       ZERO causality ist kein gültiger Zustand.
///   P2: Idempotenz: gleicher causality_ledger_event wird still ignoriert.
///   P3: XP und ALGO sind niemals negativ (u64). Ein Versuch, unter 0 zu gehen,
///       schlägt mit `InsufficientBalance` fehl.
///   P4: NFT-Besitz ist APPEND-ONLY für Einträge; ein Eintrag kann als `transferred`
///       markiert werden, wird aber nie gelöscht.
///   P5: Capability-Asset-Zustand folgt dem State-Graph:
///       active → outdated → revoked  (forward only, kein Zurück)
///       active → revoked   (direkter Widerruf ohne outdated)
///   P6: Asset-Harness-Record wird bei erstem Apply angelegt.
///       ZERO harness_id ist kein gültiger Key.
///
const std = @import("std");

// ── Konstanten ────────────────────────────────────────────────────────────

/// Maximale Anzahl Harness-Records im Store.
pub const MAX_HARNESS_RECORDS: usize = 256;

/// Maximale Anzahl NFT-Einträge pro Harness.
pub const MAX_NFT_ENTRIES: usize = 64;

/// Maximale Anzahl Capability-Asset-Einträge pro Harness.
pub const MAX_CAPABILITY_ASSETS: usize = 128;

/// Domain-Prefix für Asset-State-Hashes (5 Bytes).
pub const DOMAIN_PREFIX: [5]u8 = "BKGAS".*;

/// Zero-Hash (kein Event / kein Referenz-Nachweis).
pub const ZERO_HASH: [32]u8 = [_]u8{0} ** 32;

// ── CapabilityAssetStatus ─────────────────────────────────────────────────

/// Zustand eines Capability-Assets pro Harness.
pub const CapabilityAssetStatus = enum(u8) {
    /// Aktiv: Capability ist derzeit wirksam
    active   = 0x01,
    /// Veraltet: Capability existiert noch, aber neuere Version verfügbar
    outdated = 0x02,
    /// Widerrufen: Capability ist aufgehoben (historisch erhalten)
    revoked  = 0x03,
};

// ── CapabilityAsset ───────────────────────────────────────────────────────

/// Capability-Asset-Eintrag für einen Harness.
pub const CapabilityAsset = struct {
    /// Artefakt-CID dieser Capability
    artifact_cid: [32]u8,
    /// Aktueller Zustand
    status: CapabilityAssetStatus,
    /// Ledger-Event-Hash, der den aktuellen Zustand erzeugt hat
    causality_ledger_event: [32]u8,
    /// Epoch beim letzten Zustandsübergang
    last_transition_epoch: u64,
};

// ── NftEntry ──────────────────────────────────────────────────────────────

/// NFT-Besitz-Eintrag für einen Harness.
pub const NftEntry = struct {
    /// CID des NFTs
    nft_cid: [32]u8,
    /// true = Harness besitzt das NFT, false = übertragen/nicht mehr besessen
    owned: bool,
    /// Ledger-Event-Hash der letzten Besitzänderung
    causality_ledger_event: [32]u8,
    /// Epoch beim letzten Besitzübergang
    last_change_epoch: u64,
};

// ── HarnessAssetRecord ────────────────────────────────────────────────────

/// Vollständiger Asset-State für einen Harness (Projektion).
/// Jeder Wert ist durch einen kausalen Ledger-Event-Hash belegt.
pub const HarnessAssetRecord = struct {
    /// Domain Separation ("BKGAS")
    domain_prefix: [5]u8,

    /// Harness-ID (Schlüssel)
    harness_id: [32]u8,

    /// Aktueller XP-Stand (nie negativ, u64)
    xp: u64,
    /// Ledger-Event-Hash, der den letzten XP-Stand erzeugt hat
    xp_causality: [32]u8,

    /// Aktueller ALGO-Stand (nie negativ, u64 in Milli-ALGO)
    algo_milli: u64,
    /// Ledger-Event-Hash, der den letzten ALGO-Stand erzeugt hat
    algo_causality: [32]u8,

    /// NFT-Einträge (APPEND-ONLY)
    nft_entries: [MAX_NFT_ENTRIES]NftEntry,
    nft_count: u8,

    /// Capability-Asset-Einträge
    capability_assets: [MAX_CAPABILITY_ASSETS]CapabilityAsset,
    capability_asset_count: u8,

    /// Deterministischer State-Hash dieser Projektion.
    /// SHA256("BKGAS" || harness_id || xp_le8 || algo_le8 || causality_xp || causality_algo)
    state_hash: [32]u8,
};

// ── Fehlertypen ───────────────────────────────────────────────────────────

pub const AssetError = error{
    /// Speicherallokation fehlgeschlagen
    OutOfMemory,
    /// Kein Platz für weitere Harness-Records
    StoreFull,
    /// Kein Platz für weitere NFT-Einträge
    NftFull,
    /// Kein Platz für weitere Capability-Asset-Einträge
    CapabilityAssetsFull,
    /// Ungültiger Ledger-Event-Hash (ZERO verboten für kausale Events)
    InvalidEventHash,
    /// Ungültige Harness-ID (ZERO verboten)
    InvalidHarnessId,
    /// Ungültiger Artefakt-CID (ZERO verboten)
    InvalidArtifactCid,
    /// Ungültiger NFT-CID (ZERO verboten)
    InvalidNftCid,
    /// Unzureichendes Guthaben (XP oder ALGO unter 0)
    InsufficientBalance,
    /// Ungültiger Capability-Zustandsübergang (P5)
    InvalidStatusTransition,
};

// ── AssetStateStore ───────────────────────────────────────────────────────

/// In-Memory-Projektion der Asset-State-Dimension.
///
/// Schreibhoheit liegt beim Ledger/Rebuilder.
/// Kein Eintrag darf ohne gültigen Ledger-Event-Hash entstehen oder verändert werden.
pub const AssetStateStore = struct {
    allocator: std.mem.Allocator,

    /// Alle bekannten Harness-Records.
    records: std.ArrayList(HarnessAssetRecord),

    /// Sekundärindex: harness_id → Index in records.
    by_harness_id: std.AutoHashMap([32]u8, usize),

    // ── Lifecycle ─────────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator) AssetStateStore {
        return .{
            .allocator     = allocator,
            .records       = std.ArrayList(HarnessAssetRecord).empty,
            .by_harness_id = std.AutoHashMap([32]u8, usize).init(allocator),
        };
    }

    pub fn deinit(self: *AssetStateStore) void {
        self.records.deinit(self.allocator);
        self.by_harness_id.deinit();
    }

    // ── XP ────────────────────────────────────────────────────────────────

    /// Setzt den XP-Stand eines Harness (absolute Projektion aus Rebuilder).
    ///
    /// Legt den Harness-Record an, falls er noch nicht existiert.
    /// P2: gleicher causality_event wird still ignoriert.
    pub fn applyXpUpdate(
        self: *AssetStateStore,
        harness_id: [32]u8,
        new_xp: u64,
        causality_event: [32]u8,
        epoch: u64,
    ) AssetError!void {
        if (isZeroHash(harness_id)) return error.InvalidHarnessId;
        if (isZeroHash(causality_event)) return error.InvalidEventHash;

        const record = try self.getOrCreate(harness_id);

        // P2: Idempotenz
        if (std.mem.eql(u8, &record.xp_causality, &causality_event)) return;

        _ = epoch; // Epoch ist für zukünftige Nutzung reserviert
        record.xp = new_xp;
        record.xp_causality = causality_event;
        record.state_hash = computeStateHash(harness_id, record.xp, record.algo_milli, record.xp_causality, record.algo_causality);
    }

    /// Addiert XP zum Harness-Stand (Delta-Update).
    pub fn applyXpDelta(
        self: *AssetStateStore,
        harness_id: [32]u8,
        delta_xp: u64,
        causality_event: [32]u8,
        epoch: u64,
    ) AssetError!void {
        if (isZeroHash(harness_id)) return error.InvalidHarnessId;
        if (isZeroHash(causality_event)) return error.InvalidEventHash;

        const record = try self.getOrCreate(harness_id);
        if (std.mem.eql(u8, &record.xp_causality, &causality_event)) return;
        _ = epoch;
        record.xp +|= delta_xp; // Saturierender Add (u64 Overflow → max)
        record.xp_causality = causality_event;
        record.state_hash = computeStateHash(harness_id, record.xp, record.algo_milli, record.xp_causality, record.algo_causality);
    }

    // ── ALGO ──────────────────────────────────────────────────────────────

    /// Setzt den ALGO-Stand eines Harness (absolute Projektion, Milli-ALGO).
    ///
    /// P3: algo_milli darf nicht negativ sein (u64 → kein negatives Problem, aber
    ///     der Caller ist verantwortlich für korrekte Werte).
    pub fn applyAlgoUpdate(
        self: *AssetStateStore,
        harness_id: [32]u8,
        new_algo_milli: u64,
        causality_event: [32]u8,
        epoch: u64,
    ) AssetError!void {
        if (isZeroHash(harness_id)) return error.InvalidHarnessId;
        if (isZeroHash(causality_event)) return error.InvalidEventHash;

        const record = try self.getOrCreate(harness_id);
        if (std.mem.eql(u8, &record.algo_causality, &causality_event)) return;
        _ = epoch;
        record.algo_milli = new_algo_milli;
        record.algo_causality = causality_event;
        record.state_hash = computeStateHash(harness_id, record.xp, record.algo_milli, record.xp_causality, record.algo_causality);
    }

    /// Subtrahiert ALGO vom Harness-Stand.
    /// P3: Schlägt mit InsufficientBalance fehl wenn Ergebnis unter 0 wäre.
    pub fn applyAlgoDebit(
        self: *AssetStateStore,
        harness_id: [32]u8,
        debit_algo_milli: u64,
        causality_event: [32]u8,
        epoch: u64,
    ) AssetError!void {
        if (isZeroHash(harness_id)) return error.InvalidHarnessId;
        if (isZeroHash(causality_event)) return error.InvalidEventHash;

        const record = try self.getOrCreate(harness_id);
        if (std.mem.eql(u8, &record.algo_causality, &causality_event)) return;
        if (debit_algo_milli > record.algo_milli) return error.InsufficientBalance;
        _ = epoch;
        record.algo_milli -= debit_algo_milli;
        record.algo_causality = causality_event;
        record.state_hash = computeStateHash(harness_id, record.xp, record.algo_milli, record.xp_causality, record.algo_causality);
    }

    // ── NFT ───────────────────────────────────────────────────────────────

    /// Fügt ein NFT zum Harness-Besitz hinzu.
    ///
    /// P4: APPEND-ONLY. Wenn nft_cid bereits bekannt → Besitz-Flag aktualisieren.
    /// P2: gleicher causality_event wird still ignoriert.
    pub fn applyNftAcquired(
        self: *AssetStateStore,
        harness_id: [32]u8,
        nft_cid: [32]u8,
        causality_event: [32]u8,
        epoch: u64,
    ) AssetError!void {
        if (isZeroHash(harness_id)) return error.InvalidHarnessId;
        if (isZeroHash(nft_cid)) return error.InvalidNftCid;
        if (isZeroHash(causality_event)) return error.InvalidEventHash;

        const record = try self.getOrCreate(harness_id);

        // P2: Idempotenz per causality_event
        for (record.nft_entries[0..record.nft_count]) |*e| {
            if (std.mem.eql(u8, &e.causality_ledger_event, &causality_event)) return;
        }

        // Prüfe ob nft_cid bereits bekannt → Besitz-Flag aktualisieren
        for (record.nft_entries[0..record.nft_count]) |*e| {
            if (std.mem.eql(u8, &e.nft_cid, &nft_cid)) {
                e.owned = true;
                e.causality_ledger_event = causality_event;
                e.last_change_epoch = epoch;
                return;
            }
        }

        // Neuer Eintrag
        if (record.nft_count >= MAX_NFT_ENTRIES) return error.NftFull;
        const idx = record.nft_count;
        record.nft_entries[idx] = .{
            .nft_cid               = nft_cid,
            .owned                 = true,
            .causality_ledger_event = causality_event,
            .last_change_epoch     = epoch,
        };
        record.nft_count += 1;
    }

    /// Markiert ein NFT als übertragen (nicht mehr im Besitz).
    pub fn applyNftTransferred(
        self: *AssetStateStore,
        harness_id: [32]u8,
        nft_cid: [32]u8,
        causality_event: [32]u8,
        epoch: u64,
    ) AssetError!void {
        if (isZeroHash(harness_id)) return error.InvalidHarnessId;
        if (isZeroHash(nft_cid)) return error.InvalidNftCid;
        if (isZeroHash(causality_event)) return error.InvalidEventHash;

        const record = try self.getOrCreate(harness_id);

        for (record.nft_entries[0..record.nft_count]) |*e| {
            if (std.mem.eql(u8, &e.nft_cid, &nft_cid)) {
                if (std.mem.eql(u8, &e.causality_ledger_event, &causality_event)) return; // P2
                e.owned = false;
                e.causality_ledger_event = causality_event;
                e.last_change_epoch = epoch;
                return;
            }
        }
        // NFT nicht bekannt → still ignorieren (Rebuilder-Reihenfolge kann variieren)
    }

    // ── Capability Asset ──────────────────────────────────────────────────

    /// Fügt eine Capability als `active` hinzu oder aktualisiert den Zustand.
    ///
    /// P5: Zustandsgraph forward-only: active → outdated → revoked / active → revoked
    pub fn applyCapabilityActive(
        self: *AssetStateStore,
        harness_id: [32]u8,
        artifact_cid: [32]u8,
        causality_event: [32]u8,
        epoch: u64,
    ) AssetError!void {
        if (isZeroHash(harness_id)) return error.InvalidHarnessId;
        if (isZeroHash(artifact_cid)) return error.InvalidArtifactCid;
        if (isZeroHash(causality_event)) return error.InvalidEventHash;

        const record = try self.getOrCreate(harness_id);

        // P2: Idempotenz per causality_event
        for (record.capability_assets[0..record.capability_asset_count]) |*ca| {
            if (std.mem.eql(u8, &ca.causality_ledger_event, &causality_event)) return;
        }

        // Prüfe ob artifact_cid bereits bekannt
        for (record.capability_assets[0..record.capability_asset_count]) |*ca| {
            if (std.mem.eql(u8, &ca.artifact_cid, &artifact_cid)) {
                // P5: revoked → active ist verboten (forward-only)
                if (ca.status == .revoked) return error.InvalidStatusTransition;
                // outdated → active oder active → active (Re-Aktivierung) erlaubt
                ca.status = .active;
                ca.causality_ledger_event = causality_event;
                ca.last_transition_epoch = epoch;
                return;
            }
        }

        if (record.capability_asset_count >= MAX_CAPABILITY_ASSETS) return error.CapabilityAssetsFull;
        const idx = record.capability_asset_count;
        record.capability_assets[idx] = .{
            .artifact_cid           = artifact_cid,
            .status                 = .active,
            .causality_ledger_event = causality_event,
            .last_transition_epoch  = epoch,
        };
        record.capability_asset_count += 1;
    }

    /// Markiert eine Capability als `outdated`.
    /// P5: Nur von active. revoked → outdated ist ungültig.
    pub fn applyCapabilityOutdated(
        self: *AssetStateStore,
        harness_id: [32]u8,
        artifact_cid: [32]u8,
        causality_event: [32]u8,
        epoch: u64,
    ) AssetError!void {
        if (isZeroHash(harness_id)) return error.InvalidHarnessId;
        if (isZeroHash(artifact_cid)) return error.InvalidArtifactCid;
        if (isZeroHash(causality_event)) return error.InvalidEventHash;

        const record = try self.getOrCreate(harness_id);

        for (record.capability_assets[0..record.capability_asset_count]) |*ca| {
            if (!std.mem.eql(u8, &ca.artifact_cid, &artifact_cid)) continue;
            if (std.mem.eql(u8, &ca.causality_ledger_event, &causality_event)) return; // P2
            // P5: revoked → outdated ist verboten
            if (ca.status == .revoked) return error.InvalidStatusTransition;
            ca.status = .outdated;
            ca.causality_ledger_event = causality_event;
            ca.last_transition_epoch = epoch;
            return;
        }
        // Nicht bekannt → still ignorieren
    }

    /// Markiert eine Capability als `revoked`.
    /// P5: Von active oder outdated erlaubt.
    pub fn applyCapabilityRevoked(
        self: *AssetStateStore,
        harness_id: [32]u8,
        artifact_cid: [32]u8,
        causality_event: [32]u8,
        epoch: u64,
    ) AssetError!void {
        if (isZeroHash(harness_id)) return error.InvalidHarnessId;
        if (isZeroHash(artifact_cid)) return error.InvalidArtifactCid;
        if (isZeroHash(causality_event)) return error.InvalidEventHash;

        const record = try self.getOrCreate(harness_id);

        for (record.capability_assets[0..record.capability_asset_count]) |*ca| {
            if (!std.mem.eql(u8, &ca.artifact_cid, &artifact_cid)) continue;
            if (std.mem.eql(u8, &ca.causality_ledger_event, &causality_event)) return; // P2
            ca.status = .revoked;
            ca.causality_ledger_event = causality_event;
            ca.last_transition_epoch = epoch;
            return;
        }
        // Nicht bekannt → still ignorieren (z.B. Reihenfolge-Anomalie im Rebuild)
    }

    // ── Lookup ─────────────────────────────────────────────────────────────

    /// Sucht einen Record per harness_id. Gibt null zurück wenn nicht gefunden.
    pub fn getByHarnessId(self: *const AssetStateStore, harness_id: [32]u8) ?*const HarnessAssetRecord {
        const idx = self.by_harness_id.get(harness_id) orelse return null;
        return &self.records.items[idx];
    }

    /// Gibt die Anzahl bekannter Harness-Records zurück.
    pub fn count(self: *const AssetStateStore) usize {
        return self.records.items.len;
    }

    // ── Interne Hilfsfunktionen ───────────────────────────────────────────

    fn getOrCreate(self: *AssetStateStore, harness_id: [32]u8) AssetError!*HarnessAssetRecord {
        if (self.by_harness_id.get(harness_id)) |idx| {
            return &self.records.items[idx];
        }

        // Neuen Record anlegen
        if (self.records.items.len >= MAX_HARNESS_RECORDS) return error.StoreFull;

        const zero_nft = NftEntry{
            .nft_cid               = ZERO_HASH,
            .owned                 = false,
            .causality_ledger_event = ZERO_HASH,
            .last_change_epoch     = 0,
        };
        const zero_cap = CapabilityAsset{
            .artifact_cid           = ZERO_HASH,
            .status                 = .active,
            .causality_ledger_event = ZERO_HASH,
            .last_transition_epoch  = 0,
        };
        const new_record = HarnessAssetRecord{
            .domain_prefix          = DOMAIN_PREFIX,
            .harness_id             = harness_id,
            .xp                     = 0,
            .xp_causality           = ZERO_HASH,
            .algo_milli             = 0,
            .algo_causality         = ZERO_HASH,
            .nft_entries            = [_]NftEntry{zero_nft} ** MAX_NFT_ENTRIES,
            .nft_count              = 0,
            .capability_assets      = [_]CapabilityAsset{zero_cap} ** MAX_CAPABILITY_ASSETS,
            .capability_asset_count = 0,
            .state_hash             = computeStateHash(harness_id, 0, 0, ZERO_HASH, ZERO_HASH),
        };

        const idx = self.records.items.len;
        try self.records.append(self.allocator, new_record);
        errdefer _ = self.records.pop();
        try self.by_harness_id.put(harness_id, idx);

        return &self.records.items[idx];
    }
};

// ── computeStateHash ──────────────────────────────────────────────────────

/// Berechnet den deterministischen Asset-State-Hash.
/// SHA256("BKGAS" || harness_id || xp_le8 || algo_le8 || xp_causality || algo_causality)
pub fn computeStateHash(
    harness_id: [32]u8,
    xp: u64,
    algo_milli: u64,
    xp_causality: [32]u8,
    algo_causality: [32]u8,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&DOMAIN_PREFIX);
    hasher.update(&harness_id);
    var xp_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &xp_buf, xp, .little);
    hasher.update(&xp_buf);
    var algo_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &algo_buf, algo_milli, .little);
    hasher.update(&algo_buf);
    hasher.update(&xp_causality);
    hasher.update(&algo_causality);
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

test "asset_state: computeStateHash deterministisch" {
    const harness = h(0x01);
    const a = computeStateHash(harness, 100, 200, h(0xA1), h(0xA2));
    const b = computeStateHash(harness, 100, 200, h(0xA1), h(0xA2));
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "asset_state: computeStateHash Domain-Separation" {
    const harness = h(0x01);
    const h1 = computeStateHash(harness, 100, 0, h(0xA1), ZERO_HASH);
    const h2 = computeStateHash(harness, 0, 100, ZERO_HASH, h(0xA1));
    const h3 = computeStateHash(h(0x02), 100, 0, h(0xA1), ZERO_HASH);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
    try std.testing.expect(!std.mem.eql(u8, &h1, &h3));
}

test "asset_state: applyXpUpdate Grundfall" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try store.applyXpUpdate(h(0x01), 500, h(0xAA), 1);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    const rec = store.getByHarnessId(h(0x01)).?;
    try std.testing.expectEqual(@as(u64, 500), rec.xp);
    try std.testing.expectEqualSlices(u8, &h(0xAA), &rec.xp_causality);
}

test "asset_state: applyXpUpdate Idempotenz" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try store.applyXpUpdate(h(0x01), 500, h(0xAA), 1);
    // Gleicher causality_event → still ignoriert
    try store.applyXpUpdate(h(0x01), 999, h(0xAA), 2);

    const rec = store.getByHarnessId(h(0x01)).?;
    try std.testing.expectEqual(@as(u64, 500), rec.xp); // unverändert
}

test "asset_state: applyXpUpdate ZERO causality verboten" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidEventHash,
        store.applyXpUpdate(h(0x01), 100, ZERO_HASH, 1));
}

test "asset_state: applyXpUpdate ZERO harness_id verboten" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidHarnessId,
        store.applyXpUpdate(ZERO_HASH, 100, h(0xAA), 1));
}

test "asset_state: applyXpDelta akkumuliert XP" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try store.applyXpDelta(h(0x01), 100, h(0xA1), 1);
    try store.applyXpDelta(h(0x01), 50, h(0xA2), 2);
    try store.applyXpDelta(h(0x01), 25, h(0xA3), 3);

    const rec = store.getByHarnessId(h(0x01)).?;
    try std.testing.expectEqual(@as(u64, 175), rec.xp);
}

test "asset_state: applyAlgoUpdate Grundfall" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try store.applyAlgoUpdate(h(0x01), 1_000_000, h(0xBB), 1);

    const rec = store.getByHarnessId(h(0x01)).?;
    try std.testing.expectEqual(@as(u64, 1_000_000), rec.algo_milli);
}

test "asset_state: applyAlgoDebit Grundfall" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try store.applyAlgoUpdate(h(0x01), 1000, h(0xB1), 1);
    try store.applyAlgoDebit(h(0x01), 400, h(0xB2), 2);

    const rec = store.getByHarnessId(h(0x01)).?;
    try std.testing.expectEqual(@as(u64, 600), rec.algo_milli);
}

test "asset_state: applyAlgoDebit InsufficientBalance" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try store.applyAlgoUpdate(h(0x01), 100, h(0xB1), 1);

    try std.testing.expectError(error.InsufficientBalance,
        store.applyAlgoDebit(h(0x01), 200, h(0xB2), 2));
}

test "asset_state: applyNftAcquired Grundfall" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try store.applyNftAcquired(h(0x01), h(0xAF), h(0xC1), 1);

    const rec = store.getByHarnessId(h(0x01)).?;
    try std.testing.expectEqual(@as(u8, 1), rec.nft_count);
    try std.testing.expect(rec.nft_entries[0].owned);
    try std.testing.expectEqualSlices(u8, &h(0xAF), &rec.nft_entries[0].nft_cid);
}

test "asset_state: applyNftTransferred" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try store.applyNftAcquired(h(0x01), h(0xAF), h(0xC1), 1);
    try store.applyNftTransferred(h(0x01), h(0xAF), h(0xC2), 2);

    const rec = store.getByHarnessId(h(0x01)).?;
    try std.testing.expect(!rec.nft_entries[0].owned);
    // P4: Eintrag bleibt erhalten
    try std.testing.expectEqual(@as(u8, 1), rec.nft_count);
}

test "asset_state: applyNftAcquired ZERO nft_cid verboten" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidNftCid,
        store.applyNftAcquired(h(0x01), ZERO_HASH, h(0xC1), 1));
}

test "asset_state: Capability active → outdated → revoked" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    const harness = h(0x01);
    const artifact = h(0xAF);

    try store.applyCapabilityActive(harness, artifact, h(0xE1), 1);
    try store.applyCapabilityOutdated(harness, artifact, h(0xE2), 2);
    try store.applyCapabilityRevoked(harness, artifact, h(0xE3), 3);

    const rec = store.getByHarnessId(harness).?;
    try std.testing.expectEqual(@as(u8, 1), rec.capability_asset_count);
    try std.testing.expectEqual(CapabilityAssetStatus.revoked, rec.capability_assets[0].status);
}

test "asset_state: Capability active → revoked direkt" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    const harness = h(0x01);
    const artifact = h(0xAF);

    try store.applyCapabilityActive(harness, artifact, h(0xE1), 1);
    try store.applyCapabilityRevoked(harness, artifact, h(0xE2), 2);

    const rec = store.getByHarnessId(harness).?;
    try std.testing.expectEqual(CapabilityAssetStatus.revoked, rec.capability_assets[0].status);
}

test "asset_state: P5 revoked → outdated verboten" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    const harness = h(0x01);
    const artifact = h(0xAF);

    try store.applyCapabilityActive(harness, artifact, h(0xE1), 1);
    try store.applyCapabilityRevoked(harness, artifact, h(0xE2), 2);

    // P5: revoked → outdated ist ungültig
    try std.testing.expectError(error.InvalidStatusTransition,
        store.applyCapabilityOutdated(harness, artifact, h(0xE3), 3));
}

test "asset_state: state_hash ändert sich nach XP-Update" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    const harness = h(0x01);
    try store.applyXpUpdate(harness, 0, h(0xA1), 1);
    const rec = store.getByHarnessId(harness).?;
    const hash_before = rec.state_hash;

    try store.applyXpUpdate(harness, 100, h(0xA2), 2);
    const rec2 = store.getByHarnessId(harness).?;
    try std.testing.expect(!std.mem.eql(u8, &hash_before, &rec2.state_hash));
}

test "asset_state: Mehrere Harness unabhängig" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try store.applyXpUpdate(h(0x01), 100, h(0xA1), 1);
    try store.applyXpUpdate(h(0x02), 200, h(0xA2), 1);
    try store.applyXpUpdate(h(0x03), 300, h(0xA3), 1);

    try std.testing.expectEqual(@as(usize, 3), store.count());
    try std.testing.expectEqual(@as(u64, 100), store.getByHarnessId(h(0x01)).?.xp);
    try std.testing.expectEqual(@as(u64, 200), store.getByHarnessId(h(0x02)).?.xp);
    try std.testing.expectEqual(@as(u64, 300), store.getByHarnessId(h(0x03)).?.xp);
}

test "asset_state: deinit gibt Speicher frei" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try store.applyXpUpdate(h(0x01), 100, h(0xA1), 1);
    try store.applyAlgoUpdate(h(0x01), 500, h(0xB1), 1);
    try store.applyNftAcquired(h(0x01), h(0xAF), h(0xC1), 1);
    // deinit via defer — kein Leak
}

test "asset_state: Capability Idempotenz per causality_event" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    const harness = h(0x01);
    const artifact = h(0xAF);

    try store.applyCapabilityActive(harness, artifact, h(0xE1), 1);
    // Gleicher event → still ignoriert
    try store.applyCapabilityActive(harness, artifact, h(0xE1), 2);

    const rec = store.getByHarnessId(harness).?;
    try std.testing.expectEqual(@as(u8, 1), rec.capability_asset_count);
    try std.testing.expectEqual(CapabilityAssetStatus.active, rec.capability_assets[0].status);
}

test "asset_state: P5 revoked → active verboten" {
    // Adversarial: P5 forward-only — revoked kann nicht zu active zurück.
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    const harness  = h(0x01);
    const artifact = h(0xAF);

    try store.applyCapabilityActive(harness, artifact, h(0xE1), 1);
    try store.applyCapabilityRevoked(harness, artifact, h(0xE2), 2);

    // P5: revoked → active ist ungültig
    try std.testing.expectError(error.InvalidStatusTransition,
        store.applyCapabilityActive(harness, artifact, h(0xE3), 3));
}

test "asset_state: outdated → active erlaubt (Re-Aktivierung)" {
    // outdated → active ist erlaubt (z.B. Re-Validierung einer Capability).
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    const harness  = h(0x01);
    const artifact = h(0xAF);

    try store.applyCapabilityActive(harness, artifact, h(0xE1), 1);
    try store.applyCapabilityOutdated(harness, artifact, h(0xE2), 2);
    try store.applyCapabilityActive(harness, artifact, h(0xE3), 3);

    const rec = store.getByHarnessId(harness).?;
    try std.testing.expectEqual(CapabilityAssetStatus.active, rec.capability_assets[0].status);
}

test "asset_state: applyXpDelta Overflow Saturierung" {
    // u64 saturierender Add: kein Panic bei Overflow.
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    try store.applyXpUpdate(h(0x01), std.math.maxInt(u64), h(0xA1), 1);
    try store.applyXpDelta(h(0x01), 1, h(0xA2), 2);

    const rec = store.getByHarnessId(h(0x01)).?;
    try std.testing.expectEqual(std.math.maxInt(u64), rec.xp); // gesättigt, kein Overflow
}

test "asset_state: state_hash bindet harness_id (Domain-Separation)" {
    const harness1 = h(0x01);
    const harness2 = h(0x02);
    const h1 = computeStateHash(harness1, 100, 0, h(0xA1), ZERO_HASH);
    const h2 = computeStateHash(harness2, 100, 0, h(0xA1), ZERO_HASH);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "asset_state: NFT re-acquire nach Transfer" {
    // P4: Ein einmal transferiertes NFT kann wieder acquired werden.
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    const harness = h(0x01);
    const nft     = h(0xAF);

    try store.applyNftAcquired(harness, nft, h(0xC1), 1);
    try store.applyNftTransferred(harness, nft, h(0xC2), 2);
    try store.applyNftAcquired(harness, nft, h(0xC3), 3);

    const rec = store.getByHarnessId(harness).?;
    // Eintrag bleibt einer (kein doppelter Append)
    try std.testing.expectEqual(@as(u8, 1), rec.nft_count);
    try std.testing.expect(rec.nft_entries[0].owned); // wieder owned
}

test "asset_state: StoreFull" {
    const allocator = std.testing.allocator;
    var store = AssetStateStore.init(allocator);
    defer store.deinit();

    var i: u16 = 0;
    while (i < MAX_HARNESS_RECORDS) : (i += 1) {
        var harness: [32]u8 = ZERO_HASH;
        harness[0] = @as(u8, @truncate(i >> 8));
        harness[1] = @as(u8, @truncate(i));
        harness[2] = 0xAA;
        var ev: [32]u8 = ZERO_HASH;
        ev[0] = @as(u8, @truncate(i >> 8));
        ev[1] = @as(u8, @truncate(i));
        ev[2] = 0xBB;
        try store.applyXpUpdate(harness, 1, ev, 1);
    }

    var overflow_harness: [32]u8 = ZERO_HASH;
    overflow_harness[0] = 0xFF;
    overflow_harness[1] = 0xFF;
    overflow_harness[2] = 0xFF;
    try std.testing.expectError(error.StoreFull,
        store.applyXpUpdate(overflow_harness, 1, h(0xEE), 1));
}
