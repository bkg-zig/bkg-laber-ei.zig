/// BKG CLI — argument parser
///
/// Supports `--name value`, `--name=value`, `-n value`, and `--help` / `-h`.
/// Unknown flags are errors. Positionals after the command name are collected.
const std = @import("std");

const BkgError = @import("bkg-core").errors.BkgError;

pub const Parsed = struct {
    allocator: std.mem.Allocator,
    program: []const u8,
    command: ?[]const u8,
    positionals: [][]const u8,
    flags: std.StringHashMap([]const u8),
    help: bool,

    pub fn deinit(self: *Parsed) void {
        self.allocator.free(self.positionals);
        self.flags.deinit();
    }

    pub fn flag(self: *const Parsed, name: []const u8) ?[]const u8 {
        return self.flags.get(name);
    }

    pub fn hasFlag(self: *const Parsed, name: []const u8) bool {
        return self.flags.contains(name);
    }
};

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Parsed {
    if (argv.len == 0) return BkgError.InvalidInput;

    var flags = std.StringHashMap([]const u8).init(allocator);
    errdefer flags.deinit();
    var positionals: std.ArrayList([]const u8) = .empty;
    errdefer positionals.deinit(allocator);

    var help = false;
    var command: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            const body = arg[2..];
            if (body.len == 0) return BkgError.InvalidInput;
            if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
                if (eq == 0) return BkgError.InvalidInput;
                try flags.put(body[0..eq], body[eq + 1 ..]);
            } else {
                if (i + 1 >= argv.len) return BkgError.InvalidInput;
                i += 1;
                try flags.put(body, argv[i]);
            }
            continue;
        }
        if (arg.len >= 2 and arg[0] == '-' and arg[1] != '-') {
            if (arg.len != 2) return BkgError.InvalidInput;
            if (i + 1 >= argv.len) return BkgError.InvalidInput;
            i += 1;
            const name = shortName(arg[1]) orelse return BkgError.InvalidInput;
            try flags.put(name, argv[i]);
            continue;
        }
        if (command == null) {
            command = arg;
        } else {
            try positionals.append(allocator, arg);
        }
    }

    return .{
        .allocator = allocator,
        .program = argv[0],
        .command = command,
        .positionals = try positionals.toOwnedSlice(allocator),
        .flags = flags,
        .help = help,
    };
}

fn shortName(c: u8) ?[]const u8 {
    return switch (c) {
        'p' => "port",
        'b' => "bind",
        't' => "token-file",
        else => null,
    };
}

test "parse command and positionals" {
    const argv = [_][]const u8{ "bkg", "put", "data", "k", "v" };
    var parsed = try parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("put", parsed.command.?);
    try std.testing.expectEqual(@as(usize, 3), parsed.positionals.len);
    try std.testing.expectEqualStrings("data", parsed.positionals[0]);
}

test "parse long flags" {
    const argv = [_][]const u8{ "bkg", "serve", "data", "--port", "9090", "--bind=127.0.0.1" };
    var parsed = try parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("9090", parsed.flag("port").?);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.flag("bind").?);
}

test "parse help" {
    const argv = [_][]const u8{ "bkg", "--help" };
    var parsed = try parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try std.testing.expect(parsed.help);
    try std.testing.expect(parsed.command == null);
}

test "missing flag value is an error" {
    const argv = [_][]const u8{ "bkg", "serve", "--port" };
    try std.testing.expectError(error.InvalidInput, parse(std.testing.allocator, &argv));
}
