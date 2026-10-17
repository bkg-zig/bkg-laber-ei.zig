/// BKGDB — Schema-Definitionen
///
/// Alle Schema-Definitionen in Zig-Typen — kein SQL, kein Schema-String.
///
/// Typen:
///   FieldType     — Datentypen für Felder
///   FieldDef      — Felddefinition mit Name und Typ
///   IndexDef      — Index-Definition (unique/non-unique, Felder)
///   CollectionDef — vollständige Collection-Definition
///
/// Collections sind Named Sets von Feldern mit optionalen Indexes.
/// Der Primary Key ist immer Feld 0 (UUID-String oder u64).
const std = @import("std");

// ── Field-Typen ───────────────────────────────────────────────────────────

pub const FieldType = enum {
    uuid,       // 36-Byte UUID-String
    text,       // variable-length String
    bytes,      // variable-length Byte-Array
    u8_val,
    u16_val,
    u32_val,
    u64_val,
    i64_val,
    bool_val,
    timestamp,  // i64 Unix-Timestamp in Sekunden
    hash32,     // 32-Byte Hash (SHA256)
};

// ── FieldDef ──────────────────────────────────────────────────────────────

pub const FieldDef = struct {
    name: []const u8,
    field_type: FieldType,
    nullable: bool = false,
};

// ── IndexDef ──────────────────────────────────────────────────────────────

pub const IndexDef = struct {
    name: []const u8,
    field_names: []const []const u8,
    unique: bool = false,
};

// ── CollectionDef ─────────────────────────────────────────────────────────

pub const CollectionDef = struct {
    name: []const u8,
    fields: []const FieldDef,
    indexes: []const IndexDef = &.{},
};

// ── Kanonische eviladmin-Collections ─────────────────────────────────────

/// users
pub const USERS: CollectionDef = .{
    .name = "users",
    .fields = &.{
        .{ .name = "id",            .field_type = .uuid },
        .{ .name = "username",      .field_type = .text },
        .{ .name = "email",         .field_type = .text },
        .{ .name = "password_hash", .field_type = .text },
        .{ .name = "role",          .field_type = .text },
        .{ .name = "status",        .field_type = .text },
        .{ .name = "created_at",    .field_type = .timestamp },
        .{ .name = "updated_at",    .field_type = .timestamp },
    },
    .indexes = &.{
        .{ .name = "idx_users_username", .field_names = &.{"username"}, .unique = true },
        .{ .name = "idx_users_email",    .field_names = &.{"email"},    .unique = true },
    },
};

/// sessions
pub const SESSIONS: CollectionDef = .{
    .name = "sessions",
    .fields = &.{
        .{ .name = "id",            .field_type = .uuid },
        .{ .name = "user_id",       .field_type = .uuid },
        .{ .name = "credential_id", .field_type = .uuid,    .nullable = true },
        .{ .name = "session_key",   .field_type = .text },
        .{ .name = "peer_id",       .field_type = .text,    .nullable = true },
        .{ .name = "expires_at",    .field_type = .timestamp },
        .{ .name = "revoked_at",    .field_type = .timestamp, .nullable = true },
        .{ .name = "created_at",    .field_type = .timestamp },
    },
    .indexes = &.{
        .{ .name = "idx_sessions_user_id",  .field_names = &.{"user_id"} },
        .{ .name = "idx_sessions_key",      .field_names = &.{"session_key"}, .unique = true },
    },
};

/// accounts
pub const ACCOUNTS: CollectionDef = .{
    .name = "accounts",
    .fields = &.{
        .{ .name = "id",            .field_type = .uuid },
        .{ .name = "owner_user_id", .field_type = .uuid },
        .{ .name = "display_name",  .field_type = .text },
        .{ .name = "provider",      .field_type = .text },
        .{ .name = "status",        .field_type = .text },
        .{ .name = "capacity_tps",  .field_type = .u32_val },
        .{ .name = "created_at",    .field_type = .timestamp },
        .{ .name = "updated_at",    .field_type = .timestamp },
    },
    .indexes = &.{
        .{ .name = "idx_accounts_owner", .field_names = &.{"owner_user_id"} },
    },
};

/// credentials
pub const CREDENTIALS: CollectionDef = .{
    .name = "credentials",
    .fields = &.{
        .{ .name = "id",               .field_type = .uuid },
        .{ .name = "account_id",       .field_type = .uuid },
        .{ .name = "owner_user_id",    .field_type = .uuid },
        .{ .name = "provider",         .field_type = .text },
        .{ .name = "encrypted_secret", .field_type = .bytes },
        .{ .name = "secret_nonce",     .field_type = .bytes },
        .{ .name = "secret_hash",      .field_type = .hash32 },
        .{ .name = "preview",          .field_type = .text },
        .{ .name = "status",           .field_type = .text },
        .{ .name = "cooldown_until",   .field_type = .timestamp, .nullable = true },
        .{ .name = "last_used_at",     .field_type = .timestamp, .nullable = true },
        .{ .name = "last_error_at",    .field_type = .timestamp, .nullable = true },
        .{ .name = "error_count",      .field_type = .u32_val },
        .{ .name = "request_count",    .field_type = .u64_val },
        .{ .name = "created_at",       .field_type = .timestamp },
    },
    .indexes = &.{
        .{ .name = "idx_cred_account",  .field_names = &.{"account_id"},   .unique = true },
        .{ .name = "idx_cred_hash",     .field_names = &.{"secret_hash"},  .unique = true },
        .{ .name = "idx_cred_owner",    .field_names = &.{"owner_user_id"} },
        .{ .name = "idx_cred_status",   .field_names = &.{"status"} },
    },
};

/// pools
pub const POOLS: CollectionDef = .{
    .name = "pools",
    .fields = &.{
        .{ .name = "id",          .field_type = .uuid },
        .{ .name = "owner_id",    .field_type = .uuid },
        .{ .name = "name",        .field_type = .text },
        .{ .name = "description", .field_type = .text, .nullable = true },
        .{ .name = "pool_type",   .field_type = .text },
        .{ .name = "status",      .field_type = .text },
        .{ .name = "created_at",  .field_type = .timestamp },
    },
    .indexes = &.{
        .{ .name = "idx_pools_owner", .field_names = &.{"owner_id"} },
    },
};

/// key_health
pub const KEY_HEALTH: CollectionDef = .{
    .name = "key_health",
    .fields = &.{
        .{ .name = "credential_id", .field_type = .uuid },
        .{ .name = "model",         .field_type = .text },
        .{ .name = "healthy",       .field_type = .bool_val },
        .{ .name = "error_rate",    .field_type = .u32_val },
        .{ .name = "avg_latency_ms",.field_type = .u32_val },
        .{ .name = "updated_at",    .field_type = .timestamp },
    },
    .indexes = &.{
        .{ .name = "idx_key_health_cred_model", .field_names = &.{ "credential_id", "model" }, .unique = true },
    },
};

// ── BKG Network Collections ───────────────────────────────────────────────

/// peer_state
pub const PEER_STATE: CollectionDef = .{
    .name = "peer_state",
    .fields = &.{
        .{ .name = "id",                    .field_type = .uuid },
        .{ .name = "zone_id",               .field_type = .text, .nullable = true },
        .{ .name = "status",                .field_type = .text },
        .{ .name = "collateral",            .field_type = .u64_val },
        .{ .name = "guardian_manifest_hash",.field_type = .hash32, .nullable = true },
        .{ .name = "joined_at",             .field_type = .timestamp },
        .{ .name = "updated_at",            .field_type = .timestamp },
    },
    .indexes = &.{
        .{ .name = "idx_peer_zone", .field_names = &.{"zone_id"} },
    },
};

/// guardian_state
pub const GUARDIAN_STATE: CollectionDef = .{
    .name = "guardian_state",
    .fields = &.{
        .{ .name = "id",          .field_type = .uuid },
        .{ .name = "peer_id",     .field_type = .uuid },
        .{ .name = "role",        .field_type = .text },  // "behavior" | "economy"
        .{ .name = "version",     .field_type = .u32_val },
        .{ .name = "model_hash",  .field_type = .hash32 },
        .{ .name = "policy_hash", .field_type = .hash32 },
        .{ .name = "forge_epoch", .field_type = .u64_val },
        .{ .name = "updated_at",  .field_type = .timestamp },
    },
    .indexes = &.{
        .{ .name = "idx_guardian_peer", .field_names = &.{"peer_id"} },
    },
};

/// All-Collections Registry
pub const ALL_COLLECTIONS: []const CollectionDef = &.{
    USERS, SESSIONS, ACCOUNTS, CREDENTIALS, POOLS, KEY_HEALTH,
    PEER_STATE, GUARDIAN_STATE,
};

// ── Hilfsfunktionen ───────────────────────────────────────────────────────

/// Gibt die CollectionDef für einen Namen zurück, oder null.
pub fn findCollection(name: []const u8) ?CollectionDef {
    for (ALL_COLLECTIONS) |col| {
        if (std.mem.eql(u8, col.name, name)) return col;
    }
    return null;
}

/// Gibt die FieldDef für einen Namen in einer Collection, oder null.
pub fn findField(col: CollectionDef, name: []const u8) ?FieldDef {
    for (col.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "schema: all collections have at least one field" {
    for (ALL_COLLECTIONS) |col| {
        try std.testing.expect(col.fields.len > 0);
        // Erstes Feld muss "id" sein
        try std.testing.expectEqualStrings("id", col.fields[0].name);
    }
}

test "schema: findCollection" {
    const col = findCollection("users").?;
    try std.testing.expectEqualStrings("users", col.name);
    try std.testing.expect(findCollection("nonexistent") == null);
}

test "schema: findField" {
    const col = findCollection("credentials").?;
    const f = findField(col, "status").?;
    try std.testing.expectEqualStrings("status", f.name);
    try std.testing.expect(findField(col, "nosuchfield") == null);
}

test "schema: credentials unique constraints defined" {
    const col = findCollection("credentials").?;
    var has_account_unique = false;
    var has_hash_unique = false;
    for (col.indexes) |idx| {
        if (idx.unique and std.mem.eql(u8, idx.field_names[0], "account_id")) has_account_unique = true;
        if (idx.unique and std.mem.eql(u8, idx.field_names[0], "secret_hash")) has_hash_unique = true;
    }
    try std.testing.expect(has_account_unique);
    try std.testing.expect(has_hash_unique);
}

test "schema: guardian_state has role and version fields" {
    const col = findCollection("guardian_state").?;
    try std.testing.expect(findField(col, "role") != null);
    try std.testing.expect(findField(col, "version") != null);
    try std.testing.expect(findField(col, "model_hash") != null);
    try std.testing.expect(findField(col, "forge_epoch") != null);
}
