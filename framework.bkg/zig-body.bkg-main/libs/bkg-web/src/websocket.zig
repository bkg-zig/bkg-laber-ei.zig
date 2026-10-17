/// BKG Web — WebSocket RFC 6455
///
/// Implementiert:
///   - Server-seitiger Handshake (HTTP Upgrade → 101 Switching Protocols)
///   - Frame-Parsing: Opcode, Masking, Payload-Length (7 / 7+16 / 7+64 Bit)
///   - Frame-Schreiben (Server→Client, unmaskiert per RFC)
///   - Opcodes: Text (0x1), Binary (0x2), Close (0x8), Ping (0x9), Pong (0xA)
///   - Continuation Frames (0x0) mit FIN-Flag
///
/// Nicht implementiert (Phase 2):
///   - Compression (permessage-deflate)
///   - Subprotokolle
const std = @import("std");

// ── Konstanten ────────────────────────────────────────────────────────────────

pub const MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text         = 0x1,
    binary       = 0x2,
    close        = 0x8,
    ping         = 0x9,
    pong         = 0xA,
    _,
};

pub const Frame = struct {
    fin:     bool,
    opcode:  Opcode,
    payload: []const u8,
};

pub const WsError = error{
    BadHandshake,
    FrameTooLarge,
    InvalidOpcode,
    ConnectionClosed,
    MaskRequired,
};

// ── Handshake ─────────────────────────────────────────────────────────────────

/// Berechnet den Sec-WebSocket-Accept-Wert: Base64(SHA1(key + MAGIC)).
pub fn computeAccept(key: []const u8, out: *[28]u8) void {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(MAGIC);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// Schreibt die `101 Switching Protocols`-Antwort in `writer`.
pub fn writeHandshakeResponse(
    writer: anytype,
    accept: *const [28]u8,
) !void {
    try writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeAll("Upgrade: websocket\r\n");
    try writer.writeAll("Connection: Upgrade\r\n");
    try writer.writeAll("Sec-WebSocket-Accept: ");
    try writer.writeAll(accept);
    try writer.writeAll("\r\n\r\n");
}

// ── Frame lesen ───────────────────────────────────────────────────────────────

/// Liest einen vollständigen WebSocket-Frame aus `reader`.
/// Client→Server-Frames MÜSSEN maskiert sein (RFC 6455 §5.1).
pub fn readFrame(
    reader:      anytype,
    payload_buf: []u8,
) !Frame {
    var b0: [1]u8 = undefined;
    reader.readAll(&b0) catch return WsError.ConnectionClosed;
    const fin    = (b0[0] & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0[0] & 0x0F)));

    var b1: [1]u8 = undefined;
    reader.readAll(&b1) catch return WsError.ConnectionClosed;
    const masked = (b1[0] & 0x80) != 0;
    const len7   = @as(u64, b1[0] & 0x7F);

    if (!masked) return WsError.MaskRequired;

    const payload_len: u64 = switch (len7) {
        126 => blk: {
            var ext: [2]u8 = undefined;
            reader.readAll(&ext) catch return WsError.ConnectionClosed;
            break :blk @as(u64, std.mem.readInt(u16, &ext, .big));
        },
        127 => blk: {
            var ext: [8]u8 = undefined;
            reader.readAll(&ext) catch return WsError.ConnectionClosed;
            break :blk std.mem.readInt(u64, &ext, .big);
        },
        else => len7,
    };

    if (payload_len > payload_buf.len) return WsError.FrameTooLarge;

    var mask: [4]u8 = undefined;
    reader.readAll(&mask) catch return WsError.ConnectionClosed;

    const buf = payload_buf[0..@intCast(payload_len)];
    reader.readAll(buf) catch return WsError.ConnectionClosed;

    for (buf, 0..) |*byte, i| byte.* ^= mask[i % 4];

    return Frame{ .fin = fin, .opcode = opcode, .payload = buf };
}

// ── Frame schreiben ───────────────────────────────────────────────────────────

/// Schreibt einen Server→Client-Frame (unmaskiert, RFC 6455 §5.1).
pub fn writeFrame(
    writer:  anytype,
    opcode:  Opcode,
    fin:     bool,
    payload: []const u8,
) !void {
    const b0: u8 = (@as(u8, if (fin) 0x80 else 0x00)) | @as(u8, @intFromEnum(opcode));
    try writer.writeByte(b0);

    const len = payload.len;
    if (len < 126) {
        try writer.writeByte(@intCast(len));
    } else if (len < 65536) {
        try writer.writeByte(126);
        var ext: [2]u8 = undefined;
        std.mem.writeInt(u16, &ext, @intCast(len), .big);
        try writer.writeAll(&ext);
    } else {
        try writer.writeByte(127);
        var ext: [8]u8 = undefined;
        std.mem.writeInt(u64, &ext, len, .big);
        try writer.writeAll(&ext);
    }
    try writer.writeAll(payload);
}

pub fn sendText(writer: anytype, text: []const u8) !void {
    try writeFrame(writer, .text, true, text);
}
pub fn sendBinary(writer: anytype, data: []const u8) !void {
    try writeFrame(writer, .binary, true, data);
}
pub fn sendPong(writer: anytype, payload: []const u8) !void {
    try writeFrame(writer, .pong, true, payload);
}
pub fn sendClose(writer: anytype, code: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, code, .big);
    try writeFrame(writer, .close, true, &buf);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "computeAccept — RFC-6455-Beispielwert" {
    var out: [28]u8 = undefined;
    computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}

test "writeFrame + readFrame round-trip (mask=0)" {
    const msg = "Hallo BKG";
    // Client→Server Frame manuell bauen: FIN+text, MASK=1, mask-key=0x00000000
    var client_frame: [16]u8 = undefined;
    client_frame[0] = 0x81;
    client_frame[1] = 0x80 | @as(u8, @intCast(msg.len));
    client_frame[2] = 0; client_frame[3] = 0;
    client_frame[4] = 0; client_frame[5] = 0;
    @memcpy(client_frame[6..6 + msg.len], msg);

    var rfbs = std.io.fixedBufferStream(client_frame[0..6 + msg.len]);
    var payload_buf: [256]u8 = undefined;
    const frame = try readFrame(rfbs.reader(), &payload_buf);
    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(Opcode.text, frame.opcode);
    try std.testing.expectEqualStrings(msg, frame.payload);
}

test "MaskRequired auf unmaskierten Frame" {
    // Server→Client Frame (kein MASK-Bit) → Fehler erwartet
    const raw = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    var fbs = std.io.fixedBufferStream(&raw);
    var buf: [64]u8 = undefined;
    try std.testing.expectError(WsError.MaskRequired, readFrame(fbs.reader(), &buf));
}
