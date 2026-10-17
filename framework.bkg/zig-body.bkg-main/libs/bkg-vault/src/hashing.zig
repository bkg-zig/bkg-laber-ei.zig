/// BKG Vault — password hashing (Argon2id) and SHA-256
///
/// Production password hashing uses OWASP Argon2id parameters.
/// Weaker parameters exist only for tests via `hashPasswordWithParams`
/// and are never the default.
const std = @import("std");

const argon2 = std.crypto.pwhash.argon2;

pub const Hash = [32]u8;

/// OWASP Argon2id (m=19 MiB, t=2, p=1). This is the production default.
pub const production_params = argon2.Params.owasp_2id;

/// Small parameters for unit tests only. Never used by `hashPassword`.
pub const test_params = argon2.Params{ .t = 1, .m = 32, .p = 1 };

pub fn sha256(data: []const u8) Hash {
    var out: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

pub fn hashPassword(
    allocator: std.mem.Allocator,
    io: std.Io,
    password: []const u8,
) ![]u8 {
    return hashPasswordWithParams(allocator, io, password, production_params);
}

pub fn hashPasswordWithParams(
    allocator: std.mem.Allocator,
    io: std.Io,
    password: []const u8,
    params: argon2.Params,
) ![]u8 {
    if (password.len == 0) return error.InvalidInput;
    var out: [256]u8 = undefined;
    const phc = try argon2.strHash(password, .{
        .allocator = allocator,
        .params = params,
        .mode = .argon2id,
        .encoding = .phc,
    }, &out, io);
    return allocator.dupe(u8, phc);
}

pub fn verifyPassword(
    allocator: std.mem.Allocator,
    io: std.Io,
    phc: []const u8,
    password: []const u8,
) !void {
    argon2.strVerify(phc, password, .{ .allocator = allocator }, io) catch {
        return error.InvalidCredentials;
    };
}

test "production params are owasp argon2id" {
    try std.testing.expectEqual(@as(u32, 2), production_params.t);
    try std.testing.expectEqual(@as(u32, 19 * 1024), production_params.m);
    try std.testing.expectEqual(@as(u24, 1), production_params.p);
}

test "sha256 is deterministic and length 32" {
    const a = sha256("bkg");
    const b = sha256("bkg");
    const c = sha256("bkg-");
    try std.testing.expectEqual(@as(usize, 32), a.len);
    try std.testing.expect(std.mem.eql(u8, &a, &b));
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "argon2id hash verify roundtrip with test params" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const phc = try hashPasswordWithParams(allocator, io, "correct horse battery staple", test_params);
    defer allocator.free(phc);
    try std.testing.expect(std.mem.startsWith(u8, phc, "$argon2id$"));
    try verifyPassword(allocator, io, phc, "correct horse battery staple");
    try std.testing.expectError(
        error.InvalidCredentials,
        verifyPassword(allocator, io, phc, "wrong password!!"),
    );
}

test "empty password is rejected" {
    try std.testing.expectError(
        error.InvalidInput,
        hashPasswordWithParams(std.testing.allocator, std.testing.io, "", test_params),
    );
}
