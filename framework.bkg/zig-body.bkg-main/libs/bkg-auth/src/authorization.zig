/// BKG Auth — authorization checks (default-deny)
const std = @import("std");

const rbac = @import("rbac.zig");
const BkgError = @import("bkg-core").errors.BkgError;

pub fn require(role: rbac.Role, permission: rbac.Permission) BkgError!void {
    if (!rbac.allows(role, permission)) return error.Forbidden;
}

test "require denies missing permission" {
    try std.testing.expectError(error.Forbidden, require(.reader, .admin));
}

test "require allows granted permission" {
    try require(.admin, .kv_delete);
}
