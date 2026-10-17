/// BKG Web — public HTTP error bodies (no internals, no stack traces)
const std = @import("std");

pub fn message(status: std.http.Status) []const u8 {
    return switch (status) {
        .ok, .created, .no_content => "",
        .bad_request => "bad request",
        .unauthorized => "unauthorized",
        .forbidden => "forbidden",
        .not_found => "not found",
        .method_not_allowed => "method not allowed",
        .payload_too_large => "payload too large",
        .internal_server_error => "internal error",
        else => "error",
    };
}

pub fn jsonBody(status: std.http.Status, buf: []u8) []const u8 {
    const msg = message(status);
    if (msg.len == 0) return "{}";
    return std.fmt.bufPrint(buf, "{{\"error\":\"{s}\"}}", .{msg}) catch "{\"error\":\"error\"}";
}

test "internal errors do not include zig error names" {
    const msg = message(.internal_server_error);
    try std.testing.expectEqualStrings("internal error", msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "error.") == null);
}
