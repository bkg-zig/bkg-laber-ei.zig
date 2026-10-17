/// bkg-ws — Native WebSocket-Implementierung (RFC 6455)
///
/// Root-Modul: Re-exportiert alle Sub-Module.
///
/// Sub-Module:
///   handshake — HTTP Upgrade Handshake (SHA-1 + Base64 + 101)
///   frame     — Frame Codec (Opcodes, Masking, Payload-Limits)
///   ws        — WebSocket Lifecycle (accept/recv/send/close)
///
/// Schicht-Zugehörigkeit: banana.bkg / lib/bkg-ws/
/// Verwendet: ausschließlich std (Zig 0.16)
pub const handshake = @import("handshake.zig");
pub const frame     = @import("frame.zig");
pub const ws        = @import("ws.zig");

// Re-Exporte für Komfort-Zugriff
pub const Opcode       = frame.Opcode;
pub const FrameHeader  = frame.FrameHeader;
pub const ParseError   = frame.ParseError;
pub const MAX_PAYLOAD  = frame.MAX_PAYLOAD;
pub const WebSocket    = ws.WebSocket;
pub const ReceivedFrame = ws.ReceivedFrame;
pub const AcceptOptions = ws.AcceptOptions;

test {
    _ = handshake;
    _ = frame;
    _ = ws;
}
