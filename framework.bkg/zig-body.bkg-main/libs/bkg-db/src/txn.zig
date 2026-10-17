/// BKGDB — Transactions (MVCC)
///
/// Multi-Version Concurrency Control für den Mutable State.
///
/// txn_id: monoton steigender u64-Zähler
/// read_ts:  txn_id zum Zeitpunkt des Transaktionsstarts
/// write_ts: txn_id zum Zeitpunkt des Commits
///
/// Jede Version eines Records trägt write_ts.
/// Eine Leseoperation mit read_ts=T sieht nur Records mit write_ts ≤ T.
///
/// Write-Intent: Transaktionen schreiben zuerst einen Write-Intent,
/// der beim Commit zu einem committed Record wird.
/// Beim Abort werden Write-Intents verworfen.
const std = @import("std");

// ── Typen ─────────────────────────────────────────────────────────────────

pub const TxnId = u64;
pub const Timestamp = u64;

pub const TxnState = enum {
    active,
    committed,
    aborted,
};

/// Beschreibt eine MVCC-Version eines Wertes.
pub const Version = struct {
    write_ts: Timestamp,
    txn_id: TxnId,
    value: []const u8, // Slice — Lifetime liegt beim Caller/Store
    is_deleted: bool,
};

// ── TxnManager ────────────────────────────────────────────────────────────

/// Verwaltet den globalen Transaktionszähler.
/// In Phase 1: single-threaded, kein Locking.
pub const TxnManager = struct {
    next_txn_id: TxnId,

    pub fn init() TxnManager {
        return .{ .next_txn_id = 1 };
    }

    /// Startet eine neue Transaktion und gibt ihre ID zurück.
    pub fn begin(self: *TxnManager) TxnId {
        const id = self.next_txn_id;
        self.next_txn_id += 1;
        return id;
    }

    /// Aktueller globaler Zählerstand (letzter vergebener + 1).
    pub fn current(self: *const TxnManager) TxnId {
        return self.next_txn_id;
    }
};

// ── Transaction ───────────────────────────────────────────────────────────

/// Eine einzelne Transaktion mit Read-Snapshot und Write-Set.
pub const Transaction = struct {
    id: TxnId,
    /// Snapshot-Timestamp: sieht Records mit write_ts ≤ read_ts
    read_ts: Timestamp,
    state: TxnState,
    /// Write-Set: Key → Wert (wird beim Commit angewendet)
    writes: std.StringHashMap(WriteIntent),
    allocator: std.mem.Allocator,

    pub const WriteIntent = struct {
        value: []u8,
        is_delete: bool,
    };

    pub fn init(allocator: std.mem.Allocator, id: TxnId, read_ts: Timestamp) Transaction {
        return .{
            .id = id,
            .read_ts = read_ts,
            .state = .active,
            .writes = std.StringHashMap(WriteIntent).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Transaction) void {
        var it = self.writes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.writes.deinit();
    }

    fn putOwnedKey(self: *Transaction, key: []const u8) !std.StringHashMap(WriteIntent).GetOrPutResult {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const result = try self.writes.getOrPut(owned_key);
        if (result.found_existing) {
            self.allocator.free(owned_key);
        }
        return result;
    }

    /// Fügt einen Write-Intent hinzu (Key und Wert werden kopiert).
    pub fn put(self: *Transaction, key: []const u8, value: []const u8) !void {
        if (self.state != .active) return error.TransactionNotActive;
        const v = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(v);
        const result = try self.putOwnedKey(key);
        if (result.found_existing) {
            self.allocator.free(result.value_ptr.value);
        }
        result.value_ptr.* = .{ .value = v, .is_delete = false };
    }

    /// Markiert einen Key als gelöscht (Delete-Intent).
    pub fn delete(self: *Transaction, key: []const u8) !void {
        if (self.state != .active) return error.TransactionNotActive;
        const result = try self.putOwnedKey(key);
        if (result.found_existing) {
            self.allocator.free(result.value_ptr.value);
        }
        const empty = try self.allocator.alloc(u8, 0);
        result.value_ptr.* = .{ .value = empty, .is_delete = true };
    }

    /// Liest einen Write-Intent der aktuellen Transaktion (dirty read).
    pub fn getDirty(self: *const Transaction, key: []const u8) ?[]const u8 {
        const intent = self.writes.get(key) orelse return null;
        if (intent.is_delete) return null;
        return intent.value;
    }

    pub fn commit(self: *Transaction) !void {
        if (self.state != .active) return error.TransactionNotActive;
        self.state = .committed;
    }

    pub fn abort(self: *Transaction) void {
        self.state = .aborted;
    }

    pub fn isActive(self: *const Transaction) bool {
        return self.state == .active;
    }

    pub fn isCommitted(self: *const Transaction) bool {
        return self.state == .committed;
    }
};

// ── MVCC Version-Store (in-Memory, Phase 1) ───────────────────────────────

/// Einfacher In-Memory Version-Store für Phase 1.
/// Jeder Key hat eine Liste von Versionen (write_ts aufsteigend).
/// Lesen gibt die Version mit dem höchsten write_ts ≤ read_ts zurück.
pub const VersionStore = struct {
    // Key → sortierte Liste von Versionen
    store: std.StringHashMap(std.ArrayList(StoredVersion)),
    allocator: std.mem.Allocator,

    const StoredVersion = struct {
        write_ts: Timestamp,
        txn_id: TxnId,
        value: []u8, // owned
        is_deleted: bool,
    };

    pub fn init(allocator: std.mem.Allocator) VersionStore {
        return .{
            .store = std.StringHashMap(std.ArrayList(StoredVersion)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VersionStore) void {
        var it = self.store.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |v| {
                self.allocator.free(v.value);
            }
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.store.deinit();
    }

    /// Wendet einen einzelnen recovered/committed Write an. Der Key wird owned.
    pub fn applyWrite(
        self: *VersionStore,
        key: []const u8,
        value: []const u8,
        is_deleted: bool,
        write_ts: Timestamp,
        txn_id: TxnId,
    ) !void {
        const result = try self.store.getOrPut(key);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, key);
            result.value_ptr.* = .empty;
        }
        const value_copy = try self.allocator.dupe(u8, value);
        try result.value_ptr.append(self.allocator, .{
            .write_ts = write_ts,
            .txn_id = txn_id,
            .value = value_copy,
            .is_deleted = is_deleted,
        });
    }

    /// Liest den Wert für `key` sichtbar bei `read_ts`.
    /// Gibt null zurück wenn nicht vorhanden oder gelöscht.
    pub fn get(self: *const VersionStore, key: []const u8, read_ts: Timestamp) ?[]const u8 {
        const versions = self.store.get(key) orelse return null;
        // Höchste write_ts ≤ read_ts suchen
        var best: ?*const StoredVersion = null;
        for (versions.items) |*v| {
            if (v.write_ts <= read_ts) {
                if (best == null or v.write_ts > best.?.write_ts) {
                    best = v;
                }
            }
        }
        const b = best orelse return null;
        if (b.is_deleted) return null;
        return b.value;
    }

    /// Wendet die Write-Intents einer committed Transaktion an.
    pub fn applyCommit(self: *VersionStore, txn: *const Transaction, write_ts: Timestamp) !void {
        var it = txn.writes.iterator();
        while (it.next()) |entry| {
            try self.applyWrite(
                entry.key_ptr.*,
                entry.value_ptr.value,
                entry.value_ptr.is_delete,
                write_ts,
                txn.id,
            );
        }
    }

    /// Verwirft alte Versionen mit write_ts < min_active_read_ts (Garbage Collection).
    /// Behält mindestens eine Version pro Key (die aktuellste).
    pub fn gc(self: *VersionStore, min_active_read_ts: Timestamp) void {
        var it = self.store.iterator();
        while (it.next()) |entry| {
            const versions = entry.value_ptr;
            if (versions.items.len <= 1) continue;
            var keep_from: usize = 0;
            // Finde die aktuellste Version ≤ min_active_read_ts
            for (versions.items, 0..) |v, i| {
                if (v.write_ts <= min_active_read_ts) {
                    keep_from = i;
                }
            }
            // Versionen vor keep_from freigeben
            for (versions.items[0..keep_from]) |v| {
                self.allocator.free(v.value);
            }
            const remaining = versions.items.len - keep_from;
            std.mem.copyForwards(StoredVersion, versions.items[0..remaining], versions.items[keep_from..]);
            versions.items.len = remaining;
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "TxnManager begin increments" {
    var mgr = TxnManager.init();
    const t1 = mgr.begin();
    const t2 = mgr.begin();
    try std.testing.expectEqual(@as(TxnId, 1), t1);
    try std.testing.expectEqual(@as(TxnId, 2), t2);
    try std.testing.expectEqual(@as(TxnId, 3), mgr.current());
}

test "Transaction put and getDirty" {
    const alloc = std.testing.allocator;
    var txn = Transaction.init(alloc, 1, 0);
    defer txn.deinit();

    try txn.put("key1", "value1");
    try std.testing.expectEqualStrings("value1", txn.getDirty("key1").?);
    try std.testing.expect(txn.getDirty("nonexistent") == null);
}

test "Transaction overwrite" {
    const alloc = std.testing.allocator;
    var txn = Transaction.init(alloc, 1, 0);
    defer txn.deinit();

    try txn.put("k", "v1");
    try txn.put("k", "v2");
    try std.testing.expectEqualStrings("v2", txn.getDirty("k").?);
}

test "Transaction delete hides key" {
    const alloc = std.testing.allocator;
    var txn = Transaction.init(alloc, 1, 0);
    defer txn.deinit();

    try txn.put("k", "v");
    try txn.delete("k");
    try std.testing.expect(txn.getDirty("k") == null);
}

test "Transaction commit and abort states" {
    const alloc = std.testing.allocator;
    var txn = Transaction.init(alloc, 1, 0);
    defer txn.deinit();

    try std.testing.expect(txn.isActive());
    try txn.commit();
    try std.testing.expect(txn.isCommitted());
    try std.testing.expectError(error.TransactionNotActive, txn.put("k", "v"));
}

test "VersionStore: read at different timestamps" {
    const alloc = std.testing.allocator;
    var vs = VersionStore.init(alloc);
    defer vs.deinit();

    // Txn 1: schreibt bei ts=5
    var t1 = Transaction.init(alloc, 1, 0);
    defer t1.deinit();
    try t1.put("x", "v1");
    try t1.commit();
    try vs.applyCommit(&t1, 5);

    // Txn 2: schreibt bei ts=10
    var t2 = Transaction.init(alloc, 2, 5);
    defer t2.deinit();
    try t2.put("x", "v2");
    try t2.commit();
    try vs.applyCommit(&t2, 10);

    // Lesen bei ts=4: nichts sichtbar
    try std.testing.expect(vs.get("x", 4) == null);
    // Lesen bei ts=5: v1 sichtbar
    try std.testing.expectEqualStrings("v1", vs.get("x", 5).?);
    // Lesen bei ts=7: v1 sichtbar (v2 noch nicht)
    try std.testing.expectEqualStrings("v1", vs.get("x", 7).?);
    // Lesen bei ts=10: v2 sichtbar
    try std.testing.expectEqualStrings("v2", vs.get("x", 10).?);
}

test "VersionStore: delete hides key" {
    const alloc = std.testing.allocator;
    var vs = VersionStore.init(alloc);
    defer vs.deinit();

    var t1 = Transaction.init(alloc, 1, 0);
    defer t1.deinit();
    try t1.put("k", "v");
    try t1.commit();
    try vs.applyCommit(&t1, 1);

    var t2 = Transaction.init(alloc, 2, 1);
    defer t2.deinit();
    try t2.delete("k");
    try t2.commit();
    try vs.applyCommit(&t2, 2);

    try std.testing.expectEqualStrings("v", vs.get("k", 1).?);
    try std.testing.expect(vs.get("k", 2) == null);
}

test "VersionStore: gc removes old versions" {
    const alloc = std.testing.allocator;
    var vs = VersionStore.init(alloc);
    defer vs.deinit();

    var t1 = Transaction.init(alloc, 1, 0);
    defer t1.deinit();
    try t1.put("k", "old");
    try t1.commit();
    try vs.applyCommit(&t1, 1);

    var t2 = Transaction.init(alloc, 2, 1);
    defer t2.deinit();
    try t2.put("k", "new");
    try t2.commit();
    try vs.applyCommit(&t2, 2);

    // Vor GC: beide Versionen vorhanden
    const versions = vs.store.get("k").?;
    try std.testing.expectEqual(@as(usize, 2), versions.items.len);

    // GC mit min_active_read_ts=2: Version mit write_ts=1 kann weg
    vs.gc(2);
    const after = vs.store.get("k").?;
    try std.testing.expect(after.items.len <= 1);
}
