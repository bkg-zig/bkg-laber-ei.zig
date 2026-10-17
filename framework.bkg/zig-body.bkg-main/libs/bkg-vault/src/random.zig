/// BKG Vault — CSPRNG via injected `std.Io`
///
/// Tokens and keys use `randomSecure`. Nonces may use `random` (still
/// backed by the Io implementation's CSPRNG when available).
const std = @import("std");

pub const TOKEN_SIZE: usize = 32;

pub fn fill(io: std.Io, buffer: []u8) void {
    io.random(buffer);
}

pub fn fillSecure(io: std.Io, buffer: []u8) std.Io.RandomSecureError!void {
    try io.randomSecure(buffer);
}

pub fn token32(io: std.Io) std.Io.RandomSecureError![TOKEN_SIZE]u8 {
    var out: [TOKEN_SIZE]u8 = undefined;
    try fillSecure(io, &out);
    return out;
}

pub fn hexEncode(bytes: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= bytes.len * 2);
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 15];
    }
    return out[0 .. bytes.len * 2];
}

pub fn hexDecode(hex: []const u8, out: []u8) error{ InvalidInput, NoSpaceLeft }![]u8 {
    const trimmed = std.mem.trim(u8, hex, " \t\r\n");
    return std.fmt.hexToBytes(out, trimmed) catch return error.InvalidInput;
}

test "token32 is 32 nonzero-capable bytes" {
    const a = try token32(std.testing.io);
    const b = try token32(std.testing.io);
    try std.testing.expectEqual(@as(usize, 32), a.len);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "hex roundtrip" {
    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    var hex_buf: [8]u8 = undefined;
    const hex = hexEncode(&bytes, &hex_buf);
    try std.testing.expectEqualStrings("deadbeef", hex);
    var out: [4]u8 = undefined;
    const decoded = try hexDecode(hex, &out);
    try std.testing.expectEqualSlices(u8, &bytes, decoded);
}

test "hex decode rejects odd length" {
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.InvalidInput, hexDecode("abc", &out));
}
