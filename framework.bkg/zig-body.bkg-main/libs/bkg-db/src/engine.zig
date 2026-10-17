/// BKGDB — Kern-Engine
///
/// Koordiniert alle Subsysteme:
///   PageFile    — Disk I/O für Pages
///   WalWriter   — Write-Ahead-Log (Mutable State)
///   TxnManager  — MVCC-Transaktionszähler
///   VersionStore — In-Memory MVCC-Versionen (Phase 1)
///   Ledger      — Immutable Append-only Event Log
///
/// Lifecycle:
///   Engine.open(allocator, io, dir_path) → Engine
///   engine.begin() → *Transaction
///   txn.put(key, value) / txn.delete(key) / txn.get(key)
///   txn.commit() / txn.abort()
///   engine.ledger.append(event_type, payload)
///   engine.close()
///
/// Open spielt den WAL neu: nur committed Transaktionen, Hash/CRC fail-closed,
/// Crash-Tail am EOF wird abgeschnitten. Uncommitted Writes werden verworfen.
const std = @import("std");
const storage_mod = @import("storage.zig");
const wal_mod = @import("wal.zig");
const txn_mod = @import("txn.zig");
const ledger_mod = @import("ledger.zig");

pub const PageFile = storage_mod.PageFile;
pub const WalWriter = wal_mod.WalWriter;
pub const Transaction = txn_mod.Transaction;
pub const TxnManager = txn_mod.TxnManager;
pub const VersionStore = txn_mod.VersionStore;
pub const Ledger = ledger_mod.Ledger;
pub const LedgerEventType = ledger_mod.LedgerEventType;

// ── EngineError ────────────────────────────────────────────────────────────

pub const EngineError = error{
    AlreadyOpen,
    NotOpen,
    InvalidPath,
    TransactionNotActive,
    CorruptWal,
    OutOfMemory,
};

// ── Engine ────────────────────────────────────────────────────────────────

/// Hauptzugang zur BKGDB-Datenbank.
/// Kein Locking in Phase 1 — single-threaded.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []u8,              // owned copy

    // Subsysteme
    pages: PageFile,
    wal: WalWriter,
    txns: TxnManager,
    versions: VersionStore,
    ledger: Ledger,

    // ── Öffnen / Schließen ────────────────────────────────────────────────

    /// Öffnet (oder erstellt) eine BKGDB-Datenbank im angegebenen Verzeichnis.
    /// Erstellt das Verzeichnis falls es nicht existiert.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !Engine {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, dir_path);

        const dir_copy = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(dir_copy);

        // Pfade zusammenbauen
        const pages_path = try std.fs.path.join(allocator, &.{ dir_path, "state.pages" });
        defer allocator.free(pages_path);

        const wal_path = try std.fs.path.join(allocator, &.{ dir_path, "state.wal" });
        defer allocator.free(wal_path);

        const ledger_path = try std.fs.path.join(allocator, &.{ dir_path, "ledger.wal" });
        defer allocator.free(ledger_path);

        // PageFile öffnen
        var pages = try PageFile.open(io, cwd, pages_path);
        errdefer pages.close();

        var txns = TxnManager.init();
        var versions = VersionStore.init(allocator);
        errdefer versions.deinit();

        const durable_end = try recoverWalInto(allocator, io, cwd, &versions, &txns, wal_path);
        try truncateWalTo(io, cwd, wal_path, durable_end);

        var wal_writer = try WalWriter.open(io, cwd, wal_path);
        errdefer wal_writer.close();

        // Ledger öffnen
        var led = try Ledger.open(io, cwd, ledger_path);
        errdefer led.close();

        return Engine{
            .allocator = allocator,
            .io        = io,
            .dir_path  = dir_copy,
            .pages     = pages,
            .wal       = wal_writer,
            .txns      = txns,
            .versions  = versions,
            .ledger    = led,
        };
    }

    /// Schließt alle Dateien und gibt alle Ressourcen frei.
    pub fn close(self: *Engine) void {
        self.ledger.close();
        self.versions.deinit();
        self.pages.close();
        self.wal.close();
        self.allocator.free(self.dir_path);
    }

    // ── Transaktions-API ──────────────────────────────────────────────────

    /// Startet eine neue Transaktion.
    /// Die zurückgegebene Transaktion muss mit deinit() freigegeben werden.
    pub fn begin(self: *Engine) !*Transaction {
        const txn_id = self.txns.begin();
        // read_ts = aktueller Zähler - 1 (d.h. alles committed vor diesem begin)
        const read_ts = txn_id - 1;
        const txn = try self.allocator.create(Transaction);
        errdefer self.allocator.destroy(txn);
        txn.* = Transaction.init(self.allocator, txn_id, read_ts);
        return txn;
    }

    /// Committet eine Transaktion: wendet Write-Set auf VersionStore an und
    /// schreibt WAL-Entries.
    pub fn commit(self: *Engine, txn: *Transaction) !void {
        if (!txn.isActive()) return EngineError.TransactionNotActive;

        const write_ts = txn.id;

        // WAL: Write-Entries für jedes Dirty-Write (Key ist Teil des Records)
        var it = txn.writes.iterator();
        while (it.next()) |entry| {
            const intent = entry.value_ptr.*;
            try self.wal.appendWrite(
                txn.id,
                entry.key_ptr.*,
                if (intent.is_delete) &.{} else intent.value,
                intent.is_delete,
            );
        }

        // WAL: Commit-Entry, dann fsync — erst danach ist der Commit durable.
        try self.wal.appendCommit(txn.id);
        try self.wal.sync();

        // VersionStore: Write-Set anwenden
        try self.versions.applyCommit(txn, write_ts);

        txn.commit() catch {};
    }

    /// Bricht eine Transaktion ab (WAL Abort-Entry, Write-Set verwerfen).
    pub fn abort(self: *Engine, txn: *Transaction) !void {
        if (!txn.isActive()) return;
        try self.wal.appendAbort(txn.id);
        try self.wal.sync();
        txn.abort();
    }

    /// Liest einen Wert aus dem VersionStore (MVCC-Snapshot).
    pub fn get(self: *const Engine, txn: *const Transaction, key: []const u8) ?[]const u8 {
        // Erst im Write-Set der Transaktion suchen (dirty read)
        if (txn.getDirty(key)) |v| return v;
        // Dann im VersionStore mit read_ts
        return self.versions.get(key, txn.read_ts);
    }

    /// Schreibt einen Wert in die aktuelle Transaktion.
    pub fn put(self: *Engine, txn: *Transaction, key: []const u8, value: []const u8) !void {
        _ = self;
        try txn.put(key, value);
    }

    /// Markiert einen Key in der aktuellen Transaktion als gelöscht.
    pub fn delete(self: *Engine, txn: *Transaction, key: []const u8) !void {
        _ = self;
        try txn.delete(key);
    }

    /// Gibt eine Transaktion frei (deinit).
    /// Muss nach commit() oder abort() aufgerufen werden.
    pub fn freeTxn(self: *Engine, txn: *Transaction) void {
        txn.deinit();
        self.allocator.destroy(txn);
    }
};

const RecoveredWrite = struct {
    key: []u8,
    value: []u8,
    is_delete: bool,
};

fn freeRecoveredList(list: *std.ArrayList(RecoveredWrite), allocator: std.mem.Allocator) void {
    for (list.items) |w| {
        allocator.free(w.key);
        allocator.free(w.value);
    }
    list.deinit(allocator);
}

/// Spielt den Mutable-State-WAL. Gibt das Byte-Ende des letzten gültigen Records zurück.
/// Fehlende Datei → 0. Korruption in der Mitte → CorruptWal.
fn recoverWalInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    versions: *VersionStore,
    txns: *TxnManager,
    wal_path: []const u8,
) !u64 {
    var reader = wal_mod.WalReader.open(io, dir, wal_path) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer reader.close();

    var pending = std.AutoHashMap(u64, std.ArrayList(RecoveredWrite)).init(allocator);
    defer {
        var it = pending.iterator();
        while (it.next()) |entry| {
            freeRecoveredList(entry.value_ptr, allocator);
        }
        pending.deinit();
    }

    var max_txn: u64 = 0;
    while (true) {
        const result = try reader.readNext(allocator);
        switch (result) {
            .eof, .crash_tail => break,
            .corrupt => return EngineError.CorruptWal,
            .entry => |en| {
                if (en.txn_id > max_txn) max_txn = en.txn_id;
                switch (en.entry_type) {
                    .write => {
                        const gop = try pending.getOrPut(en.txn_id);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = .empty;
                        }
                        try gop.value_ptr.append(allocator, .{
                            .key = try allocator.dupe(u8, en.key()),
                            .value = try allocator.dupe(u8, en.data()),
                            .is_delete = en.isDelete(),
                        });
                    },
                    .commit => {
                        if (pending.getPtr(en.txn_id)) |list| {
                            for (list.items) |w| {
                                try versions.applyWrite(w.key, w.value, w.is_delete, en.txn_id, en.txn_id);
                            }
                            freeRecoveredList(list, allocator);
                            _ = pending.remove(en.txn_id);
                        }
                    },
                    .abort => {
                        if (pending.getPtr(en.txn_id)) |list| {
                            freeRecoveredList(list, allocator);
                            _ = pending.remove(en.txn_id);
                        }
                    },
                    .checkpoint => {},
                }
            },
        }
    }

    if (max_txn + 1 > txns.next_txn_id) {
        txns.next_txn_id = max_txn + 1;
    }
    return reader.durable_end;
}

fn truncateWalTo(io: std.Io, dir: std.Io.Dir, wal_path: []const u8, durable_end: u64) !void {
    const file = dir.openFile(io, wal_path, .{ .mode = .read_write }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer file.close(io);
    const size = try file.length(io);
    if (size != durable_end) {
        try file.setLength(io, durable_end);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "engine: open and close" {
    const dir = "test_engine_open";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var engine = try Engine.open(std.testing.allocator, std.testing.io, dir);
    engine.close();
}

test "engine: put, commit, get" {
    const dir = "test_engine_put";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var engine = try Engine.open(std.testing.allocator, std.testing.io, dir);
    defer engine.close();

    const txn = try engine.begin();
    try engine.put(txn, "user:1", "Alice");
    try engine.commit(txn);
    engine.freeTxn(txn);

    // Neues Lese-Txn
    const rtxn = try engine.begin();
    defer engine.freeTxn(rtxn);

    const val = engine.get(rtxn, "user:1");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("Alice", val.?);
}

test "engine: abort discards writes" {
    const dir = "test_engine_abort";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var engine = try Engine.open(std.testing.allocator, std.testing.io, dir);
    defer engine.close();

    const txn = try engine.begin();
    try engine.put(txn, "key", "value");
    try engine.abort(txn);
    engine.freeTxn(txn);

    const rtxn = try engine.begin();
    defer engine.freeTxn(rtxn);
    const val = engine.get(rtxn, "key");
    try std.testing.expect(val == null);
}

test "engine: snapshot isolation" {
    const dir = "test_engine_snapshot";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var engine = try Engine.open(std.testing.allocator, std.testing.io, dir);
    defer engine.close();

    // Transaktion 1 schreibt und committet
    const t1 = try engine.begin();
    try engine.put(t1, "x", "v1");
    try engine.commit(t1);
    engine.freeTxn(t1);

    // Transaktion 2 beginnt (sieht t1's commit)
    const t2 = try engine.begin();
    defer engine.freeTxn(t2);

    // Transaktion 3 schreibt nach t2-Start
    const t3 = try engine.begin();
    try engine.put(t3, "x", "v3");
    try engine.commit(t3);
    engine.freeTxn(t3);

    // t2 sieht noch v1 (Snapshot-Isolation)
    const val = engine.get(t2, "x");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("v1", val.?);
}

test "engine: ledger append and merkle root" {
    const dir = "test_engine_ledger";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var engine = try Engine.open(std.testing.allocator, std.testing.io, dir);
    defer engine.close();

    _ = try engine.ledger.append(.{ .event_type = .peer_joined, .payload = "peer-1" });
    _ = try engine.ledger.append(.{ .event_type = .guardian_flag, .payload = "event-2" });

    const root = engine.ledger.merkleRoot();
    // Root darf kein Genesis-Hash sein (es gibt Einträge)
    const genesis = @import("merkle.zig").GENESIS_HASH;
    try std.testing.expect(!std.mem.eql(u8, root, &genesis));
}

test "engine: reopen recovers committed state bit-exact" {
    const dir = "test_engine_reopen";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    {
        var engine = try Engine.open(std.testing.allocator, std.testing.io, dir);
        defer engine.close();

        const txn = try engine.begin();
        try engine.put(txn, "user:1", "Alice");
        try engine.put(txn, "user:2", "Bob");
        try engine.commit(txn);
        engine.freeTxn(txn);

        const txn2 = try engine.begin();
        try engine.put(txn2, "user:1", "Alicia");
        try engine.commit(txn2);
        engine.freeTxn(txn2);
    }

    var engine = try Engine.open(std.testing.allocator, std.testing.io, dir);
    defer engine.close();
    const rtxn = try engine.begin();
    defer engine.freeTxn(rtxn);
    try std.testing.expectEqualStrings("Alicia", engine.get(rtxn, "user:1").?);
    try std.testing.expectEqualStrings("Bob", engine.get(rtxn, "user:2").?);
}

test "engine: reopen discards uncommitted writes" {
    const dir = "test_engine_uncommitted";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    {
        var engine = try Engine.open(std.testing.allocator, std.testing.io, dir);
        defer engine.close();
        const txn = try engine.begin();
        try engine.put(txn, "k", "committed");
        try engine.commit(txn);
        engine.freeTxn(txn);

        const txn2 = try engine.begin();
        try engine.put(txn2, "k", "dirty");
        try engine.wal.appendWrite(txn2.id, "k", "dirty", false);
        engine.freeTxn(txn2);
    }

    var engine = try Engine.open(std.testing.allocator, std.testing.io, dir);
    defer engine.close();
    const rtxn = try engine.begin();
    defer engine.freeTxn(rtxn);
    try std.testing.expectEqualStrings("committed", engine.get(rtxn, "k").?);
}

test "engine: reopen rejects a tampered WAL" {
    const dir = "test_engine_tamper_wal";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    {
        var engine = try Engine.open(std.testing.allocator, std.testing.io, dir);
        defer engine.close();
        const txn = try engine.begin();
        try engine.put(txn, "k", "v");
        try engine.commit(txn);
        engine.freeTxn(txn);
    }

    const wal_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "state.wal" });
    defer std.testing.allocator.free(wal_path);
    const io = std.testing.io;
    const file = try std.Io.Dir.cwd().openFile(io, wal_path, .{ .mode = .read_write });
    defer file.close(io);
    var b: [1]u8 = undefined;
    _ = try file.readPositionalAll(io, &b, 10);
    b[0] ^= 0xFF;
    try file.writePositionalAll(io, &b, 10);
    try file.sync(io);

    try std.testing.expectError(EngineError.CorruptWal, Engine.open(std.testing.allocator, std.testing.io, dir));
}
