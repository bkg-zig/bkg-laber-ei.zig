/// bkg-ws — WebSocket Lifecycle (RFC 6455)
///
/// Verbindet handshake.zig + frame.zig mit I/O.
///
/// Design:
///   - `WebSocket` ist ein generischer Struct über Reader/Writer-Typen
///   - `accept()` führt HTTP-Upgrade durch und gibt WebSocket zurück
///   - `recv()` liest einen Frame, allokiert Payload — Aufrufer ist für free() verantwortlich
///   - `sendText/sendBinary/ping/pong/close` schreiben Server-Frames (unmaskiert)
///
/// Ownership:
///   - Nach accept() gehört der Stream dem WebSocket
///   - recv() allokiert payload mit self.allocator — Aufrufer muss free() aufrufen
const std = @import("std");
const handshake = @import("handshake.zig");
const frame     = @import("frame.zig");

// ── Fehlermengen ──────────────────────────────────────────────────────────────

pub const AcceptError = error{
    NotAWebSocketUpgrade,
    MissingConnectionUpgrade,
    MissingKey,
    InvalidVersion,
    WriteError,
} || error{OutOfMemory};

pub const RecvError = error{
    ConnectionClosed,
    FrameError,
    InvalidCloseReason,
    OutOfMemory,
} || frame.ParseError;

pub const SendError = error{
    WriteError,
};

// ── Optionen ──────────────────────────────────────────────────────────────────

pub const AcceptOptions = struct {
    /// Maximale Payload-Länge in Bytes (Standard: frame.MAX_PAYLOAD)
    max_payload: usize = frame.MAX_PAYLOAD,
};

// ── Frame ─────────────────────────────────────────────────────────────────────

/// Ein empfangener WebSocket-Frame.
/// `payload` ist allokiert — der Aufrufer muss `allocator.free(frame.payload)` aufrufen.
pub const ReceivedFrame = struct {
    opcode:  frame.Opcode,
    fin:     bool,
    payload: []u8,    // allokiert, Aufrufer ruft allocator.free() auf
};

// ── WebSocket ─────────────────────────────────────────────────────────────────

/// Generischer WebSocket-Struct über Reader/Writer-Typen.
/// `ReaderType` und `WriterType` müssen `readAll([]u8)` bzw. `writeAll([]const u8)`
/// und `writeByte(u8)` bereitstellen (std.io.Reader / std.io.Writer-Kompatibel).
pub fn WebSocket(comptime ReaderType: type, comptime WriterType: type) type {
    return struct {
        const Self = @This();

        allocator:   std.mem.Allocator,
        reader:      ReaderType,
        writer:      WriterType,
        max_payload: usize,

        // ── accept ────────────────────────────────────────────────────────────

        /// Führt den HTTP-Upgrade-Handshake durch.
        /// `head_buffer`: der bereits gelesene HTTP-Header-Puffer.
        /// Schreibt 101-Response, gibt WebSocket zurück.
        pub fn accept(
            allocator:   std.mem.Allocator,
            head_buffer: []const u8,
            reader:      ReaderType,
            writer:      WriterType,
            options:     AcceptOptions,
        ) AcceptError!Self {
            // Handshake validieren
            const key = handshake.validateHandshake(head_buffer) catch |err| switch (err) {
                handshake.HandshakeError.NotAWebSocketUpgrade    => return AcceptError.NotAWebSocketUpgrade,
                handshake.HandshakeError.MissingConnectionUpgrade => return AcceptError.MissingConnectionUpgrade,
                handshake.HandshakeError.MissingKey              => return AcceptError.MissingKey,
                handshake.HandshakeError.InvalidVersion          => return AcceptError.InvalidVersion,
                handshake.HandshakeError.WriteError              => return AcceptError.WriteError,
            };

            // Accept-Wert berechnen und 101-Response senden
            var accept_val: [28]u8 = undefined;
            handshake.computeAccept(key, &accept_val);
            handshake.writeUpgradeResponse(writer, &accept_val) catch return AcceptError.WriteError;

            return Self{
                .allocator   = allocator,
                .reader      = reader,
                .writer      = writer,
                .max_payload = options.max_payload,
            };
        }

        // ── recv ──────────────────────────────────────────────────────────────

        /// Liest den nächsten WebSocket-Frame.
        /// Allokiert `payload` mit `self.allocator` — Aufrufer muss `allocator.free(result.payload)` aufrufen.
        pub fn recv(self: *Self) RecvError!ReceivedFrame {
            // Mindest-Header einlesen: 2 Bytes + bis zu 8 Ext-Bytes + 4 Mask = max 14 Bytes
            var header_buf: [14]u8 = undefined;

            // Erste 2 Bytes lesen
            self.reader.readSliceAll(header_buf[0..2]) catch return RecvError.ConnectionClosed;

            const b1_raw = header_buf[1];
            const len7: u64 = b1_raw & 0x7F;
            // Ext-Bytes bestimmen
            const ext_len: usize = switch (len7) {
                126 => 2,
                127 => 8,
                else => 0,
            };

            if (ext_len > 0) {
                self.reader.readSliceAll(header_buf[2..2 + ext_len]) catch return RecvError.ConnectionClosed;
            }
            // Mask-Key lesen
            const mask_offset = 2 + ext_len;
            self.reader.readSliceAll(header_buf[mask_offset..mask_offset + 4]) catch return RecvError.ConnectionClosed;

            const header_total = mask_offset + 4;
            const hdr = frame.parseHeader(header_buf[0..header_total], self.max_payload) catch |err| {
                return @as(RecvError, switch (err) {
                    frame.ParseError.InvalidRsv             => RecvError.InvalidRsv,
                    frame.ParseError.UnmaskedClientFrame    => RecvError.UnmaskedClientFrame,
                    frame.ParseError.FragmentedControlFrame => RecvError.FragmentedControlFrame,
                    frame.ParseError.ControlPayloadTooLarge => RecvError.ControlPayloadTooLarge,
                    frame.ParseError.PayloadTooLarge        => RecvError.PayloadTooLarge,
                    frame.ParseError.InvalidOpcode          => RecvError.InvalidOpcode,
                    frame.ParseError.InvalidClosePayload    => RecvError.InvalidClosePayload,
                    frame.ParseError.InvalidUtf8CloseReason => RecvError.InvalidUtf8CloseReason,
                    frame.ParseError.Truncated              => RecvError.Truncated,
                });
            };

            // Payload allokieren und lesen
            const payload_len: usize = @intCast(hdr.payload_len);
            const payload = try self.allocator.alloc(u8, payload_len);
            errdefer self.allocator.free(payload);

            if (payload_len > 0) {
                self.reader.readSliceAll(payload) catch {
                    self.allocator.free(payload);
                    return RecvError.ConnectionClosed;
                };
                // Unmaskieren
                frame.unmask(payload, hdr.mask_key);
            }

            // Close-Frame: Reason-UTF-8 prüfen
            if (hdr.opcode == .connection_close and payload_len > 2) {
                if (!std.unicode.utf8ValidateSlice(payload[2..])) {
                    self.allocator.free(payload);
                    return RecvError.InvalidCloseReason;
                }
            }

            return ReceivedFrame{
                .opcode  = hdr.opcode,
                .fin     = hdr.fin,
                .payload = payload,
            };
        }

        // ── Sende-Funktionen ──────────────────────────────────────────────────

        fn sendFrame(self: *Self, op: frame.Opcode, data: []const u8) SendError!void {
            var hdr_buf: [10]u8 = undefined;
            const hdr_len = frame.encodeHeader(&hdr_buf, true, op, data.len);
            self.writer.writeAll(hdr_buf[0..hdr_len]) catch return SendError.WriteError;
            self.writer.writeAll(data) catch return SendError.WriteError;
        }

        pub fn sendText(self: *Self, data: []const u8) SendError!void {
            return self.sendFrame(.text, data);
        }

        pub fn sendBinary(self: *Self, data: []const u8) SendError!void {
            return self.sendFrame(.binary, data);
        }

        pub fn ping(self: *Self, data: []const u8) SendError!void {
            return self.sendFrame(.ping, data);
        }

        pub fn pong(self: *Self, data: []const u8) SendError!void {
            return self.sendFrame(.pong, data);
        }

        /// Sendet einen Close-Frame mit Statuscode und optionalem Reason.
        pub fn close(self: *Self, code: u16, reason: []const u8) SendError!void {
            const payload_len = 2 + reason.len;
            var buf: [127]u8 = undefined; // max Close-Payload: 125 Bytes
            if (payload_len > buf.len) {
                // Reason kürzen
                std.mem.writeInt(u16, buf[0..2], code, .big);
                const max_reason = buf.len - 2;
                @memcpy(buf[2..2 + max_reason], reason[0..max_reason]);
                return self.sendFrame(.connection_close, buf[0..buf.len]);
            }
            std.mem.writeInt(u16, buf[0..2], code, .big);
            @memcpy(buf[2..2 + reason.len], reason);
            return self.sendFrame(.connection_close, buf[0..payload_len]);
        }
    };
}

/// Komfort-Funktion: Erzeugt einen WebSocket mit std.io-Reader/Writer.
pub fn makeWebSocket(
    comptime ReaderType: type,
    comptime WriterType: type,
    allocator: std.mem.Allocator,
    head_buffer: []const u8,
    reader: ReaderType,
    writer: WriterType,
    options: AcceptOptions,
) AcceptError!WebSocket(ReaderType, WriterType) {
    return WebSocket(ReaderType, WriterType).accept(
        allocator, head_buffer, reader, writer, options,
    );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Hilfsfunktion: Baut einen maskierten Client-Frame in einen Buffer.
fn buildMaskedFrame(
    buf:        []u8,
    fin:        bool,
    op:         u4,
    mask_key:   [4]u8,
    payload:    []const u8,
) usize {
    buf[0] = (@as(u8, if (fin) 0x80 else 0x00)) | @as(u8, op);
    var pos: usize = 2;
    const plen = payload.len;
    if (plen < 126) {
        buf[1] = 0x80 | @as(u8, @intCast(plen));
    } else if (plen < 65536) {
        buf[1] = 0x80 | 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(plen), .big);
        pos = 4;
    } else {
        buf[1] = 0x80 | 127;
        std.mem.writeInt(u64, buf[2..10], @intCast(plen), .big);
        pos = 10;
    }
    buf[pos..][0..4].* = mask_key;
    pos += 4;
    for (payload, 0..) |b, i| buf[pos + i] = b ^ mask_key[i % 4];
    return pos + plen;
}

test "WebSocket accept + recv Text-Frame" {
    const head =
        "GET /ws HTTP/1.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    const msg = "Hello BKG";
    var client_frame_buf: [32]u8 = undefined;
    const mask_key = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    const frame_len = buildMaskedFrame(&client_frame_buf, true, 1, mask_key, msg);

    // Handshake-Response landet in einem Out-Buffer
    var out_buf: [256]u8 = undefined;
    @memset(&out_buf, 0);
    var out_writer = std.Io.Writer.fixed(&out_buf);

    // Eingehende Daten: nur der Frame (Handshake wurde bereits gelesen)
    var in_reader = std.Io.Reader.fixed(client_frame_buf[0..frame_len]);

    const WS = WebSocket(
        @TypeOf(&in_reader),
        @TypeOf(&out_writer),
    );
    var ws = try WS.accept(
        testing.allocator,
        head,
        &in_reader,
        &out_writer,
        .{},
    );

    // Prüfen dass 101 in der Antwort steht
    const resp = out_writer.buffered();
    try testing.expect(std.mem.indexOf(u8, resp, "101") != null);

    // Frame lesen
    const f = try ws.recv();
    defer testing.allocator.free(f.payload);
    try testing.expectEqual(frame.Opcode.text, f.opcode);
    try testing.expect(f.fin);
    try testing.expectEqualStrings(msg, f.payload);
}

test "WebSocket sendText erzeugt korrekten Server-Frame" {
    var in_buf: [1]u8 = undefined;
    @memset(&in_buf, 0);
    var in_reader = std.Io.Reader.fixed(&in_buf);

    var out_buf: [256]u8 = undefined;
    @memset(&out_buf, 0);
    var out_writer = std.Io.Writer.fixed(&out_buf);

    const WS = WebSocket(
        @TypeOf(&in_reader),
        @TypeOf(&out_writer),
    );
    var ws = WS{
        .allocator   = testing.allocator,
        .reader      = &in_reader,
        .writer      = &out_writer,
        .max_payload = frame.MAX_PAYLOAD,
    };

    try ws.sendText("Hi");
    const written = out_writer.buffered();
    try testing.expectEqual(@as(u8, 0x81), written[0]); // FIN + text
    try testing.expectEqual(@as(u8, 2), written[1]);     // len=2, kein MASK
    try testing.expectEqualStrings("Hi", written[2..4]);
}

test "WebSocket close erzeugt korrekten Close-Frame" {
    var in_buf: [1]u8 = undefined;
    @memset(&in_buf, 0);
    var in_reader = std.Io.Reader.fixed(&in_buf);

    var out_buf: [256]u8 = undefined;
    @memset(&out_buf, 0);
    var out_writer = std.Io.Writer.fixed(&out_buf);

    const WS = WebSocket(
        @TypeOf(&in_reader),
        @TypeOf(&out_writer),
    );
    var ws = WS{
        .allocator   = testing.allocator,
        .reader      = &in_reader,
        .writer      = &out_writer,
        .max_payload = frame.MAX_PAYLOAD,
    };

    try ws.close(1000, "Normal");
    const written = out_writer.buffered();
    try testing.expectEqual(@as(u8, 0x88), written[0]); // FIN + close(8)
    const code = std.mem.readInt(u16, written[2..4], .big);
    try testing.expectEqual(@as(u16, 1000), code);
    try testing.expectEqualStrings("Normal", written[4..10]);
}
