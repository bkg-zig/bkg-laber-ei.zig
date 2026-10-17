//! Connection — one pooled HTTP/1.1 session.
//!
//! Idle in the pool or checked out for a single request. Application code
//! never stores *Connection. TLS handle is absent until a TLS PR.

const std = @import("std");
const Error = @import("error.zig").Error;
const tls = @import("tls.zig");
const transport_mod = @import("transport.zig");

pub const Transport = transport_mod.Transport;
pub const Dial = transport_mod.Dial;
pub const DialArgs = transport_mod.DialArgs;
pub const ExchangeRequest = transport_mod.ExchangeRequest;
pub const ExchangeResult = transport_mod.ExchangeResult;

pub const Connection = struct {
    transport: Transport,
    generation: u32,
    reusable: bool,
    host_buf: [std.Io.net.HostName.max_len]u8,
    host_len: u8,
    port: u16,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        dial: Dial,
        host_name: []const u8,
        port: u16,
        connect_timeout: std.Io.Timeout,
    ) (Error || error{OutOfMemory})!Connection {
        if (host_name.len == 0 or host_name.len > std.Io.net.HostName.max_len) return error.InvalidInput;
        const stream = try dial.dialFn(dial.ptr, .{
            .allocator = allocator,
            .io = io,
            .host = host_name,
            .port = port,
            .timeout = connect_timeout,
        });
        errdefer stream.close(io);
        var t = try Transport.initOwned(allocator, io, stream);
        errdefer t.deinit();
        var conn: Connection = .{
            .transport = t,
            .generation = 0,
            .reusable = true,
            .host_buf = undefined,
            .host_len = @intCast(host_name.len),
            .port = port,
        };
        @memcpy(conn.host_buf[0..host_name.len], host_name);
        return conn;
    }

    pub fn openSecure() Error!void {
        return tls.openSecure();
    }

    pub fn host(self: *const Connection) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    pub fn matches(self: *const Connection, host_name: []const u8, port: u16) bool {
        return self.port == port and std.ascii.eqlIgnoreCase(self.host(), host_name);
    }

    pub fn exchange(
        self: *Connection,
        req: ExchangeRequest,
        dest: []u8,
        deadline: std.Io.Timeout,
    ) Error!ExchangeResult {
        const result = self.transport.exchange(req, dest, deadline) catch |e| {
            self.reusable = false;
            return e;
        };
        if (!result.reusable) self.reusable = false;
        return result;
    }

    pub fn deinit(self: *Connection) void {
        self.transport.deinit();
        self.reusable = false;
    }
};

test "Connection.openSecure is not implemented in v1" {
    try std.testing.expectError(error.NotImplemented, Connection.openSecure());
}
