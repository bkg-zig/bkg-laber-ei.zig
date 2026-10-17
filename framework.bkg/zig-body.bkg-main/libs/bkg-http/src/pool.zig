//! Pool — connection ownership and lifecycle. Enforces the caller-supplied limit.
//!
//! No default limit. limit 0 is InvalidInput. The library never grows past
//! `limit` and never interns pools by hostname. See docs/BKG_HTTP_CLIENT_v1.md.

const std = @import("std");
const Error = @import("error.zig").Error;
const connection_mod = @import("connection.zig");
const transport_mod = @import("transport.zig");

pub const Connection = connection_mod.Connection;
pub const Dial = connection_mod.Dial;

const SlotState = enum { empty, idle, in_use };

const Slot = struct {
    state: SlotState = .empty,
    conn: Connection = undefined,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    limit: usize,
    slots: []Slot,
    idle: usize,
    in_use: usize,
    dial: Dial,
    deinited: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        limit: usize,
        dial: Dial,
    ) (Error || error{OutOfMemory})!Pool {
        if (limit == 0) return error.InvalidInput;
        const slots = try allocator.alloc(Slot, limit);
        for (slots) |*s| s.* = .{};
        return .{
            .allocator = allocator,
            .io = io,
            .limit = limit,
            .slots = slots,
            .idle = 0,
            .in_use = 0,
            .dial = dial,
            .deinited = false,
        };
    }

    pub fn checkout(
        self: *Pool,
        host: []const u8,
        port: u16,
        connect_timeout: std.Io.Timeout,
    ) (Error || error{OutOfMemory})!*Connection {
        std.debug.assert(!self.deinited);
        for (self.slots) |*slot| {
            if (slot.state == .idle and slot.conn.matches(host, port) and slot.conn.reusable) {
                slot.state = .in_use;
                slot.conn.generation +%= 1;
                self.idle -= 1;
                self.in_use += 1;
                return &slot.conn;
            }
        }
        if (self.in_use + self.idle >= self.limit) return error.PoolExhausted;
        for (self.slots) |*slot| {
            if (slot.state == .empty) {
                slot.conn = Connection.open(
                    self.allocator,
                    self.io,
                    self.dial,
                    host,
                    port,
                    connect_timeout,
                ) catch |e| return e;
                slot.state = .in_use;
                slot.conn.generation = 1;
                self.in_use += 1;
                return &slot.conn;
            }
        }
        return error.PoolExhausted;
    }

    pub fn release(self: *Pool, conn: *Connection, reusable: bool) void {
        std.debug.assert(!self.deinited);
        const slot = self.slotOf(conn);
        std.debug.assert(slot.state == .in_use);
        self.in_use -= 1;
        const keep = reusable and conn.reusable;
        if (keep) {
            slot.state = .idle;
            self.idle += 1;
        } else {
            conn.deinit();
            slot.state = .empty;
            slot.conn = undefined;
        }
    }

    pub fn deinit(self: *Pool) void {
        if (self.deinited) return;
        self.deinited = true;
        for (self.slots) |*slot| {
            switch (slot.state) {
                .empty => {},
                .idle, .in_use => slot.conn.deinit(),
            }
            slot.state = .empty;
        }
        self.idle = 0;
        self.in_use = 0;
        self.allocator.free(self.slots);
        self.slots = &.{};
    }

    fn slotOf(self: *Pool, conn: *Connection) *Slot {
        for (self.slots) |*slot| {
            if (slot.state != .empty and &slot.conn == conn) return slot;
        }
        unreachable;
    }
};

const FailDial = struct {
    calls: u32 = 0,
    err: Error = error.ConnectionFailed,

    fn dial(ptr: *anyopaque, args: connection_mod.DialArgs) Error!std.Io.net.Stream {
        _ = args;
        const self: *FailDial = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return self.err;
    }

    fn asDial(self: *FailDial) Dial {
        return .{ .ptr = @ptrCast(self), .dialFn = dial };
    }
};

const CountTcp = struct {
    calls: u32 = 0,

    fn dial(ptr: *anyopaque, args: connection_mod.DialArgs) Error!std.Io.net.Stream {
        const self: *CountTcp = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return transport_mod.dialTcp(undefined, args);
    }

    fn asDial(self: *CountTcp) Dial {
        return .{ .ptr = @ptrCast(self), .dialFn = dial };
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

fn testTimeout() std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(2000), .clock = .awake } };
}

test "Pool.init rejects limit 0" {
    try std.testing.expectError(
        error.InvalidInput,
        Pool.init(std.testing.allocator, std.testing.io, 0, .tcp),
    );
}

test "Pool checkout at limit returns PoolExhausted; deinit closes remaining" {
    const io = std.testing.io;
    var held = listenLoopback(io) catch return error.SkipZigTest;
    defer held.server.deinit(io);
    var counter: CountTcp = .{};
    var pool = try Pool.init(std.testing.allocator, io, 2, counter.asDial());
    defer pool.deinit();

    const a = pool.checkout("127.0.0.1", held.port, testTimeout()) catch return error.SkipZigTest;
    const b = pool.checkout("127.0.0.1", held.port, testTimeout()) catch return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 2), pool.in_use);
    try std.testing.expectError(error.PoolExhausted, pool.checkout("127.0.0.1", held.port, testTimeout()));
    pool.release(a, true);
    try std.testing.expectEqual(@as(usize, 1), pool.in_use);
    try std.testing.expectEqual(@as(usize, 1), pool.idle);
    pool.release(b, true);
    try std.testing.expectEqual(@as(usize, 0), pool.in_use);
    try std.testing.expectEqual(@as(usize, 2), pool.idle);
}

test "Pool broken connection is not reused" {
    const io = std.testing.io;
    var held = listenLoopback(io) catch return error.SkipZigTest;
    defer held.server.deinit(io);
    var counter: CountTcp = .{};
    var pool = try Pool.init(std.testing.allocator, io, 1, counter.asDial());
    defer pool.deinit();
    const a = pool.checkout("127.0.0.1", held.port, testTimeout()) catch return error.SkipZigTest;
    a.reusable = false;
    pool.release(a, false);
    try std.testing.expectEqual(@as(usize, 0), pool.idle);
    try std.testing.expectEqual(@as(usize, 0), pool.in_use);
    _ = pool.checkout("127.0.0.1", held.port, testTimeout()) catch return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, 2), counter.calls);
}

test "Pool acquire then release reusable connection is checked out again without a second dial" {
    const io = std.testing.io;
    var held = listenLoopback(io) catch return error.SkipZigTest;
    defer held.server.deinit(io);
    var counter: CountTcp = .{};
    var pool = try Pool.init(std.testing.allocator, io, 1, counter.asDial());
    defer pool.deinit();
    const a = pool.checkout("127.0.0.1", held.port, testTimeout()) catch return error.SkipZigTest;
    pool.release(a, true);
    const b = try pool.checkout("127.0.0.1", held.port, testTimeout());
    try std.testing.expectEqual(@as(u32, 1), counter.calls);
    try std.testing.expect(a == b);
    pool.release(b, true);
}

test "Pool connect failure does not occupy a slot" {
    var fail: FailDial = .{};
    var pool = try Pool.init(std.testing.allocator, std.testing.io, 2, fail.asDial());
    defer pool.deinit();
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } };
    try std.testing.expectError(error.ConnectionFailed, pool.checkout("x", 80, timeout));
    try std.testing.expectEqual(@as(usize, 0), pool.in_use);
    try std.testing.expectEqual(@as(usize, 0), pool.idle);
    try std.testing.expectEqual(@as(u32, 1), fail.calls);
}
