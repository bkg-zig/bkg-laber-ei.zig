//! TimeoutPolicy — time limits for a single attempt.
//!
//! Not a retry budget, not a circuit cooldown, not a field of RetryPolicy or
//! CircuitBreaker. Value type. No I/O. No clock ownership.
//!
//! Client converts these durations into a deadline with std.Io at the start of
//! each attempt. A retry does not inherit a spent deadline.
//! Zero durations are InvalidInput (not "infinite"). Infinite timeouts are
//! forbidden on the production Client path.

const std = @import("std");
const Error = @import("error.zig").Error;

pub const TimeoutPolicy = struct {
    connect: std.Io.Duration,
    request: std.Io.Duration,
    total_attempt: std.Io.Duration,

    pub fn init(
        connect: std.Io.Duration,
        request: std.Io.Duration,
        total_attempt: std.Io.Duration,
    ) Error!TimeoutPolicy {
        if (connect.nanoseconds <= 0) return error.InvalidInput;
        if (request.nanoseconds <= 0) return error.InvalidInput;
        if (total_attempt.nanoseconds <= 0) return error.InvalidInput;
        return .{
            .connect = connect,
            .request = request,
            .total_attempt = total_attempt,
        };
    }

    pub fn initMillis(connect_ms: i64, request_ms: i64, total_ms: i64) Error!TimeoutPolicy {
        return init(
            .fromMilliseconds(connect_ms),
            .fromMilliseconds(request_ms),
            .fromMilliseconds(total_ms),
        );
    }

    /// Bind this policy to `now` (caller/Client supplies the clock via Io).
    /// Does not allocate, sleep, or touch sockets.
    pub fn deadlines(self: TimeoutPolicy, now: std.Io.Clock.Timestamp) AttemptDeadline {
        const clock = now.clock;
        const connect_end = now.addDuration(.{ .raw = self.connect, .clock = clock });
        const request_end = now.addDuration(.{ .raw = self.request, .clock = clock });
        const total_end = now.addDuration(.{ .raw = self.total_attempt, .clock = clock });
        return .{
            .connect = .{ .deadline = earlier(connect_end, total_end) },
            .request = .{ .deadline = earlier(request_end, total_end) },
        };
    }
};

pub const AttemptDeadline = struct {
    connect: std.Io.Timeout,
    request: std.Io.Timeout,
};

fn earlier(a: std.Io.Clock.Timestamp, b: std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    if (a.compare(.lte, b)) return a;
    return b;
}

test "TimeoutPolicy rejects zero durations" {
    try std.testing.expectError(
        error.InvalidInput,
        TimeoutPolicy.initMillis(0, 1000, 1000),
    );
    try std.testing.expectError(
        error.InvalidInput,
        TimeoutPolicy.initMillis(1000, 0, 1000),
    );
    try std.testing.expectError(
        error.InvalidInput,
        TimeoutPolicy.initMillis(1000, 1000, 0),
    );
}

test "TimeoutPolicy rejects negative durations" {
    try std.testing.expectError(
        error.InvalidInput,
        TimeoutPolicy.init(.fromMilliseconds(-1), .fromMilliseconds(10), .fromMilliseconds(10)),
    );
}

test "TimeoutPolicy deadlines are per-attempt and cap at total_attempt" {
    const policy = try TimeoutPolicy.initMillis(5000, 5000, 1000);
    const now: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(1_000_000_000),
        .clock = .awake,
    };
    const dl = policy.deadlines(now);
    const connect_ts = dl.connect.deadline;
    const request_ts = dl.request.deadline;
    const expected = now.addDuration(.{
        .raw = .fromMilliseconds(1000),
        .clock = .awake,
    });
    try std.testing.expect(connect_ts.compare(.eq, expected));
    try std.testing.expect(request_ts.compare(.eq, expected));
}

test "TimeoutPolicy retry does not inherit a spent deadline: fresh bind from a later now" {
    const policy = try TimeoutPolicy.initMillis(200, 200, 200);
    const first_now: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(0),
        .clock = .awake,
    };
    const later_now: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(150_000_000),
        .clock = .awake,
    };
    const first = policy.deadlines(first_now);
    const second = policy.deadlines(later_now);
    try std.testing.expect(first.connect.deadline.compare(.lt, second.connect.deadline));
    try std.testing.expectEqual(
        @as(i96, 200_000_000),
        second.connect.deadline.raw.nanoseconds - later_now.raw.nanoseconds,
    );
}

test "TimeoutPolicy is a value type and does not allocate" {
    const a = try TimeoutPolicy.initMillis(10, 20, 30);
    const b = a;
    try std.testing.expectEqual(a.connect.nanoseconds, b.connect.nanoseconds);
}
