/// BKG Core — Fundamental Domain Types
///
/// Basis-Typen für das gesamte Framework.
/// Kein BKG-Modul hat externe Abhängigkeiten außer std.
const std = @import("std");

// ── Grundlegende Skalare ──────────────────────────────────────────────────

/// Unix-Timestamp in Millisekunden
pub const Timestamp = i64;

/// Gibt den aktuellen Timestamp in Millisekunden zurück
pub fn now() Timestamp {
    return std.time.milliTimestamp();
}

/// Gibt den aktuellen Timestamp in Sekunden zurück
pub fn nowSeconds() i64 {
    return @divTrunc(std.time.milliTimestamp(), 1000);
}

// ── Status-Typen ─────────────────────────────────────────────────────────

pub const Status = enum {
    active,
    inactive,
    suspended,
    pending,
    deleted,
};

// ── Pagination ───────────────────────────────────────────────────────────

pub const Pagination = struct {
    page: u32 = 1,
    per_page: u32 = 50,

    pub fn offset(self: Pagination) u32 {
        return (self.page - 1) * self.per_page;
    }

    pub fn limit(self: Pagination) u32 {
        return self.per_page;
    }
};

pub const Page = struct {
    total: u64,
    page: u32,
    per_page: u32,
    total_pages: u32,

    pub fn init(total: u64, pagination: Pagination) Page {
        const tp: u32 = if (total == 0) 1 else @intCast((total + pagination.per_page - 1) / pagination.per_page);
        return .{
            .total = total,
            .page = pagination.page,
            .per_page = pagination.per_page,
            .total_pages = tp,
        };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "Pagination offset" {
    const p = Pagination{ .page = 3, .per_page = 20 };
    try std.testing.expectEqual(@as(u32, 40), p.offset());
    try std.testing.expectEqual(@as(u32, 20), p.limit());
}

test "Page total_pages" {
    const pg = Page.init(101, .{ .page = 1, .per_page = 50 });
    try std.testing.expectEqual(@as(u32, 3), pg.total_pages);
}

test "now returns positive" {
    try std.testing.expect(now() > 0);
}
