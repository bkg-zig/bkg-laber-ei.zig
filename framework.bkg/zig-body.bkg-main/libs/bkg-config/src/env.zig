/// BKG Config — environment lookup
const std = @import("std");

pub fn get(map: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    return map.get(key);
}

pub fn getOr(map: *const std.process.Environ.Map, key: []const u8, fallback: []const u8) []const u8 {
    return get(map, key) orelse fallback;
}

test "get missing is null" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expect(get(&map, "BKG_AUTH_TOKEN") == null);
}

test "get present" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("BKG_DATA_DIR", "/var/lib/bkg");
    try std.testing.expectEqualStrings("/var/lib/bkg", get(&map, "BKG_DATA_DIR").?);
}
