/// BKG CLI — Commands, Subcommands, Flags, Args, Output Formatting
pub const app = @import("app.zig");
pub const command = @import("command.zig");
pub const flag = @import("flag.zig");
pub const output = @import("output.zig");
pub const table = @import("table.zig");
pub const progress = @import("progress.zig");

test {
    _ = app;
    _ = command;
    _ = flag;
}
