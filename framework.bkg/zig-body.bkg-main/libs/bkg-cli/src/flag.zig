/// BKG CLI — flag definitions
const std = @import("std");

pub const Flag = struct {
    long: []const u8,
    short: ?u8 = null,
    takes_value: bool,
    description: []const u8,
};

pub fn looksLikeFlag(arg: []const u8) bool {
    return arg.len >= 2 and arg[0] == '-';
}
