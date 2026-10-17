/// BKGDB — Page Layer
///
/// Jede Page ist exakt 4096 Bytes groß.
///
/// Layout:
///   [0..32)   PageHeader
///   [32..)    Slot-Array wächst von oben nach unten
///             Record-Daten wachsen von unten nach oben
///
/// Slot-Array: array of Slot { offset: u16, len: u16 }
/// Record-Daten: variable-length, von unten beginnend
///
/// free_start zeigt auf das erste freie Byte nach dem letzten Slot
/// free_end   zeigt auf das letzte freie Byte vor dem letzten Record
const std = @import("std");

// ── Konstanten ────────────────────────────────────────────────────────────

pub const PAGE_SIZE: usize = 4096;
pub const HEADER_SIZE: usize = 32;
pub const SLOT_SIZE: usize = 4; // 2 Bytes offset + 2 Bytes len

pub const PageType = enum(u8) {
    data = 0x01,
    index = 0x02,
    overflow = 0x03,
    leaf = 0x04,
    internal = 0x05,
    meta = 0x06,
};

// ── PageHeader ────────────────────────────────────────────────────────────

/// 32-Byte Header am Anfang jeder Page.
pub const PageHeader = extern struct {
    page_id: u64,       // 8 bytes — eindeutige Page-ID
    page_type: u8,      // 1 byte  — PageType
    free_start: u16,    // 2 bytes — Offset: Ende des Slot-Arrays
    free_end: u16,      // 2 bytes — Offset: Beginn der Record-Daten (von unten)
    slot_count: u16,    // 2 bytes — Anzahl der Slots
    flags: u8,          // 1 byte  — reserviert
    checksum: u32,      // 4 bytes — CRC32 des Page-Inhalts (exkl. Checksum-Feld selbst)
    _padding: [6]u8,    // 6 bytes — auf 32 Bytes auffüllen

    comptime {
        if (@sizeOf(PageHeader) != HEADER_SIZE) {
            @compileError("PageHeader must be exactly 32 bytes");
        }
    }
};

/// Slot: beschreibt die Position eines Records auf der Page.
pub const Slot = extern struct {
    offset: u16, // Byte-Offset des Records innerhalb der Page
    len: u16,    // Länge des Records in Bytes

    comptime {
        if (@sizeOf(Slot) != SLOT_SIZE) {
            @compileError("Slot must be exactly 4 bytes");
        }
    }
};

// ── Page ──────────────────────────────────────────────────────────────────

/// In-Memory-Darstellung einer Page.
/// Die raw-Bytes sind PAGE_SIZE groß und werden direkt von/auf Disk gelesen.
pub const Page = struct {
    data: [PAGE_SIZE]u8 align(@alignOf(PageHeader)),

    /// Initialisiert eine leere Page mit gegebener ID und Typ.
    pub fn init(page_id: u64, page_type: PageType) Page {
        var p = Page{ .data = [_]u8{0} ** PAGE_SIZE };
        const h = p.headerMut();
        h.page_id = page_id;
        h.page_type = @intFromEnum(page_type);
        h.free_start = HEADER_SIZE;
        h.free_end = PAGE_SIZE;
        h.slot_count = 0;
        h.flags = 0;
        h.checksum = 0;
        return p;
    }

    /// Gibt einen Zeiger auf den Header zurück (read-only).
    pub fn header(self: *const Page) *const PageHeader {
        return @ptrCast(@alignCast(&self.data[0]));
    }

    /// Gibt einen mutierbaren Zeiger auf den Header zurück.
    pub fn headerMut(self: *Page) *PageHeader {
        return @ptrCast(@alignCast(&self.data[0]));
    }

    /// Gibt den Slot an Index i zurück (read-only).
    pub fn slot(self: *const Page, i: u16) *const Slot {
        const offset = HEADER_SIZE + i * SLOT_SIZE;
        return @ptrCast(@alignCast(&self.data[offset]));
    }

    /// Gibt den mutierbaren Slot an Index i zurück.
    pub fn slotMut(self: *Page, i: u16) *Slot {
        const offset = HEADER_SIZE + i * SLOT_SIZE;
        return @ptrCast(@alignCast(&self.data[offset]));
    }

    /// Freier Platz auf der Page in Bytes.
    pub fn freeSpace(self: *const Page) usize {
        const h = self.header();
        if (h.free_end <= h.free_start) return 0;
        const raw = @as(usize, h.free_end) - @as(usize, h.free_start);
        // Mindestens ein neuer Slot (SLOT_SIZE) muss noch Platz haben
        if (raw <= SLOT_SIZE) return 0;
        return raw - SLOT_SIZE;
    }

    /// Schreibt einen Record auf die Page.
    /// Gibt den Slot-Index zurück oder einen Fehler wenn kein Platz.
    pub fn insertRecord(self: *Page, record: []const u8) error{PageFull}!u16 {
        if (record.len > std.math.maxInt(u16)) return error.PageFull;
        const len: u16 = @intCast(record.len);
        const h = self.headerMut();

        // Platz prüfen: Slot-Array wächst nach unten, Records von unten nach oben
        const needed = SLOT_SIZE + len;
        const available = if (h.free_end > h.free_start)
            @as(usize, h.free_end) - @as(usize, h.free_start)
        else
            0;
        if (available < needed) return error.PageFull;

        // Record von unten einschreiben
        const record_offset: u16 = h.free_end - len;
        @memcpy(self.data[record_offset..][0..len], record);

        // Slot anlegen
        const slot_idx = h.slot_count;
        const s = self.slotMut(slot_idx);
        s.offset = record_offset;
        s.len = len;

        h.free_end = record_offset;
        h.free_start += SLOT_SIZE;
        h.slot_count += 1;

        return slot_idx;
    }

    /// Gibt den Record-Inhalt für Slot i zurück (Slice in page.data).
    pub fn readRecord(self: *const Page, slot_idx: u16) error{InvalidSlot}![]const u8 {
        if (slot_idx >= self.header().slot_count) return error.InvalidSlot;
        const s = self.slot(slot_idx);
        if (s.len == 0) return error.InvalidSlot;
        return self.data[s.offset..][0..s.len];
    }

    /// Berechnet CRC32 über alle Bytes der Page (Checksum-Feld auf 0 gesetzt).
    pub fn computeChecksum(self: *const Page) u32 {
        // Checksum-Feld liegt bei Offset 20 im Header (nach page_id=8, page_type=1, free_start=2, free_end=2, slot_count=2, flags=1)
        // Wir berechnen über die gesamte Page, Checksum-Bytes temporär auf 0
        var scratch: [PAGE_SIZE]u8 = self.data;
        // Checksum liegt bei Byte 20..24 im Header
        @memset(scratch[20..24], 0);
        return std.hash.Crc32.hash(&scratch);
    }

    /// Schreibt den Checksum in den Header.
    pub fn updateChecksum(self: *Page) void {
        self.headerMut().checksum = self.computeChecksum();
    }

    /// Prüft ob der gespeicherte Checksum stimmt.
    pub fn verifyChecksum(self: *const Page) bool {
        return self.header().checksum == self.computeChecksum();
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "PageHeader size" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(PageHeader));
}

test "Slot size" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Slot));
}

test "Page init" {
    const p = Page.init(42, .data);
    const h = p.header();
    try std.testing.expectEqual(@as(u64, 42), h.page_id);
    try std.testing.expectEqual(@as(u8, @intFromEnum(PageType.data)), h.page_type);
    try std.testing.expectEqual(@as(u16, HEADER_SIZE), h.free_start);
    try std.testing.expectEqual(@as(u16, PAGE_SIZE), h.free_end);
    try std.testing.expectEqual(@as(u16, 0), h.slot_count);
}

test "Page insertRecord and readRecord" {
    var p = Page.init(1, .data);
    const record = "hello world";
    const slot_idx = try p.insertRecord(record);
    try std.testing.expectEqual(@as(u16, 0), slot_idx);
    try std.testing.expectEqual(@as(u16, 1), p.header().slot_count);

    const read = try p.readRecord(0);
    try std.testing.expectEqualStrings(record, read);
}

test "Page multiple inserts" {
    var p = Page.init(1, .data);
    _ = try p.insertRecord("first");
    _ = try p.insertRecord("second");
    _ = try p.insertRecord("third");
    try std.testing.expectEqual(@as(u16, 3), p.header().slot_count);
    try std.testing.expectEqualStrings("first", try p.readRecord(0));
    try std.testing.expectEqualStrings("second", try p.readRecord(1));
    try std.testing.expectEqualStrings("third", try p.readRecord(2));
}

test "Page invalid slot" {
    const p = Page.init(1, .data);
    try std.testing.expectError(error.InvalidSlot, p.readRecord(0));
}

test "Page freeSpace decreases with inserts" {
    var p = Page.init(1, .data);
    const initial = p.freeSpace();
    _ = try p.insertRecord("test");
    try std.testing.expect(p.freeSpace() < initial);
}

test "Page checksum" {
    var p = Page.init(7, .data);
    _ = try p.insertRecord("checksum-test");
    p.updateChecksum();
    try std.testing.expect(p.verifyChecksum());
    // Daten verändern → Checksum muss falsch sein
    p.data[100] ^= 0xFF;
    try std.testing.expect(!p.verifyChecksum());
}

test "Page full" {
    var p = Page.init(1, .data);
    // Fülle die Page mit 100-Byte Records bis sie voll ist
    var buf: [100]u8 = [_]u8{'x'} ** 100;
    var count: usize = 0;
    while (p.insertRecord(&buf)) |_| {
        count += 1;
    } else |_| {}
    try std.testing.expect(count > 0);
    try std.testing.expectError(error.PageFull, p.insertRecord(&buf));
}
