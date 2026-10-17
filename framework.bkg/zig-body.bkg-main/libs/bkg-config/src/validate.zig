/// BKG Config — validation (fail-closed, no invented defaults for secrets)
const std = @import("std");

const BkgError = @import("bkg-core").errors.BkgError;

pub fn requireNonEmpty(name: []const u8, value: []const u8) BkgError!void {
    _ = name;
    if (value.len == 0) return error.InvalidInput;
}

pub fn parsePort(text: []const u8) BkgError!u16 {
    const n = std.fmt.parseInt(u16, text, 10) catch return error.InvalidInput;
    if (n == 0) return error.InvalidInput;
    return n;
}

test "empty value rejected" {
    try std.testing.expectError(error.InvalidInput, requireNonEmpty("host", ""));
}

test "port 0 rejected" {
    try std.testing.expectError(error.InvalidInput, parsePort("0"));
}

test "valid port" {
    try std.testing.expectEqual(@as(u16, 8080), try parsePort("8080"));
}
