//! Client — request orchestration only.
//!
//! Does not speak HTTP bytes. Does not own sockets. Owns one Pool.
//! Composition order for one logical request (docs/BKG_HTTP_CLIENT_v1.md):
//!   CircuitBreaker → Pool → TimeoutPolicy deadline → Transport →
//!   RetryPolicy decide → CircuitBreaker record → Pool release.
//! RetryPolicy itself never sleeps or performs I/O; Client waits via std.Io
//! after releasing the connection.
//!
//! Distinct constructors: initCleartext vs initSecure. No optional TLS flag
//! that defaults off. v1 initSecure returns NotImplemented.

const std = @import("std");
const Error = @import("error.zig").Error;
const timeout_mod = @import("timeout.zig");
const retry_mod = @import("retry.zig");
const cb_mod = @import("circuit_breaker.zig");
const pool_mod = @import("pool.zig");
const transport_mod = @import("transport.zig");
const tls = @import("tls.zig");

pub const TimeoutPolicy = timeout_mod.TimeoutPolicy;
pub const RetryPolicy = retry_mod.RetryPolicy;
pub const CircuitBreaker = cb_mod.CircuitBreaker;
pub const Pool = pool_mod.Pool;
pub const Method = transport_mod.Method;
pub const Header = transport_mod.Header;
pub const Dial = transport_mod.Dial;

pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = &.{},
    /// Caller mark for a replay-safe POST/PATCH. Safe methods ignore this.
    idempotent: bool = false,
};

pub const Response = struct {
    status: u16,
    body_len: usize,
};

pub const InitCleartext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool_limit: usize,
    retry: *const RetryPolicy,
    breaker: *CircuitBreaker,
    timeout: *const TimeoutPolicy,
    dial: Dial = .tcp,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: Pool,
    retry: *const RetryPolicy,
    breaker: *CircuitBreaker,
    timeout: *const TimeoutPolicy,
    secure: bool,
    busy: bool,

    pub fn initCleartext(args: InitCleartext) (Error || error{OutOfMemory})!Client {
        _ = try TimeoutPolicy.init(args.timeout.connect, args.timeout.request, args.timeout.total_attempt);
        var pool = try Pool.init(args.allocator, args.io, args.pool_limit, args.dial);
        errdefer pool.deinit();
        return .{
            .allocator = args.allocator,
            .io = args.io,
            .pool = pool,
            .retry = args.retry,
            .breaker = args.breaker,
            .timeout = args.timeout,
            .secure = false,
            .busy = false,
        };
    }

    pub fn initSecure(_: InitCleartext) Error!void {
        return tls.openSecure();
    }

    pub fn deinit(self: *Client) void {
        std.debug.assert(!self.busy);
        self.pool.deinit();
    }

    pub fn request(self: *Client, req: Request, dest: []u8) (Error || error{OutOfMemory})!Response {
        if (self.busy) return error.InvalidInput;
        const parsed = try parseUrl(req.url, self.secure);
        try validateHeaders(req.headers);

        self.busy = true;
        defer self.busy = false;

        const idempotent = req.idempotent or req.method.isIdempotent();
        var attempt: u32 = 0;

        while (true) {
            attempt += 1;
            const now_ts = std.Io.Clock.Timestamp.now(self.io, .awake);
            const now_ns: cb_mod.InstantNs = now_ts.raw.nanoseconds;

            if (!self.breaker.admit(now_ns)) return error.CircuitOpen;

            const deadline = self.timeout.deadlines(now_ts);
            const conn = self.pool.checkout(parsed.host, parsed.port, deadline.connect) catch |e| {
                const err = mapAlloc(e);
                switch (err) {
                    error.PoolExhausted, error.InvalidInput, error.OutOfMemory => return err,
                    else => {
                        if (err == error.Timeout or err == error.ConnectionFailed or err == error.Cancelled) {
                            self.breaker.onFailure(now_ns);
                        }
                        if (try self.maybeRetry(stripOom(err), attempt, idempotent)) continue;
                        return err;
                    },
                }
            };

            const result = conn.exchange(.{
                .method = req.method,
                .host = parsed.host,
                .port = parsed.port,
                .target = parsed.target,
                .headers = req.headers,
                .body = req.body,
            }, dest, deadline.request) catch |e| {
                self.pool.release(conn, false);
                self.breaker.onFailure(now_ns);
                if (try self.maybeRetry(e, attempt, idempotent)) continue;
                return e;
            };

            self.pool.release(conn, result.reusable);
            self.breaker.onSuccess();
            return .{ .status = result.status, .body_len = result.body_len };
        }
    }

    fn maybeRetry(self: *Client, err: Error, attempt: u32, idempotent: bool) Error!bool {
        if (!idempotent) return false;
        switch (self.retry.decide(err, attempt)) {
            .stop => {
                if (attempt >= self.retry.max_attempts and self.retry.isListed(err)) {
                    return error.RetryBudgetExceeded;
                }
                return false;
            },
            .retry_after => |d| {
                std.debug.assert(self.pool.in_use == 0);
                const clock_d: std.Io.Clock.Duration = .{ .raw = d, .clock = .awake };
                clock_d.sleep(self.io) catch |sleep_err| switch (sleep_err) {
                    error.Canceled => return error.Cancelled,
                };
                return true;
            },
        }
    }
};

fn mapAlloc(e: anyerror) (Error || error{OutOfMemory}) {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidInput => error.InvalidInput,
        error.Timeout => error.Timeout,
        error.ConnectionFailed => error.ConnectionFailed,
        error.PoolExhausted => error.PoolExhausted,
        error.Cancelled, error.Canceled => error.Cancelled,
        error.TlsRequired => error.TlsRequired,
        error.TlsFailure => error.TlsFailure,
        error.Protocol => error.Protocol,
        error.NotImplemented => error.NotImplemented,
        error.CircuitOpen => error.CircuitOpen,
        error.RetryBudgetExceeded => error.RetryBudgetExceeded,
        else => error.ConnectionFailed,
    };
}

fn stripOom(e: (Error || error{OutOfMemory})) Error {
    return switch (e) {
        error.OutOfMemory => error.ConnectionFailed,
        else => |rest| rest,
    };
}

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    target: []const u8,
};

fn parseUrl(url: []const u8, secure_client: bool) Error!ParsedUrl {
    const uri = std.Uri.parse(url) catch return error.InvalidInput;
    if (uri.host == null) return error.InvalidInput;

    const http = std.ascii.eqlIgnoreCase(uri.scheme, "http");
    const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!http and !https) return error.InvalidInput;

    if (secure_client) {
        if (http) return error.TlsRequired;
        return error.NotImplemented;
    }
    if (https) return error.TlsRequired;

    var host_storage: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = uri.getHost(&host_storage) catch return error.InvalidInput;
    if (host_name.bytes.len == 0) return error.InvalidInput;

    const host = hostSlice(url) orelse return error.InvalidInput;
    const port: u16 = uri.port orelse 80;

    const path_start = pathStart(url) orelse return error.InvalidInput;
    const target = if (path_start >= url.len) "/" else url[path_start..];
    return .{ .host = host, .port = port, .target = target };
}

fn hostSlice(url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const i = scheme_end + 3;
    if (i >= url.len) return null;
    if (url[i] == '[') {
        const end = std.mem.indexOfScalarPos(u8, url, i, ']') orelse return null;
        return url[i .. end + 1];
    }
    const end_chars = "/:?#";
    var j = i;
    while (j < url.len) : (j += 1) {
        if (std.mem.indexOfScalar(u8, end_chars, url[j]) != null) break;
    }
    if (j == i) return null;
    return url[i..j];
}

fn pathStart(url: []const u8) ?usize {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    var i = scheme_end + 3;
    if (i < url.len and url[i] == '[') {
        i = (std.mem.indexOfScalarPos(u8, url, i, ']') orelse return null) + 1;
    }
    while (i < url.len and url[i] != '/' and url[i] != '?' and url[i] != '#') i += 1;
    return i;
}

fn validateHeaders(headers: []const Header) Error!void {
    for (headers) |h| {
        if (h.name.len == 0) return error.InvalidInput;
        if (std.mem.indexOfAny(u8, h.name, "\r\n:") != null) return error.InvalidInput;
        if (std.mem.indexOfAny(u8, h.value, "\r\n") != null) return error.InvalidInput;
    }
}

fn failDial(ptr: *anyopaque, args: transport_mod.DialArgs) Error!std.Io.net.Stream {
    _ = args;
    const calls: *u32 = @ptrCast(@alignCast(ptr));
    calls.* += 1;
    return error.ConnectionFailed;
}

fn testTimeout() TimeoutPolicy {
    return TimeoutPolicy.initMillis(200, 200, 200) catch unreachable;
}

test "Client.initSecure is NotImplemented while TLS is absent" {
    var breaker = try CircuitBreaker.init(3, 1_000_000_000);
    const retry = RetryPolicy.never;
    const timeout = testTimeout();
    try std.testing.expectError(error.NotImplemented, Client.initSecure(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .pool_limit = 1,
        .retry = &retry,
        .breaker = &breaker,
        .timeout = &timeout,
    }));
}

test "Client cleartext rejects https and secure constructor has no http fallback" {
    var dial_calls: u32 = 0;
    var breaker = try CircuitBreaker.init(3, 1_000_000_000);
    const retry = RetryPolicy.never;
    const timeout = testTimeout();
    var client = try Client.initCleartext(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .pool_limit = 1,
        .retry = &retry,
        .breaker = &breaker,
        .timeout = &timeout,
        .dial = .{ .ptr = @ptrCast(&dial_calls), .dialFn = failDial },
    });
    defer client.deinit();
    var dest: [8]u8 = undefined;
    try std.testing.expectError(error.TlsRequired, client.request(.{
        .method = .GET,
        .url = "https://example.test/",
    }, &dest));
    try std.testing.expectEqual(@as(u32, 0), dial_calls);
}

test "Client circuit open rejects without transport" {
    var dial_calls: u32 = 0;
    var breaker = try CircuitBreaker.init(1, std.time.ns_per_hour);
    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.expect(breaker.admit(now.raw.nanoseconds));
    breaker.onFailure(now.raw.nanoseconds);
    try std.testing.expect(breaker.state == .open);

    const retry = RetryPolicy.never;
    const timeout = testTimeout();
    var client = try Client.initCleartext(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .pool_limit = 1,
        .retry = &retry,
        .breaker = &breaker,
        .timeout = &timeout,
        .dial = .{ .ptr = @ptrCast(&dial_calls), .dialFn = failDial },
    });
    defer client.deinit();
    var dest: [8]u8 = undefined;
    try std.testing.expectError(error.CircuitOpen, client.request(.{
        .method = .GET,
        .url = "http://example.test/",
    }, &dest));
    try std.testing.expectEqual(@as(u32, 0), dial_calls);
    try std.testing.expectEqual(@as(usize, 0), client.pool.in_use);
}

test "Client retry does not run I/O itself; connection is released before backoff" {
    var dial_calls: u32 = 0;
    var breaker = try CircuitBreaker.init(99, 1_000_000_000);
    const retry = try RetryPolicy.init(3, .{ .connection_failed = true }, .{
        .base = .fromNanoseconds(1),
        .kind = .constant,
    });
    const timeout = testTimeout();
    var client = try Client.initCleartext(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .pool_limit = 1,
        .retry = &retry,
        .breaker = &breaker,
        .timeout = &timeout,
        .dial = .{ .ptr = @ptrCast(&dial_calls), .dialFn = failDial },
    });
    defer client.deinit();
    var dest: [8]u8 = undefined;
    try std.testing.expectError(error.RetryBudgetExceeded, client.request(.{
        .method = .GET,
        .url = "http://127.0.0.1/",
    }, &dest));
    try std.testing.expectEqual(@as(u32, 3), dial_calls);
    try std.testing.expectEqual(@as(usize, 0), client.pool.in_use);
}

test "Client listed Timeout on POST without mark does not retry" {
    var dial_calls: u32 = 0;
    var breaker = try CircuitBreaker.init(99, 1_000_000_000);
    const retry = try RetryPolicy.init(5, .{ .connection_failed = true }, .{
        .base = .fromNanoseconds(1),
        .kind = .constant,
    });
    const timeout = testTimeout();
    var client = try Client.initCleartext(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .pool_limit = 1,
        .retry = &retry,
        .breaker = &breaker,
        .timeout = &timeout,
        .dial = .{ .ptr = @ptrCast(&dial_calls), .dialFn = failDial },
    });
    defer client.deinit();
    var dest: [8]u8 = undefined;
    try std.testing.expectError(error.ConnectionFailed, client.request(.{
        .method = .POST,
        .url = "http://127.0.0.1/x",
        .body = "n",
    }, &dest));
    try std.testing.expectEqual(@as(u32, 1), dial_calls);
}

test "Client listed error on GET does retry" {
    var dial_calls: u32 = 0;
    var breaker = try CircuitBreaker.init(99, 1_000_000_000);
    const retry = try RetryPolicy.init(2, .{ .connection_failed = true }, .{
        .base = .fromNanoseconds(1),
        .kind = .constant,
    });
    const timeout = testTimeout();
    var client = try Client.initCleartext(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .pool_limit = 1,
        .retry = &retry,
        .breaker = &breaker,
        .timeout = &timeout,
        .dial = .{ .ptr = @ptrCast(&dial_calls), .dialFn = failDial },
    });
    defer client.deinit();
    var dest: [8]u8 = undefined;
    _ = client.request(.{ .method = .GET, .url = "http://127.0.0.1/" }, &dest) catch {};
    try std.testing.expectEqual(@as(u32, 2), dial_calls);
}

test "Client caller-marked POST is retried when the error is listed" {
    var dial_calls: u32 = 0;
    var breaker = try CircuitBreaker.init(99, 1_000_000_000);
    const retry = try RetryPolicy.init(2, .{ .connection_failed = true }, .{
        .base = .fromNanoseconds(1),
        .kind = .constant,
    });
    const timeout = testTimeout();
    var client = try Client.initCleartext(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .pool_limit = 1,
        .retry = &retry,
        .breaker = &breaker,
        .timeout = &timeout,
        .dial = .{ .ptr = @ptrCast(&dial_calls), .dialFn = failDial },
    });
    defer client.deinit();
    var dest: [8]u8 = undefined;
    _ = client.request(.{
        .method = .POST,
        .url = "http://127.0.0.1/x",
        .body = "n",
        .idempotent = true,
    }, &dest) catch {};
    try std.testing.expectEqual(@as(u32, 2), dial_calls);
}

test "Client half_open probe failure opens; leftover retry budget does not start a second attempt" {
    var dial_calls: u32 = 0;
    var breaker = try CircuitBreaker.init(1, 1_000_000_000);
    const retry = try RetryPolicy.init(5, .{ .connection_failed = true }, .{
        .base = .fromNanoseconds(1),
        .kind = .constant,
    });
    const timeout = testTimeout();
    var client = try Client.initCleartext(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .pool_limit = 1,
        .retry = &retry,
        .breaker = &breaker,
        .timeout = &timeout,
        .dial = .{ .ptr = @ptrCast(&dial_calls), .dialFn = failDial },
    });
    defer client.deinit();
    var dest: [8]u8 = undefined;
    try std.testing.expectError(error.CircuitOpen, client.request(.{
        .method = .GET,
        .url = "http://127.0.0.1/",
    }, &dest));
    try std.testing.expectEqual(@as(u32, 1), dial_calls);
    try std.testing.expect(breaker.state == .open);
}

test "Client InvalidInput does not dial" {
    var dial_calls: u32 = 0;
    var breaker = try CircuitBreaker.init(3, 1);
    const retry = RetryPolicy.never;
    const timeout = testTimeout();
    var client = try Client.initCleartext(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .pool_limit = 1,
        .retry = &retry,
        .breaker = &breaker,
        .timeout = &timeout,
        .dial = .{ .ptr = @ptrCast(&dial_calls), .dialFn = failDial },
    });
    defer client.deinit();
    var dest: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidInput, client.request(.{
        .method = .GET,
        .url = "not-a-url",
    }, &dest));
    try std.testing.expectEqual(@as(u32, 0), dial_calls);
}

test "parseUrl extracts host port target from http URL" {
    const p = try parseUrl("http://example.test:8080/a/b?q=1", false);
    try std.testing.expectEqualStrings("example.test", p.host);
    try std.testing.expectEqual(@as(u16, 8080), p.port);
    try std.testing.expectEqualStrings("/a/b?q=1", p.target);
}

test "loopback listen smoke: Client GET against std.Io.net.Server" {
    const io = std.testing.io;
    var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = addr.listen(io, .{ .reuse_address = true }) catch return error.SkipZigTest;
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    if (port == 0) return error.SkipZigTest;

    const Serve = struct {
        fn run(s: *std.Io.net.Server, serve_io: std.Io) void {
            var stream = s.accept(serve_io) catch return;
            defer stream.close(serve_io);
            var rbuf: [512]u8 = undefined;
            var reader = stream.reader(serve_io, &rbuf);
            _ = reader.interface.peekGreedy(1) catch {};
            var wbuf: [128]u8 = undefined;
            var writer = stream.writer(serve_io, &wbuf);
            writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch return;
            writer.interface.flush() catch {};
        }
    };

    var fut = io.concurrent(Serve.run, .{ &server, io }) catch return error.SkipZigTest;
    defer _ = fut.cancel(io);

    var breaker = try CircuitBreaker.init(3, 1_000_000_000);
    const retry = RetryPolicy.never;
    const timeout = testTimeout();
    var client = try Client.initCleartext(.{
        .allocator = std.testing.allocator,
        .io = io,
        .pool_limit = 1,
        .retry = &retry,
        .breaker = &breaker,
        .timeout = &timeout,
        .dial = .tcp,
    });
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port}) catch return error.SkipZigTest;
    var dest: [8]u8 = undefined;
    const res = try client.request(.{ .method = .GET, .url = url }, &dest);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("ok", dest[0..res.body_len]);
    fut.await(io);
}
