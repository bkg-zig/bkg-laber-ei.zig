/// BKG Web — default-deny Bearer middleware
const std = @import("std");

const auth = @import("bkg-auth");
const request_mod = @import("request.zig");
const BkgError = @import("bkg-core").errors.BkgError;

pub fn requireBearer(req: request_mod.Request, expected_hash: *const auth.middleware.TokenHash) BkgError![]const u8 {
    return auth.middleware.requireBearer(req.authorization, expected_hash);
}

test "middleware denies missing bearer" {
    const expected = auth.middleware.hashToken("secret-token");
    const req = request_mod.Request{
        .method = .GET,
        .target = "/v1/status",
        .authorization = null,
        .body = "",
    };
    try std.testing.expectError(error.Unauthorized, requireBearer(req, &expected));
}

test "middleware accepts matching bearer" {
    const expected = auth.middleware.hashToken("secret-token");
    const req = request_mod.Request{
        .method = .GET,
        .target = "/v1/status",
        .authorization = "Bearer secret-token",
        .body = "",
    };
    const token = try requireBearer(req, &expected);
    try std.testing.expectEqualStrings("secret-token", token);
}
