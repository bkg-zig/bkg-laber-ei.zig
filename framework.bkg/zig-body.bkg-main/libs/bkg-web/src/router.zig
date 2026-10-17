/// BKG Web — path matching (exact and `/v1/kv/` prefix)
const std = @import("std");

pub const Route = enum {
    health,
    status,
    kv,
    unknown,
};

pub fn classify(path: []const u8) Route {
    if (std.mem.eql(u8, path, "/health")) return .health;
    if (std.mem.eql(u8, path, "/v1/status")) return .status;
    if (std.mem.startsWith(u8, path, "/v1/kv/")) return .kv;
    return .unknown;
}

pub fn kvKey(path: []const u8) ?[]const u8 {
    const prefix = "/v1/kv/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const key = path[prefix.len..];
    if (key.len == 0) return null;
    if (std.mem.indexOfScalar(u8, key, '/') != null) return null;
    if (std.mem.indexOf(u8, key, "..") != null) return null;
    return key;
}

test "classify known routes" {
    try std.testing.expectEqual(Route.health, classify("/health"));
    try std.testing.expectEqual(Route.status, classify("/v1/status"));
    try std.testing.expectEqual(Route.kv, classify("/v1/kv/foo"));
    try std.testing.expectEqual(Route.unknown, classify("/secret"));
}

test "kvKey rejects traversal" {
    try std.testing.expectEqualStrings("name", kvKey("/v1/kv/name").?);
    try std.testing.expect(kvKey("/v1/kv/") == null);
    try std.testing.expect(kvKey("/v1/kv/a/b") == null);
    try std.testing.expect(kvKey("/v1/kv/..") == null);
}
