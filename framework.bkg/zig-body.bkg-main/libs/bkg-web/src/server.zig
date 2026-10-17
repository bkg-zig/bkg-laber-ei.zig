/// BKG Web — HTTP listen loop (127.0.0.1 by default at the caller)
///
/// Does not log secrets. Client responses never include stack traces.
const std = @import("std");

const request_mod = @import("request.zig");
const response_mod = @import("response.zig");
const errors_mod = @import("errors.zig");

pub const MAX_BODY: usize = 1 * 1024 * 1024;
pub const MAX_HEAD: usize = 16 * 1024;

pub const Handler = *const fn (*anyopaque, request_mod.Request) response_mod.Response;

pub fn listen(io: std.Io, host: []const u8, port: u16) !std.Io.net.Server {
    const address = try std.Io.net.IpAddress.parse(host, port);
    return address.listen(io, .{ .reuse_address = true });
}

pub fn serveStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    ctx: *anyopaque,
    handler: Handler,
) !void {
    var in_buf: [MAX_HEAD]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);

    var http = std.http.Server.init(&reader.interface, &writer.interface);
    var request = http.receiveHead() catch {
        return;
    };

    const target = allocator.dupe(u8, request.head.target) catch return;
    defer allocator.free(target);
    const authorization = if (request_mod.headerValue(request.head_buffer, "authorization")) |h|
        allocator.dupe(u8, h) catch return
    else
        null;
    defer if (authorization) |a| allocator.free(a);

    var body_list: std.ArrayList(u8) = .empty;
    defer body_list.deinit(allocator);
    if (request.head.method.requestHasBody()) {
        var body_read_buf: [4096]u8 = undefined;
        const body_reader = request.readerExpectContinue(&body_read_buf) catch {
            respondStatic(&request, .bad_request);
            return;
        };
        body_reader.appendRemaining(allocator, &body_list, .limited(MAX_BODY)) catch {
            respondStatic(&request, .payload_too_large);
            return;
        };
    }

    const incoming = request_mod.Request{
        .method = request.head.method,
        .target = target,
        .authorization = authorization,
        .body = body_list.items,
    };

    const outgoing = handler(ctx, incoming);
    const extra = [_]std.http.Header{
        .{ .name = "content-type", .value = outgoing.content_type },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    request.respond(outgoing.body, .{
        .status = outgoing.status,
        .keep_alive = false,
        .extra_headers = &extra,
    }) catch {};
}

fn respondStatic(request: *std.http.Server.Request, status: std.http.Status) void {
    var buf: [64]u8 = undefined;
    const body = errors_mod.jsonBody(status, &buf);
    const extra = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };
    request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &extra,
    }) catch {};
}
