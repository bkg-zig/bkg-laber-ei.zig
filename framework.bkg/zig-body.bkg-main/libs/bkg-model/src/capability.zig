/// BKG Model Layer — Capability State Machine
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/MODEL_LAYER_v1.md
///
/// Capability ist KÖNNEN, nicht AUTHORITY.
///
/// Zustandsmaschine:
///
///   known → verified → materializable → activated
///                                          ↓
///                    revoked ←─────────────┘
///   known → outdated
///   known → lost
///
/// Übergänge:
///   known        → verified       : Hash + Lineage + Authority-Evidence OK
///   verified     → materializable : Policy + Testvektoren + Version OK
///   materializable → activated    : Volle Pipeline erfolgreich
///   activated    → revoked        : Authority-Evidence widerrufen
///   known/verified → outdated     : Neuere Version vorhanden
///   activated    → lost           : Artefakt nicht mehr verfügbar (kein Fallback)
///
/// Verbote:
///   - Kein Übergang von known/verified direkt zu activated (kein Bypass)
///   - Kein stiller Fallback bei fehlgeschlagenem Policy/TV-Check
///   - Revoked darf nicht reaktiviert werden (neue Verifikation nötig)
///   - Keine Capability impliziert Authority
const std = @import("std");
const hash_mod    = @import("hash.zig");
const artifact_mod = @import("artifact.zig");

pub const Hash = hash_mod.Hash;
pub const CapabilityId = artifact_mod.CapabilityId;

// ── Capability-Zustand ─────────────────────────────────────────────────────

pub const CapabilityState = enum(u8) {
    /// Artefakt bekannt, noch nicht verifiziert.
    known          = 0x01,
    /// Hash + Lineage + Evidence verifiziert. Policy noch nicht geprüft.
    verified       = 0x02,
    /// Verifikation + Policy + Testvektoren OK. Bereit zur Aktivierung.
    materializable = 0x03,
    /// Vollständig aktiviert — darf verwendet werden.
    activated      = 0x04,
    /// Revoziert — darf nicht aktiviert werden.
    revoked        = 0x05,
    /// Veraltet — neuere Version vorhanden.
    outdated       = 0x06,
    /// Verloren — Artefakt nicht mehr verfügbar.
    lost           = 0x07,
};

// ── Capability-Eintrag ─────────────────────────────────────────────────────

/// Ein einzelner Capability-Eintrag im lokalen Cache.
pub const CapabilityEntry = struct {
    /// Opaker Bezeichner dieser Capability.
    id:             CapabilityId,
    /// Content-Hash des Artefakts, aus dem die Capability stammt.
    artifact_hash:  Hash,
    /// Aktueller Zustand.
    state:          CapabilityState,
    /// Version (aus Provenance.forge_generation).
    version:        u64,
    /// Epoch der letzten Zustandsänderung.
    last_changed_epoch: u64,
    /// Hash des Artefakts, das diese Capability abgelöst hat (bei outdated).
    superseded_by:  Hash,
};

// ── Capability-Cache ───────────────────────────────────────────────────────

/// Maximale Anzahl gleichzeitig verwalteter Capabilities.
pub const MAX_CACHED_CAPS: usize = hash_mod.MAX_CAPABILITIES;

/// Lokaler Capability-Cache (kein Heap, kein Singleton).
pub const CapabilityCache = struct {
    entries: [MAX_CACHED_CAPS]CapabilityEntry,
    count:   usize,

    pub fn init() CapabilityCache {
        return .{
            .entries = [_]CapabilityEntry{.{
                .id = artifact_mod.ZERO_CAP_ID,
                .artifact_hash = hash_mod.ZERO_HASH,
                .state = .known,
                .version = 0,
                .last_changed_epoch = 0,
                .superseded_by = hash_mod.ZERO_HASH,
            }} ** MAX_CACHED_CAPS,
            .count = 0,
        };
    }

    /// Fügt eine neue Capability im Zustand `known` hinzu.
    ///
    /// PROTOKOLLREGEL M6 — DUPLIKAT-GUARD:
    ///   Eine `capability_id` darf im Cache nur einmal existieren.
    ///   `REVOKED` ist ein terminaler Zustand für diese Capability-Version.
    ///   Ein zweiter addKnown()-Aufruf mit derselben ID schlägt fehl:
    ///     - existiert bereits (any state) → error.DuplicateCapabilityId
    ///   Dies verhindert Cache-Bypass durch frischen Slot nach Revokation.
    ///
    /// Rückgabe:
    ///   ok(idx)                   → neuer Eintrag angelegt
    ///   error.DuplicateCapabilityId → ID bereits im Cache (inkl. revoked)
    ///   error.CacheFull           → kein Slot mehr verfügbar
    pub fn addKnown(
        self: *CapabilityCache,
        id: CapabilityId,
        artifact_hash: Hash,
        version: u64,
        epoch: u64,
    ) CapabilityError!usize {
        // Duplikat-Prüfung (M6): ID darf nur einmal existieren
        if (self.findById(id) != null) return CapabilityError.DuplicateCapabilityId;
        if (self.count >= MAX_CACHED_CAPS) return CapabilityError.CacheFull;
        const idx = self.count;
        self.entries[idx] = .{
            .id = id,
            .artifact_hash = artifact_hash,
            .state = .known,
            .version = version,
            .last_changed_epoch = epoch,
            .superseded_by = hash_mod.ZERO_HASH,
        };
        self.count += 1;
        return idx;
    }

    /// Findet eine Capability nach ID (erste Übereinstimmung).
    pub fn findById(self: *const CapabilityCache, id: CapabilityId) ?usize {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, &self.entries[i].id, &id)) return i;
        }
        return null;
    }

    /// Findet eine Capability nach Artefakt-Hash.
    pub fn findByHash(self: *const CapabilityCache, h: Hash) ?usize {
        for (0..self.count) |i| {
            if (hash_mod.hashEqual(self.entries[i].artifact_hash, h)) return i;
        }
        return null;
    }

    /// Übergang: known → verified (intern, durch Validator aufgerufen).
    pub fn markVerified(self: *CapabilityCache, idx: usize, epoch: u64) CapabilityError!void {
        if (idx >= self.count) return CapabilityError.EntryNotFound;
        if (self.entries[idx].state != .known) return CapabilityError.InvalidTransition;
        self.entries[idx].state = .verified;
        self.entries[idx].last_changed_epoch = epoch;
    }

    /// Übergang: verified → materializable.
    pub fn markMaterializable(self: *CapabilityCache, idx: usize, epoch: u64) CapabilityError!void {
        if (idx >= self.count) return CapabilityError.EntryNotFound;
        if (self.entries[idx].state != .verified) return CapabilityError.InvalidTransition;
        self.entries[idx].state = .materializable;
        self.entries[idx].last_changed_epoch = epoch;
    }

    /// Übergang: materializable → activated.
    pub fn markActivated(self: *CapabilityCache, idx: usize, epoch: u64) CapabilityError!void {
        if (idx >= self.count) return CapabilityError.EntryNotFound;
        if (self.entries[idx].state != .materializable) return CapabilityError.InvalidTransition;
        self.entries[idx].state = .activated;
        self.entries[idx].last_changed_epoch = epoch;
    }

    /// Übergang: activated → revoked. Kann nicht rückgängig gemacht werden.
    pub fn markRevoked(self: *CapabilityCache, idx: usize, epoch: u64) CapabilityError!void {
        if (idx >= self.count) return CapabilityError.EntryNotFound;
        const s = self.entries[idx].state;
        if (s == .revoked or s == .lost) return CapabilityError.InvalidTransition;
        self.entries[idx].state = .revoked;
        self.entries[idx].last_changed_epoch = epoch;
    }

    /// Übergang: beliebig → outdated (neuere Version vorhanden).
    pub fn markOutdated(
        self: *CapabilityCache,
        idx: usize,
        superseded_by: Hash,
        epoch: u64,
    ) CapabilityError!void {
        if (idx >= self.count) return CapabilityError.EntryNotFound;
        self.entries[idx].state = .outdated;
        self.entries[idx].superseded_by = superseded_by;
        self.entries[idx].last_changed_epoch = epoch;
    }

    /// Übergang: activated → lost.
    pub fn markLost(self: *CapabilityCache, idx: usize, epoch: u64) CapabilityError!void {
        if (idx >= self.count) return CapabilityError.EntryNotFound;
        if (self.entries[idx].state != .activated) return CapabilityError.InvalidTransition;
        self.entries[idx].state = .lost;
        self.entries[idx].last_changed_epoch = epoch;
    }

    /// Gibt true zurück wenn eine Capability aktiviert ist.
    pub fn isActivated(self: *const CapabilityCache, idx: usize) bool {
        if (idx >= self.count) return false;
        return self.entries[idx].state == .activated;
    }
};

// ── Fehler ─────────────────────────────────────────────────────────────────

pub const CapabilityError = error{
    /// Zustandsübergang nicht erlaubt.
    InvalidTransition,
    /// Eintrag nicht gefunden.
    EntryNotFound,
    /// Cache voll.
    CacheFull,
    /// Capability revoziert.
    Revoked,
    /// Kein direkter Sprung zu activated.
    ActivationBypass,
    /// M6: Dieselbe capability_id bereits im Cache (inkl. revoked/outdated).
    /// REVOKED ist terminal — kein Cache-Bypass durch neuen Slot.
    DuplicateCapabilityId,
};

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

fn testCapId(b: u8) CapabilityId {
    var id = artifact_mod.ZERO_CAP_ID;
    id[0] = b;
    return id;
}

test "capability: init leer" {
    const c = CapabilityCache.init();
    try std.testing.expectEqual(@as(usize, 0), c.count);
}

test "capability: addKnown und findById" {
    var c = CapabilityCache.init();
    const id = testCapId(0x01);
    const h  = hash_mod.hashBytes("art1");
    const idx = try c.addKnown(id, h, 1, 100);
    try std.testing.expectEqual(@as(usize, 0), idx);
    const found = c.findById(id) orelse unreachable;
    try std.testing.expectEqual(idx, found);
    try std.testing.expect(c.entries[found].state == .known);
}

test "capability: vollständiger Zustandsübergang known→verified→materializable→activated" {
    var c = CapabilityCache.init();
    const id = testCapId(0x02);
    const h  = hash_mod.hashBytes("art2");
    const idx = try c.addKnown(id, h, 1, 1);
    try c.markVerified(idx, 2);
    try std.testing.expect(c.entries[idx].state == .verified);
    try c.markMaterializable(idx, 3);
    try std.testing.expect(c.entries[idx].state == .materializable);
    try c.markActivated(idx, 4);
    try std.testing.expect(c.entries[idx].state == .activated);
    try std.testing.expect(c.isActivated(idx));
}

test "capability: kein Bypass von known direkt zu activated" {
    var c = CapabilityCache.init();
    const id = testCapId(0x03);
    const idx = try c.addKnown(id, hash_mod.ZERO_HASH, 1, 1);
    // known → activated ist verboten (kein markActivated ohne materializable)
    try std.testing.expectError(CapabilityError.InvalidTransition, c.markActivated(idx, 2));
}

test "capability: kein Bypass von verified direkt zu activated" {
    var c = CapabilityCache.init();
    const id = testCapId(0x04);
    const idx = try c.addKnown(id, hash_mod.ZERO_HASH, 1, 1);
    try c.markVerified(idx, 2);
    try std.testing.expectError(CapabilityError.InvalidTransition, c.markActivated(idx, 3));
}

test "capability: revoke verhindert Re-Aktivierung" {
    var c = CapabilityCache.init();
    const id = testCapId(0x05);
    const idx = try c.addKnown(id, hash_mod.ZERO_HASH, 1, 1);
    try c.markVerified(idx, 2);
    try c.markMaterializable(idx, 3);
    try c.markActivated(idx, 4);
    try c.markRevoked(idx, 5);
    try std.testing.expect(c.entries[idx].state == .revoked);
    // Erneut revoke = InvalidTransition
    try std.testing.expectError(CapabilityError.InvalidTransition, c.markRevoked(idx, 6));
}

test "capability: outdated mit superseded_by Hash" {
    var c = CapabilityCache.init();
    const id = testCapId(0x06);
    const new_h = hash_mod.hashBytes("new-version");
    const idx = try c.addKnown(id, hash_mod.ZERO_HASH, 1, 1);
    try c.markOutdated(idx, new_h, 10);
    try std.testing.expect(c.entries[idx].state == .outdated);
    try std.testing.expect(hash_mod.hashEqual(new_h, c.entries[idx].superseded_by));
}

test "capability: Cache voll → CacheFull" {
    var c = CapabilityCache.init();
    for (0..MAX_CACHED_CAPS) |i| {
        var id = artifact_mod.ZERO_CAP_ID;
        id[0] = @intCast(i & 0xFF);
        id[1] = @intCast((i >> 8) & 0xFF);
        _ = try c.addKnown(id, hash_mod.ZERO_HASH, 1, 1);
    }
    const extra = testCapId(0xFF);
    try std.testing.expectError(CapabilityError.CacheFull, c.addKnown(extra, hash_mod.ZERO_HASH, 1, 1));
}

test "capability: markLost nur von activated möglich" {
    var c = CapabilityCache.init();
    const id = testCapId(0x07);
    const idx = try c.addKnown(id, hash_mod.ZERO_HASH, 1, 1);
    // known → lost verboten
    try std.testing.expectError(CapabilityError.InvalidTransition, c.markLost(idx, 2));
}

test "capability: findByHash" {
    var c = CapabilityCache.init();
    const h = hash_mod.hashBytes("lookup");
    const id = testCapId(0x08);
    _ = try c.addKnown(id, h, 1, 1);
    const found = c.findByHash(h) orelse unreachable;
    try std.testing.expect(hash_mod.hashEqual(h, c.entries[found].artifact_hash));
}

// ── M6: Duplikat-Guard + REVOKED terminal — Adversarial Tests ─────────────

test "capability M6: addKnown mit Duplikat-ID → DuplicateCapabilityId" {
    var c = CapabilityCache.init();
    const id = testCapId(0xA0);
    _ = try c.addKnown(id, hash_mod.ZERO_HASH, 1, 1);
    // Zweiter Aufruf mit derselben ID muss fehlschlagen
    try std.testing.expectError(
        CapabilityError.DuplicateCapabilityId,
        c.addKnown(id, hash_mod.hashBytes("other"), 2, 2),
    );
}

test "capability M6: REVOKED ist terminal — kein Cache-Bypass durch neuen Slot" {
    var c = CapabilityCache.init();
    const id = testCapId(0xA1);
    const idx = try c.addKnown(id, hash_mod.ZERO_HASH, 1, 1);
    try c.markVerified(idx, 2);
    try c.markMaterializable(idx, 3);
    try c.markActivated(idx, 4);
    try c.markRevoked(idx, 5);
    try std.testing.expect(c.entries[idx].state == .revoked);

    // Versuch, einen neuen Slot mit derselben ID anzulegen → verboten
    try std.testing.expectError(
        CapabilityError.DuplicateCapabilityId,
        c.addKnown(id, hash_mod.hashBytes("fresh"), 2, 6),
    );
    // Der revozierte Eintrag ist weiterhin revoked
    try std.testing.expect(c.entries[idx].state == .revoked);
}

test "capability M6: OUTDATED blockiert ebenfalls Duplikat" {
    var c = CapabilityCache.init();
    const id = testCapId(0xA2);
    const idx = try c.addKnown(id, hash_mod.ZERO_HASH, 1, 1);
    try c.markOutdated(idx, hash_mod.hashBytes("newer"), 10);

    try std.testing.expectError(
        CapabilityError.DuplicateCapabilityId,
        c.addKnown(id, hash_mod.hashBytes("other"), 2, 11),
    );
}

test "capability M6: verschiedene IDs können unabhängig hinzugefügt werden" {
    var c = CapabilityCache.init();
    const id1 = testCapId(0xB0);
    const id2 = testCapId(0xB1);
    _ = try c.addKnown(id1, hash_mod.ZERO_HASH, 1, 1);
    _ = try c.addKnown(id2, hash_mod.ZERO_HASH, 1, 1);
    try std.testing.expectEqual(@as(usize, 2), c.count);
}
