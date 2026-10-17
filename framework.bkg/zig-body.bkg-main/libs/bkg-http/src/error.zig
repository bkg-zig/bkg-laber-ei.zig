//! Typed error set for bkg-http Client v1.
//! Failures are never encoded as strings. See docs/BKG_HTTP_CLIENT_v1.md.

const std = @import("std");

pub const Error = error{
    InvalidInput,
    Timeout,
    ConnectionFailed,
    TlsRequired,
    TlsFailure,
    Protocol,
    RetryBudgetExceeded,
    CircuitOpen,
    PoolExhausted,
    Cancelled,
    NotImplemented,
};

test "error set is typed not stringly" {
    const e: Error = error.CircuitOpen;
    try std.testing.expect(e == error.CircuitOpen);
}
