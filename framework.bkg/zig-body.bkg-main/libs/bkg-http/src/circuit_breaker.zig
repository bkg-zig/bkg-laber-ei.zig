//! CircuitBreaker — CPU-only state machine.
//!
//! open is default-deny (no transport). half_open admits exactly one probe;
//! further admits while a probe is in flight are denied.
//! The breaker does not call Io, allocate, or touch Pool/Retry/Timeout.
//!
//! Time-based reopen uses a timestamp supplied by the caller (Client reads
//! the Io clock and passes `now`). See docs/BKG_HTTP_CLIENT_v1.md.

const std = @import("std");

pub const InstantNs = i96;

pub const State = enum { closed, open, half_open };

pub const CircuitBreaker = struct {
    state: State,
    probe_in_flight: bool,
    consecutive_failures: u32,
    open_until: InstantNs,
    threshold: u32,
    cooldown_ns: InstantNs,

    pub fn init(threshold: u32, cooldown_ns: InstantNs) error{InvalidInput}!CircuitBreaker {
        if (threshold == 0) return error.InvalidInput;
        if (cooldown_ns < 0) return error.InvalidInput;
        return .{
            .state = .closed,
            .probe_in_flight = false,
            .consecutive_failures = 0,
            .open_until = 0,
            .threshold = threshold,
            .cooldown_ns = cooldown_ns,
        };
    }

    /// Pure state question plus the single probe flag. No I/O.
    /// Returns true if this attempt may proceed to Pool/Transport.
    pub fn admit(self: *CircuitBreaker, now: InstantNs) bool {
        self.maybeEnterHalfOpen(now);
        return switch (self.state) {
            .closed => true,
            .open => false,
            .half_open => blk: {
                if (self.probe_in_flight) break :blk false;
                self.probe_in_flight = true;
                break :blk true;
            },
        };
    }

    pub fn onSuccess(self: *CircuitBreaker) void {
        switch (self.state) {
            .closed => self.consecutive_failures = 0,
            .half_open => {
                self.state = .closed;
                self.probe_in_flight = false;
                self.consecutive_failures = 0;
                self.open_until = 0;
            },
            .open => {},
        }
    }

    pub fn onFailure(self: *CircuitBreaker, now: InstantNs) void {
        switch (self.state) {
            .closed => {
                self.consecutive_failures +|= 1;
                if (self.consecutive_failures >= self.threshold) {
                    self.tripOpen(now);
                }
            },
            .half_open => self.tripOpen(now),
            .open => {},
        }
    }

    /// Explicit probe grant without waiting for `open_until`.
    pub fn allowProbe(self: *CircuitBreaker) void {
        if (self.state == .open) {
            self.state = .half_open;
            self.probe_in_flight = false;
        }
    }

    fn maybeEnterHalfOpen(self: *CircuitBreaker, now: InstantNs) void {
        if (self.state == .open and now >= self.open_until) {
            self.state = .half_open;
            self.probe_in_flight = false;
        }
    }

    fn tripOpen(self: *CircuitBreaker, now: InstantNs) void {
        self.state = .open;
        self.probe_in_flight = false;
        self.open_until = now + self.cooldown_ns;
    }
};

test "CircuitBreaker closed success stays closed and admits" {
    var cb = try CircuitBreaker.init(3, 1000);
    try std.testing.expect(cb.admit(0));
    cb.onSuccess();
    try std.testing.expect(cb.state == .closed);
    try std.testing.expect(cb.admit(1));
}

test "CircuitBreaker closed failure below threshold stays closed" {
    var cb = try CircuitBreaker.init(3, 1000);
    try std.testing.expect(cb.admit(0));
    cb.onFailure(0);
    try std.testing.expect(cb.state == .closed);
    try std.testing.expectEqual(@as(u32, 1), cb.consecutive_failures);
    try std.testing.expect(cb.admit(1));
}

test "CircuitBreaker closed failure at threshold opens; subsequent admit denied" {
    var cb = try CircuitBreaker.init(2, 1000);
    try std.testing.expect(cb.admit(0));
    cb.onFailure(0);
    try std.testing.expect(cb.admit(1));
    cb.onFailure(1);
    try std.testing.expect(cb.state == .open);
    try std.testing.expect(!cb.admit(2));
}

test "CircuitBreaker open is default-deny" {
    var cb = try CircuitBreaker.init(1, 1000);
    _ = cb.admit(0);
    cb.onFailure(0);
    try std.testing.expect(cb.state == .open);
    try std.testing.expect(!cb.admit(1));
    try std.testing.expect(!cb.admit(500));
}

test "CircuitBreaker open transitions to half_open when now >= open_until" {
    var cb = try CircuitBreaker.init(1, 1000);
    _ = cb.admit(0);
    cb.onFailure(0);
    try std.testing.expectEqual(@as(InstantNs, 1000), cb.open_until);
    try std.testing.expect(cb.admit(1000));
    try std.testing.expect(cb.state == .half_open);
    try std.testing.expect(cb.probe_in_flight);
}

test "CircuitBreaker half_open second admit is denied while probe in flight" {
    var cb = try CircuitBreaker.init(1, 1000);
    _ = cb.admit(0);
    cb.onFailure(0);
    try std.testing.expect(cb.admit(1000));
    try std.testing.expect(!cb.admit(1001));
    try std.testing.expect(cb.state == .half_open);
    try std.testing.expect(cb.probe_in_flight);
}

test "CircuitBreaker half_open probe success closes" {
    var cb = try CircuitBreaker.init(1, 1000);
    _ = cb.admit(0);
    cb.onFailure(0);
    try std.testing.expect(cb.admit(1000));
    cb.onSuccess();
    try std.testing.expect(cb.state == .closed);
    try std.testing.expect(!cb.probe_in_flight);
    try std.testing.expectEqual(@as(u32, 0), cb.consecutive_failures);
    try std.testing.expect(cb.admit(1001));
}

test "CircuitBreaker half_open probe failure opens" {
    var cb = try CircuitBreaker.init(1, 1000);
    _ = cb.admit(0);
    cb.onFailure(0);
    try std.testing.expect(cb.admit(1000));
    cb.onFailure(1000);
    try std.testing.expect(cb.state == .open);
    try std.testing.expect(!cb.probe_in_flight);
    try std.testing.expect(!cb.admit(1001));
}

test "CircuitBreaker allowProbe moves open to half_open" {
    var cb = try CircuitBreaker.init(1, 1_000_000);
    _ = cb.admit(0);
    cb.onFailure(0);
    cb.allowProbe();
    try std.testing.expect(cb.state == .half_open);
    try std.testing.expect(cb.admit(1));
}

test "CircuitBreaker threshold 0 is InvalidInput" {
    try std.testing.expectError(error.InvalidInput, CircuitBreaker.init(0, 10));
}

test "CircuitBreaker admit and onFailure do not allocate" {
    var cb = try CircuitBreaker.init(1, 0);
    _ = cb.admit(0);
    cb.onFailure(0);
    _ = cb.admit(0);
    cb.onSuccess();
}
