// v1.2 ProjectionState + deterministic two-phase fold.
//
// Contract (frozen):
//   * VERIFY/AUTHORIZE and ALL RAM reservation happen in `prepareTransition`
//     (may fail: OOM, invalid actor, missing influence, ...). Nothing touches the
//     WAL here.
//   * After WAL COMMIT the engine calls `applyPreparedTransition` which is a
//     TOTAL function (returns `void`, never `!void`) and therefore cannot fail.
//   * generation increments ONLY on `artifact_absorbed`. Every other event leaves
//     generation untouched.
//   * No reverse path from a ProjectionState back to ManifestationState.

const std = @import("std");
const tlv = @import("canonical_tlv.zig");

pub const Hash32 = tlv.Hash32;
pub const Event = tlv.Event;
pub const Payload = tlv.Payload;
pub const RoleType = tlv.RoleType;
pub const InfluenceKind = tlv.InfluenceKind;
pub const Capability = tlv.Capability;

pub const ProtocolError = error{
    OutOfMemory,
    InvalidActor,
    SequenceGap,
    DuplicateInfluence,
    MissingCurse,
    MissingBlessing,
    UnknownBlessingSource,
    DuplicateForge,
    UnknownForge,
    UnknownDelegation,
    InvalidRevocation,
    DuplicateDelegation,
    AuthorityScopeMismatch,
    GenerationRollback,
    InvalidGenesis,
} || std.mem.Allocator.Error;

/// A single pending/consumed influence coupon bound to a beneficiary.
pub const Influence = struct {
    beneficiary: Hash32,
    kind: InfluenceKind,
    target_generation: u64,
    consumed: bool,
};

/// An active (non-revoked, non-expired) delegated authority.
pub const Delegation = struct {
    delegator: Hash32, // pubkey that granted
    role_type: RoleType,
    valid_until_generation: u64,
    scope_cid: Hash32,
    origin_event_hash: Hash32, // the authority_delegated event that created this
};

pub const ProjectionState = struct {
    allocator: std.mem.Allocator,
    genesis_pubkey: Hash32,
    generation: u64 = 0,
    current_artifact_cid: ?Hash32 = null,
    next_sequence: u64 = 0,
    ledger_tip_hash: Hash32 = [_]u8{0} ** 32,
    state_root: Hash32 = [_]u8{0} ** 32,
    causal_fingerprint: Hash32 = [_]u8{0} ** 32,

    /// cid -> blessing_source of artifacts forged but not yet absorbed
    pending_forged: std.AutoHashMap(Hash32, Hash32),
    /// blessing_source -> influence coupon (exactly-once consumption)
    influences: std.AutoHashMap(Hash32, Influence),
    /// delegate_pubkey -> delegation
    delegated: std.AutoHashMap(Hash32, Delegation),

    pub fn init(allocator: std.mem.Allocator, genesis_pubkey: Hash32) ProjectionState {
        return .{
            .allocator = allocator,
            .genesis_pubkey = genesis_pubkey,
            .pending_forged = std.AutoHashMap(Hash32, Hash32).init(allocator),
            .influences = std.AutoHashMap(Hash32, Influence).init(allocator),
            .delegated = std.AutoHashMap(Hash32, Delegation).init(allocator),
        };
    }

    pub fn deinit(self: *ProjectionState) void {
        self.pending_forged.deinit();
        self.influences.deinit();
        self.delegated.deinit();
    }

    /// Is `actor` allowed to transact? Genesis key, or an active delegation whose
    /// scope covers the target artifact and whose validity window includes the
    /// current generation.
    fn isAuthorized(self: *const ProjectionState, actor: Hash32, scope_cid: Hash32) bool {
        if (std.mem.eql(u8, &actor, &self.genesis_pubkey)) return true;
        const d = self.delegated.get(actor) orelse return false;
        if (d.valid_until_generation < self.generation) return false;
        // A zero scope_cid is a wild-card delegation covering everything.
        if (std.mem.allEqual(u8, &d.scope_cid, 0)) return true;
        return std.mem.eql(u8, &d.scope_cid, &scope_cid);
    }
};

/// Result of `prepareTransition`: everything apply needs, with all storage already
/// reserved. Carrying resolved data lets apply stay purely infallible.
pub const ValidatedTransition = struct {
    event: Event,
    // event hash of the committed frame; the engine computes it during VERIFY and
    // it becomes the next ledger tip. (Event itself has no payload_hash field.)
    event_hash: Hash32,
    // resolved apply intent
    consume_influence: ?Hash32 = null, // blessing_source to consume (forge/absorb)
    set_current_cid: ?Hash32 = null, // cid to set on absorb
    grant_influence: ?Hash32 = null, // blessing_source added by influence_authorized
    grant_influence_rec: ?Influence = null,
    forge_cid: ?Hash32 = null, // cid registered as pending
    delegate_pubkey: ?Hash32 = null,
    delegate_rec: ?Delegation = null,
    revoke_pubkey: ?Hash32 = null,
};

/// ==== PHASE 1: VERIFY + AUTHORIZE + resource reservation (may fail) ====
pub fn prepareTransition(
    state: *ProjectionState,
    actor: Hash32,
    event_hash: Hash32,
    event: *const Event,
) ProtocolError!ValidatedTransition {
    if (event.sequence != state.next_sequence) return error.SequenceGap;
    if (state.next_sequence == std.math.maxInt(u64)) return error.SequenceGap;
    switch (event.payload) {
        .influence_authorized => |p| {
            if (!isAuthorizedSafe(state, actor, p.target_artifact)) return error.AuthorityScopeMismatch;
            if (state.influences.contains(event_hash)) return error.DuplicateInfluence;
            // last transition increments generation only on absorb; authorize is a
            // separate consumption path, so target generation must be the current one.
            if (p.target_generation != state.generation) return error.GenerationRollback;
            try state.influences.ensureUnusedCapacity(1); // OOM surfaces here, pre-WAL
            return .{ .event = event.*, .event_hash = event_hash, .grant_influence = event_hash, .grant_influence_rec = .{
                .beneficiary = p.beneficiary, .kind = p.kind, .target_generation = p.target_generation, .consumed = false,
            } };
        },
        .cross_lineage_composed => |p| {
            // Provenance only; requires an actor that can see the external parents.
            if (!isAuthorizedSafe(state, actor, [_]u8{0} ** 32)) return error.InvalidActor;
            _ = p;
            return .{ .event = event.*, .event_hash = event_hash };
        },
        .artifact_forged => |p| {
            if (!isAuthorizedSafe(state, actor, p.artifact_cid)) return error.AuthorityScopeMismatch;
            // Forge CONSUMES a curse coupon on the parent artifact.
            const inf = state.influences.get(p.blessing_source) orelse return error.MissingCurse;
            if (inf.kind != .curse) return error.MissingCurse;
            if (inf.consumed) return error.DuplicateInfluence;
            if (state.pending_forged.contains(p.artifact_cid)) return error.DuplicateForge;
            try state.pending_forged.ensureUnusedCapacity(1); // OOM pre-WAL
            return .{ .event = event.*, .event_hash = event_hash, .consume_influence = p.blessing_source, .forge_cid = p.artifact_cid };
        },
        .artifact_absorbed => |p| {
            if (state.generation == std.math.maxInt(u64)) return error.GenerationRollback;
            if (!isAuthorizedSafe(state, actor, p.artifact_cid)) return error.AuthorityScopeMismatch;
            // Absorb burns a BLESSING and is the ONLY path that advances generation.
            const inf = state.influences.get(p.blessing_source) orelse return error.MissingBlessing;
            if (inf.kind != .blessing) return error.MissingBlessing;
            if (inf.consumed) return error.DuplicateInfluence;
            if (!state.pending_forged.contains(p.artifact_cid)) return error.UnknownForge;
            return .{ .event = event.*, .event_hash = event_hash, .consume_influence = p.blessing_source, .set_current_cid = p.artifact_cid };
        },
        .guardian_verdict => |p| {
            if (!isAuthorizedSafe(state, actor, [_]u8{0} ** 32)) return error.InvalidActor;
            // Verdict is advisory today; folded as an audit record but does not
            // change generation.
            _ = p;
            return .{ .event = event.*, .event_hash = event_hash };
        },
        .authority_delegated => |p| {
            // Only genesis can grant. A delegate cannot escalate by minting new authority.
            if (!std.mem.eql(u8, &actor, &state.genesis_pubkey)) return error.InvalidActor;
            if (state.delegated.contains(p.delegate_pubkey)) return error.DuplicateDelegation;
            try state.delegated.ensureUnusedCapacity(1); // OOM pre-WAL
            return .{ .event = event.*, .event_hash = event_hash, .delegate_pubkey = p.delegate_pubkey, .delegate_rec = .{
                .delegator = actor, .role_type = p.role_type, .valid_until_generation = p.valid_until_generation, .scope_cid = p.scope_cid, .origin_event_hash = event_hash,
            } };
        },
        .authority_revoked => |p| {
            if (!std.mem.eql(u8, &actor, &state.genesis_pubkey)) return error.InvalidActor;
            // Resolve the delegation created by the referenced authority_delegated
            // event so apply can actually remove it (no silent no-op).
            var revoked: ?Hash32 = null;
            var it = state.delegated.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, &entry.value_ptr.origin_event_hash, &p.revoked_ref)) {
                    revoked = entry.key_ptr.*;
                    break;
                }
            }
            const pubkey = revoked orelse return error.InvalidRevocation;
            return .{ .event = event.*, .event_hash = event_hash, .revoke_pubkey = pubkey };
        },
    }
}

/// Bypass helper so the top loop stays ergonomic (see `isAuthorized`).
fn isAuthorizedSafe(state: *ProjectionState, actor: Hash32, scope: Hash32) bool {
    return isAuthorizedImpl(state, actor, scope);
}

fn isAuthorizedImpl(state: *ProjectionState, actor: Hash32, scope: Hash32) bool {
    if (std.mem.eql(u8, &actor, &state.genesis_pubkey)) return true;
    const d = state.delegated.get(actor) orelse return false;
    if (d.valid_until_generation < state.generation) return false;
    if (std.mem.allEqual(u8, &d.scope_cid, 0)) return true;
    return std.mem.eql(u8, &d.scope_cid, &scope);
}

/// ==== PHASE 2: TOTAL FOLD (cannot fail, never returns error) ====
pub fn applyPreparedTransition(state: *ProjectionState, t: *const ValidatedTransition) void {
    state.ledger_tip_hash = t.event_hash;
    state.next_sequence += 1;

    if (t.consume_influence) |source| {
        if (state.influences.getPtr(source)) |inf| inf.consumed = true;
    }
    if (t.grant_influence) |source| {
        if (t.grant_influence_rec) |rec| state.influences.putAssumeCapacity(source, rec);
    }
    if (t.forge_cid) |cid| {
        if (t.consume_influence) |src| state.pending_forged.putAssumeCapacity(cid, src);
    }
    if (t.set_current_cid) |cid| {
        // Absorb is the ONLY place generation advances.
        state.current_artifact_cid = cid;
        state.generation += 1;
        // Drop the forged artifact from pending once absorbed.
        _ = state.pending_forged.remove(cid);
    }
    if (t.delegate_pubkey) |pk| {
        if (t.delegate_rec) |rec| state.delegated.putAssumeCapacity(pk, rec);
    }
    if (t.revoke_pubkey) |pk| {
        _ = state.delegated.remove(pk);
    }
}

// ---------------------------------------------------------------------------
// Deterministic materialization (v1.2). These run AFTER the total fold, in the
// engine, so `applyPreparedTransition` itself stays allocation-free and total.
// Both hashes are order-independent because they fold over lexicographically
// sorted keys — the resulting digest is identical regardless of insertion order,
// which the crash-replay gate depends on.
// ---------------------------------------------------------------------------
const Sha256 = std.crypto.hash.sha2.Sha256;
const STATE_ROOT_LABEL: []const u8 = "BKG_STATE_ROOT_V1";
const CAUSAL_LABEL: []const u8 = "BKG_CAUSAL_FINGERPRINT_V1";

fn h64(ctx: *Sha256, v: u64) void {
    var le: [8]u8 = undefined;
    std.mem.writeInt(u64, &le, v, .little);
    ctx.update(&le);
}

fn h32(ctx: *Sha256, v: *const Hash32) void {
    ctx.update(v);
}

/// Deterministic state root over the entire projection. Allocates for sorting.
pub fn computeStateRoot(state: *const ProjectionState, allocator: std.mem.Allocator) std.mem.Allocator.Error!Hash32 {
    var ctx = Sha256.init(.{});
    ctx.update(STATE_ROOT_LABEL);
    h64(&ctx, state.generation);
    if (state.current_artifact_cid) |cid| {
        ctx.update(&[_]u8{1});
        h32(&ctx, &cid);
    } else {
        ctx.update(&[_]u8{0});
    }
    h64(&ctx, state.next_sequence);

    // pending_forged (cid -> blessing_source), sorted by cid
    var pk = try allocator.alloc(Hash32, state.pending_forged.count());
    defer allocator.free(pk);
    {
        var i: usize = 0;
        var it = state.pending_forged.iterator();
        while (it.next()) |e| : (i += 1) pk[i] = e.key_ptr.*;
    }
    std.mem.sort(Hash32, pk, {}, struct {
        fn lt(_: void, a: Hash32, b: Hash32) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.lt);
    for (pk) |cid| {
        ctx.update(&[_]u8{0x10});
        h32(&ctx, &cid);
        h32(&ctx, &state.pending_forged.get(cid).?);
    }

    // influences (source -> Influence), sorted by source
    var ski = try allocator.alloc(Hash32, state.influences.count());
    defer allocator.free(ski);
    {
        var i: usize = 0;
        var it = state.influences.iterator();
        while (it.next()) |e| : (i += 1) ski[i] = e.key_ptr.*;
    }
    std.mem.sort(Hash32, ski, {}, struct {
        fn lt(_: void, a: Hash32, b: Hash32) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.lt);
    for (ski) |src| {
        const inf = state.influences.get(src).?;
        ctx.update(&[_]u8{0x20});
        h32(&ctx, &src);
        h32(&ctx, &inf.beneficiary);
        ctx.update(&[_]u8{@intFromEnum(inf.kind)});
        h64(&ctx, inf.target_generation);
        ctx.update(&[_]u8{@intFromBool(inf.consumed)});
    }

    // delegated (pubkey -> Delegation), sorted by pubkey
    var dk = try allocator.alloc(Hash32, state.delegated.count());
    defer allocator.free(dk);
    {
        var i: usize = 0;
        var it = state.delegated.iterator();
        while (it.next()) |e| : (i += 1) dk[i] = e.key_ptr.*;
    }
    std.mem.sort(Hash32, dk, {}, struct {
        fn lt(_: void, a: Hash32, b: Hash32) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.lt);
    for (dk) |pubkey| {
        const d = state.delegated.get(pubkey).?;
        ctx.update(&[_]u8{0x30});
        h32(&ctx, &pubkey);
        h32(&ctx, &d.delegator);
        ctx.update(&[_]u8{@intFromEnum(d.role_type)});
        h64(&ctx, d.valid_until_generation);
        h32(&ctx, &d.scope_cid);
        h32(&ctx, &d.origin_event_hash);
    }

    var out: Hash32 = undefined;
    ctx.final(&out);
    return out;
}

/// Causal fingerprint: the engine's identity over the whole deltas it has seen.
/// Deterministic and order-independent for a given committed set.
pub fn computeCausalFingerprint(
    state: *const ProjectionState,
    state_root: Hash32,
) Hash32 {
    var ctx = Sha256.init(.{});
    ctx.update(CAUSAL_LABEL);
    ctx.update(&state_root);
    h64(&ctx, state.generation);
    h32(&ctx, &state.ledger_tip_hash);
    var out: Hash32 = undefined;
    ctx.final(&out);
    return out;
}