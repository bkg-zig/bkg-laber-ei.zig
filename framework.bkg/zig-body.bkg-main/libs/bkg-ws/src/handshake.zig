/// bkg-ws — WebSocket HTTP Upgrade Handshake (RFC 6455)
///
/// Nutzt ausschließlich std:
///   - std.crypto.hash.Sha1  für SHA-1
///   - std.base64             für Base64-Encoding
///
/// Fail-closed: Alle Fehlerszenarien geben einen Fehler zurück.
const std = @import("std");

/// WebSocket-GUID gemäß RFC 6455 §1.3
pub const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const HandshakeError = error{
    NotAWebSocketUpgrade,
    MissingConnectionUpgrade,
    MissingKey,
    InvalidVersion,
    WriteError,
};

// ── Hilfsfunktionen zur Header-Analyse ───────────────────────────────────────

/// Sucht `needle` case-insensitiv als Header-Zeilen-Substring.
/// Gibt `true` zurück, wenn der Header-Wert `value` in `head_buffer` vorkommt.
fn headerContains(head_buffer: []const u8, name: []const u8, value: []const u8) bool {
    var it = std.mem.splitScalar(u8, head_buffer, '\n');
    while (it.next()) |raw_line| {
        // Zeilenende bereinigen
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        // Header-Name + ":"
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = std.mem.trim(u8, line[0..colon], " ");
        const hval  = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(hname, name) and
            std.ascii.indexOfIgnoreCase(hval, value) != null)
        {
            return true;
        }
    }
    return false;
}

/// Extrahiert den Wert eines Headers (erste Übereinstimmung, case-insensitiv).
/// Gibt `null` zurück wenn der Header fehlt.
fn extractHeader(head_buffer: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, head_buffer, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = std.mem.trim(u8, line[0..colon], " ");
        const hval  = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(hname, name)) {
            return hval;
        }
    }
    return null;
}

// ── Öffentliche API ───────────────────────────────────────────────────────────

/// Prüft ob der Request ein WebSocket-Upgrade ist.
/// Erwartet `Connection: Upgrade` und `Upgrade: websocket` (case-insensitiv).
pub fn isUpgradeRequest(head_buffer: []const u8) bool {
    return headerContains(head_buffer, "Connection", "Upgrade") and
           headerContains(head_buffer, "Upgrade",    "websocket");
}

/// Extrahiert den `Sec-WebSocket-Key`-Header-Wert.
/// Gibt `null` zurück wenn der Header fehlt.
pub fn extractKey(head_buffer: []const u8) ?[]const u8 {
    return extractHeader(head_buffer, "Sec-WebSocket-Key");
}

/// Extrahiert die `Sec-WebSocket-Version` als `u16`.
/// Gibt `null` zurück wenn der Header fehlt oder nicht parsebar ist.
pub fn extractVersion(head_buffer: []const u8) ?u16 {
    const val = extractHeader(head_buffer, "Sec-WebSocket-Version") orelse return null;
    return std.fmt.parseInt(u16, val, 10) catch null;
}

/// Berechnet den `Sec-WebSocket-Accept`-Wert:
///   Base64( SHA-1( key + GUID ) ) → 28 ASCII-Bytes
///
/// `out` muss genau 28 Bytes groß sein.
pub fn computeAccept(key: []const u8, out: *[28]u8) void {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(GUID);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    h.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// Schreibt die `101 Switching Protocols`-Antwort in `writer`.
/// `writer` ist `anytype` (kompatibel mit std.io.Writer und std.Io.Writer).
pub fn writeUpgradeResponse(writer: anytype, accept: *const [28]u8) !void {
    try writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeAll("Upgrade: websocket\r\n");
    try writer.writeAll("Connection: Upgrade\r\n");
    try writer.writeAll("Sec-WebSocket-Accept: ");
    try writer.writeAll(accept);
    try writer.writeAll("\r\n\r\n");
}

/// Führt eine vollständige Handshake-Validierung durch.
/// Gibt den Key zurück oder einen Fehler wenn etwas fehlt/falsch ist.
pub fn validateHandshake(head_buffer: []const u8) HandshakeError![]const u8 {
    if (!headerContains(head_buffer, "Upgrade", "websocket"))
        return HandshakeError.NotAWebSocketUpgrade;
    if (!headerContains(head_buffer, "Connection", "Upgrade"))
        return HandshakeError.MissingConnectionUpgrade;
    const key = extractKey(head_buffer) orelse return HandshakeError.MissingKey;
    const ver = extractVersion(head_buffer) orelse return HandshakeError.InvalidVersion;
    if (ver != 13) return HandshakeError.InvalidVersion;
    return key;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "computeAccept — RFC-6455-Beispielwert" {
    var out: [28]u8 = undefined;
    computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}

test "isUpgradeRequest — korrekter Header" {
    const head =
        "GET /ws HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    try testing.expect(isUpgradeRequest(head));
}

test "isUpgradeRequest — fehlende Upgrade-Header" {
    const head =
        "GET /ws HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";
    try testing.expect(!isUpgradeRequest(head));
}

test "extractKey — vorhandener Key" {
    const head =
        "GET /ws HTTP/1.1\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "\r\n";
    const key = extractKey(head);
    try testing.expect(key != null);
    try testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", key.?);
}

test "extractKey — kein Key" {
    const head = "GET /ws HTTP/1.1\r\nHost: example.com\r\n\r\n";
    try testing.expectEqual(@as(?[]const u8, null), extractKey(head));
}

test "extractVersion — Version 13" {
    const head = "Sec-WebSocket-Version: 13\r\n\r\n";
    try testing.expectEqual(@as(?u16, 13), extractVersion(head));
}

test "extractVersion — Version 8 (nicht 13)" {
    const head = "Sec-WebSocket-Version: 8\r\n\r\n";
    try testing.expectEqual(@as(?u16, 8), extractVersion(head));
}

test "extractVersion — kein Header" {
    const head = "Host: example.com\r\n\r\n";
    try testing.expectEqual(@as(?u16, null), extractVersion(head));
}

test "writeUpgradeResponse — korrekte 101-Antwort" {
    var out_buf: [256]u8 = undefined;
    @memset(&out_buf, 0);
    var writer = std.Io.Writer.fixed(&out_buf);
    var accept: [28]u8 = undefined;
    computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &accept);
    try writeUpgradeResponse(&writer, &accept);
    const written = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, written, "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, written, "Sec-WebSocket-Accept: ") != null);
    try testing.expect(std.mem.indexOf(u8, written, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
}

test "validateHandshake — fehlende Upgrade-Header" {
    const head = "Connection: keep-alive\r\n\r\n";
    try testing.expectError(HandshakeError.NotAWebSocketUpgrade, validateHandshake(head));
}

test "validateHandshake — fehlende Connection-Header" {
    const head = "Upgrade: websocket\r\n\r\n";
    try testing.expectError(HandshakeError.MissingConnectionUpgrade, validateHandshake(head));
}

test "validateHandshake — fehlender Key" {
    const head =
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    try testing.expectError(HandshakeError.MissingKey, validateHandshake(head));
}

test "validateHandshake — Version != 13" {
    const head =
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: abc123\r\n" ++
        "Sec-WebSocket-Version: 8\r\n" ++
        "\r\n";
    try testing.expectError(HandshakeError.InvalidVersion, validateHandshake(head));
}
