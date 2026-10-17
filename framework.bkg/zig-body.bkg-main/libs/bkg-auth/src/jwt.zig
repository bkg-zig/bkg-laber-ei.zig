/// BKG Auth — HS256 JWT
///
/// Rejects `alg=none` and any algorithm other than HS256.
/// Requires `exp`. Secret must be at least 32 bytes.
const std = @import("std");

const BkgError = @import("bkg-core").errors.BkgError;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;

pub const MIN_SECRET_LEN: usize = 32;

pub const Claims = struct {
    sub: []const u8,
    exp: i64,
};

const Header = struct {
    alg: []const u8,
    typ: []const u8 = "JWT",
};

fn encodePart(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const size = b64.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, size);
    _ = b64.Encoder.encode(out, bytes);
    return out;
}

fn decodePart(allocator: std.mem.Allocator, part: []const u8) ![]u8 {
    const size = b64.Decoder.calcSizeForSlice(part) catch return BkgError.TokenInvalid;
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    b64.Decoder.decode(out, part) catch {
        allocator.free(out);
        return BkgError.TokenInvalid;
    };
    return out;
}

fn sign(secret: []const u8, data: []const u8) [HmacSha256.mac_length]u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, data, secret);
    return mac;
}

pub fn issue(allocator: std.mem.Allocator, secret: []const u8, claims: Claims) ![]u8 {
    if (secret.len < MIN_SECRET_LEN) return BkgError.InvalidInput;
    if (claims.sub.len == 0) return BkgError.InvalidInput;

    var header_buf: [64]u8 = undefined;
    var header_w = std.Io.Writer.fixed(&header_buf);
    try std.json.Stringify.value(Header{ .alg = "HS256", .typ = "JWT" }, .{}, &header_w);
    const header_json = header_w.buffered();

    var payload_buf: [512]u8 = undefined;
    var payload_w = std.Io.Writer.fixed(&payload_buf);
    try std.json.Stringify.value(claims, .{}, &payload_w);
    const payload_json = payload_w.buffered();

    const header_b64 = try encodePart(allocator, header_json);
    defer allocator.free(header_b64);
    const payload_b64 = try encodePart(allocator, payload_json);
    defer allocator.free(payload_b64);

    var signing_input = std.ArrayList(u8).empty;
    defer signing_input.deinit(allocator);
    try signing_input.appendSlice(allocator, header_b64);
    try signing_input.append(allocator, '.');
    try signing_input.appendSlice(allocator, payload_b64);

    const mac = sign(secret, signing_input.items);
    const sig_b64 = try encodePart(allocator, &mac);
    defer allocator.free(sig_b64);

    var token = std.ArrayList(u8).empty;
    errdefer token.deinit(allocator);
    try token.appendSlice(allocator, signing_input.items);
    try token.append(allocator, '.');
    try token.appendSlice(allocator, sig_b64);
    return token.toOwnedSlice(allocator);
}

pub fn verify(allocator: std.mem.Allocator, secret: []const u8, token: []const u8, now: i64) !Claims {
    if (secret.len < MIN_SECRET_LEN) return BkgError.InvalidInput;

    var it = std.mem.splitScalar(u8, token, '.');
    const header_b64 = it.next() orelse return BkgError.TokenInvalid;
    const payload_b64 = it.next() orelse return BkgError.TokenInvalid;
    const sig_b64 = it.next() orelse return BkgError.TokenInvalid;
    if (it.next() != null) return BkgError.TokenInvalid;
    if (header_b64.len == 0 or payload_b64.len == 0) return BkgError.TokenInvalid;

    const header_json = try decodePart(allocator, header_b64);
    defer allocator.free(header_json);
    const parsed_header = std.json.parseFromSlice(Header, allocator, header_json, .{}) catch return BkgError.TokenInvalid;
    defer parsed_header.deinit();

    if (std.ascii.eqlIgnoreCase(parsed_header.value.alg, "none")) return BkgError.TokenInvalid;
    if (!std.mem.eql(u8, parsed_header.value.alg, "HS256")) return BkgError.TokenInvalid;

    const payload_json = try decodePart(allocator, payload_b64);
    defer allocator.free(payload_json);
    const parsed_claims = std.json.parseFromSlice(Claims, allocator, payload_json, .{}) catch return BkgError.TokenInvalid;
    defer parsed_claims.deinit();
    if (parsed_claims.value.sub.len == 0) return BkgError.TokenInvalid;
    if (now >= parsed_claims.value.exp) return BkgError.TokenExpired;

    var signing_input = std.ArrayList(u8).empty;
    defer signing_input.deinit(allocator);
    try signing_input.appendSlice(allocator, header_b64);
    try signing_input.append(allocator, '.');
    try signing_input.appendSlice(allocator, payload_b64);

    const expected = sign(secret, signing_input.items);
    const got_raw = try decodePart(allocator, sig_b64);
    defer allocator.free(got_raw);
    if (got_raw.len != expected.len) return BkgError.TokenInvalid;

    var got: [HmacSha256.mac_length]u8 = undefined;
    @memcpy(&got, got_raw);
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, got, expected)) {
        return BkgError.TokenInvalid;
    }

    return Claims{
        .sub = try allocator.dupe(u8, parsed_claims.value.sub),
        .exp = parsed_claims.value.exp,
    };
}

test "jwt issue and verify" {
    const allocator = std.testing.allocator;
    var secret: [32]u8 = undefined;
    std.testing.io.random(&secret);
    const token = try issue(allocator, &secret, .{ .sub = "user-1", .exp = 2_000 });
    defer allocator.free(token);
    const claims = try verify(allocator, &secret, token, 1_000);
    defer allocator.free(claims.sub);
    try std.testing.expectEqualStrings("user-1", claims.sub);
}

test "jwt rejects alg none" {
    const allocator = std.testing.allocator;
    var secret: [32]u8 = undefined;
    std.testing.io.random(&secret);
    const header = try encodePart(allocator, "{\"alg\":\"none\",\"typ\":\"JWT\"}");
    defer allocator.free(header);
    const payload = try encodePart(allocator, "{\"sub\":\"x\",\"exp\":999999}");
    defer allocator.free(payload);
    var token = std.ArrayList(u8).empty;
    defer token.deinit(allocator);
    try token.appendSlice(allocator, header);
    try token.append(allocator, '.');
    try token.appendSlice(allocator, payload);
    try token.append(allocator, '.');
    try std.testing.expectError(error.TokenInvalid, verify(allocator, &secret, token.items, 1));
}

test "jwt rejects expired token" {
    const allocator = std.testing.allocator;
    var secret: [32]u8 = undefined;
    std.testing.io.random(&secret);
    const token = try issue(allocator, &secret, .{ .sub = "user-1", .exp = 10 });
    defer allocator.free(token);
    try std.testing.expectError(error.TokenExpired, verify(allocator, &secret, token, 11));
}

test "jwt rejects short secret" {
    try std.testing.expectError(
        error.InvalidInput,
        issue(std.testing.allocator, "tooshort", .{ .sub = "u", .exp = 1 }),
    );
}

test "jwt rejects tampered payload" {
    const allocator = std.testing.allocator;
    var secret: [32]u8 = undefined;
    std.testing.io.random(&secret);
    const token = try issue(allocator, &secret, .{ .sub = "user-1", .exp = 2_000 });
    defer allocator.free(token);
    const copy = try allocator.dupe(u8, token);
    defer allocator.free(copy);
    copy[copy.len / 2] ^= 0x01;
    try std.testing.expectError(error.TokenInvalid, verify(allocator, &secret, copy, 1_000));
}

test "jwt rejects missing exp" {
    const allocator = std.testing.allocator;
    var secret: [32]u8 = undefined;
    std.testing.io.random(&secret);
    const header = try encodePart(allocator, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
    defer allocator.free(header);
    const payload = try encodePart(allocator, "{\"sub\":\"x\"}");
    defer allocator.free(payload);
    const signing = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header, payload });
    defer allocator.free(signing);
    const mac = sign(&secret, signing);
    const sig = try encodePart(allocator, &mac);
    defer allocator.free(sig);
    const token = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing, sig });
    defer allocator.free(token);
    try std.testing.expectError(error.TokenInvalid, verify(allocator, &secret, token, 1));
}
