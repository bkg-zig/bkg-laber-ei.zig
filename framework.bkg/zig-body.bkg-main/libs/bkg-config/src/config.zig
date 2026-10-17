/// BKG Config — process configuration from environment
///
/// No default auth token. Serve refuses to start without an operator-supplied
/// token (env `BKG_AUTH_TOKEN` or a token file).
const std = @import("std");

const env = @import("env.zig");
const validate = @import("validate.zig");
const BkgError = @import("bkg-core").errors.BkgError;

pub const DEFAULT_BIND: []const u8 = "127.0.0.1";
pub const DEFAULT_PORT: u16 = 8080;
pub const TOKEN_FILE_NAME: []const u8 = "auth.token";

pub const App = struct {
    data_dir: []const u8,
    bind: []const u8,
    port: u16,
    token_file: ?[]const u8,
    auth_token: ?[]const u8,

    pub fn fromEnv(map: *const std.process.Environ.Map) BkgError!App {
        const bind = env.getOr(map, "BKG_BIND", DEFAULT_BIND);
        try validate.requireNonEmpty("BKG_BIND", bind);

        const port = if (env.get(map, "BKG_PORT")) |p|
            try validate.parsePort(p)
        else
            DEFAULT_PORT;

        if (env.get(map, "BKG_LISTEN")) |listen| {
            _ = listen;
            // Listen is parsed by the CLI (`host:port`). Env bind/port win for
            // this struct; CLI overlay happens in the binary.
        }

        return .{
            .data_dir = env.get(map, "BKG_DATA_DIR") orelse "",
            .bind = bind,
            .port = port,
            .token_file = env.get(map, "BKG_TOKEN_FILE"),
            .auth_token = env.get(map, "BKG_AUTH_TOKEN"),
        };
    }
};

test "fromEnv has no default token" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    const cfg = try App.fromEnv(&map);
    try std.testing.expect(cfg.auth_token == null);
    try std.testing.expectEqualStrings(DEFAULT_BIND, cfg.bind);
    try std.testing.expectEqual(DEFAULT_PORT, cfg.port);
}

test "fromEnv rejects empty bind" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("BKG_BIND", "");
    try std.testing.expectError(error.InvalidInput, App.fromEnv(&map));
}
