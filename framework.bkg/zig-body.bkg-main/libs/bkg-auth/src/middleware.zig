/// BKG Auth — Bearer token extraction and verification
///
/// The expected secret is stored as SHA-256(token). Presented tokens are
/// hashed and compared with `timing_safe.eql`.
const std = @import("std");

const vault = @import("bkg-vault");
const BkgError = @import("bkg-core").errors.BkgError;

pub const TokenHash = vault.hashing.Hash;

pub fn hashToken(token: []const u8) TokenHash {
    return vault.hashing.sha256(token);
}

/// Returns the token bytes after a `Bearer ` prefix, or null.
pub fn extractBearer(authorization: ?[]const u8) ?[]const u8 {
    const header = authorization orelse return null;
    const prefix = "Bearer ";
    if (header.len <= prefix.len) return null;
    if (!std.mem.startsWith(u8, header, prefix)) return null;
    const token = std.mem.trim(u8, header[prefix.len..], " \t");
    if (token.len == 0) return null;
    return token;
}

pub fn verifyBearerHash(presented: []const u8, expected_hash: *const TokenHash) bool {
    const presented_hash = hashToken(presented);
    return std.crypto.timing_safe.eql(TokenHash, presented_hash, expected_hash.*);
}

pub fn requireBearer(authorization: ?[]const u8, expected_hash: *const TokenHash) BkgError![]const u8 {
    const token = extractBearer(authorization) orelse return error.Unauthorized;
    if (!verifyBearerHash(token, expected_hash)) return error.Unauthorized;
    return token;
}

test "extractBearer requires Bearer prefix" {
    try std.testing.expect(extractBearer(null) == null);
    try std.testing.expect(extractBearer("Basic abc") == null);
    try std.testing.expect(extractBearer("Bearer") == null);
    try std.testing.expectEqualStrings("tok", extractBearer("Bearer tok").?);
}

test "verifyBearerHash default deny" {
    const expected = hashToken("correct-token-value");
    try std.testing.expect(verifyBearerHash("correct-token-value", &expected));
    try std.testing.expect(!verifyBearerHash("wrong-token-value!!", &expected));
    try std.testing.expect(!verifyBearerHash("", &expected));
}

test "requireBearer unauthorized without header" {
    const expected = hashToken("token");
    try std.testing.expectError(error.Unauthorized, requireBearer(null, &expected));
}
