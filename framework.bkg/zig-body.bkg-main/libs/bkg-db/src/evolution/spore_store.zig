/// BKGDB Evolution Memory v1 — Spore Store
///
/// Status: STAGE 1 — NICHT FROZEN
/// Spec:   docs/BKGDB_EVOLUTION_MEMORY_v1.md §Spore Store
///
/// WICHTIG: Store State != Ledger Truth
/// Dieses Modul speichert Wissen und Kandidaten.
/// Kanonische Wahrheit liegt im Ledger/Rebuilder.
///
/// Eine gespeicherte Spore ist empfangen, nicht verifiziert.
/// Eine Spore mit state=accepted ist lokal akzeptiert, nicht kanonisch.
/// Kanonische Wahrheit liegt im Ledger/Rebuilder.
///
/// Semantik:
///   - Zustandsmaschine mit definierten erlaubten Übergängen
///   - WRITE ONCE für Records (Content-addressed per spore_hash)
///   - Domain Separation: spore_hash = SHA256("BKGS" || payload_hash)
const std = @import("std");

// ── Domain Separation ─────────────────────────────────────────────────────

/// Domain-Prefix für Spore-Hashes (4 Bytes).
pub const DOMAIN_PREFIX: [4]u8 = "BKGS".*;

/// Berechnet SHA256("BKGS" || data).
fn domainHash(data: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&DOMAIN_PREFIX);
    hasher.update(data);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

// ── SporeState ────────────────────────────────────────────────────────────

pub const SporeState = enum(u8) {
    received  = 0,
    validated = 1,
    candidate = 2,
    accepted  = 3,
    rejected  = 4,
    retired   = 5,
    lost      = 6,
};

/// Prüft ob ein Zustandsübergang erlaubt ist.
///
/// Erlaubte Übergänge:
///   received  → validated, rejected, lost
///   validated → candidate, rejected
///   candidate → accepted, rejected
///   accepted  → retired
///   rejected  → lost
///   retired   → lost
///   lost      → (Terminal — kein Übergang)
pub fn isValidTransition(from: SporeState, to: SporeState) bool {
    return switch (from) {
        .received  => to == .validated or to == .rejected or to == .lost,
        .validated => to == .candidate or to == .rejected,
        .candidate => to == .accepted  or to == .rejected,
        .accepted  => to == .retired,
        .rejected  => to == .lost,
        .retired   => to == .lost,
        .lost      => false,
    };
}

// ── SporeRecord ───────────────────────────────────────────────────────────

/// Index-Eintrag für eine empfangene Spore.
/// Kanonisch serialisierbar: keine Pointer, keine Padding-Gaps.
pub const SporeRecord = struct {
    /// Domain Separation ("BKGS")
    domain_prefix: [4]u8,
    /// SHA256("BKGS" || payload_hash)
    spore_hash: [32]u8,
    /// SHA256 des rohen Payloads
    payload_hash: [32]u8,
    /// ZERO = kein Parent
    parent_lineage_hash: [32]u8,
    /// Herkunfts-Beweis
    source_provenance_hash: [32]u8,
    /// Agenten-/Lineage-Referenz
    originating_agent_hash: [32]u8,
    creation_epoch: u64,
    generation: u64,
    state: SporeState,
};

// ── Fehlertypen ───────────────────────────────────────────────────────────

pub const SporeError = error{
    ContentConflict,
    InvalidState,
    InvalidTransition,
    NotFound,
    OutOfMemory,
};

// ── SporeStore ────────────────────────────────────────────────────────────

pub const SporeStore = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap([32]u8, SporeRecord),

    pub fn init(allocator: std.mem.Allocator) SporeStore {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap([32]u8, SporeRecord).init(allocator),
        };
    }

    pub fn deinit(self: *SporeStore) void {
        self.entries.deinit();
    }

    /// Empfängt einen SporeRecord und speichert ihn.
    ///
    /// Prüfungen:
    ///   - record.state muss .received sein (sonst InvalidState)
    ///   - record.spore_hash muss SHA256("BKGS" || record.payload_hash) entsprechen (sonst ContentConflict)
    ///   - Duplikat (gleicher spore_hash, gleicher Record): idempotent
    ///   - Duplikat (gleicher spore_hash, anderer Inhalt): ContentConflict
    pub fn receive(self: *SporeStore, record: SporeRecord) SporeError!void {
        if (record.state != .received) return SporeError.InvalidState;

        // Integritätsprüfung: spore_hash = SHA256("BKGS" || payload_hash)
        const expected = domainHash(&record.payload_hash);
        if (!std.mem.eql(u8, &expected, &record.spore_hash)) {
            return SporeError.ContentConflict;
        }

        if (self.entries.get(record.spore_hash)) |existing| {
            // Idempotent bei identischem Record
            if (recordEql(existing, record)) return;
            return SporeError.ContentConflict;
        }

        try self.entries.put(record.spore_hash, record);
    }

    /// Führt einen Zustandsübergang durch.
    ///
    /// - Ungültiger Übergang: InvalidTransition
    /// - Unbekannter Hash: NotFound
    pub fn transition(
        self: *SporeStore,
        spore_hash: [32]u8,
        new_state: SporeState,
    ) SporeError!void {
        const entry = self.entries.getPtr(spore_hash) orelse return SporeError.NotFound;
        if (!isValidTransition(entry.state, new_state)) return SporeError.InvalidTransition;
        entry.state = new_state;
    }

    /// Gibt eine Kopie des SporeRecord zurück, oder null.
    pub fn get(self: *const SporeStore, spore_hash: [32]u8) ?SporeRecord {
        return self.entries.get(spore_hash);
    }

    /// Gibt den aktuellen Zustand zurück, oder null.
    pub fn getState(self: *const SporeStore, spore_hash: [32]u8) ?SporeState {
        if (self.entries.get(spore_hash)) |r| return r.state;
        return null;
    }

    /// Anzahl gespeicherter Einträge.
    pub fn count(self: *const SporeStore) usize {
        return self.entries.count();
    }
};

// ── Hilfsfunktionen ───────────────────────────────────────────────────────

/// Vergleicht zwei SporeRecord byteweise (alle Felder).
fn recordEql(a: SporeRecord, b: SporeRecord) bool {
    return std.mem.eql(u8, &a.domain_prefix, &b.domain_prefix) and
        std.mem.eql(u8, &a.spore_hash, &b.spore_hash) and
        std.mem.eql(u8, &a.payload_hash, &b.payload_hash) and
        std.mem.eql(u8, &a.parent_lineage_hash, &b.parent_lineage_hash) and
        std.mem.eql(u8, &a.source_provenance_hash, &b.source_provenance_hash) and
        std.mem.eql(u8, &a.originating_agent_hash, &b.originating_agent_hash) and
        a.creation_epoch == b.creation_epoch and
        a.generation == b.generation and
        a.state == b.state;
}

/// Erstellt einen validen SporeRecord für Tests (spore_hash korrekt berechnet).
fn makeRecord(payload_hash: [32]u8, epoch: u64, gen: u64) SporeRecord {
    const spore_hash = domainHash(&payload_hash);
    return SporeRecord{
        .domain_prefix          = "BKGS".*,
        .spore_hash             = spore_hash,
        .payload_hash           = payload_hash,
        .parent_lineage_hash    = [_]u8{0} ** 32,
        .source_provenance_hash = [_]u8{0} ** 32,
        .originating_agent_hash = [_]u8{0} ** 32,
        .creation_epoch         = epoch,
        .generation             = gen,
        .state                  = .received,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "spore_store: receive valid record, get zurück" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const rec = makeRecord([_]u8{0x01} ** 32, 1, 0);
    try store.receive(rec);

    const got = store.get(rec.spore_hash);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(SporeState.received, got.?.state);
}

test "spore_store: receive duplicate gleicher Record — idempotent" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const rec = makeRecord([_]u8{0x02} ** 32, 1, 0);
    try store.receive(rec);
    try store.receive(rec); // zweiter identischer receive — kein Fehler
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "spore_store: receive gleicher Hash + anderer Record — ContentConflict" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const rec1 = makeRecord([_]u8{0x03} ** 32, 1, 0);
    try store.receive(rec1);

    // Gleicher spore_hash, aber anderes Feld
    var rec2 = rec1;
    rec2.creation_epoch = 999; // anderer Inhalt
    try std.testing.expectError(SporeError.ContentConflict, store.receive(rec2));
}

test "spore_store: receive mit state != received — InvalidState" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    var rec = makeRecord([_]u8{0x04} ** 32, 1, 0);
    rec.state = .validated;
    try std.testing.expectError(SporeError.InvalidState, store.receive(rec));
}

test "spore_store: receive mit falschem spore_hash — ContentConflict" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    var rec = makeRecord([_]u8{0x05} ** 32, 1, 0);
    rec.spore_hash = [_]u8{0xFF} ** 32; // manipulierter Hash
    try std.testing.expectError(SporeError.ContentConflict, store.receive(rec));
}

test "spore_store: transition received → validated" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const rec = makeRecord([_]u8{0x06} ** 32, 1, 0);
    try store.receive(rec);
    try store.transition(rec.spore_hash, .validated);
    try std.testing.expectEqual(SporeState.validated, store.getState(rec.spore_hash).?);
}

test "spore_store: transition received → candidate — InvalidTransition" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const rec = makeRecord([_]u8{0x07} ** 32, 1, 0);
    try store.receive(rec);
    try std.testing.expectError(
        SporeError.InvalidTransition,
        store.transition(rec.spore_hash, .candidate),
    );
}

test "spore_store: transition received → accepted — InvalidTransition" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const rec = makeRecord([_]u8{0x08} ** 32, 1, 0);
    try store.receive(rec);
    try std.testing.expectError(
        SporeError.InvalidTransition,
        store.transition(rec.spore_hash, .accepted),
    );
}

test "spore_store: transition rejected → lost" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const rec = makeRecord([_]u8{0x09} ** 32, 1, 0);
    try store.receive(rec);
    try store.transition(rec.spore_hash, .rejected);
    try store.transition(rec.spore_hash, .lost);
    try std.testing.expectEqual(SporeState.lost, store.getState(rec.spore_hash).?);
}

test "spore_store: transition rejected → accepted — InvalidTransition" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const rec = makeRecord([_]u8{0x0A} ** 32, 1, 0);
    try store.receive(rec);
    try store.transition(rec.spore_hash, .rejected);
    try std.testing.expectError(
        SporeError.InvalidTransition,
        store.transition(rec.spore_hash, .accepted),
    );
}

test "spore_store: transition lost → anything — InvalidTransition" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const rec = makeRecord([_]u8{0x0B} ** 32, 1, 0);
    try store.receive(rec);
    try store.transition(rec.spore_hash, .lost);

    const all_states = [_]SporeState{
        .received, .validated, .candidate, .accepted, .rejected, .retired, .lost,
    };
    for (all_states) |s| {
        try std.testing.expectError(
            SporeError.InvalidTransition,
            store.transition(rec.spore_hash, s),
        );
    }
}

test "spore_store: transition unbekannter Hash — NotFound" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const unknown: [32]u8 = [_]u8{0xDE} ** 32;
    try std.testing.expectError(SporeError.NotFound, store.transition(unknown, .validated));
}

test "spore_store: vollständiger Lifecycle received → validated → candidate → accepted → retired → lost" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const rec = makeRecord([_]u8{0x0C} ** 32, 1, 0);
    try store.receive(rec);
    try std.testing.expectEqual(SporeState.received, store.getState(rec.spore_hash).?);

    try store.transition(rec.spore_hash, .validated);
    try std.testing.expectEqual(SporeState.validated, store.getState(rec.spore_hash).?);

    try store.transition(rec.spore_hash, .candidate);
    try std.testing.expectEqual(SporeState.candidate, store.getState(rec.spore_hash).?);

    try store.transition(rec.spore_hash, .accepted);
    try std.testing.expectEqual(SporeState.accepted, store.getState(rec.spore_hash).?);

    try store.transition(rec.spore_hash, .retired);
    try std.testing.expectEqual(SporeState.retired, store.getState(rec.spore_hash).?);

    try store.transition(rec.spore_hash, .lost);
    try std.testing.expectEqual(SporeState.lost, store.getState(rec.spore_hash).?);
}

test "spore_store: getState vor und nach Transition korrekt" {
    var store = SporeStore.init(std.testing.allocator);
    defer store.deinit();

    const rec = makeRecord([_]u8{0x0D} ** 32, 1, 0);
    try std.testing.expect(store.getState(rec.spore_hash) == null);

    try store.receive(rec);
    try std.testing.expectEqual(SporeState.received, store.getState(rec.spore_hash).?);

    try store.transition(rec.spore_hash, .validated);
    try std.testing.expectEqual(SporeState.validated, store.getState(rec.spore_hash).?);
}

test "spore_store: Memory-Safety — alle Fehlerpfade leak-frei" {
    // InvalidState — kein Alloc
    {
        var store = SporeStore.init(std.testing.allocator);
        defer store.deinit();
        var rec = makeRecord([_]u8{0xE0} ** 32, 1, 0);
        rec.state = .accepted;
        _ = store.receive(rec) catch {};
    }
    // ContentConflict (falscher spore_hash) — kein Alloc
    {
        var store = SporeStore.init(std.testing.allocator);
        defer store.deinit();
        var rec = makeRecord([_]u8{0xE1} ** 32, 1, 0);
        rec.spore_hash = [_]u8{0x00} ** 32;
        _ = store.receive(rec) catch {};
    }
    // InvalidTransition — kein Alloc (State schon im Store)
    {
        var store = SporeStore.init(std.testing.allocator);
        defer store.deinit();
        const rec = makeRecord([_]u8{0xE2} ** 32, 1, 0);
        try store.receive(rec);
        _ = store.transition(rec.spore_hash, .accepted) catch {};
    }
    // NotFound — kein Alloc
    {
        var store = SporeStore.init(std.testing.allocator);
        defer store.deinit();
        _ = store.transition([_]u8{0xFF} ** 32, .validated) catch {};
    }
}
