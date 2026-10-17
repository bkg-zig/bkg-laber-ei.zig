// bkg-docker/client.zig — Docker Unix-Socket HTTP-Client (Library-Version)
//
// Wiederverwendbare Library, aus bkg-flocker.zig herausgezogen.
// Kommuniziert direkt mit dem Docker-Daemon über /var/run/docker.sock.
//
// API:
//   Client.init(allocator, socket_path) → Client
//   client.get(io, path)               → Error!Response
//   client.post(io, path, body)        → Error!Response
//   client.delete(io, path)            → Error!Response
//
// Zig 0.16:
//   - std.Io.net.UnixAddress.connect(io) statt std.posix.socket
//   - std.ArrayList(u8).empty statt .init()
//   - appendRemaining für vollständiges Lesen
const std = @import("std");

const MAX_RESPONSE: usize = 16 * 1024 * 1024; // 16 MiB

pub const Error = error{
    SocketPathTooLong,
    ConnectFailed,
    SendFailed,
    ReceiveFailed,
    ResponseTooLarge,
    InvalidResponse,
    OutOfMemory,
};

/// HTTP-Antwort: Status-Code und Body (allokiert, Aufrufer befreit via deinit).
pub const Response = struct {
    status:    u16,
    body:      []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Response) void {
        self.allocator.free(self.body);
    }

    pub fn ok(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

/// Docker HTTP-Client gebunden an einen Unix-Socket-Pfad.
pub const Client = struct {
    socket_path: []const u8,
    allocator:   std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) Client {
        return .{ .allocator = allocator, .socket_path = socket_path };
    }

    // ── Öffentliche API ──────────────────────────────────────────────────────

    pub fn get(c: Client, io: std.Io, path: []const u8) Error!Response {
        return c.request(io, "GET", path, null);
    }

    pub fn post(c: Client, io: std.Io, path: []const u8, body: ?[]const u8) Error!Response {
        return c.request(io, "POST", path, body);
    }

    pub fn delete(c: Client, io: std.Io, path: []const u8) Error!Response {
        return c.request(io, "DELETE", path, null);
    }

    // ── Interna ──────────────────────────────────────────────────────────────

    fn request(
        c:      Client,
        io:     std.Io,
        method: []const u8,
        path:   []const u8,
        body:   ?[]const u8,
    ) Error!Response {
        // ── 1. Unix-Socket verbinden ─────────────────────────────────────────
        const addr = std.Io.net.UnixAddress.init(c.socket_path) catch
            return error.SocketPathTooLong;
        const stream = addr.connect(io) catch
            return error.ConnectFailed;
        defer stream.close(io);

        // ── 2. HTTP-Request serialisieren ────────────────────────────────────
        const body_len = if (body) |b| b.len else 0;
        const req_alloc_size = 512 + body_len;
        const req_buf = c.allocator.alloc(u8, req_alloc_size) catch return error.OutOfMemory;
        defer c.allocator.free(req_buf);

        var req_len: usize = 0;
        if (body) |b| {
            const hdr = std.fmt.bufPrint(
                req_buf,
                "{s} {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                .{ method, path, b.len },
            ) catch return error.OutOfMemory;
            if (hdr.len + b.len > req_alloc_size) return error.OutOfMemory;
            @memcpy(req_buf[hdr.len..][0..b.len], b);
            req_len = hdr.len + b.len;
        } else {
            const hdr = std.fmt.bufPrint(
                req_buf,
                "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
                .{ method, path },
            ) catch return error.OutOfMemory;
            req_len = hdr.len;
        }

        // ── 3. Senden ────────────────────────────────────────────────────────
        var out_write_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &out_write_buf);
        writer.interface.writeAll(req_buf[0..req_len]) catch return error.SendFailed;
        writer.interface.flush() catch return error.SendFailed;
        if (writer.err != null) return error.SendFailed;

        // ── 4. Empfangen ─────────────────────────────────────────────────────
        var in_read_buf: [4096]u8 = undefined;
        var net_reader = stream.reader(io, &in_read_buf);

        var raw = std.ArrayList(u8).empty;
        defer raw.deinit(c.allocator);

        net_reader.interface.appendRemaining(c.allocator, &raw, .limited(MAX_RESPONSE)) catch |err| switch (err) {
            error.StreamTooLong => return error.ResponseTooLarge,
            error.OutOfMemory  => return error.OutOfMemory,
            error.ReadFailed   => return error.ReceiveFailed,
        };
        if (net_reader.err != null) return error.ReceiveFailed;

        // ── 5. HTTP-Antwort parsen ────────────────────────────────────────────
        return parseResponse(c.allocator, raw.items);
    }

    pub fn parseResponse(allocator: std.mem.Allocator, raw: []const u8) Error!Response {
        // Header / Body trennen: CRLF CRLF
        const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse
            return error.InvalidResponse;
        const headers = raw[0..header_end];
        var body_slice = raw[header_end + 4 ..];

        // Status aus erster Zeile: "HTTP/1.1 200 OK"
        const status_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse headers.len;
        const status_line = headers[0..status_line_end];

        const sp1 = std.mem.indexOfScalar(u8, status_line, ' ') orelse
            return error.InvalidResponse;
        const after_version = status_line[sp1 + 1 ..];
        const sp2 = std.mem.indexOfScalar(u8, after_version, ' ') orelse after_version.len;
        const status_str = after_version[0..sp2];
        const status = std.fmt.parseInt(u16, status_str, 10) catch
            return error.InvalidResponse;

        // Chunked Transfer Encoding auflösen
        const is_chunked = containsHeaderValue(headers, "transfer-encoding", "chunked");
        const body_owned = if (is_chunked)
            try decodeChunked(allocator, body_slice)
        else blk: {
            if (contentLength(headers)) |cl| {
                if (cl < body_slice.len) body_slice = body_slice[0..cl];
            }
            break :blk allocator.dupe(u8, body_slice) catch return error.OutOfMemory;
        };

        return Response{
            .status    = status,
            .body      = body_owned,
            .allocator = allocator,
        };
    }
};

// ── Hilfsfunktionen ───────────────────────────────────────────────────────────

pub fn containsHeaderValue(headers: []const u8, name: []const u8, value: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next(); // Status-Line überspringen
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = std.mem.trim(u8, line[0..colon], " ");
        const hval  = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(hname, name) and
            std.ascii.eqlIgnoreCase(hval, value)) return true;
    }
    return false;
}

pub fn contentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = std.mem.trim(u8, line[0..colon], " ");
        if (!std.ascii.eqlIgnoreCase(hname, "content-length")) continue;
        const hval = std.mem.trim(u8, line[colon + 1 ..], " ");
        return std.fmt.parseInt(usize, hval, 10) catch null;
    }
    return null;
}

/// Dekodiert einen Chunked-Transfer-Encoding-Body.
pub fn decodeChunked(allocator: std.mem.Allocator, data: []const u8) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (pos < data.len) {
        const crlf = std.mem.indexOf(u8, data[pos..], "\r\n") orelse break;
        const size_str = data[pos .. pos + crlf];
        const semi = std.mem.indexOfScalar(u8, size_str, ';') orelse size_str.len;
        const chunk_size = std.fmt.parseInt(
            usize,
            std.mem.trim(u8, size_str[0..semi], " "),
            16,
        ) catch return error.InvalidResponse;
        pos += crlf + 2;
        if (chunk_size == 0) break;
        if (pos + chunk_size > data.len) return error.InvalidResponse;
        out.appendSlice(allocator, data[pos .. pos + chunk_size]) catch return error.OutOfMemory;
        pos += chunk_size + 2;
    }

    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parseResponse – 200 mit JSON-Body" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]";
    const resp = try Client.parseResponse(std.testing.allocator, raw);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("[]", resp.body);
}

test "parseResponse – 204 kein Body" {
    const raw = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n";
    const resp = try Client.parseResponse(std.testing.allocator, raw);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 204), resp.status);
    try std.testing.expectEqual(@as(usize, 0), resp.body.len);
}

test "parseResponse – chunked Body" {
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\nhello\r\n" ++
        "6\r\n world\r\n" ++
        "0\r\n\r\n";
    const resp = try Client.parseResponse(std.testing.allocator, raw);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("hello world", resp.body);
}

test "decodeChunked – einfacher Fall" {
    const data = "4\r\ntest\r\n0\r\n\r\n";
    const result = try decodeChunked(std.testing.allocator, data);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("test", result);
}

test "containsHeaderValue – case-insensitive" {
    const headers = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked";
    try std.testing.expect(containsHeaderValue(headers, "transfer-encoding", "chunked"));
    try std.testing.expect(!containsHeaderValue(headers, "content-type", "json"));
}
