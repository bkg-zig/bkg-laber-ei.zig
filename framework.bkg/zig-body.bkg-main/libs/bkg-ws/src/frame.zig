/// bkg-ws — WebSocket Frame Codec (RFC 6455)
///
/// Pure Bit-Manipulation — kein I/O, kein Allokator.
/// Validiert Frames gemäß RFC 6455 §5: fail-closed.
///
/// Unterstützte Payload-Größen:
///   7 Bit (0–125), 7+16 Bit (126 = 16-bit ext), 7+64 Bit (127 = 64-bit ext)
const std = @import("std");

// ── Typen ─────────────────────────────────────────────────────────────────────

pub const Opcode = enum(u4) {
    continuation     = 0,
    text             = 1,
    binary           = 2,
    connection_close = 8,
    ping             = 9,
    pong             = 10,
    _,
};

pub const FrameHeader = struct {
    fin:         bool,
    rsv:         u3,      // muss 0 sein (kein Extension-Aushandlung)
    opcode:      Opcode,
    masked:      bool,
    payload_len: u64,
    mask_key:    [4]u8,   // nur gültig wenn masked == true
};

pub const ParseError = error{
    /// RSV-Bits gesetzt ohne Extension
    InvalidRsv,
    /// Client-Frame ohne Mask-Bit (RFC 6455 §5.1)
    UnmaskedClientFrame,
    /// Control-Frame mit FIN=false (RFC 6455 §5.5)
    FragmentedControlFrame,
    /// Control-Frame mit payload_len > 125 (RFC 6455 §5.5)
    ControlPayloadTooLarge,
    /// Payload größer als max_payload
    PayloadTooLarge,
    /// Unbekannter oder reservierter Opcode
    InvalidOpcode,
    /// Close-Frame mit genau 1 Byte Payload (RFC 6455 §5.5.1)
    InvalidClosePayload,
    /// Close-Frame Reason ist kein gültiges UTF-8
    InvalidUtf8CloseReason,
    /// Zu wenige Bytes für einen vollständigen Frame-Header
    Truncated,
};

/// Maximale Payload-Länge (1 MiB Standardlimit)
pub const MAX_PAYLOAD: usize = 1024 * 1024;

// ── Öffentliche API ───────────────────────────────────────────────────────────

/// Parst den Frame-Header aus rohen Bytes.
/// `buf` muss mindestens 2 Bytes enthalten.
/// Gibt einen validierten `FrameHeader` zurück oder einen `ParseError`.
pub fn parseHeader(buf: []const u8, max_payload: usize) ParseError!FrameHeader {
    if (buf.len < 2) return ParseError.Truncated;

    const b0 = buf[0];
    const b1 = buf[1];

    const fin    = (b0 & 0x80) != 0;
    const rsv: u3 = @truncate((b0 >> 4) & 0x07);
    const op_raw: u4 = @truncate(b0 & 0x0F);
    const opcode: Opcode = @enumFromInt(op_raw);
    const masked = (b1 & 0x80) != 0;
    const len7: u64   = b1 & 0x7F;

    // RSV-Bits: ohne Extension-Aushandlung müssen alle 0 sein
    if (rsv != 0) return ParseError.InvalidRsv;

    // Client→Server Frames müssen maskiert sein
    if (!masked) return ParseError.UnmaskedClientFrame;

    // Opcode-Validierung (nur bekannte Opcodes erlaubt)
    switch (op_raw) {
        0, 1, 2, 8, 9, 10 => {},
        else => return ParseError.InvalidOpcode,
    }

    // Control-Frame-Regeln (RFC 6455 §5.5)
    const is_control = op_raw >= 8;
    if (is_control) {
        if (!fin)    return ParseError.FragmentedControlFrame;
        if (len7 > 125) return ParseError.ControlPayloadTooLarge;
        // Für 126/127 kommt die weitere Prüfung unten — aber bei Control-Frames
        // ist len7 > 125 schon ein Fehler, daher brauchen wir keine ext-Größe zu lesen.
    }

    // Payload-Länge berechnen — benötigte Bytes prüfen
    var offset: usize = 2;
    const payload_len: u64 = switch (len7) {
        126 => blk: {
            if (buf.len < offset + 2) return ParseError.Truncated;
            const v = std.mem.readInt(u16, buf[offset..][0..2], .big);
            offset += 2;
            break :blk @as(u64, v);
        },
        127 => blk: {
            if (buf.len < offset + 8) return ParseError.Truncated;
            const v = std.mem.readInt(u64, buf[offset..][0..8], .big);
            offset += 8;
            break :blk v;
        },
        else => len7,
    };

    // Payload-Größenlimit prüfen
    if (payload_len > max_payload) return ParseError.PayloadTooLarge;

    // Mask-Key einlesen
    if (buf.len < offset + 4) return ParseError.Truncated;
    const mask_key: [4]u8 = buf[offset..][0..4].*;

    // Close-Frame: genau 1 Byte Payload ist ungültig (RFC 6455 §5.5.1)
    if (opcode == .connection_close) {
        if (payload_len == 1) return ParseError.InvalidClosePayload;
        // UTF-8-Check für Reason (Bytes ab Index 2 nach Mask)
        // Hinweis: Wir prüfen hier den *rohen* Puffer-Inhalt nach dem Header.
        // Die eigentliche UTF-8-Prüfung nach dem Unmaskieren erfolgt in ws.zig.
        // Falls payload_len > 2, delegieren wir die UTF-8-Prüfung an den Aufrufer.
    }

    return FrameHeader{
        .fin         = fin,
        .rsv         = rsv,
        .opcode      = opcode,
        .masked      = masked,
        .payload_len = payload_len,
        .mask_key    = mask_key,
    };
}

/// Berechnet die Größe des Frame-Headers in Bytes.
/// Nützlich um den Datenbereich direkt hinter dem Header zu finden.
pub fn headerSize(payload_len: usize) usize {
    // 2 Basis + Erweiterung + 4 Mask (client-seitig immer maskiert)
    const ext: usize = if (payload_len < 126) 0
                       else if (payload_len < 65536) 2
                       else 8;
    return 2 + ext + 4; // immer mit Mask (Client→Server)
}

/// Unmaskiert Payload in-place: jedes Byte XOR mask_key[i % 4].
pub fn unmask(payload: []u8, mask_key: [4]u8) void {
    for (payload, 0..) |*byte, i| {
        byte.* ^= mask_key[i % 4];
    }
}

/// Encodiert einen Server→Client Frame-Header (unmaskiert) in `buf` (max 10 Bytes).
/// Gibt die Anzahl geschriebener Header-Bytes zurück.
/// Server-Frames sind per RFC 6455 §5.1 NICHT maskiert.
pub fn encodeHeader(buf: *[10]u8, fin: bool, opcode: Opcode, payload_len: usize) usize {
    buf[0] = (@as(u8, if (fin) 0x80 else 0x00)) | @as(u8, @intFromEnum(opcode));
    if (payload_len < 126) {
        buf[1] = @intCast(payload_len); // kein MASK-Bit (Server → Client)
        return 2;
    } else if (payload_len < 65536) {
        buf[1] = 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(payload_len), .big);
        return 4;
    } else {
        buf[1] = 127;
        std.mem.writeInt(u64, buf[2..10], @intCast(payload_len), .big);
        return 10;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Hilfsfunktion: Baut einen Client→Server Frame-Header in einen Buffer.
fn buildClientHeader(
    out: []u8,
    fin: bool,
    opcode: u4,
    mask_key: [4]u8,
    payload_len: usize,
) usize {
    out[0] = (@as(u8, if (fin) 0x80 else 0x00)) | @as(u8, opcode);
    var pos: usize = 2;
    if (payload_len < 126) {
        out[1] = 0x80 | @as(u8, @intCast(payload_len));
    } else if (payload_len < 65536) {
        out[1] = 0x80 | 126;
        std.mem.writeInt(u16, out[2..4], @intCast(payload_len), .big);
        pos = 4;
    } else {
        out[1] = 0x80 | 127;
        std.mem.writeInt(u64, out[2..10], @intCast(payload_len), .big);
        pos = 10;
    }
    out[pos..][0..4].* = mask_key;
    return pos + 4;
}

test "parseHeader — einfacher Text-Frame (FIN, opcode=text, masked, len=5)" {
    var buf: [14]u8 = undefined;
    const mask_key = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    const header_len = buildClientHeader(&buf, true, 1, mask_key, 5);
    // Payload-Bytes anhängen (maskiert)
    const payload = "Hello";
    for (payload, 0..) |b, i| buf[header_len + i] = b ^ mask_key[i % 4];

    const h = try parseHeader(buf[0..header_len], MAX_PAYLOAD);
    try testing.expect(h.fin);
    try testing.expectEqual(Opcode.text, h.opcode);
    try testing.expectEqual(@as(u64, 5), h.payload_len);
    try testing.expect(h.masked);
    try testing.expectEqual(mask_key, h.mask_key);
}

test "parseHeader — extended 16-bit payload (len=126, actual=200)" {
    var buf: [8]u8 = undefined;
    const mask_key = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const n = buildClientHeader(&buf, true, 2, mask_key, 200);
    _ = n;

    const h = try parseHeader(&buf, MAX_PAYLOAD);
    try testing.expectEqual(@as(u64, 200), h.payload_len);
    try testing.expectEqual(Opcode.binary, h.opcode);
}

test "parseHeader — extended 64-bit payload (len=127, actual=70000)" {
    var buf: [14]u8 = undefined;
    const mask_key = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    const n = buildClientHeader(&buf, true, 1, mask_key, 70000);
    _ = n;

    const h = try parseHeader(&buf, MAX_PAYLOAD);
    try testing.expectEqual(@as(u64, 70000), h.payload_len);
}

test "parseHeader — RSV != 0 → InvalidRsv" {
    var buf: [6]u8 = undefined;
    const mask_key = [4]u8{ 0, 0, 0, 0 };
    _ = buildClientHeader(&buf, true, 1, mask_key, 0);
    buf[0] |= 0x40; // RSV1 setzen
    try testing.expectError(ParseError.InvalidRsv, parseHeader(&buf, MAX_PAYLOAD));
}

test "parseHeader — unmaskierter Client-Frame → UnmaskedClientFrame" {
    // Kein MASK-Bit setzen
    const buf = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    try testing.expectError(ParseError.UnmaskedClientFrame, parseHeader(&buf, MAX_PAYLOAD));
}

test "parseHeader — fragmentierter Ping (fin=false, opcode=9) → FragmentedControlFrame" {
    var buf: [6]u8 = undefined;
    const mask_key = [4]u8{ 0, 0, 0, 0 };
    _ = buildClientHeader(&buf, false, 9, mask_key, 0);
    try testing.expectError(ParseError.FragmentedControlFrame, parseHeader(&buf, MAX_PAYLOAD));
}

test "parseHeader — Ping mit 126 Bytes → ControlPayloadTooLarge" {
    var buf: [8]u8 = undefined;
    const mask_key = [4]u8{ 0, 0, 0, 0 };
    _ = buildClientHeader(&buf, true, 9, mask_key, 126);
    try testing.expectError(ParseError.ControlPayloadTooLarge, parseHeader(&buf, MAX_PAYLOAD));
}

test "parseHeader — Payload > MAX → PayloadTooLarge" {
    var buf: [14]u8 = undefined;
    const mask_key = [4]u8{ 0, 0, 0, 0 };
    _ = buildClientHeader(&buf, true, 1, mask_key, 70000);
    try testing.expectError(ParseError.PayloadTooLarge, parseHeader(&buf, 1000));
}

test "parseHeader — Close-Frame mit 1 Byte → InvalidClosePayload" {
    var buf: [7]u8 = undefined;
    const mask_key = [4]u8{ 0, 0, 0, 0 };
    _ = buildClientHeader(&buf, true, 8, mask_key, 1);
    buf[6] = 0x42; // 1 Byte Payload
    try testing.expectError(ParseError.InvalidClosePayload, parseHeader(&buf, MAX_PAYLOAD));
}

test "unmask — XOR-Korrektheit" {
    var payload = [_]u8{ 0x37, 0xFA, 0x21, 0x3D };
    const mask = [4]u8{ 0x37, 0xFA, 0x21, 0x3D };
    unmask(&payload, mask);
    // XOR mit sich selbst → 0
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &payload);
}

test "unmask — bekannte Transformation" {
    var payload = [_]u8{ 'H' ^ 0x01, 'e' ^ 0x02, 'l' ^ 0x03, 'l' ^ 0x04, 'o' ^ 0x01 };
    const mask = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    unmask(&payload, mask);
    try testing.expectEqualSlices(u8, "Hello", &payload);
}

test "encodeHeader — Text-Frame, 5 Bytes → 2-Byte-Header" {
    var buf: [10]u8 = undefined;
    const n = encodeHeader(&buf, true, .text, 5);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 0x81), buf[0]); // FIN + text(1)
    try testing.expectEqual(@as(u8, 5), buf[1]);    // kein MASK + len=5
}

test "encodeHeader — Binary-Frame, 200 Bytes → extended 16-bit (4 Bytes)" {
    var buf: [10]u8 = undefined;
    const n = encodeHeader(&buf, true, .binary, 200);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(u8, 0x82), buf[0]); // FIN + binary(2)
    try testing.expectEqual(@as(u8, 126), buf[1]);
    const ext = std.mem.readInt(u16, buf[2..4], .big);
    try testing.expectEqual(@as(u16, 200), ext);
}

test "encodeHeader — Ping, 0 Bytes" {
    var buf: [10]u8 = undefined;
    const n = encodeHeader(&buf, true, .ping, 0);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 0x89), buf[0]); // FIN + ping(9)
    try testing.expectEqual(@as(u8, 0x00), buf[1]);
}

test "parseHeader — ungültiger Opcode → InvalidOpcode" {
    var buf: [6]u8 = undefined;
    const mask_key = [4]u8{ 0, 0, 0, 0 };
    _ = buildClientHeader(&buf, true, 3, mask_key, 0); // opcode=3 reserviert
    try testing.expectError(ParseError.InvalidOpcode, parseHeader(&buf, MAX_PAYLOAD));
}
