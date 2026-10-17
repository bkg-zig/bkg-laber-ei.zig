const std = @import("std");
const auth = @import("bkg-auth");
const config = @import("bkg-config");
const db = @import("bkg-db");
const vault = @import("bkg-vault");
const web = @import("bkg-web");

const Engine = db.engine.Engine;
const Request = web.request.Request;
const Response = web.response.Response;

const ServerContext = struct {
    allocator: std.mem.Allocator,
    engine: *Engine,
    token_hash: auth.middleware.TokenHash,
    response_body: ?[]u8 = null,
};

pub fn main(init: std.process.Init) void {
    run(init) catch {
        std.debug.print("bkg: command failed\n", .{});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or isHelp(args[1])) {
        try printUsage(io);
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "init")) {
        if (args.len != 3) return error.InvalidArguments;
        try initialize(io, allocator, args[2]);
        return;
    }
    if (std.mem.eql(u8, command, "put")) {
        if (args.len != 5) return error.InvalidArguments;
        var engine = try Engine.open(allocator, io, args[2]);
        defer engine.close();
        const txn = try engine.begin();
        defer engine.freeTxn(txn);
        try engine.put(txn, args[3], args[4]);
        try engine.commit(txn);
        return;
    }
    if (std.mem.eql(u8, command, "get")) {
        if (args.len != 4) return error.InvalidArguments;
        var engine = try Engine.open(allocator, io, args[2]);
        defer engine.close();
        const txn = try engine.begin();
        defer engine.freeTxn(txn);
        const value = engine.get(txn, args[3]) orelse return error.KeyNotFound;
        try std.Io.File.stdout().writeStreamingAll(io, value);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        return;
    }
    if (std.mem.eql(u8, command, "delete")) {
        if (args.len != 4) return error.InvalidArguments;
        var engine = try Engine.open(allocator, io, args[2]);
        defer engine.close();
        const txn = try engine.begin();
        defer engine.freeTxn(txn);
        try engine.delete(txn, args[3]);
        try engine.commit(txn);
        return;
    }
    if (std.mem.eql(u8, command, "status")) {
        if (args.len != 3) return error.InvalidArguments;
        var engine = try Engine.open(allocator, io, args[2]);
        defer engine.close();
        try std.Io.File.stdout().writeStreamingAll(io, "{\"ok\":true}\n");
        return;
    }
    if (std.mem.eql(u8, command, "serve")) {
        if (args.len < 3) return error.InvalidArguments;
        try serve(init, args[2], args[3..]);
        return;
    }

    return error.InvalidArguments;
}

fn initialize(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !void {
    var engine = try Engine.open(allocator, io, data_dir);
    engine.close();

    const token = try vault.random.token32(io);
    var encoded: [vault.random.TOKEN_SIZE * 2]u8 = undefined;
    const token_hex = vault.random.hexEncode(&token, &encoded);
    const token_path = try std.fs.path.join(allocator, &.{ data_dir, config.config.TOKEN_FILE_NAME });
    defer allocator.free(token_path);

    var token_file = try std.Io.Dir.cwd().createFile(io, token_path, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    });
    defer token_file.close(io);
    try token_file.writeStreamingAll(io, token_hex);
    try token_file.writeStreamingAll(io, "\n");
    try token_file.sync(io);
}

fn serve(init: std.process.Init, data_dir: []const u8, options: []const []const u8) !void {
    const allocator = init.gpa;
    const io = init.io;
    var app_config = try config.config.App.fromEnv(init.environ_map);
    app_config.data_dir = data_dir;

    var option_index: usize = 0;
    while (option_index < options.len) : (option_index += 1) {
        const option = options[option_index];
        if (std.mem.eql(u8, option, "--bind") or std.mem.eql(u8, option, "--port") or std.mem.eql(u8, option, "--token-file")) {
            if (option_index + 1 >= options.len) return error.InvalidArguments;
            option_index += 1;
            const value = options[option_index];
            if (std.mem.eql(u8, option, "--bind")) {
                app_config.bind = value;
            } else if (std.mem.eql(u8, option, "--port")) {
                app_config.port = try std.fmt.parseUnsigned(u16, value, 10);
                if (app_config.port == 0) return error.InvalidArguments;
            } else {
                app_config.token_file = value;
            }
        } else {
            return error.InvalidArguments;
        }
    }

    const token = if (app_config.auth_token) |value|
        value
    else blk: {
        const token_path = app_config.token_file orelse try std.fs.path.join(allocator, &.{ data_dir, config.config.TOKEN_FILE_NAME });
        defer if (app_config.token_file == null) allocator.free(token_path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, token_path, allocator, .limited(4096));
        defer allocator.free(bytes);
        break :blk std.mem.trim(u8, bytes, " \t\r\n");
    };
    if (token.len == 0) return error.MissingAuthToken;

    var engine = try Engine.open(allocator, io, data_dir);
    defer engine.close();
    var listener = try web.server.listen(io, app_config.bind, app_config.port);
    defer listener.deinit(io);
    var context = ServerContext{
        .allocator = allocator,
        .engine = &engine,
        .token_hash = auth.middleware.hashToken(token),
    };

    while (true) {
        var stream = try listener.accept(io);
        {
            defer stream.close(io);
            context.response_body = null;
            web.server.serveStream(io, allocator, stream, &context, handleRequest) catch {};
            if (context.response_body) |body| {
                allocator.free(body);
                context.response_body = null;
            }
        }
    }
}

fn handleRequest(raw_context: *anyopaque, request: Request) Response {
    const context: *ServerContext = @ptrCast(@alignCast(raw_context));
    const path = request.path();
    const route = web.router.classify(path);

    if (route == .health and request.method == .GET) {
        return makeResponse(context, .ok, "{\"ok\":true}", "application/json");
    }
    if (route == .unknown or route == .health) {
        return makeResponse(context, .not_found, "{\"error\":\"not found\"}", "application/json");
    }
    if (web.middleware.requireBearer(request, &context.token_hash)) |_| {} else |_| {
        return makeResponse(context, .unauthorized, "{\"error\":\"unauthorized\"}", "application/json");
    }

    if (route == .status and request.method == .GET) {
        return makeResponse(context, .ok, "{\"ok\":true}", "application/json");
    }
    if (route == .status) {
        return makeResponse(context, .method_not_allowed, "{\"error\":\"method not allowed\"}", "application/json");
    }

    const key = web.router.kvKey(path) orelse return makeResponse(context, .not_found, "{\"error\":\"not found\"}", "application/json");
    if (request.method == .GET) {
        const txn = context.engine.begin() catch return internalError(context);
        defer context.engine.freeTxn(txn);
        const value = context.engine.get(txn, key) orelse return makeResponse(context, .not_found, "{\"error\":\"not found\"}", "application/json");
        return makeResponse(context, .ok, value, "application/octet-stream");
    }
    if (request.method == .PUT) {
        const txn = context.engine.begin() catch return internalError(context);
        defer context.engine.freeTxn(txn);
        context.engine.put(txn, key, request.body) catch return internalError(context);
        context.engine.commit(txn) catch return internalError(context);
        return makeResponse(context, .ok, "{\"ok\":true}", "application/json");
    }
    if (request.method == .DELETE) {
        const txn = context.engine.begin() catch return internalError(context);
        defer context.engine.freeTxn(txn);
        context.engine.delete(txn, key) catch return internalError(context);
        context.engine.commit(txn) catch return internalError(context);
        return makeResponse(context, .ok, "{\"ok\":true}", "application/json");
    }
    return makeResponse(context, .method_not_allowed, "{\"error\":\"method not allowed\"}", "application/json");
}

fn makeResponse(context: *ServerContext, status: std.http.Status, body: []const u8, content_type: []const u8) Response {
    context.response_body = context.allocator.dupe(u8, body) catch null;
    const response_body = context.response_body orelse "{\"error\":\"internal error\"}";
    return .{ .status = status, .content_type = content_type, .body = response_body };
}

fn internalError(context: *ServerContext) Response {
    return makeResponse(context, .internal_server_error, "{\"error\":\"internal error\"}", "application/json");
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn printUsage(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        "bkg init <data-dir>\n" ++
        "bkg put <data-dir> <key> <value>\n" ++
        "bkg get <data-dir> <key>\n" ++
        "bkg delete <data-dir> <key>\n" ++
        "bkg status <data-dir>\n" ++
        "bkg serve <data-dir> [--bind <address>] [--port <port>] [--token-file <path>]\n",
    );
}