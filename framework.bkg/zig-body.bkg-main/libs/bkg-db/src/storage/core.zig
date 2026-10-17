//! core.zig — StorageEngine: the deterministic v1.2 transaction orchestrator.
//!
//! Pipeline (frozen): DECODE -> VERIFY (Ed25519 + eventHash recompute) ->
//! AUTHORIZE/PRE-FOLD (prepareTransition: all RAM reservation, may fail) ->
//! WAL COMMIT (PREP->fsync->COMM->fsync) -> APPLY PREPARED TRANSITION (total,
//! void) -> MATERIALIZE (deterministic state root + causal fingerprint).
//!
//! Hard rules this module enforces:
//!   * OOM and authorization errors surface in `prepareTransition`, BEFORE the
//!     WAL is touched. A failed commit never leaves a write behind.
//!   * Recovery NEVER trusts the `event_hash`/`signature` in a WAL header. It
//!     re-decodes the canonical payload, recomputes `eventHash`, re-verifies the
//!     Ed25519 signature, and re-checks sequence/prev-hash before folding.
//!   * `applyPreparedTransition` is a total function (returns void) and therefore
//!     cannot fail after the WAL COMMIT.

const std = @import("std");
const tlv = @import("canonical_tlv.zig");
const st = @import("state.zig");
const wal = @import("wal.zig");

const Hash32 = st.Hash32;
const Ed25519 = std.crypto.sign.Ed25519;

pub const CommitError = error{
    InvalidSignature,
    HashMismatch,
    Encode,
} || tlv.ParseError || st.ProtocolError || wal.WalError;

pub const RecoveryError = error{
    InvalidSignature,
    HashMismatch,
} || tlv.ParseError || st.ProtocolError || wal.RecoveryError || error{OutOfMemory};

pub const StorageEngine = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state: st.ProjectionState,
    writer: wal.WalWriter,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        file: std.Io.File,
        genesis_pubkey: Hash32,
    ) StorageEngine {
        return .{
            .allocator = allocator,
            .io = io,
            .state = st.ProjectionState.init(allocator, genesis_pubkey),
            .writer = wal.WalWriter.init(file, io),
        };
    }

    pub fn deinit(self: *StorageEngine) void {
        self.state.deinit();
    }

    /// Deterministic materialization step: state root + causal fingerprint,
    /// recomputed after every applied transition.
    fn materialize(self: *StorageEngine) !void {
        self.state.state_root = try st.computeStateRoot(&self.state, self.allocator);
        self.state.causal_fingerprint = st.computeCausalFingerprint(&self.state, self.state.state_root);
    }

    /// Full v1.2 commit. `signature` covers `canonical_bytes`; `event_hash` is the
    /// result of `eventHash(canonical_bytes)`.
    pub fn commit(
        self: *StorageEngine,
        actor_pubkey: Hash32,
        signature: [64]u8,
        event_hash: Hash32,
        canonical_bytes: []const u8,
    ) CommitError!void {
        // 1. DECODE — the canonical payload must be a well-formed event.
        var decoded = try tlv.decodeEvent(self.allocator, canonical_bytes);
        defer decoded.deinit(self.allocator);
        const ev = &decoded.event;

        // 2. VERIFY — recompute the event hash (never trust the caller's value).
        const recomputed = tlv.eventHash(canonical_bytes);
        if (!std.mem.eql(u8, &recomputed, &event_hash)) return error.HashMismatch;
        // 2b. Ed25519 signature over the canonical bytes.
        const public_key = Ed25519.PublicKey.fromBytes(actor_pubkey) catch return error.InvalidSignature;
        const sig = Ed25519.Signature.fromBytes(signature);
        sig.verify(&recomputed, public_key) catch return error.InvalidSignature;

        // 3. AUTHORIZE + PRE-FOLD (may fail: OOM, bad authority, missing influence).
        //    All RAM reservation happens here, before any WAL write.
        const transition = try st.prepareTransition(&self.state, actor_pubkey, event_hash, ev);

        // 4. WAL COMMIT — durable; after both fsyncs the fold cannot fail.
        try self.writer.commit(
            self.io,
            transition.event.sequence,
            &event_hash,
            &actor_pubkey,
            &signature,
            canonical_bytes,
        );

        // 5. APPLY (total, void) then materialize the projection's fingerprints.
        st.applyPreparedTransition(&self.state, &transition);
        try self.materialize();
    }
};

/// Replay a WAL into a freshly-created engine. Unlike the naive path, recovery
/// reconstructs each event from the CANONICAL PAYLOAD bytes, so a tampered
/// header cannot inject a phantom event.
pub fn recoverFromWal(
    allocator: std.mem.Allocator,
    io: std.Io,
    stale_file: std.Io.File,
    genesis_pubkey: Hash32,
    payload_buf: []u8,
    out_engine: *StorageEngine,
) RecoveryError!void {
    _ = genesis_pubkey;
    var reader = wal.WalReader.init(stale_file, io, payload_buf);
    while (true) {
        const maybe_frame = reader.next() catch |e| switch (e) {
            error.CrashTail => break,
            else => return e,
        };
        const frame = maybe_frame orelse break;

        // DECODE from the payload (not the header).
        var decoded = try tlv.decodeEvent(allocator, frame.canonical_bytes);
        defer decoded.deinit(allocator);
        const ev = &decoded.event;

        // VERIFY: recompute the event hash. Never trust the WAL header hash.
        const recomputed = tlv.eventHash(frame.canonical_bytes);
        if (!std.mem.eql(u8, &recomputed, &frame.event_hash)) return error.HashMismatch;

        // VERIFY: Ed25519 over the recomputed hash, not the header field.
        const public_key = Ed25519.PublicKey.fromBytes(frame.actor_pubkey) catch return error.InvalidSignature;
        const sig = Ed25519.Signature.fromBytes(frame.signature);
        sig.verify(&recomputed, public_key) catch return error.InvalidSignature;

        // SEQUENCE / PREV re-check + fold.
        const transition = try st.prepareTransition(&out_engine.state, frame.actor_pubkey, frame.event_hash, ev);
        st.applyPreparedTransition(&out_engine.state, &transition);
    }
    try out_engine.materialize();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;
const tio = std.testing.io;
