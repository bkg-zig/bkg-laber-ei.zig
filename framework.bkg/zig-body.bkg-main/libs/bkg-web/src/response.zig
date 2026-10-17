/// BKG Web — response helpers
const std = @import("std");

pub const Response = struct {
    status: std.http.Status,
    content_type: []const u8 = "application/json",
    body: []const u8,
};

pub fn json(status: std.http.Status, body: []const u8) Response {
    return .{ .status = status, .content_type = "application/json", .body = body };
}

pub fn text(status: std.http.Status, body: []const u8) Response {
    return .{ .status = status, .content_type = "text/plain; charset=utf-8", .body = body };
}
