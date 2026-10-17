/// BKG Auth — RBAC, default-deny
const std = @import("std");

pub const Permission = enum {
    kv_read,
    kv_write,
    kv_delete,
    ledger_append,
    admin,
};

pub const Role = enum {
    none,
    reader,
    writer,
    admin,
};

pub fn allows(role: Role, permission: Permission) bool {
    return switch (role) {
        .none => false,
        .reader => switch (permission) {
            .kv_read => true,
            .kv_write, .kv_delete, .ledger_append, .admin => false,
        },
        .writer => switch (permission) {
            .kv_read, .kv_write, .kv_delete, .ledger_append => true,
            .admin => false,
        },
        .admin => true,
    };
}

test "default deny for none" {
    try std.testing.expect(!allows(.none, .kv_read));
    try std.testing.expect(!allows(.none, .kv_write));
    try std.testing.expect(!allows(.none, .admin));
}

test "reader cannot write" {
    try std.testing.expect(allows(.reader, .kv_read));
    try std.testing.expect(!allows(.reader, .kv_write));
    try std.testing.expect(!allows(.reader, .admin));
}

test "writer cannot admin" {
    try std.testing.expect(allows(.writer, .kv_write));
    try std.testing.expect(!allows(.writer, .admin));
}

test "admin has every permission" {
    inline for (@typeInfo(Permission).@"enum".fields) |field| {
        const perm: Permission = @enumFromInt(field.value);
        try std.testing.expect(allows(.admin, perm));
    }
}
