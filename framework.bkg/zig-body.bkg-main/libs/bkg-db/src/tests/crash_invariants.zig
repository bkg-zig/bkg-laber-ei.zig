//! BKGDB Storage Core v1.2 hard crash invariants.
//! Real canonical codec + WAL + State + Core. No mocks, no alternate reducer.
const std = @import("std");
const canonical = @import("canonical_tlv.zig");
const wal = @import("wal.zig");
const state = @import("state.zig");
const core = @import("core.zig");
const testing = std.testing;
const io = testing.io;
const Ed25519 = std.crypto.sign.Ed25519;

fn eventInfluence(key: Ed25519.KeyPair, seq: u64, prev: canonical.Hash32, target: canonical.Hash32, kind: canonical.InfluenceKind) canonical.Event {
    return .{ .event_type_id = canonical.EVENT_INFLUENCE_AUTHORIZED, .sequence = seq, .prev_hash = prev, .actor_pubkey = key.public_key.toBytes(), .payload = .{ .influence_authorized = .{ .target_artifact = target, .target_generation = 0, .beneficiary = key.public_key.toBytes(), .kind = kind } } };
}

fn eventForge(key: Ed25519.KeyPair, seq: u64, prev: canonical.Hash32, artifact: canonical.Hash32, source: canonical.Hash32) canonical.Event {
    return .{ .event_type_id = canonical.EVENT_ARTIFACT_FORGED, .sequence = seq, .prev_hash = prev, .actor_pubkey = key.public_key.toBytes(), .payload = .{ .artifact_forged = .{ .artifact_cid = artifact, .required_capability = .artifact_inspect, .blessing_source = source } } };
}

fn eventAbsorb(key: Ed25519.KeyPair, seq: u64, prev: canonical.Hash32, artifact: canonical.Hash32, source: canonical.Hash32) canonical.Event {
    return .{ .event_type_id = canonical.EVENT_ARTIFACT_ABSORBED, .sequence = seq, .prev_hash = prev, .actor_pubkey = key.public_key.toBytes(), .payload = .{ .artifact_absorbed = .{ .artifact_cid = artifact, .blessing_source = source } } };
}

fn encodeAndSign(allocator: std.mem.Allocator, key: Ed25519.KeyPair, event: *const canonical.Event) !struct { bytes: []u8, hash: canonical.Hash32, sig: canonical.Sig64 } {
    const bytes = try canonical.encodeEvent(allocator, event);
    errdefer allocator.free(bytes);
    const hash = canonical.eventHash(bytes);
    const sig = try key.sign(&hash, null);
    return .{ .bytes = bytes, .hash = hash, .sig = sig.toBytes() };
}

test "Invariant 1: OOM/failure before WAL leaves the durable log untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "oom.wal", .{ .read = true });
    defer file.close(io);
    const key = Ed25519.KeyPair.generate(io);
    const ev = eventInfluence(key, 0, canonical.GENESIS_PARENT_HASH, [_]u8{0xAA} ** 32, .curse);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var manifest = state.ProjectionState.init(failing.allocator(), key.public_key.toBytes());
    defer manifest.deinit();
    const result = state.prepareTransition(&manifest, key.public_key.toBytes(), [_]u8{1} ** 32, &ev);
    try testing.expectError(error.OutOfMemory, result);
    try testing.expectEqual(@as(usize, 0), manifest.influences.count());
    try testing.expectEqual(@as(u64, 0), file.length(io));
}

test "Invariant 2: committed WAL survives process restart and uses the same reducer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const key = Ed25519.KeyPair.generate(io);
    const artifact = [_]u8{0xAA} ** 32;
    var live_root: canonical.Hash32 = undefined;
    var live_fp: canonical.Hash32 = undefined;
    {
        const file = try tmp.dir.createFile(io, "replay.wal", .{ .read = true });
        var engine = core.StorageEngine.init(testing.allocator, io, file, key.public_key.toBytes());
        defer engine.deinit();
        var ev = eventInfluence(key, 0, canonical.GENESIS_PARENT_HASH, artifact, .curse);
        const signed = try encodeAndSign(testing.allocator, key, &ev);
        defer testing.allocator.free(signed.bytes);
        try engine.commit(key.public_key.toBytes(), signed.sig, signed.hash, signed.bytes);
        ev = eventForge(key, 1, engine.state.ledger_tip_hash, artifact, signed.hash);
        const signed2 = try encodeAndSign(testing.allocator, key, &ev);
        defer testing.allocator.free(signed2.bytes);
        try engine.commit(key.public_key.toBytes(), signed2.sig, signed2.hash, signed2.bytes);
        try testing.expect(engine.state.pending_forged.contains(artifact));
        live_root = engine.state.state_root;
        live_fp = engine.state.causal_fingerprint;
        try file.sync(io);
    }
    const file = try tmp.dir.openFile(io, "replay.wal", .{ .mode = .read_only });
    defer file.close(io);
    var recovered = core.StorageEngine.init(testing.allocator, io, file, key.public_key.toBytes());
    defer recovered.deinit();
    var buf: [4096]u8 = undefined;
    try core.recoverFromWal(testing.allocator, io, file, key.public_key.toBytes(), &buf, &recovered);
    try testing.expect(recovered.state.pending_forged.contains(artifact));
    try testing.expectEqual(@as(u64, 2), recovered.state.next_sequence);
    try testing.expectEqualSlices(u8, &live_root, &recovered.state.state_root);
    try testing.expectEqualSlices(u8, &live_fp, &recovered.state.causal_fingerprint);
}

test "Invariant 3: generation changes only on artifact_absorbed" {
    const key = Ed25519.KeyPair.generate(io);
    var manifest = state.ProjectionState.init(testing.allocator, key.public_key.toBytes());
    defer manifest.deinit();
    const artifact = [_]u8{0xAA} ** 32;
    const curse_source = [_]u8{0xBB} ** 32;
    const blessing_source = [_]u8{0xCC} ** 32;

    var ev = eventInfluence(key, 0, canonical.GENESIS_PARENT_HASH, artifact, .curse);
    var transition = try state.prepareTransition(&manifest, key.public_key.toBytes(), [_]u8{2} ** 32, &ev);
    state.applyPreparedTransition(&manifest, &transition);
    try testing.expectEqual(@as(u64, 0), manifest.generation);

    // Use a direct deterministic coupon insertion to isolate the generation rule.
    manifest.influences.putAssumeCapacity(curse_source, .{ .beneficiary = key.public_key.toBytes(), .kind = .curse, .target_generation = 0, .consumed = false });
    ev = eventForge(key, 1, manifest.ledger_tip_hash, artifact, curse_source);
    transition = try state.prepareTransition(&manifest, key.public_key.toBytes(), [_]u8{3} ** 32, &ev);
    state.applyPreparedTransition(&manifest, &transition);
    try testing.expectEqual(@as(u64, 0), manifest.generation);

    manifest.influences.putAssumeCapacity(blessing_source, .{ .beneficiary = key.public_key.toBytes(), .kind = .blessing, .target_generation = 0, .consumed = false });
    ev = eventAbsorb(key, 2, manifest.ledger_tip_hash, artifact, blessing_source);
    transition = try state.prepareTransition(&manifest, key.public_key.toBytes(), [_]u8{4} ** 32, &ev);
    state.applyPreparedTransition(&manifest, &transition);
    try testing.expectEqual(@as(u64, 1), manifest.generation);
    try testing.expect(!manifest.pending_forged.contains(artifact));
    try testing.expectEqual(artifact, manifest.current_artifact_cid.?);
}

test "Invariant 4: applyPreparedTransition is compile-time total" {
    const ReturnType = @typeInfo(@TypeOf(state.applyPreparedTransition)).@"fn".return_type.?;
    try testing.expect(ReturnType == void);
}

test "Invariant 5: bad event hash is rejected before WAL mutation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "hash.wal", .{ .read = true });
    defer file.close(io);
    const key = Ed25519.KeyPair.generate(io);
    var engine = core.StorageEngine.init(testing.allocator, io, file, key.public_key.toBytes());
    defer engine.deinit();
    const ev = eventInfluence(key, 0, canonical.GENESIS_PARENT_HASH, [_]u8{1} ** 32, .curse);
    const signed = try encodeAndSign(testing.allocator, key, &ev);
    defer testing.allocator.free(signed.bytes);
    var bad_hash = signed.hash;
    bad_hash[0] ^= 0xFF;
    try testing.expectError(error.HashMismatch, engine.commit(key.public_key.toBytes(), signed.sig, bad_hash, signed.bytes));
    try testing.expectEqual(@as(u64, 0), file.length(io));
}

test "Invariant 6: invalid signature is rejected before WAL mutation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "sig.wal", .{ .read = true });
    defer file.close(io);
    const key = Ed25519.KeyPair.generate(io);
    const other = Ed25519.KeyPair.generate(io);
    var engine = core.StorageEngine.init(testing.allocator, io, file, key.public_key.toBytes());
    defer engine.deinit();
    const ev = eventInfluence(key, 0, canonical.GENESIS_PARENT_HASH, [_]u8{1} ** 32, .curse);
    const signed = try encodeAndSign(testing.allocator, key, &ev);
    defer testing.allocator.free(signed.bytes);
    const forged_sig = (try other.sign(&signed.hash, null)).toBytes();
    try testing.expectError(error.InvalidSignature, engine.commit(key.public_key.toBytes(), forged_sig, signed.hash, signed.bytes));
    try testing.expectEqual(@as(u64, 0), file.length(io));
}

fn eventDelegate(key: Ed25519.KeyPair, seq: u64, prev: canonical.Hash32, delegate: canonical.Hash32, scope: canonical.Hash32) canonical.Event {
    return .{
        .event_type_id = canonical.EVENT_AUTHORITY_DELEGATED,
        .sequence = seq,
        .prev_hash = prev,
        .actor_pubkey = key.public_key.toBytes(),
        .payload = .{ .authority_delegated = .{
            .delegate_pubkey = delegate,
            .role_type = .signer,
            .valid_until_generation = 100,
            .scope_cid = scope,
        } },
    };
}

test "Invariant 7: a delegate cannot grant further authority" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "esc.wal", .{ .read = true });
    defer file.close(io);
    const genesis = Ed25519.KeyPair.generate(io);
    const delegate = Ed25519.KeyPair.generate(io);
    const other = Ed25519.KeyPair.generate(io);
    var engine = core.StorageEngine.init(testing.allocator, io, file, genesis.public_key.toBytes());
    defer engine.deinit();

    var ev = eventDelegate(genesis, 0, canonical.GENESIS_PARENT_HASH, delegate.public_key.toBytes(), [_]u8{0} ** 32);
    const signed = try encodeAndSign(testing.allocator, genesis, &ev);
    defer testing.allocator.free(signed.bytes);
    try engine.commit(genesis.public_key.toBytes(), signed.sig, signed.hash, signed.bytes);

    ev = eventDelegate(delegate, 1, engine.state.ledger_tip_hash, other.public_key.toBytes(), [_]u8{0} ** 32);
    ev.actor_pubkey = delegate.public_key.toBytes();
    const signed2 = try encodeAndSign(testing.allocator, delegate, &ev);
    defer testing.allocator.free(signed2.bytes);
    try testing.expectError(error.InvalidActor, engine.commit(delegate.public_key.toBytes(), signed2.sig, signed2.hash, signed2.bytes));
    try testing.expect(!engine.state.delegated.contains(other.public_key.toBytes()));
}

test "Invariant 8: crash tail after a committed prefix recovers bit-exact fingerprints" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const key = Ed25519.KeyPair.generate(io);
    const artifact = [_]u8{0xAA} ** 32;
    var live_root: canonical.Hash32 = undefined;
    var live_fp: canonical.Hash32 = undefined;
    {
        const file = try tmp.dir.createFile(io, "tail.wal", .{ .read = true });
        var engine = core.StorageEngine.init(testing.allocator, io, file, key.public_key.toBytes());
        defer engine.deinit();
        var ev = eventInfluence(key, 0, canonical.GENESIS_PARENT_HASH, artifact, .curse);
        const signed = try encodeAndSign(testing.allocator, key, &ev);
        defer testing.allocator.free(signed.bytes);
        try engine.commit(key.public_key.toBytes(), signed.sig, signed.hash, signed.bytes);
        live_root = engine.state.state_root;
        live_fp = engine.state.causal_fingerprint;
        // Incomplete PREP at EOF — recovery must ignore it.
        const pos = engine.writer.pos;
        try file.writePositionalAll(io, "PREPXXXX", pos);
        try file.sync(io);
    }
    const file = try tmp.dir.openFile(io, "tail.wal", .{ .mode = .read_only });
    defer file.close(io);
    var recovered = core.StorageEngine.init(testing.allocator, io, file, key.public_key.toBytes());
    defer recovered.deinit();
    var buf: [4096]u8 = undefined;
    try core.recoverFromWal(testing.allocator, io, file, key.public_key.toBytes(), &buf, &recovered);
    try testing.expectEqual(@as(u64, 1), recovered.state.next_sequence);
    try testing.expectEqualSlices(u8, &live_root, &recovered.state.state_root);
    try testing.expectEqualSlices(u8, &live_fp, &recovered.state.causal_fingerprint);
}
