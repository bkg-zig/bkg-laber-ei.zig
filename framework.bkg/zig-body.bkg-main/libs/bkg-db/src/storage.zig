/// BKGDB — Storage Layer
///
/// Disk I/O für Pages: open, close, read page, write page, fsync.
/// Jede Page ist exakt PAGE_SIZE (4096) Bytes groß.
/// Page 0 ist reserviert für Metadaten (meta-page).
///
/// Datei-Layout: sequenzieller Array von Pages
///   Byte 0        .. PAGE_SIZE-1   → Page 0 (meta)
///   Byte PAGE_SIZE.. 2*PAGE_SIZE-1 → Page 1
///   ...
///   Byte N*PAGE_SIZE               → Page N
const std = @import("std");
const page_mod = @import("page.zig");

pub const PAGE_SIZE = page_mod.PAGE_SIZE;
pub const Page = page_mod.Page;
pub const PageType = page_mod.PageType;

// ── Fehler ────────────────────────────────────────────────────────────────

pub const StorageError = error{
    FileNotFound,
    ReadError,
    WriteError,
    InvalidPageId,
    ChecksumMismatch,
    FileTooSmall,
};

// ── PageFile ──────────────────────────────────────────────────────────────

/// Verwaltet die Page-Datei auf Disk.
/// Thread-safety: kein internes Locking — Aufrufer ist verantwortlich.
pub const PageFile = struct {
    file: std.Io.File,
    io: std.Io,
    page_count: u64,

    /// Öffnet oder erstellt eine Page-Datei.
    /// Wenn die Datei neu ist, wird Page 0 (meta) angelegt.
    pub fn open(io: std.Io, dir: std.Io.Dir, path: []const u8) !PageFile {
        const file = try dir.createFile(io, path, .{ .read = true, .truncate = false });
        errdefer file.close(io);

        const size = try file.length(io);
        const page_count: u64 = size / PAGE_SIZE;

        var pf = PageFile{
            .file = file,
            .io = io,
            .page_count = page_count,
        };

        if (page_count == 0) {
            // Neue Datei: Meta-Page 0 anlegen
            var meta = Page.init(0, .meta);
            meta.updateChecksum();
            try pf.writePage(0, &meta);
        }

        return pf;
    }

    pub fn close(self: *PageFile) void {
        self.file.close(self.io);
    }

    /// Liest Page `page_id` von Disk in `out`.
    /// Prüft den Checksum; gibt ChecksumMismatch wenn inkorrekt.
    pub fn readPage(self: *const PageFile, page_id: u64, out: *Page) !void {
        if (page_id >= self.page_count) return StorageError.InvalidPageId;
        const offset: u64 = page_id * PAGE_SIZE;
        const n = try self.file.readPositionalAll(self.io, &out.data, offset);
        if (n != PAGE_SIZE) return StorageError.ReadError;
        if (!out.verifyChecksum()) return StorageError.ChecksumMismatch;
    }

    /// Schreibt `p` als Page `page_id` auf Disk.
    /// page_id darf maximal page_count sein (append), sonst muss sie bereits existieren.
    pub fn writePage(self: *PageFile, page_id: u64, p: *const Page) !void {
        if (page_id > self.page_count) return StorageError.InvalidPageId;
        const offset: u64 = page_id * PAGE_SIZE;
        try self.file.writePositionalAll(self.io, &p.data, offset);
        if (page_id == self.page_count) {
            self.page_count += 1;
        }
    }

    /// Alloziert eine neue Page (append), gibt ihre ID zurück.
    pub fn allocPage(self: *PageFile, page_type: PageType) !u64 {
        const new_id = self.page_count;
        var p = Page.init(new_id, page_type);
        p.updateChecksum();
        try self.writePage(new_id, &p);
        return new_id;
    }

    /// Schreibt alle ausstehenden I/O-Puffer auf Disk durch.
    pub fn sync(self: *PageFile) !void {
        try self.file.sync(self.io);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "PageFile open, write, read" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pf = try PageFile.open(io, tmp.dir, "test.pages");
    defer pf.close();

    // Meta-Page wurde automatisch angelegt
    try std.testing.expectEqual(@as(u64, 1), pf.page_count);

    // Neue Page allozieren und schreiben
    const new_id = try pf.allocPage(.data);
    try std.testing.expectEqual(@as(u64, 1), new_id);
    try std.testing.expectEqual(@as(u64, 2), pf.page_count);

    // Record in Page schreiben
    var p = Page.init(new_id, .data);
    _ = try p.insertRecord("storage test");
    p.updateChecksum();
    try pf.writePage(new_id, &p);

    // Page zurücklesen
    var p2: Page = undefined;
    try pf.readPage(new_id, &p2);
    const rec = try p2.readRecord(0);
    try std.testing.expectEqualStrings("storage test", rec);
}

test "PageFile invalid page_id" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pf = try PageFile.open(io, tmp.dir, "inv.pages");
    defer pf.close();

    var out: Page = undefined;
    try std.testing.expectError(StorageError.InvalidPageId, pf.readPage(99, &out));
}

test "PageFile checksum mismatch detected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pf = try PageFile.open(io, tmp.dir, "corrupt.pages");
    defer pf.close();

    const new_id = try pf.allocPage(.data);

    // Page direkt ohne Checksum-Update schreiben (Checksum bleibt 0)
    var p = Page.init(new_id, .data);
    _ = try p.insertRecord("data");
    // checksum NICHT updaten → bleibt 0 → wird falsch sein
    // Wir schreiben sie trotzdem roh auf Disk
    try pf.file.writePositionalAll(io, &p.data, new_id * PAGE_SIZE);

    var out: Page = undefined;
    try std.testing.expectError(StorageError.ChecksumMismatch, pf.readPage(new_id, &out));
}
