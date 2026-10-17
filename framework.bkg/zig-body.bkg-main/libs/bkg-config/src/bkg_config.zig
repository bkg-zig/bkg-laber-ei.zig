/// BKG Config — TOML, Environment, CLI Args, Defaults, Validation
pub const config = @import("config.zig");
pub const env = @import("env.zig");
pub const toml = @import("toml.zig");
pub const validate = @import("validate.zig");

test {
    _ = config;
    _ = env;
    _ = validate;
}
