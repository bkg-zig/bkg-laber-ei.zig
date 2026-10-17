/// BKG Web — HTTP Server, Router, Middleware, SSE, WebSocket, Templates
///
/// Usable v1 surface: server, router, request, response, middleware (Bearer),
/// json, errors. Other files remain unimplemented rather than stubbed as success.
pub const server = @import("server.zig");
pub const connection = @import("connection.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const router = @import("router.zig");
pub const middleware = @import("middleware.zig");
pub const context = @import("context.zig");
pub const cookies = @import("cookies.zig");
pub const sse = @import("sse.zig");
pub const websocket = @import("websocket.zig");
pub const static_files = @import("static_files.zig");
pub const template = @import("template.zig");
pub const compression = @import("compression.zig");
pub const json = @import("json.zig");
pub const errors = @import("errors.zig");
pub const testing = @import("testing.zig");

test {
    _ = server;
    _ = request;
    _ = response;
    _ = router;
    _ = middleware;
    _ = json;
    _ = errors;
}
