/// BKG Core — Result Type
///
/// Einfacher Result-Wrapper für explizite Fehlerbehandlung.
const std = @import("std");

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: anyerror,

        pub fn isOk(self: @This()) bool {
            return self == .ok;
        }

        pub fn isErr(self: @This()) bool {
            return self == .err;
        }

        pub fn unwrap(self: @This()) T {
            return switch (self) {
                .ok => |v| v,
                .err => |e| std.debug.panic("unwrap called on Err: {s}", .{@errorName(e)}),
            };
        }

        pub fn unwrapOr(self: @This(), default: T) T {
            return switch (self) {
                .ok => |v| v,
                .err => default,
            };
        }
    };
}

pub fn ok(comptime T: type, value: T) Result(T) {
    return .{ .ok = value };
}

pub fn err(comptime T: type, e: anyerror) Result(T) {
    return .{ .err = e };
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "Result ok" {
    const r = ok(u32, 42);
    try std.testing.expect(r.isOk());
    try std.testing.expectEqual(@as(u32, 42), r.unwrap());
}

test "Result err" {
    const r = err(u32, error.NotFound);
    try std.testing.expect(r.isErr());
    try std.testing.expectEqual(@as(u32, 0), r.unwrapOr(0));
}
