/// BKG HTTP Client v1 — std-only HTTP/1.1 client.
/// Architecture: docs/BKG_HTTP_CLIENT_v1.md
/// TLS is not implemented in v1 (see tls.zig). Cleartext is a distinct constructor.
pub const Error = @import("error.zig").Error;
pub const timeout = @import("timeout.zig");
pub const retry = @import("retry.zig");
pub const circuit_breaker = @import("circuit_breaker.zig");
pub const tls = @import("tls.zig");
pub const transport = @import("transport.zig");
pub const connection = @import("connection.zig");
pub const pool = @import("pool.zig");
pub const client = @import("client.zig");

pub const TimeoutPolicy = timeout.TimeoutPolicy;
pub const RetryPolicy = retry.RetryPolicy;
pub const RetryableSet = retry.RetryableSet;
pub const CircuitBreaker = circuit_breaker.CircuitBreaker;
pub const Client = client.Client;
pub const Request = client.Request;
pub const Response = client.Response;
pub const Method = transport.Method;
pub const Header = transport.Header;
pub const Pool = pool.Pool;
pub const Dial = transport.Dial;

test {
    _ = timeout;
    _ = retry;
    _ = circuit_breaker;
    _ = tls;
    _ = transport;
    _ = connection;
    _ = pool;
    _ = client;
}
