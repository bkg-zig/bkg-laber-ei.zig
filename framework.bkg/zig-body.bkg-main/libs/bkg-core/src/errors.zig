/// BKG Core — Error Types
///
/// Zentrale Fehlertypen für das gesamte Framework.
const std = @import("std");

// ── Framework Fehler ──────────────────────────────────────────────────────

pub const BkgError = error{
    // Allgemein
    NotFound,
    AlreadyExists,
    InvalidInput,
    Unauthorized,
    Forbidden,
    InternalError,
    NotImplemented,
    Timeout,
    Cancelled,

    // Storage
    DatabaseError,
    MigrationFailed,
    TransactionFailed,
    ConnectionFailed,

    // Auth
    InvalidCredentials,
    SessionExpired,
    SessionRevoked,
    TokenInvalid,
    TokenExpired,
    PasswordTooWeak,
    AccountDisabled,
    AccountNotActivated,

    // Secrets
    EncryptionFailed,
    DecryptionFailed,
    KeyNotFound,
    SecretTampered,

    // Rate Limiting
    RateLimitExceeded,
    CapacityExceeded,
    QuotaExceeded,

    // Provider
    ProviderUnavailable,
    ProviderError,
    ProviderRateLimit,
    ProviderAuthFailed,
    ProviderTimeout,
    StreamingError,
};

// ── HTTP Status Mapping ───────────────────────────────────────────────────

pub fn httpStatus(err: BkgError) u16 {
    return switch (err) {
        error.NotFound => 404,
        error.AlreadyExists => 409,
        error.InvalidInput => 400,
        error.Unauthorized, error.InvalidCredentials, error.TokenInvalid, error.TokenExpired => 401,
        error.Forbidden => 403,
        error.SessionExpired, error.SessionRevoked => 401,
        error.RateLimitExceeded, error.ProviderRateLimit => 429,
        error.CapacityExceeded, error.QuotaExceeded => 429,
        else => 500,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "httpStatus not_found" {
    try std.testing.expectEqual(@as(u16, 404), httpStatus(error.NotFound));
}

test "httpStatus unauthorized" {
    try std.testing.expectEqual(@as(u16, 401), httpStatus(error.Unauthorized));
}

test "httpStatus rate_limit" {
    try std.testing.expectEqual(@as(u16, 429), httpStatus(error.RateLimitExceeded));
}
