/// BKG Web — incoming request view
const std = @import("std");

pub const Request = struct {
    method: std.http.Method,
    target: []const u8,
    authorization: ?[]const u8,
    body: []const u8,

    pub fn path(self: Request) []const u8 {
        const q = std.mem.indexOfScalar(u8, self.target, '?') orelse return self.target;
        return self.target[0..q];
    }
};

pub fn headerValue(head_buffer: []const u8, name: []const u8) ?[]const u8 {
    var it = std.http.HeaderIterator.init(head_buffer);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

test "path strips query" {
    const req = Request{ .method = .GET, .target = "/v1/kv/foo?x=1", .authorization = null, .body = "" };
    try std.testing.expectEqualStrings("/v1/kv/foo", req.path());
}
