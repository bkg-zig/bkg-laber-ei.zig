// bkg-docker/demux.zig — Docker Multiplexed Stream Decoder
//
// Docker-Attach/Logs-Streams mit ?multiplexing=1 haben einen 8-Byte-Frame-Header:
//
//   Byte 0:     Stream-Typ  (0=stdin, 1=stdout, 2=stderr)
//   Bytes 1–3:  Padding (ignorieren)
//   Bytes 4–7:  Payload-Größe, big-endian uint32
//   Bytes 8+:   Payload
//
// Mehrere Frames folgen direkt aufeinander bis zum Ende der Daten.
//
// Referenz: https://docs.docker.com/engine/api/v1.44/#tag/Container/operation/ContainerAttach
const std = @import("std");

pub const StreamType = enum(u8) {
    stdin  = 0,
    stdout = 1,
    stderr = 2,
    _,
};

/// Einzelner dekodierter Frame.
pub const Frame = struct {
    stream_type: StreamType,
    /// Zeigt auf Daten innerhalb des Original-Buffers (kein eigenes Alloc).
    payload: []const u8,
};

/// Dekodiert alle Frames aus einem rohen Docker-Mux-Buffer.
/// Gibt ein Slice von Frames zurück — Payloads zeigen in `data`.
/// Aufrufer befreit den zurückgegebenen Slice via `allocator.free(frames)`.
pub fn decodeFrames(
    allocator: std.mem.Allocator,
    data: []const u8,
) error{OutOfMemory}![]Frame {
    var frames = std.ArrayList(Frame).empty;
    errdefer frames.deinit(allocator);

    var pos: usize = 0;
    while (pos + 8 <= data.len) {
        const stream_type: StreamType = @enumFromInt(data[pos]);
        // Bytes 1-3: Padding ignorieren
        const size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
        pos += 8;
        if (pos + size > data.len) break; // Trunkierter Frame → abbrechen
        try frames.append(allocator, Frame{
            .stream_type = stream_type,
            .payload     = data[pos .. pos + size],
        });
        pos += size;
    }

    return frames.toOwnedSlice(allocator);
}

/// Dekodiert einen Docker-Mux-Buffer und gibt nur stdout zurück (allokiert).
/// Aufrufer befreit via `allocator.free(result)`.
pub fn demux(
    allocator: std.mem.Allocator,
    data: []const u8,
) error{OutOfMemory}![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (pos + 8 <= data.len) {
        const stream_type: StreamType = @enumFromInt(data[pos]);
        const size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
        pos += 8;
        if (pos + size > data.len) break;
        if (stream_type == .stdout) {
            try out.appendSlice(allocator, data[pos .. pos + size]);
        }
        pos += size;
    }

    return out.toOwnedSlice(allocator);
}

/// Ergebnis von demuxSeparate: stdout und stderr getrennt allokiert.
pub const DemuxResult = struct {
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: DemuxResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Dekodiert einen Docker-Mux-Buffer und trennt stdout und stderr.
/// Aufrufer befreit via `result.deinit(allocator)`.
pub fn demuxSeparate(
    allocator: std.mem.Allocator,
    data: []const u8,
) error{OutOfMemory}!DemuxResult {
    var out_stdout = std.ArrayList(u8).empty;
    errdefer out_stdout.deinit(allocator);
    var out_stderr = std.ArrayList(u8).empty;
    errdefer out_stderr.deinit(allocator);

    var pos: usize = 0;
    while (pos + 8 <= data.len) {
        const stream_type: StreamType = @enumFromInt(data[pos]);
        const size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
        pos += 8;
        if (pos + size > data.len) break;
        switch (stream_type) {
            .stdout => try out_stdout.appendSlice(allocator, data[pos .. pos + size]),
            .stderr => try out_stderr.appendSlice(allocator, data[pos .. pos + size]),
            else    => {},
        }
        pos += size;
    }

    return DemuxResult{
        .stdout = try out_stdout.toOwnedSlice(allocator),
        .stderr = try out_stderr.toOwnedSlice(allocator),
    };
}

// ── Hilfsfunktion: Frame bauen (für Tests) ────────────────────────────────────

/// Erstellt einen einzelnen Docker-Mux-Frame (8-Byte-Header + Payload).
/// Aufrufer befreit via `allocator.free(result)`.
pub fn buildFrame(
    allocator: std.mem.Allocator,
    stream_type: StreamType,
    payload: []const u8,
) error{OutOfMemory}![]u8 {
    const frame = try allocator.alloc(u8, 8 + payload.len);
    frame[0] = @intFromEnum(stream_type);
    frame[1] = 0;
    frame[2] = 0;
    frame[3] = 0;
    std.mem.writeInt(u32, frame[4..8], @intCast(payload.len), .big);
    @memcpy(frame[8..], payload);
    return frame;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "demux – nur stdout extrahieren" {
    const alloc = std.testing.allocator;

    const stdout_frame = try buildFrame(alloc, .stdout, "hello");
    defer alloc.free(stdout_frame);
    const stderr_frame = try buildFrame(alloc, .stderr, "error");
    defer alloc.free(stderr_frame);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, stdout_frame);
    try buf.appendSlice(alloc, stderr_frame);

    const result = try demux(alloc, buf.items);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("hello", result);
}

test "demux – leerer Input gibt leeren Slice zurück" {
    const result = try demux(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "demuxSeparate – stdout und stderr getrennt" {
    const alloc = std.testing.allocator;

    const f1 = try buildFrame(alloc, .stdout, "out1");
    defer alloc.free(f1);
    const f2 = try buildFrame(alloc, .stderr, "err1");
    defer alloc.free(f2);
    const f3 = try buildFrame(alloc, .stdout, "out2");
    defer alloc.free(f3);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, f1);
    try buf.appendSlice(alloc, f2);
    try buf.appendSlice(alloc, f3);

    const res = try demuxSeparate(alloc, buf.items);
    defer res.deinit(alloc);

    try std.testing.expectEqualStrings("out1out2", res.stdout);
    try std.testing.expectEqualStrings("err1", res.stderr);
}

test "decodeFrames – Frame-Metadaten korrekt" {
    const alloc = std.testing.allocator;

    const f = try buildFrame(alloc, .stderr, "test");
    defer alloc.free(f);

    const frames = try decodeFrames(alloc, f);
    defer alloc.free(frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqual(StreamType.stderr, frames[0].stream_type);
    try std.testing.expectEqualStrings("test", frames[0].payload);
}

test "demux – trunkierter Frame wird ignoriert" {
    const alloc = std.testing.allocator;

    // Vollständiger Frame
    const f1 = try buildFrame(alloc, .stdout, "ok");
    defer alloc.free(f1);
    // Trunkierter Frame (Header sagt 100 Bytes, aber nur 3 folgen)
    var trunc: [8 + 3]u8 = undefined;
    trunc[0] = @intFromEnum(StreamType.stdout);
    trunc[1] = 0; trunc[2] = 0; trunc[3] = 0;
    std.mem.writeInt(u32, trunc[4..8], 100, .big);
    trunc[8] = 'x'; trunc[9] = 'y'; trunc[10] = 'z';

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, f1);
    try buf.appendSlice(alloc, &trunc);

    const result = try demux(alloc, buf.items);
    defer alloc.free(result);

    // Nur der vollständige Frame "ok" darf im Ergebnis sein
    try std.testing.expectEqualStrings("ok", result);
}

test "buildFrame – Header-Bytes korrekt" {
    const alloc = std.testing.allocator;
    const f = try buildFrame(alloc, .stdout, "ab");
    defer alloc.free(f);

    try std.testing.expectEqual(@as(u8, 1), f[0]); // stdout = 1
    try std.testing.expectEqual(@as(u8, 0), f[1]);
    try std.testing.expectEqual(@as(u8, 0), f[2]);
    try std.testing.expectEqual(@as(u8, 0), f[3]);
    // Größe big-endian: 0x00000002
    try std.testing.expectEqual(@as(u8, 0), f[4]);
    try std.testing.expectEqual(@as(u8, 0), f[5]);
    try std.testing.expectEqual(@as(u8, 0), f[6]);
    try std.testing.expectEqual(@as(u8, 2), f[7]);
    try std.testing.expectEqual(@as(u8, 'a'), f[8]);
    try std.testing.expectEqual(@as(u8, 'b'), f[9]);
}
