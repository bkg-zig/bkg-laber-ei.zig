/// BKG Vault — AES-256-GCM encryption
///
/// Wire format (little endian, no padding):
///   magic[4] = "BKGV" | version[1] = 0x01 | nonce[12] | ciphertext_len[4 LE]
///   ciphertext[N] | tag[16]
///
/// The 21-byte header is AEAD additional authenticated data.
/// Nonces come only from injected `io.random`. Decrypt is fail-closed:
/// authentication failure never returns plaintext.
const std = @import("std");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const BkgError = @import("bkg-core").errors.BkgError;

pub const KEY_SIZE: usize = Aes256Gcm.key_length;
pub const NONCE_SIZE: usize = Aes256Gcm.nonce_length;
pub const TAG_SIZE: usize = Aes256Gcm.tag_length;
pub const HEADER_SIZE: usize = 4 + 1 + NONCE_SIZE + 4;
pub const VERSION: u8 = 0x01;
pub const MAGIC: [4]u8 = .{ 'B', 'K', 'G', 'V' };
pub const MAX_PLAINTEXT: u32 = 64 * 1024 * 1024;

pub const Key = [KEY_SIZE]u8;
pub const Nonce = [NONCE_SIZE]u8;

fn writeU32Le(buf: []u8, value: u32) void {
    std.mem.writeInt(u32, buf[0..4], value, .little);
}

fn readU32Le(buf: []const u8) u32 {
    return std.mem.readInt(u32, buf[0..4], .little);
}

/// Encrypts `plaintext` under `key`. Caller owns the returned envelope bytes.
pub fn encrypt(
    allocator: std.mem.Allocator,
    io: std.Io,
    key: *const Key,
    plaintext: []const u8,
    aad: []const u8,
) (BkgError || std.mem.Allocator.Error)![]u8 {
    if (plaintext.len > MAX_PLAINTEXT) return error.InvalidInput;

    var nonce: Nonce = undefined;
    io.random(&nonce);

    const ct_len: u32 = @intCast(plaintext.len);
    const total = HEADER_SIZE + plaintext.len + TAG_SIZE;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    @memcpy(out[0..4], &MAGIC);
    out[4] = VERSION;
    @memcpy(out[5 .. 5 + NONCE_SIZE], &nonce);
    writeU32Le(out[5 + NONCE_SIZE ..][0..4], ct_len);

    var header_aad: std.ArrayList(u8) = .empty;
    defer header_aad.deinit(allocator);
    try header_aad.appendSlice(allocator, out[0..HEADER_SIZE]);
    try header_aad.appendSlice(allocator, aad);

    const ciphertext = out[HEADER_SIZE .. HEADER_SIZE + plaintext.len];
    const tag = out[HEADER_SIZE + plaintext.len ..][0..TAG_SIZE];
    Aes256Gcm.encrypt(
        ciphertext,
        tag,
        plaintext,
        header_aad.items,
        nonce,
        key.*,
    );
    return out;
}

/// Decrypts an envelope produced by `encrypt`. Fail-closed: on authentication
/// failure the plaintext buffer is wiped and freed before returning.
pub fn decrypt(
    allocator: std.mem.Allocator,
    key: *const Key,
    envelope: []const u8,
    aad: []const u8,
) (BkgError || std.mem.Allocator.Error)![]u8 {
    if (envelope.len < HEADER_SIZE + TAG_SIZE) return error.DecryptionFailed;
    if (!std.mem.eql(u8, envelope[0..4], &MAGIC)) return error.DecryptionFailed;
    if (envelope[4] != VERSION) return error.DecryptionFailed;

    const nonce = envelope[5 .. 5 + NONCE_SIZE][0..NONCE_SIZE].*;
    const ct_len = readU32Le(envelope[5 + NONCE_SIZE ..][0..4]);
    if (ct_len > MAX_PLAINTEXT) return error.DecryptionFailed;
    const expected = HEADER_SIZE + @as(usize, ct_len) + TAG_SIZE;
    if (envelope.len != expected) return error.DecryptionFailed;

    const ciphertext = envelope[HEADER_SIZE .. HEADER_SIZE + ct_len];
    const tag = envelope[HEADER_SIZE + ct_len ..][0..TAG_SIZE].*;

    var header_aad: std.ArrayList(u8) = .empty;
    defer header_aad.deinit(allocator);
    try header_aad.appendSlice(allocator, envelope[0..HEADER_SIZE]);
    try header_aad.appendSlice(allocator, aad);

    const plaintext = try allocator.alloc(u8, ct_len);
    errdefer {
        std.crypto.secureZero(u8, plaintext);
        allocator.free(plaintext);
    }

    Aes256Gcm.decrypt(plaintext, ciphertext, tag, header_aad.items, nonce, key.*) catch {
        return error.DecryptionFailed;
    };
    return plaintext;
}

test "encrypt decrypt roundtrip" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var key: Key = undefined;
    io.random(&key);
    const envelope = try encrypt(allocator, io, &key, "secret payload", "name:api");
    defer allocator.free(envelope);
    const plain = try decrypt(allocator, &key, envelope, "name:api");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("secret payload", plain);
}

test "decrypt fails closed on tampered ciphertext" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var key: Key = undefined;
    io.random(&key);
    const envelope = try encrypt(allocator, io, &key, "secret payload", "");
    defer allocator.free(envelope);
    envelope[HEADER_SIZE] ^= 0xFF;
    try std.testing.expectError(error.DecryptionFailed, decrypt(allocator, &key, envelope, ""));
}

test "decrypt fails closed on wrong aad" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var key: Key = undefined;
    io.random(&key);
    const envelope = try encrypt(allocator, io, &key, "secret payload", "aad-a");
    defer allocator.free(envelope);
    try std.testing.expectError(error.DecryptionFailed, decrypt(allocator, &key, envelope, "aad-b"));
}

test "decrypt fails closed on wrong key" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var key: Key = undefined;
    var other: Key = undefined;
    io.random(&key);
    io.random(&other);
    const envelope = try encrypt(allocator, io, &key, "secret payload", "");
    defer allocator.free(envelope);
    try std.testing.expectError(error.DecryptionFailed, decrypt(allocator, &other, envelope, ""));
}

test "decrypt rejects truncated envelope" {
    const allocator = std.testing.allocator;
    var key: Key = undefined;
    std.testing.io.random(&key);
    try std.testing.expectError(error.DecryptionFailed, decrypt(allocator, &key, "short", ""));
}
