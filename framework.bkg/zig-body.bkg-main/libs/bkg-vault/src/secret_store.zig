/// BKG Vault — in-memory encrypted secret store
///
/// Values are stored as AES-256-GCM envelopes bound to the secret name.
/// The master key never leaves the process; names are not encrypted.
const std = @import("std");

const encryption = @import("encryption.zig");
const BkgError = @import("bkg-core").errors.BkgError;

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    master_key: encryption.Key,
    envelopes: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, master_key: encryption.Key) Store {
        return .{
            .allocator = allocator,
            .io = io,
            .master_key = master_key,
            .envelopes = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        var it = self.envelopes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            std.crypto.secureZero(u8, entry.value_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.envelopes.deinit();
        std.crypto.secureZero(u8, &self.master_key);
    }

    pub fn put(self: *Store, name: []const u8, plaintext: []const u8) !void {
        if (name.len == 0) return BkgError.InvalidInput;
        const envelope = try encryption.encrypt(self.allocator, self.io, &self.master_key, plaintext, name);
        errdefer {
            std.crypto.secureZero(u8, envelope);
            self.allocator.free(envelope);
        }

        const gop = try self.envelopes.getOrPut(name);
        if (gop.found_existing) {
            std.crypto.secureZero(u8, gop.value_ptr.*);
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
        }
        gop.value_ptr.* = envelope;
    }

    pub fn get(self: *Store, name: []const u8) ![]u8 {
        const envelope = self.envelopes.get(name) orelse return BkgError.KeyNotFound;
        return encryption.decrypt(self.allocator, &self.master_key, envelope, name);
    }

    pub fn delete(self: *Store, name: []const u8) !void {
        const kv = self.envelopes.fetchRemove(name) orelse return BkgError.KeyNotFound;
        self.allocator.free(kv.key);
        std.crypto.secureZero(u8, kv.value);
        self.allocator.free(kv.value);
    }
};

test "secret store put get delete" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var key: encryption.Key = undefined;
    io.random(&key);
    var store = Store.init(allocator, io, key);
    defer store.deinit();

    try store.put("db/password", "s3cret-value");
    const got = try store.get("db/password");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("s3cret-value", got);

    try store.delete("db/password");
    try std.testing.expectError(error.KeyNotFound, store.get("db/password"));
}

test "secret store missing key is fail-closed" {
    const allocator = std.testing.allocator;
    var key: encryption.Key = undefined;
    std.testing.io.random(&key);
    var store = Store.init(allocator, std.testing.io, key);
    defer store.deinit();
    try std.testing.expectError(error.KeyNotFound, store.get("nope"));
}
