/// BKG Auth — password hashing policy
///
/// Minimum length 12. Argon2id with OWASP parameters by default.
/// Passwords are never accepted from this module's public API as argv;
/// callers must supply the password bytes from a safe source.
const std = @import("std");

const vault = @import("bkg-vault");
const BkgError = @import("bkg-core").errors.BkgError;

pub const MIN_LEN: usize = 12;

pub fn hash(allocator: std.mem.Allocator, io: std.Io, password: []const u8) ![]u8 {
    if (password.len < MIN_LEN) return BkgError.PasswordTooWeak;
    return vault.hashing.hashPassword(allocator, io, password);
}

pub fn hashWithParams(
    allocator: std.mem.Allocator,
    io: std.Io,
    password: []const u8,
    params: std.crypto.pwhash.argon2.Params,
) ![]u8 {
    if (password.len < MIN_LEN) return BkgError.PasswordTooWeak;
    return vault.hashing.hashPasswordWithParams(allocator, io, password, params);
}

pub fn verify(allocator: std.mem.Allocator, io: std.Io, phc: []const u8, password: []const u8) !void {
    return vault.hashing.verifyPassword(allocator, io, phc, password);
}

test "password shorter than 12 is rejected" {
    try std.testing.expectError(
        error.PasswordTooWeak,
        hashWithParams(std.testing.allocator, std.testing.io, "short", vault.hashing.test_params),
    );
}

test "password hash verify with test params" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const phc = try hashWithParams(allocator, io, "twelve chars!", vault.hashing.test_params);
    defer allocator.free(phc);
    try verify(allocator, io, phc, "twelve chars!");
    try std.testing.expectError(error.InvalidCredentials, verify(allocator, io, phc, "twelve chars?"));
}
