/// BKG Auth — session tokens
///
/// The raw token is 32 random bytes. Only SHA-256(token) is stored.
/// Authentication hashes the presented token and compares with
/// `timing_safe.eql` — never a raw-token memcmp that can short-circuit.
const std = @import("std");

const vault = @import("bkg-vault");
const BkgError = @import("bkg-core").errors.BkgError;

pub const TOKEN_SIZE: usize = vault.random.TOKEN_SIZE;
pub const Token = [TOKEN_SIZE]u8;
pub const TokenHash = vault.hashing.Hash;

pub const Record = struct {
    user_id: []u8,
    expires_at: i64,
    revoked: bool,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    by_hash: std.AutoHashMap(TokenHash, Record),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .by_hash = std.AutoHashMap(TokenHash, Record).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        var it = self.by_hash.iterator();
        while (it.next()) |entry| {
            std.crypto.secureZero(u8, entry.value_ptr.user_id);
            self.allocator.free(entry.value_ptr.user_id);
        }
        self.by_hash.deinit();
    }

    pub fn hashToken(token: []const u8) TokenHash {
        return vault.hashing.sha256(token);
    }

    /// Creates a session. Returns the raw token once; it is not stored.
    pub fn create(self: *Store, io: std.Io, user_id: []const u8, now: i64, ttl_seconds: u32) !Token {
        if (user_id.len == 0) return BkgError.InvalidInput;
        if (ttl_seconds == 0) return BkgError.InvalidInput;

        const token = try vault.random.token32(io);
        const token_hash = hashToken(&token);
        const record = Record{
            .user_id = try self.allocator.dupe(u8, user_id),
            .expires_at = now + @as(i64, ttl_seconds),
            .revoked = false,
        };
        errdefer self.allocator.free(record.user_id);
        try self.by_hash.put(token_hash, record);
        return token;
    }

    pub fn authenticate(self: *Store, token: []const u8, now: i64) !*const Record {
        if (token.len != TOKEN_SIZE) return BkgError.Unauthorized;
        const presented = hashToken(token);
        var it = self.by_hash.iterator();
        var found: ?*Record = null;
        while (it.next()) |entry| {
            if (std.crypto.timing_safe.eql(TokenHash, entry.key_ptr.*, presented)) {
                found = entry.value_ptr;
            }
        }
        const record = found orelse return BkgError.Unauthorized;
        if (record.revoked) return BkgError.SessionRevoked;
        if (now >= record.expires_at) return BkgError.SessionExpired;
        return record;
    }

    pub fn revoke(self: *Store, token: []const u8) !void {
        if (token.len != TOKEN_SIZE) return BkgError.Unauthorized;
        const presented = hashToken(token);
        var it = self.by_hash.iterator();
        while (it.next()) |entry| {
            if (std.crypto.timing_safe.eql(TokenHash, entry.key_ptr.*, presented)) {
                entry.value_ptr.revoked = true;
                return;
            }
        }
        return BkgError.Unauthorized;
    }
};

test "session create authenticate revoke" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var store = Store.init(allocator);
    defer store.deinit();

    const token = try store.create(io, "user-1", 1_000, 60);
    const rec = try store.authenticate(&token, 1_010);
    try std.testing.expectEqualStrings("user-1", rec.user_id);

    try std.testing.expectError(error.SessionExpired, store.authenticate(&token, 1_061));

    try store.revoke(&token);
    try std.testing.expectError(error.SessionRevoked, store.authenticate(&token, 1_010));
}

test "unknown token is unauthorized" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var fake: Token = undefined;
    std.testing.io.random(&fake);
    try std.testing.expectError(error.Unauthorized, store.authenticate(&fake, 0));
}

test "wrong length token is unauthorized" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectError(error.Unauthorized, store.authenticate("short", 0));
}
