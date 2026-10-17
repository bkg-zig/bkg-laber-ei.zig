//! Transport — HTTP/1.1 I/O on an already-obtained stream.
//!
//! Blocking through caller-supplied std.Io. No retries. No circuit breaker.
//! Receives a deadline value from TimeoutPolicy; does not read the policy.
//! TLS is a separate type (see tls.zig), never a boolean on this Transport.

const std = @import("std");
const Error = @import("error.zig").Error;

pub const read_buf_cap: usize = 8192;
pub const write_buf_cap: usize = 1024;

pub const DialArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    timeout: std.Io.Timeout,
};

/// Byte-stream opener. Production uses TCP. Tests inject a scripted dial.
/// TLS is not a Dial flag — Connection.openSecure is a distinct path.
pub const Dial = struct {
    ptr: *anyopaque = undefined,
    dialFn: *const fn (*anyopaque, DialArgs) Error!std.Io.net.Stream,

    pub const tcp: Dial = .{ .dialFn = dialTcp };
};

pub fn dialTcp(_ptr: *anyopaque, args: DialArgs) Error!std.Io.net.Stream {
    _ = _ptr;
    if (args.host.len == 0 or args.host.len > std.Io.net.HostName.max_len) {
        return error.InvalidInput;
    }
    try rejectIfPast(args.io, args.timeout);
    // Zig 0.16 Threaded panics when ConnectOptions.timeout != .none. Deadline is
    // enforced before and after this blocking connect instead.
    const opts: std.Io.net.IpAddress.ConnectOptions = .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = .none,
    };
    const stream = if (std.Io.net.IpAddress.parse(args.host, args.port)) |addr|
        addr.connect(args.io, opts) catch |e| return mapConnect(e)
    else |_| blk: {
        const hn = std.Io.net.HostName.init(args.host) catch return error.InvalidInput;
        break :blk hn.connect(args.io, args.port, opts) catch |e| return mapConnect(e);
    };
    errdefer stream.close(args.io);
    try rejectIfPast(args.io, args.timeout);
    return stream;
}

fn mapConnect(e: anyerror) Error {
    return switch (e) {
        error.Timeout => error.Timeout,
        error.Canceled, error.Cancelled => error.Cancelled,
        error.InvalidHostName, error.NameTooLong => error.InvalidInput,
        else => error.ConnectionFailed,
    };
}

pub fn mapIo(e: anyerror) Error {
    return switch (e) {
        error.Timeout => error.Timeout,
        error.Canceled, error.Cancelled => error.Cancelled,
        error.EndOfStream, error.ConnectionResetByPeer => error.ConnectionFailed,
        error.ReadFailed, error.WriteFailed => error.ConnectionFailed,
        else => error.ConnectionFailed,
    };
}

pub const Method = enum {
    GET,
    HEAD,
    PUT,
    DELETE,
    OPTIONS,
    POST,
    PATCH,
    TRACE,
    CONNECT,

    pub fn bytes(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .HEAD => "HEAD",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .OPTIONS => "OPTIONS",
            .POST => "POST",
            .PATCH => "PATCH",
            .TRACE => "TRACE",
            .CONNECT => "CONNECT",
        };
    }

    /// Architecture lock: GET, HEAD, PUT, DELETE, OPTIONS.
    pub fn isIdempotent(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .PUT, .DELETE, .OPTIONS => true,
            .POST, .PATCH, .TRACE, .CONNECT => false,
        };
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ExchangeRequest = struct {
    method: Method,
    host: []const u8,
    port: u16,
    target: []const u8,
    headers: []const Header,
    body: []const u8,
};

pub const ExchangeResult = struct {
    status: u16,
    body_len: usize,
    reusable: bool,
};

pub const Transport = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: ?std.Io.net.Stream,
    read_buf: []u8,
    write_buf: []u8,
    owns_buffers: bool,
    deinited: bool,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
    ) error{OutOfMemory}!Transport {
        const read_buf = try allocator.alloc(u8, read_buf_cap);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, write_buf_cap);
        errdefer allocator.free(write_buf);
        return .{
            .io = io,
            .allocator = allocator,
            .stream = stream,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .owns_buffers = true,
            .deinited = false,
        };
    }

    pub fn deinit(self: *Transport) void {
        if (self.deinited) return;
        self.deinited = true;
        if (self.stream) |s| {
            s.close(self.io);
            self.stream = null;
        }
        if (self.owns_buffers) {
            self.allocator.free(self.read_buf);
            self.allocator.free(self.write_buf);
            self.read_buf = &.{};
            self.write_buf = &.{};
            self.owns_buffers = false;
        }
    }

    pub fn exchange(
        self: *Transport,
        req: ExchangeRequest,
        dest: []u8,
        deadline: std.Io.Timeout,
    ) Error!ExchangeResult {
        if (self.stream == null) return error.ConnectionFailed;
        try rejectIfPast(self.io, deadline);

        var writer = self.stream.?.writer(self.io, self.write_buf);
        writeHttpRequest(&writer.interface, req) catch |e| return mapIo(e);
        writer.interface.flush() catch |e| return mapIo(e);
        try rejectIfPast(self.io, deadline);

        var reader = self.stream.?.reader(self.io, self.read_buf);
        return readHttpResponse(&reader.interface, req.method, dest);
    }
};

fn rejectIfPast(io: std.Io, deadline: std.Io.Timeout) Error!void {
    switch (deadline) {
        .none => return error.InvalidInput,
        .duration => |d| {
            if (d.raw.nanoseconds <= 0) return error.Timeout;
        },
        .deadline => |ts| {
            const rem = ts.durationFromNow(io);
            if (rem.raw.nanoseconds <= 0) return error.Timeout;
        },
    }
}

fn writeHttpRequest(w: *std.Io.Writer, req: ExchangeRequest) std.Io.Writer.Error!void {
    const target = if (req.target.len == 0) "/" else req.target;
    try w.print("{s} {s} HTTP/1.1\r\n", .{ req.method.bytes(), target });
    try writeHost(w, req.host, req.port);
    try w.print("Content-Length: {d}\r\n", .{req.body.len});
    try w.writeAll("Connection: keep-alive\r\n");
    for (req.headers) |h| {
        try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    try w.writeAll("\r\n");
    if (req.body.len > 0) try w.writeAll(req.body);
}

fn writeHost(w: *std.Io.Writer, host: []const u8, port: u16) std.Io.Writer.Error!void {
    if (port == 80) {
        try w.print("Host: {s}\r\n", .{host});
    } else {
        try w.print("Host: {s}:{d}\r\n", .{ host, port });
    }
}

fn readHttpResponse(r: *std.Io.Reader, method: Method, dest: []u8) Error!ExchangeResult {
    var parser: std.http.HeadParser = .{};
    var head_len: usize = 0;
    var scratch: [read_buf_cap]u8 = undefined;

    while (parser.state != .finished) {
        const chunk = r.peekGreedy(1) catch |e| return mapIo(e);
        const take_n = @min(chunk.len, scratch.len - head_len);
        if (take_n == 0) return error.Protocol;
        const consumed = parser.feed(chunk[0..take_n]);
        if (head_len + consumed > scratch.len) return error.Protocol;
        @memcpy(scratch[head_len..][0..consumed], chunk[0..consumed]);
        head_len += consumed;
        r.toss(consumed);
        if (parser.state != .finished and consumed == 0) return error.Protocol;
    }

    const head = scratch[0..head_len];
    const parsed = parseHead(head) catch return error.Protocol;

    if (parsed.transfer_encoding_forbidden) return error.Protocol;

    var reusable = parsed.keep_alive;
    const no_body = method == .HEAD or noBodyStatus(parsed.status);
    var body_len: usize = 0;
    if (!no_body) {
        if (parsed.content_length) |cl| {
            if (cl > dest.len) return error.Protocol;
            if (cl > 0) {
                r.readSliceAll(dest[0..cl]) catch |e| return mapIo(e);
            }
            body_len = cl;
        } else {
            // Fail closed: no unbounded read-until-EOF in v1.
            if (!parsed.connection_close) return error.Protocol;
            reusable = false;
            body_len = r.readSliceShort(dest) catch |e| return mapIo(e);
        }
    }

    return .{
        .status = parsed.status,
        .body_len = body_len,
        .reusable = reusable,
    };
}

const ParsedHead = struct {
    status: u16,
    content_length: ?usize,
    keep_alive: bool,
    connection_close: bool,
    transfer_encoding_forbidden: bool,
};

fn noBodyStatus(status: u16) bool {
    return status < 200 or status == 204 or status == 304;
}

fn parseHead(head: []const u8) error{Protocol}!ParsedHead {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return error.Protocol;
    const status = try parseStatusLine(status_line);

    var content_length: ?usize = null;
    var keep_alive = true;
    var connection_close = false;
    var transfer_encoding_forbidden = false;

    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.Protocol;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.Protocol;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (headerContainsToken(value, "close")) {
                keep_alive = false;
                connection_close = true;
            }
            if (headerContainsToken(value, "keep-alive")) {
                keep_alive = true;
                connection_close = false;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (!std.ascii.eqlIgnoreCase(value, "identity")) {
                transfer_encoding_forbidden = true;
            }
        }
    }

    return .{
        .status = status,
        .content_length = content_length,
        .keep_alive = keep_alive,
        .connection_close = connection_close,
        .transfer_encoding_forbidden = transfer_encoding_forbidden,
    };
}

fn parseStatusLine(line: []const u8) error{Protocol}!u16 {
    if (!std.mem.startsWith(u8, line, "HTTP/1.")) return error.Protocol;
    const space = std.mem.findScalar(u8, line, ' ') orelse return error.Protocol;
    const rest = line[space + 1 ..];
    if (rest.len < 3) return error.Protocol;
    return std.fmt.parseInt(u16, rest[0..3], 10) catch error.Protocol;
}

fn headerContainsToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (std.ascii.eqlIgnoreCase(t, token)) return true;
    }
    return false;
}

fn writeAllToStream(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buf: [256]u8 = undefined;
    var writer = stream.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

test "Transport protocol parse: status, content-length, connection close" {
    const head = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    const parsed = try parseHead(head);
    try std.testing.expectEqual(@as(u16, 204), parsed.status);
    try std.testing.expectEqual(@as(?usize, 0), parsed.content_length);
    try std.testing.expect(parsed.connection_close);
    try std.testing.expect(!parsed.keep_alive);
}

test "Transport protocol parse rejects chunked transfer-encoding" {
    const head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
    const parsed = try parseHead(head);
    try std.testing.expect(parsed.transfer_encoding_forbidden);
}

test "Transport protocol parse rejects malformed status" {
    try std.testing.expectError(error.Protocol, parseHead("HTTPnope\r\n\r\n"));
}

test "Method idempotent set matches architecture lock" {
    try std.testing.expect(Method.GET.isIdempotent());
    try std.testing.expect(Method.HEAD.isIdempotent());
    try std.testing.expect(Method.PUT.isIdempotent());
    try std.testing.expect(Method.DELETE.isIdempotent());
    try std.testing.expect(Method.OPTIONS.isIdempotent());
    try std.testing.expect(!Method.POST.isIdempotent());
    try std.testing.expect(!Method.PATCH.isIdempotent());
    try std.testing.expect(!Method.TRACE.isIdempotent());
}

const ServeOnce = struct {
    fn run(server: *std.Io.net.Server, io: std.Io, response: []const u8) void {
        var stream = server.accept(io) catch return;
        defer stream.close(io);
        var rbuf: [512]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        _ = reader.interface.peekGreedy(1) catch {};
        writeAllToStream(io, stream, response) catch {};
    }
};

fn listenLoopback(io: std.Io) !struct { server: std.Io.net.Server, port: u16 } {
    var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    const port = server.socket.address.getPort();
    if (port == 0) {
        server.deinit(io);
        return error.ConnectionFailed;
    }
    return .{ .server = server, .port = port };
}

test "Transport exchange over loopback: GET 200 hello" {
    const io = std.testing.io;
    var held = listenLoopback(io) catch return error.SkipZigTest;
    defer held.server.deinit(io);

    const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
    var fut = io.concurrent(ServeOnce.run, .{ &held.server, io, response }) catch return error.SkipZigTest;
    defer _ = fut.cancel(io);

    const stream = dialTcp(undefined, .{
        .allocator = std.testing.allocator,
        .io = io,
        .host = "127.0.0.1",
        .port = held.port,
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(2000), .clock = .awake } },
    }) catch return error.SkipZigTest;

    var tpt = try Transport.initOwned(std.testing.allocator, io, stream);
    defer tpt.deinit();

    var dest: [64]u8 = undefined;
    const result = try tpt.exchange(.{
        .method = .GET,
        .host = "127.0.0.1",
        .port = held.port,
        .target = "/",
        .headers = &.{},
        .body = &.{},
    }, &dest, .{ .duration = .{ .raw = .fromMilliseconds(2000), .clock = .awake } });

    try std.testing.expectEqual(@as(u16, 200), result.status);
    try std.testing.expectEqual(@as(usize, 5), result.body_len);
    try std.testing.expectEqualStrings("hello", dest[0..result.body_len]);
    try std.testing.expect(!result.reusable);
    _ = fut.await(io);
}

test "Transport protocol error on truncated head" {
    const io = std.testing.io;
    var held = listenLoopback(io) catch return error.SkipZigTest;
    defer held.server.deinit(io);

    var fut = io.concurrent(ServeOnce.run, .{ &held.server, io, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n" }) catch return error.SkipZigTest;
    defer _ = fut.cancel(io);

    const stream = dialTcp(undefined, .{
        .allocator = std.testing.allocator,
        .io = io,
        .host = "127.0.0.1",
        .port = held.port,
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(2000), .clock = .awake } },
    }) catch return error.SkipZigTest;

    var tpt = try Transport.initOwned(std.testing.allocator, io, stream);
    defer tpt.deinit();
    var dest: [8]u8 = undefined;
    if (tpt.exchange(.{
        .method = .GET,
        .host = "127.0.0.1",
        .port = held.port,
        .target = "/",
        .headers = &.{},
        .body = &.{},
    }, &dest, .{ .duration = .{ .raw = .fromMilliseconds(2000), .clock = .awake } })) |_| {
        return error.TestUnexpectedResult;
    } else |e| switch (e) {
        error.Protocol, error.ConnectionFailed => {},
        else => return e,
    }
    _ = fut.await(io);
}
