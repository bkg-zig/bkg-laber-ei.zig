/// BKGDB — B-Tree Index
///
/// Insert, Lookup und Range-Scan auf dem Page Store.
///
/// Node-Typen:
///   InternalNode  — [key₀, child₀, key₁, child₁, ..., childₙ]
///   LeafNode      — [key₀, RecordRef₀, key₁, RecordRef₁, ...]
///
/// Leaf-Nodes sind doppelt verkettet (prev_page / next_page) für Range-Scans.
///
/// Ein B-Tree verwaltet genau einen Index (Primary Key oder Named Index).
/// Der Schlüssel ist immer ein raw byte-slice (max. 512 Bytes).
/// Der Wert in Leaf-Nodes ist ein RecordRef {page_id: u64, slot: u16}.
///
/// Implementierungshinweise:
///   - Keys + RecordRefs werden direkt in Pages serialisiert (storage.zig).
///   - Splits propagieren nach oben; Root-Split erzeugt neue Root-Page.
///   - Alle Page-Allokationen laufen über PageFile.allocPage().
///   - Kein Locking — Aufrufer (engine.zig / txn.zig) ist verantwortlich.
const std = @import("std");
const storage_mod = @import("storage.zig");
const page_mod = @import("page.zig");

pub const PageFile = storage_mod.PageFile;
pub const Page = page_mod.Page;
pub const PageType = page_mod.PageType;

// ── Konstanten ────────────────────────────────────────────────────────────

/// Maximale Schlüssellänge in Bytes.
pub const MAX_KEY_LEN: usize = 512;

/// Maximale Anzahl an Einträgen pro Node bevor gesplittet wird.
/// (Passend für 4 KB Pages: Header + Slots + Records)
pub const MAX_ENTRIES: usize = 63;

/// NULL-Page-ID (kein Kind / kein Nachbar)
pub const NULL_PAGE: u64 = 0xFFFF_FFFF_FFFF_FFFF;

// ── RecordRef ─────────────────────────────────────────────────────────────

/// Zeigt auf den physischen Speicherort eines Records im Page Store.
pub const RecordRef = packed struct {
    page_id: u64,
    slot: u16,
};

// ── BTreeError ────────────────────────────────────────────────────────────

pub const BTreeError = error{
    KeyTooLong,
    KeyNotFound,
    DuplicateKey,
    NodeFull,
    CorruptedNode,
    StorageError,
    OutOfMemory,
};

// ── Entry: interner In-Memory-Repräsentation eines B-Tree-Eintrags ────────

/// Ein Eintrag innerhalb eines Nodes (im Speicher).
pub const Entry = struct {
    key: []const u8,   // geleihter Slice
    ref: RecordRef,    // Leaf: Ziel-Record; Internal: ignoriert (child stattdessen)
    child: u64 = NULL_PAGE, // Internal-Node: rechts vom key liegender child page_id
};

// ── NodeHeader — serialisiert in Page.data[0..NODE_HEADER_SIZE] ───────────

pub const NODE_HEADER_SIZE: usize = 32;

pub const NodeKind = enum(u8) {
    internal = 0x10,
    leaf     = 0x20,
};

/// In-Memory NodeHeader.
/// Wird in den ersten NODE_HEADER_SIZE Bytes einer Page gespeichert.
pub const NodeHeader = struct {
    kind: NodeKind,
    entry_count: u16,
    prev_page: u64,  // Leaf: linker Nachbar (NULL_PAGE wenn keiner)
    next_page: u64,  // Leaf: rechter Nachbar (NULL_PAGE wenn keiner)
    left_child: u64, // Internal: linkster child (vor key[0])

    pub fn serialize(self: NodeHeader, buf: []u8) void {
        std.debug.assert(buf.len >= NODE_HEADER_SIZE);
        buf[0] = @intFromEnum(self.kind);
        std.mem.writeInt(u16, buf[1..3],   self.entry_count, .little);
        std.mem.writeInt(u64, buf[3..11],  self.prev_page,   .little);
        std.mem.writeInt(u64, buf[11..19], self.next_page,   .little);
        std.mem.writeInt(u64, buf[19..27], self.left_child,  .little);
        // 5 Bytes padding
        @memset(buf[27..32], 0);
    }

    pub fn deserialize(buf: []const u8) BTreeError!NodeHeader {
        if (buf.len < NODE_HEADER_SIZE) return BTreeError.CorruptedNode;
        const kind_byte = buf[0];
        const kind: NodeKind = switch (kind_byte) {
            0x10 => .internal,
            0x20 => .leaf,
            else  => return BTreeError.CorruptedNode,
        };
        return .{
            .kind        = kind,
            .entry_count = std.mem.readInt(u16, buf[1..3],   .little),
            .prev_page   = std.mem.readInt(u64, buf[3..11],  .little),
            .next_page   = std.mem.readInt(u64, buf[11..19], .little),
            .left_child  = std.mem.readInt(u64, buf[19..27], .little),
        };
    }
};

// ── BTree ─────────────────────────────────────────────────────────────────

/// B-Tree Index über einem PageFile.
/// Ein BTree-Objekt verwaltet genau einen Index.
/// root_page_id ist die Page-ID der aktuellen Root.
pub const BTree = struct {
    pf: *PageFile,
    root_page_id: u64,
    allocator: std.mem.Allocator,

    /// Initialisiert einen neuen B-Tree mit einer leeren Root-Leaf-Page.
    pub fn init(pf: *PageFile, allocator: std.mem.Allocator) !BTree {
        const root_id = try pf.allocPage(.leaf);
        var root_page: Page = undefined;
        try pf.readPage(root_id, &root_page);
        var hdr = NodeHeader{
            .kind        = .leaf,
            .entry_count = 0,
            .prev_page   = NULL_PAGE,
            .next_page   = NULL_PAGE,
            .left_child  = NULL_PAGE,
        };
        var hdr_buf: [NODE_HEADER_SIZE]u8 = undefined;
        hdr.serialize(&hdr_buf);
        _ = try insertRawIntoPage(&root_page, &hdr_buf);
        root_page.updateChecksum();
        try pf.writePage(root_id, &root_page);
        return .{
            .pf           = pf,
            .root_page_id = root_id,
            .allocator    = allocator,
        };
    }

    /// Öffnet einen bestehenden B-Tree an root_page_id.
    pub fn open(pf: *PageFile, root_page_id: u64, allocator: std.mem.Allocator) BTree {
        return .{
            .pf           = pf,
            .root_page_id = root_page_id,
            .allocator    = allocator,
        };
    }

    // ── Öffentliche API ───────────────────────────────────────────────────

    /// Sucht key und gibt RecordRef zurück, oder null wenn nicht gefunden.
    pub fn lookup(self: *BTree, key: []const u8) !?RecordRef {
        if (key.len > MAX_KEY_LEN) return BTreeError.KeyTooLong;
        return try self.lookupInPage(self.root_page_id, key);
    }

    /// Fügt key → ref ein.  Fehlt bei Duplikat.
    pub fn insert(self: *BTree, key: []const u8, ref: RecordRef) !void {
        if (key.len > MAX_KEY_LEN) return BTreeError.KeyTooLong;
        const split = try self.insertInPage(self.root_page_id, key, ref);
        if (split) |s| {
            // Root wurde gesplittet — neue Root anlegen
            try self.growRoot(s);
        }
    }

    /// Liefert alle RecordRefs deren Key im Bereich [from, to) liegt.
    /// Aufrufer ist verantwortlich, result-slice zu freigeben (allocator).
    pub fn rangeScan(
        self: *BTree,
        from: []const u8,
        to: []const u8,
        allocator: std.mem.Allocator,
    ) ![]RecordRef {
        var list: std.ArrayList(RecordRef) = .empty;
        errdefer list.deinit(allocator);

        // Linkes Blatt finden
        var leaf_id = try self.findLeafPage(self.root_page_id, from);

        scan: while (leaf_id != NULL_PAGE) {
            var pg: Page = undefined;
            try self.pf.readPage(leaf_id, &pg);
            const hdr = try NodeHeader.deserialize(rawData(&pg));

            var it = LeafIter.init(&pg, hdr.entry_count);
            while (it.next()) |e| {
                const cmp_from = std.mem.order(u8, e.key, from);
                const cmp_to   = std.mem.order(u8, e.key, to);
                if (cmp_from == .lt) continue;
                if (cmp_to   != .lt) break :scan;
                try list.append(allocator, e.ref);
            }

            leaf_id = hdr.next_page;
        }

        return list.toOwnedSlice(allocator);
    }

    // ── Interne Hilfsfunktionen ───────────────────────────────────────────

    /// Rekursive Lookup-Implementierung.
    fn lookupInPage(self: *BTree, page_id: u64, key: []const u8) !?RecordRef {
        var pg: Page = undefined;
        try self.pf.readPage(page_id, &pg);
        const data = rawData(&pg);
        const hdr = try NodeHeader.deserialize(data);

        switch (hdr.kind) {
            .leaf => {
                var it = LeafIter.init(&pg, hdr.entry_count);
                while (it.next()) |e| {
                    if (std.mem.eql(u8, e.key, key)) return e.ref;
                }
                return null;
            },
            .internal => {
                const child = findChildPage(&pg, hdr, key);
                return self.lookupInPage(child, key);
            },
        }
    }

    /// Findet die Leaf-Page für einen key (nicht notwendigerweise vorhanden).
    fn findLeafPage(self: *BTree, page_id: u64, key: []const u8) !u64 {
        var pg: Page = undefined;
        try self.pf.readPage(page_id, &pg);
        const hdr = try NodeHeader.deserialize(rawData(&pg));
        switch (hdr.kind) {
            .leaf     => return page_id,
            .internal => {
                const child = findChildPage(&pg, hdr, key);
                return self.findLeafPage(child, key);
            },
        }
    }

    /// SplitResult: Median-Key + page_id der neuen rechten Seite.
    const SplitResult = struct {
        median_key: []u8,  // heap-allokiert
        right_page_id: u64,
    };

    /// Rekursiver Insert.  Gibt SplitResult zurück wenn der Node gesplittet wurde.
    fn insertInPage(
        self: *BTree,
        page_id: u64,
        key: []const u8,
        ref: RecordRef,
    ) !?SplitResult {
        var pg: Page = undefined;
        try self.pf.readPage(page_id, &pg);
        const hdr = try NodeHeader.deserialize(rawData(&pg));

        switch (hdr.kind) {
            .leaf => {
                return try self.insertLeaf(page_id, &pg, hdr, key, ref);
            },
            .internal => {
                const child_id = findChildPage(&pg, hdr, key);
                const child_split = try self.insertInPage(child_id, key, ref);
                if (child_split) |s| {
                    defer self.allocator.free(s.median_key);
                    return try self.insertInternal(
                        page_id, &pg, hdr, s.median_key, s.right_page_id, child_id,
                    );
                }
                return null;
            },
        }
    }

    /// Einfügen in Leaf-Node.
    fn insertLeaf(
        self: *BTree,
        page_id: u64,
        pg: *Page,
        hdr: NodeHeader,
        key: []const u8,
        ref: RecordRef,
    ) !?SplitResult {
        // Duplikat-Check
        var it = LeafIter.init(pg, hdr.entry_count);
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key, key)) return BTreeError.DuplicateKey;
        }

        if (hdr.entry_count < MAX_ENTRIES) {
            // Platz vorhanden — direkt einfügen
            var new_hdr = hdr;
            new_hdr.entry_count += 1;
            insertLeafEntry(pg, new_hdr, key, ref);
            try self.pf.writePage(page_id, pg);
            return null;
        }

        // Node voll → Split
        return try self.splitLeaf(page_id, pg, hdr, key, ref);
    }

    /// Leaf-Node splitten.
    fn splitLeaf(
        self: *BTree,
        left_id: u64,
        left_pg: *Page,
        left_hdr: NodeHeader,
        new_key: []const u8,
        new_ref: RecordRef,
    ) !SplitResult {
        // Alle Einträge + neuen Eintrag in temp-Array sammeln
        const total = left_hdr.entry_count + 1;
        var keys  = try self.allocator.alloc([]const u8, total);
        var refs  = try self.allocator.alloc(RecordRef,  total);
        defer self.allocator.free(keys);
        defer self.allocator.free(refs);

        var tmp_count: usize = 0;
        var it = LeafIter.init(left_pg, left_hdr.entry_count);
        while (it.next()) |e| {
            keys[tmp_count] = e.key;
            refs[tmp_count] = e.ref;
            tmp_count += 1;
        }
        // Neuen Eintrag an richtiger Position einfügen
        var insert_pos: usize = tmp_count;
        for (keys[0..tmp_count], 0..) |k, i| {
            if (std.mem.lessThan(u8, new_key, k)) { insert_pos = i; break; }
        }
        var i: usize = tmp_count;
        while (i > insert_pos) : (i -= 1) {
            keys[i] = keys[i - 1];
            refs[i] = refs[i - 1];
        }
        keys[insert_pos] = new_key;
        refs[insert_pos] = new_ref;

        const mid = total / 2;

        // Rechte Page anlegen
        const right_id = try self.pf.allocPage(.leaf);
        var right_pg: Page = undefined;
        try self.pf.readPage(right_id, &right_pg);

        // Linken Node neu schreiben (erste mid Einträge)
        var new_left_hdr = left_hdr;
        new_left_hdr.entry_count = @intCast(mid);
        new_left_hdr.next_page   = right_id;
        rebuildLeafPage(left_pg, new_left_hdr, keys[0..mid], refs[0..mid]);
        try self.pf.writePage(left_id, left_pg);

        // Rechten Node schreiben (mid..total)
        const right_hdr = NodeHeader{
            .kind        = .leaf,
            .entry_count = @intCast(total - mid),
            .prev_page   = left_id,
            .next_page   = left_hdr.next_page,
            .left_child  = NULL_PAGE,
        };
        rebuildLeafPage(&right_pg, right_hdr, keys[mid..total], refs[mid..total]);
        try self.pf.writePage(right_id, &right_pg);

        // Median-Key: erster Key des rechten Nodes (für Parent)
        const median = try self.allocator.dupe(u8, keys[mid]);
        return .{ .median_key = median, .right_page_id = right_id };
    }

    /// Einfügen in Internal-Node nach einem Child-Split.
    fn insertInternal(
        self: *BTree,
        page_id: u64,
        pg: *Page,
        hdr: NodeHeader,
        median_key: []const u8,
        right_child: u64,
        _: u64, // left_child (bereits bekannt via parent)
    ) !?SplitResult {
        if (hdr.entry_count < MAX_ENTRIES) {
            var new_hdr = hdr;
            new_hdr.entry_count += 1;
            insertInternalEntry(pg, new_hdr, median_key, right_child);
            try self.pf.writePage(page_id, pg);
            return null;
        }
        return try self.splitInternal(page_id, pg, hdr, median_key, right_child);
    }

    /// Internal-Node splitten.
    fn splitInternal(
        self: *BTree,
        left_id: u64,
        left_pg: *Page,
        left_hdr: NodeHeader,
        new_key: []const u8,
        new_right: u64,
    ) !SplitResult {
        const total = left_hdr.entry_count + 1;
        var keys     = try self.allocator.alloc([]const u8, total);
        var children = try self.allocator.alloc(u64,         total + 1);
        defer self.allocator.free(keys);
        defer self.allocator.free(children);

        // Alle Einträge lesen
        var tmp_count: usize = 0;
        children[0] = left_hdr.left_child;
        var it = InternalIter.init(left_pg, left_hdr.entry_count);
        while (it.next()) |e| {
            keys[tmp_count]         = e.key;
            children[tmp_count + 1] = e.child;
            tmp_count += 1;
        }

        // Neuen Key einfügen
        var insert_pos: usize = tmp_count;
        for (keys[0..tmp_count], 0..) |k, j| {
            if (std.mem.lessThan(u8, new_key, k)) { insert_pos = j; break; }
        }
        var i: usize = tmp_count;
        while (i > insert_pos) : (i -= 1) {
            keys[i] = keys[i - 1];
            children[i + 1] = children[i];
        }
        keys[insert_pos]         = new_key;
        children[insert_pos + 1] = new_right;

        const mid = total / 2;

        // Rechte Page
        const right_id = try self.pf.allocPage(.index);
        var right_pg: Page = undefined;
        try self.pf.readPage(right_id, &right_pg);

        // Linken Node (keys[0..mid-1], children[0..mid])
        var new_left_hdr = left_hdr;
        new_left_hdr.entry_count = @intCast(mid);
        new_left_hdr.left_child  = children[0];
        rebuildInternalPage(left_pg, new_left_hdr, keys[0..mid], children[1 .. mid + 1]);
        try self.pf.writePage(left_id, left_pg);

        // Rechten Node (keys[mid+1..total], children[mid+1..total+1])
        const right_hdr = NodeHeader{
            .kind        = .internal,
            .entry_count = @intCast(total - mid - 1),
            .prev_page   = NULL_PAGE,
            .next_page   = NULL_PAGE,
            .left_child  = children[mid + 1],
        };
        rebuildInternalPage(
            &right_pg,
            right_hdr,
            keys[mid + 1 .. total],
            children[mid + 2 .. total + 1],
        );
        try self.pf.writePage(right_id, &right_pg);

        const median = try self.allocator.dupe(u8, keys[mid]);
        return .{ .median_key = median, .right_page_id = right_id };
    }

    /// Neue Root nach Root-Split anlegen.
    fn growRoot(self: *BTree, split: SplitResult) !void {
        defer self.allocator.free(split.median_key);
        const new_root_id = try self.pf.allocPage(.index);
        var root_pg: Page = undefined;
        try self.pf.readPage(new_root_id, &root_pg);
        const hdr = NodeHeader{
            .kind        = .internal,
            .entry_count = 1,
            .prev_page   = NULL_PAGE,
            .next_page   = NULL_PAGE,
            .left_child  = self.root_page_id,
        };
        var keys     = [_][]const u8{ split.median_key };
        var children = [_]u64{ split.right_page_id };
        rebuildInternalPage(&root_pg, hdr, &keys, &children);
        try self.pf.writePage(new_root_id, &root_pg);
        self.root_page_id = new_root_id;
    }
};

// ── Page-Format-Hilfsfunktionen ───────────────────────────────────────────
//
// Ein B-Tree-Node liegt komplett in der raw data eines Records auf einer Page.
// Wir serialisieren Node-Header + Einträge als einen einzigen Record in Slot 0.
//
// Format eines Leaf-Records (nach NODE_HEADER_SIZE):
//   Für jeden Eintrag:
//     key_len: u16
//     key:     [key_len]u8
//     ref:     RecordRef (10 Bytes: u64 + u16)
//
// Format eines Internal-Records (nach NODE_HEADER_SIZE):
//   Für jeden Eintrag:
//     key_len: u16
//     key:     [key_len]u8
//     child:   u64

const RECORD_REF_SIZE: usize = @sizeOf(RecordRef); // 10

/// Gibt den raw Payload-Slice von Slot 0 zurück (Node-Header + Einträge).
/// Gibt leeren Slice zurück wenn keine Slots vorhanden.
fn rawData(pg: *Page) []u8 {
    if (pg.header().slot_count == 0) return pg.data[0..0];
    const s = pg.slot(0);
    if (s.len == 0) return pg.data[0..0];
    return pg.data[s.offset..][0..s.len];
}

/// Legt einen neuen Raw-Record in Slot 0 einer frischen Page an.
fn insertRawIntoPage(pg: *Page, data: []const u8) !u16 {
    return pg.insertRecord(data);
}

/// Schreibt alle Leaf-Einträge neu in pg (leert vorher den Record und schreibt neu).
fn rebuildLeafPage(pg: *Page, hdr: NodeHeader, keys: []const []const u8, refs: []const RecordRef) void {
    // Berechne Gesamtgröße
    var size: usize = NODE_HEADER_SIZE;
    for (keys) |k| size += 2 + k.len + RECORD_REF_SIZE;

    var buf = std.heap.page_allocator.alloc(u8, size) catch return;
    defer std.heap.page_allocator.free(buf);

    var hdr_buf: [NODE_HEADER_SIZE]u8 = undefined;
    hdr.serialize(&hdr_buf);
    @memcpy(buf[0..NODE_HEADER_SIZE], &hdr_buf);

    var off: usize = NODE_HEADER_SIZE;
    for (keys, refs) |k, r| {
        std.mem.writeInt(u16, buf[off..][0..2], @intCast(k.len), .little);
        off += 2;
        @memcpy(buf[off..][0..k.len], k);
        off += k.len;
        std.mem.writeInt(u64, buf[off..][0..8], r.page_id, .little);
        off += 8;
        std.mem.writeInt(u16, buf[off..][0..2], r.slot, .little);
        off += 2;
    }

    pg.* = Page.init(pg.header().page_id, .index);
    _ = pg.insertRecord(buf) catch {};
    pg.updateChecksum();
}

/// Schreibt alle Internal-Einträge neu in pg.
fn rebuildInternalPage(pg: *Page, hdr: NodeHeader, keys: []const []const u8, children: []const u64) void {
    var size: usize = NODE_HEADER_SIZE;
    for (keys) |k| size += 2 + k.len + 8;

    var buf = std.heap.page_allocator.alloc(u8, size) catch return;
    defer std.heap.page_allocator.free(buf);

    var hdr_buf: [NODE_HEADER_SIZE]u8 = undefined;
    hdr.serialize(&hdr_buf);
    @memcpy(buf[0..NODE_HEADER_SIZE], &hdr_buf);

    var off: usize = NODE_HEADER_SIZE;
    for (keys, children) |k, c| {
        std.mem.writeInt(u16, buf[off..][0..2], @intCast(k.len), .little);
        off += 2;
        @memcpy(buf[off..][0..k.len], k);
        off += k.len;
        std.mem.writeInt(u64, buf[off..][0..8], c, .little);
        off += 8;
    }

    pg.* = Page.init(pg.header().page_id, .index);
    _ = pg.insertRecord(buf) catch {};
    pg.updateChecksum();
}

/// Leaf: neuen Eintrag sortiert in Page einfügen (page wird komplett neu gebaut).
fn insertLeafEntry(pg: *Page, hdr: NodeHeader, key: []const u8, ref: RecordRef) void {
    const old_data = rawData(pg);
    const old_hdr = NodeHeader.deserialize(old_data) catch return;
    const old_count = old_hdr.entry_count;

    // Alte Einträge lesen
    var keys = std.heap.page_allocator.alloc([]const u8, old_count + 1) catch return;
    var refs = std.heap.page_allocator.alloc(RecordRef,  old_count + 1) catch return;
    defer std.heap.page_allocator.free(keys);
    defer std.heap.page_allocator.free(refs);

    var tmp: usize = 0;
    var it = LeafIter.initFromData(old_data[NODE_HEADER_SIZE..], old_count);
    while (it.next()) |e| {
        keys[tmp] = e.key;
        refs[tmp] = e.ref;
        tmp += 1;
    }

    // Position für neuen Key
    var pos: usize = tmp;
    for (keys[0..tmp], 0..) |k, i| {
        if (std.mem.lessThan(u8, key, k)) { pos = i; break; }
    }
    var i: usize = tmp;
    while (i > pos) : (i -= 1) {
        keys[i] = keys[i - 1];
        refs[i] = refs[i - 1];
    }
    keys[pos] = key;
    refs[pos]  = ref;

    rebuildLeafPage(pg, hdr, keys[0 .. old_count + 1], refs[0 .. old_count + 1]);
}

/// Internal: neuen Key + child einfügen.
fn insertInternalEntry(pg: *Page, hdr: NodeHeader, key: []const u8, child: u64) void {
    const old_data = rawData(pg);
    const old_hdr = NodeHeader.deserialize(old_data) catch return;
    const old_count = old_hdr.entry_count;

    var keys     = std.heap.page_allocator.alloc([]const u8, old_count + 1) catch return;
    var children = std.heap.page_allocator.alloc(u64,         old_count + 1) catch return;
    defer std.heap.page_allocator.free(keys);
    defer std.heap.page_allocator.free(children);

    var tmp: usize = 0;
    var it = InternalIter.initFromData(old_data[NODE_HEADER_SIZE..], old_count);
    while (it.next()) |e| {
        keys[tmp]     = e.key;
        children[tmp] = e.child;
        tmp += 1;
    }

    var pos: usize = tmp;
    for (keys[0..tmp], 0..) |k, i| {
        if (std.mem.lessThan(u8, key, k)) { pos = i; break; }
    }
    var i: usize = tmp;
    while (i > pos) : (i -= 1) {
        keys[i]     = keys[i - 1];
        children[i] = children[i - 1];
    }
    keys[pos]     = key;
    children[pos] = child;

    rebuildInternalPage(pg, hdr, keys[0 .. old_count + 1], children[0 .. old_count + 1]);
}

/// Internal: welcher child enthält key?
fn findChildPage(pg: *Page, hdr: NodeHeader, key: []const u8) u64 {
    const data = rawData(pg);
    var last_child: u64 = hdr.left_child;
    var it = InternalIter.initFromData(data[NODE_HEADER_SIZE..], hdr.entry_count);
    while (it.next()) |e| {
        if (std.mem.lessThan(u8, key, e.key)) return last_child;
        last_child = e.child;
    }
    return last_child;
}

// ── Iteratoren (In-Memory über serialisierte Page-Daten) ──────────────────

const LeafEntry = struct { key: []const u8, ref: RecordRef };
const InternalEntry = struct { key: []const u8, child: u64 };

const LeafIter = struct {
    data: []const u8,
    off: usize,
    remaining: u16,

    fn init(pg: *Page, count: u16) LeafIter {
        const d = rawData(pg);
        return .{ .data = d[NODE_HEADER_SIZE..], .off = 0, .remaining = count };
    }

    fn initFromData(data: []const u8, count: u16) LeafIter {
        return .{ .data = data, .off = 0, .remaining = count };
    }

    fn next(self: *LeafIter) ?LeafEntry {
        if (self.remaining == 0) return null;
        if (self.off + 2 > self.data.len) return null;
        const key_len = std.mem.readInt(u16, self.data[self.off..][0..2], .little);
        self.off += 2;
        if (self.off + key_len + RECORD_REF_SIZE > self.data.len) return null;
        const key = self.data[self.off .. self.off + key_len];
        self.off += key_len;
        const page_id = std.mem.readInt(u64, self.data[self.off..][0..8], .little);
        self.off += 8;
        const slot = std.mem.readInt(u16, self.data[self.off..][0..2], .little);
        self.off += 2;
        self.remaining -= 1;
        return .{ .key = key, .ref = .{ .page_id = page_id, .slot = slot } };
    }
};

const InternalIter = struct {
    data: []const u8,
    off: usize,
    remaining: u16,

    fn init(pg: *Page, count: u16) InternalIter {
        const d = rawData(pg);
        return .{ .data = d[NODE_HEADER_SIZE..], .off = 0, .remaining = count };
    }

    fn initFromData(data: []const u8, count: u16) InternalIter {
        return .{ .data = data, .off = 0, .remaining = count };
    }

    fn next(self: *InternalIter) ?InternalEntry {
        if (self.remaining == 0) return null;
        if (self.off + 2 > self.data.len) return null;
        const key_len = std.mem.readInt(u16, self.data[self.off..][0..2], .little);
        self.off += 2;
        if (self.off + key_len + 8 > self.data.len) return null;
        const key = self.data[self.off .. self.off + key_len];
        self.off += key_len;
        const child = std.mem.readInt(u64, self.data[self.off..][0..8], .little);
        self.off += 8;
        self.remaining -= 1;
        return .{ .key = key, .child = child };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "btree: NodeHeader serialize/deserialize roundtrip" {
    const hdr = NodeHeader{
        .kind        = .leaf,
        .entry_count = 42,
        .prev_page   = NULL_PAGE,
        .next_page   = 7,
        .left_child  = NULL_PAGE,
    };
    var buf: [NODE_HEADER_SIZE]u8 = undefined;
    hdr.serialize(&buf);
    const got = try NodeHeader.deserialize(&buf);
    try std.testing.expectEqual(hdr.kind,        got.kind);
    try std.testing.expectEqual(hdr.entry_count, got.entry_count);
    try std.testing.expectEqual(hdr.prev_page,   got.prev_page);
    try std.testing.expectEqual(hdr.next_page,   got.next_page);
}

test "btree: insert and lookup single key" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pf = try storage_mod.PageFile.open(io, tmp.dir, "test_btree_single.pages");
    defer pf.close();

    var bt = try BTree.init(&pf, std.testing.allocator);
    const ref = RecordRef{ .page_id = 5, .slot = 3 };
    try bt.insert("hello", ref);

    const found = try bt.lookup("hello");
    try std.testing.expect(found != null);
    try std.testing.expectEqual(ref.page_id, found.?.page_id);
    try std.testing.expectEqual(ref.slot,    found.?.slot);

    const miss = try bt.lookup("world");
    try std.testing.expect(miss == null);
}

test "btree: duplicate key returns error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pf = try storage_mod.PageFile.open(io, tmp.dir, "test_btree_dup.pages");
    defer pf.close();

    var bt = try BTree.init(&pf, std.testing.allocator);
    try bt.insert("key", .{ .page_id = 1, .slot = 0 });
    try std.testing.expectError(BTreeError.DuplicateKey, bt.insert("key", .{ .page_id = 2, .slot = 0 }));
}

test "btree: multiple inserts and lookups" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pf = try storage_mod.PageFile.open(io, tmp.dir, "test_btree_multi.pages");
    defer pf.close();

    var bt = try BTree.init(&pf, std.testing.allocator);

    const keys = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    for (keys, 0..) |k, i| {
        try bt.insert(k, .{ .page_id = @intCast(i + 10), .slot = @intCast(i) });
    }

    for (keys, 0..) |k, i| {
        const r = try bt.lookup(k);
        try std.testing.expect(r != null);
        try std.testing.expectEqual(@as(u64, @intCast(i + 10)), r.?.page_id);
    }
}

test "btree: range scan" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pf = try storage_mod.PageFile.open(io, tmp.dir, "test_btree_range.pages");
    defer pf.close();

    var bt = try BTree.init(&pf, std.testing.allocator);

    // Einfügen: a, b, c, d, e
    const keys = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (keys, 0..) |k, i| {
        try bt.insert(k, .{ .page_id = @intCast(i), .slot = 0 });
    }

    // Range [b, d) → b, c
    const result = try bt.rangeScan("b", "d", std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u64, 1), result[0].page_id); // "b"
    try std.testing.expectEqual(@as(u64, 2), result[1].page_id); // "c"
}
