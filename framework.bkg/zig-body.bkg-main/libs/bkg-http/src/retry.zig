//! RetryPolicy — retry decision + backoff duration.
//!
//! No I/O. No sleep. No sockets. No time source. `decide` must not allocate.
//! Idempotency is not a field here; Client applies it before honoring retry_after.
//! Default empty allow-list never retries (fail-closed).
//!
//! See docs/BKG_HTTP_CLIENT_v1.md.

const std = @import("std");
const Error = @import("error.zig").Error;

/// Explicit allow-list of Error tags. Missing from the list means do not retry.
pub const RetryableSet = struct {
    timeout: bool = false,
    connection_failed: bool = false,
    tls_failure: bool = false,
    protocol: bool = false,
    pool_exhausted: bool = false,
};

pub const Backoff = struct {
    base: std.Io.Duration = .fromMilliseconds(0),
    kind: Kind = .constant,

    pub const Kind = enum { constant, linear, exponential };

    /// Pure function (attempt) → duration. `attempt` is the 1-based attempt that just failed.
    pub fn forAttempt(self: Backoff, attempt: u32) std.Io.Duration {
        const n: i96 = @intCast(@max(attempt, 1));
        const base_ns = self.base.nanoseconds;
        const ns: i96 = switch (self.kind) {
            .constant => base_ns,
            .linear => base_ns * n,
            .exponential => blk: {
                var factor: i96 = 1;
                var i: u32 = 1;
                while (i < attempt) : (i += 1) {
                    factor *|= 2;
                }
                break :blk base_ns * factor;
            },
        };
        return .{ .nanoseconds = ns };
    }
};

pub const Decision = union(enum) {
    stop,
    retry_after: std.Io.Duration,
};

pub const RetryPolicy = struct {
    max_attempts: u32,
    retryable: RetryableSet,
    backoff: Backoff,

    /// Fail-closed default: never retry.
    pub const never: RetryPolicy = .{
        .max_attempts = 1,
        .retryable = .{},
        .backoff = .{},
    };

    pub fn init(max_attempts: u32, retryable: RetryableSet, backoff: Backoff) Error!RetryPolicy {
        if (max_attempts == 0) return error.InvalidInput;
        return .{
            .max_attempts = max_attempts,
            .retryable = retryable,
            .backoff = backoff,
        };
    }

    pub fn isListed(self: RetryPolicy, err: Error) bool {
        return switch (err) {
            error.Timeout => self.retryable.timeout,
            error.ConnectionFailed => self.retryable.connection_failed,
            error.TlsFailure => self.retryable.tls_failure,
            error.Protocol => self.retryable.protocol,
            error.PoolExhausted => self.retryable.pool_exhausted,
            error.InvalidInput,
            error.TlsRequired,
            error.RetryBudgetExceeded,
            error.CircuitOpen,
            error.Cancelled,
            error.NotImplemented,
            => false,
        };
    }

    /// Pure: (error, attempt_index, policy fields) → decision.
    /// `attempt_index` is the 1-based count of Transport/connect attempts already performed.
    /// Does not sleep, allocate, or open sockets.
    pub fn decide(self: *const RetryPolicy, err: Error, attempt_index: u32) Decision {
        if (attempt_index >= self.max_attempts) return .stop;
        if (!self.isListed(err)) return .stop;
        return .{ .retry_after = self.backoff.forAttempt(attempt_index) };
    }
};

test "RetryPolicy empty allow-list never retries" {
    const policy = RetryPolicy.never;
    try std.testing.expect(policy.decide(error.Timeout, 1) == .stop);
    try std.testing.expect(policy.decide(error.ConnectionFailed, 1) == .stop);
}

test "RetryPolicy listed Timeout retries; unlisted Protocol does not" {
    const policy = try RetryPolicy.init(3, .{ .timeout = true }, .{
        .base = .fromMilliseconds(10),
        .kind = .constant,
    });
    switch (policy.decide(error.Timeout, 1)) {
        .retry_after => |d| try std.testing.expectEqual(@as(i96, 10_000_000), d.nanoseconds),
        .stop => return error.TestUnexpectedResult,
    }
    try std.testing.expect(policy.decide(error.Protocol, 1) == .stop);
}

test "RetryPolicy CircuitOpen and InvalidInput are never listed" {
    const policy = try RetryPolicy.init(5, .{
        .timeout = true,
        .connection_failed = true,
        .tls_failure = true,
        .protocol = true,
        .pool_exhausted = true,
    }, .{});
    try std.testing.expect(policy.decide(error.CircuitOpen, 1) == .stop);
    try std.testing.expect(policy.decide(error.InvalidInput, 1) == .stop);
    try std.testing.expect(policy.decide(error.Cancelled, 1) == .stop);
    try std.testing.expect(policy.decide(error.TlsRequired, 1) == .stop);
    try std.testing.expect(policy.decide(error.NotImplemented, 1) == .stop);
}

test "RetryPolicy backoff is deterministic given attempt index" {
    const policy = try RetryPolicy.init(8, .{ .timeout = true }, .{
        .base = .fromMilliseconds(4),
        .kind = .exponential,
    });
    const d1 = policy.decide(error.Timeout, 1).retry_after;
    const d2 = policy.decide(error.Timeout, 2).retry_after;
    const d3 = policy.decide(error.Timeout, 3).retry_after;
    try std.testing.expectEqual(@as(i96, 4_000_000), d1.nanoseconds);
    try std.testing.expectEqual(@as(i96, 8_000_000), d2.nanoseconds);
    try std.testing.expectEqual(@as(i96, 16_000_000), d3.nanoseconds);
}

test "RetryPolicy stops when attempt_index reaches max_attempts" {
    const policy = try RetryPolicy.init(2, .{ .timeout = true }, .{});
    try std.testing.expect(policy.decide(error.Timeout, 1) == .retry_after);
    try std.testing.expect(policy.decide(error.Timeout, 2) == .stop);
}

test "RetryPolicy init rejects max_attempts 0" {
    try std.testing.expectError(error.InvalidInput, RetryPolicy.init(0, .{}, .{}));
}

test "RetryPolicy decide does not take Io" {
    const policy = RetryPolicy.never;
    const d = policy.decide(error.Timeout, 0);
    try std.testing.expect(d == .stop);
}
