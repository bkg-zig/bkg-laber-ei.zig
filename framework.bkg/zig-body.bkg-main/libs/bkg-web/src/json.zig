/// BKG Web — tiny JSON helpers
const std = @import("std");

pub fn objectToArray(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

test "objectToArray" {
    const bytes = try objectToArray(std.testing.allocator, .{ .ok = true });
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"ok\":true}", bytes);
}
