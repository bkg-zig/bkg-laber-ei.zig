//! TLS transport is not part of bkg-http Client v1.
//!
//! A later PR adds a distinct TLS type wrapping a stream owned by Connection.
//! This module must not handshake, encrypt, or return success for a secure
//! session. There is no dummy encrypt and no flag that skips TLS.
//!
//! `Client.initSecure` returns `error.NotImplemented` until a TLS PR lands.
//! A secure client given `http://` returns `error.TlsRequired` — never
//! cleartext fallback. Frozen bkg-db crypto modules are not used here.

const std = @import("std");
const Error = @import("error.zig").Error;

/// Handle reserved for a future TLS session. Absent in v1.
pub const TlsSession = struct {
    _never_constructed_in_v1: void,
};

pub fn openSecure() Error!void {
    return error.NotImplemented;
}

test "TLS v1 has no success path" {
    try std.testing.expectError(error.NotImplemented, openSecure());
}
