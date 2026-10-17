// bkg-docker — Wiederverwendbarer Docker-Unix-Socket-Client
//
// Re-exportiert alle Sub-Module:
//   client  — HTTP-Client über Unix-Domain-Socket
//   stream  — Streaming-Antwort (Events, Logs) via Zeilenweise Callbacks
//   demux   — Docker Multiplexed Stream Decoder (stdout/stderr trennen)
pub const client = @import("client.zig");
pub const stream = @import("stream.zig");
pub const demux  = @import("demux.zig");
