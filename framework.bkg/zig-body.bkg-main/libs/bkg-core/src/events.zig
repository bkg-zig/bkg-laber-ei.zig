/// BKG Core — Events
///
/// Minimales Event-System für interne Kommunikation.
const std = @import("std");

// ── Event-Typen ───────────────────────────────────────────────────────────

pub const EventKind = enum {
    // Lifecycle
    app_started,
    app_stopping,
    app_stopped,

    // User
    user_created,
    user_updated,
    user_suspended,
    user_deleted,

    // Auth
    user_logged_in,
    user_logged_out,
    session_expired,
    session_revoked,

    // Account / Credential
    account_added,
    account_removed,
    credential_added,
    credential_revoked,
    credential_cooldown,
    credential_recovered,
    credential_rotated,

    // Pool
    pool_created,
    pool_updated,
    pool_deleted,
    pool_member_added,
    pool_member_removed,

    // Request
    request_started,
    request_completed,
    request_failed,
    request_queued,

    // Capacity
    rate_limit_reached,
    pool_capacity_changed,
    cluster_capacity_changed,

    // Model
    model_unavailable,
    model_recovered,

    // Admin
    admin_action,
};

pub const Event = struct {
    kind: EventKind,
    /// Eindeutige Event-ID
    id: []const u8,
    /// Betroffene Entity-ID (optional)
    entity_id: ?[]const u8 = null,
    /// Auslösender User (optional)
    actor_id: ?[]const u8 = null,
    /// Zeitstempel in Millisekunden
    timestamp_ms: i64,
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "Event creation" {
    const e = Event{
        .kind = .user_created,
        .id = "evt-001",
        .entity_id = "user-123",
        .timestamp_ms = 1000,
    };
    try std.testing.expectEqual(EventKind.user_created, e.kind);
    try std.testing.expectEqualStrings("user-123", e.entity_id.?);
}
