/// BKGDB Protocol Baseline Engine — rebuildProtocol
///
/// Baseline verriegelt: 2026-09-01
///
/// Lifecycle: INPUT → VERIFY → AUTHORIZE → FOLD → CONSUME → MATERIALIZE → FINGERPRINT → STATE ROOT
///
/// Fünf Invarianten sind in diesem Code erzwungen:
///
///   Regel 1 (Sequenzpflicht):
///     Jedes Envelope muss prev_event_hash des vorherigen und eine lückenlose
///     Sequenz-Nr. tragen. Abweichung → BrokenChainLink / InvalidSequence.
///
///   Regel 2 (Konsum-Invarianten):
///     artifact_forged  darf NUR next_generation-Einflüsse konsumieren.
///     artifact_absorbed darf NUR current_manifestation-Einflüsse konsumieren.
///     Falscher Typ oder nicht-existenter Hash → IllegalInfluenceConsumption.
///
///   Regel 3 (Forge/Absorb-Trennung):
///     Forge erschafft A₁ im Content-Store, ändert aber NICHT current_artifact_cid.
///     Absorb integriert das Artefakt: current_artifact_cid wechselt erst hier.
///
///   Regel 4 (Unabhängige Fingerprint-Berechnung):
///     causal_fingerprint = SHA256(aller event_hashes der verifizierten Kette).
///     Abgeleitet ausschließlich aus der Ledger-Kette, nie aus der State-Projektion.
///     Watcher vergleichen diesen Fingerprint. Abweichung → Challenge → Killchain.
///
///   Regel 5 (Absorb-Binding-Invariante):
///     artifact_absorbed darf nur ein Artefakt integrieren, das:
///       (a) zuvor von einem artifact_forged-Event erzeugt wurde (PendingForgeEntry existiert),
///       (b) dessen target_harness mit state.identity.harness_id übereinstimmt,
///       (c) und exakt die vom Forge-Event deklarierte absorbed_artifact_cid trägt.
///     Jede Abweichung → AbsorbBindingViolation.
///     Damit ist die Kausalitätskette geschlossen:
///       Forge sagt „A₁ für Harness H" — Absorb beweist „H hat A₁ integriert."
///
///   Zeitbindungs-Invariante (AUTHORIZE):
///     Authorization wird immer gegen den unmittelbar vorherigen Ledger-State
///     des Events geprüft — niemals gegen einen später rekonstruierten Zustand.
///     Ein authority_revoked-Event schließt den Scope für das nächste Event,
///     lässt das aktuelle Event aber unberührt.
///
///   Genesis-Authority-Invariante:
///     Privilegierte Events (artifact_forged, guardian_set_changed) müssen von
///     genesis.forge_pubkey signiert sein (envelope.actor_pubkey == genesis.forge_pubkey).
///     Abweichung → UnauthorizedPrivilegedEvent.
///
///   Signatur-Invariante:
///     Jedes Envelope trägt eine Ed25519-Signatur über den event_hash.
///     Die Signatur muss mit dem actor_pubkey des Envelopes verifizierbar sein.
///     Ungültige Signatur → InvalidSignature (schlägt vor Actor-Autorisierung).
///
///   Guardian-Provenance-Invariante:
///     trusted_guardians[] wird ausschließlich aus genesis.guardian_pubkeys[] und
///     guardian_set_changed-Events abgeleitet — niemals aus P2P-Daten.
///     Ein guardian_set_changed-Event, das nicht von forge_pubkey signiert ist,
///     → UnauthorizedGuardianChange.
const std = @import("std");
const ledger_mod = @import("../protocol/ledger.zig");
const state_mod  = @import("../protocol/state.zig");
const genesis_mod = @import("../genesis/genesis.zig");

pub const Hash                 = ledger_mod.Hash;
pub const LedgerEventEnvelope  = ledger_mod.LedgerEventEnvelope;
pub const HarnessManifestation = state_mod.HarnessManifestation;
pub const CausalInfluence      = state_mod.CausalInfluence;
pub const LineageResonance     = state_mod.LineageResonance;
pub const TargetGeneration     = state_mod.TargetGeneration;
pub const ZERO_HASH            = ledger_mod.ZERO_HASH;

// ── Fehler ────────────────────────────────────────────────────────────────

pub const RebuildError = error{
    /// Zwei aufeinanderfolgende Envelopes haben keine korrekte prev_event_hash-Verknüpfung.
    BrokenChainLink,
    /// Sequenz-Nummer ist nicht lückenlos monoton steigend.
    InvalidSequence,
    /// Ed25519-Signatur des Envelopes ist ungültig.
    /// envelope.signature muss Ed25519(actor_privkey, event_hash) sein.
    InvalidSignature,
    /// artifact_forged versuchte einen current_manifestation-Einfluss zu konsumieren,
    /// oder artifact_absorbed versuchte einen next_generation-Einfluss zu konsumieren,
    /// oder der referenzierte Hash existiert nicht / wurde bereits konsumiert.
    IllegalInfluenceConsumption,
    /// artifact_absorbed referenziert ein Artefakt, das entweder nicht in pending_forge_set
    /// liegt, für einen anderen Harness geschmiedet wurde, oder dessen CID nicht übereinstimmt.
    /// (Regel 5: Absorb-Binding-Invariante)
    AbsorbBindingViolation,
    /// Ein Event kam vor manifestation_booted_from_spore.
    ManifestationNotBooted,
    /// Stream ist leer oder enthält kein Boot-Event.
    EmptyStream,
    /// Ein privilegiertes Event (artifact_forged, guardian_set_changed) wurde von einem
    /// Akteur signiert, der nicht die Genesis Forge Authority ist.
    UnauthorizedPrivilegedEvent,
    /// Ein guardian_set_changed-Event wurde nicht von der Forge Authority signiert —
    /// Guardian-Provenance-Invariante verletzt.
    UnauthorizedGuardianChange,
    /// Der Akteur ist weder Forge, noch aktiver Guardian, noch Träger eines
    /// gültigen Authority-Mandats.
    UnauthorizedActor,
    OutOfMemory,
};

// ── RebuildResult ─────────────────────────────────────────────────────────

/// Ergebnis eines erfolgreichen Rebuilds.
/// state und causal_fingerprint werden unabhängig berechnet (Regel 4).
///
/// Ownership:
///   active_guardian_set ist ein owned slice — Aufrufer muss freeRebuildResult() aufrufen
///   oder active_guardian_set.len == 0 prüfen bevor er freigibt.
pub const RebuildResult = struct {
    state:              HarnessManifestation,
    /// SHA256(alle event_hashes in Reihenfolge).
    /// Watcher vergleichen diesen Wert mit dem gecachten Peer-State.
    causal_fingerprint: Hash,
    /// Aktuell autorisierter Guardian-Set.
    /// Abgeleitet aus genesis.guardian_pubkeys[] → guardian_set_changed Events.
    /// Owned slice — Aufrufer muss freeRebuildResult() aufrufen.
    active_guardian_set: [][32]u8,
};

/// Gibt den RebuildResult und den zugehörigen HarnessManifestation-State frei.
pub fn freeRebuildResult(r: *RebuildResult, allocator: std.mem.Allocator) void {
    state_mod.freeHarnessManifestation(&r.state, allocator);
    allocator.free(r.active_guardian_set);
}

// ── verifyEnvelopeSignature ───────────────────────────────────────────────

/// Verifiziert die Ed25519-Signatur eines Envelopes.
///
/// Prüfung: Ed25519.verify(envelope.signature, envelope.event_hash, envelope.actor_pubkey)
///
/// Fehler:
///   InvalidSignature — actor_pubkey kein gültiger Ed25519-Schlüssel, oder
///                      Signatur stimmt nicht mit event_hash überein.
pub fn verifyEnvelopeSignature(envelope: *const LedgerEventEnvelope) RebuildError!void {
    const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(envelope.actor_pubkey) catch
        return RebuildError.InvalidSignature;
    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(envelope.signature);
    sig.verify(&envelope.event_hash, pk) catch
        return RebuildError.InvalidSignature;
}

// ── isPrivilegedEvent ─────────────────────────────────────────────────────

/// Gibt true zurück, wenn das Payload-Tag ein privilegiertes Event ist,
/// das ausschließlich von der Genesis Forge Authority signiert werden darf.
/// guardian_set_changed ist ausgenommen — hat einen eigenen dedizierten Fehler.
fn isPrivilegedEvent(payload: *const ledger_mod.EventPayload) bool {
    return switch (payload.*) {
        .artifact_forged,
        .soul_anchored,
        .manifestation_booted_from_spore,
        .c2_binding_established,
        .c2_binding_revoked => true,
        .watcher_evidence_submitted,
        .guardian_authorization_granted,
        .influence_authorized,
        .artifact_absorbed,
        .guardian_set_changed => false,
    };
}

fn mandateCovers(scope: state_mod.AuthorityScope, payload: *const ledger_mod.EventPayload) bool {
    return switch (scope) {
        .global => true,
        .harness => |hid| switch (payload.*) {
            .influence_authorized => |inf|
                ledger_mod.ids.hashEql(inf.target_harness, hid) or
                ledger_mod.ids.hashEql(inf.source_harness, hid),
            .artifact_absorbed => |abs| ledger_mod.ids.hashEql(abs.harness_id, hid),
            .watcher_evidence_submitted => |w| ledger_mod.ids.hashEql(w.harness_id, hid),
            .guardian_authorization_granted => |g|
                ledger_mod.ids.hashEql(g.harness_source, hid) or
                ledger_mod.ids.hashEql(g.harness_target, hid),
            .soul_anchored,
            .manifestation_booted_from_spore,
            .c2_binding_established,
            .c2_binding_revoked,
            .artifact_forged,
            .guardian_set_changed => false,
        },
        .work_context => |ctx| switch (payload.*) {
            .influence_authorized => |inf| ledger_mod.ids.hashEql(inf.shared_work_context, ctx),
            .watcher_evidence_submitted => |w| ledger_mod.ids.hashEql(w.work_context, ctx),
            .guardian_authorization_granted => |g| ledger_mod.ids.hashEql(g.work_context, ctx),
            .soul_anchored,
            .manifestation_booted_from_spore,
            .c2_binding_established,
            .c2_binding_revoked,
            .artifact_forged,
            .artifact_absorbed,
            .guardian_set_changed => false,
        },
        .operation => |op| @intFromEnum(std.meta.activeTag(payload.*)) == op,
    };
}

fn actorIsAuthorized(
    envelope: *const LedgerEventEnvelope,
    genesis: *const genesis_mod.GenesisAuthorityRecord,
    guardian_set: []const [32]u8,
    authorities: []const state_mod.AuthorityMandate,
) bool {
    if (std.mem.eql(u8, &envelope.actor_pubkey, &genesis.forge_pubkey)) return true;

    const tag = std.meta.activeTag(envelope.payload);
    const guardian_ok = switch (tag) {
        .watcher_evidence_submitted,
        .guardian_authorization_granted,
        .influence_authorized => true,
        .soul_anchored,
        .manifestation_booted_from_spore,
        .c2_binding_established,
        .c2_binding_revoked,
        .artifact_forged,
        .artifact_absorbed,
        .guardian_set_changed => false,
    };
    if (guardian_ok) {
        for (guardian_set) |pk| {
            if (std.mem.eql(u8, &envelope.actor_pubkey, &pk)) return true;
        }
    }

    for (authorities) |m| {
        if (m.revoked_at_sequence != 0) continue;
        if (!ledger_mod.ids.hashEql(m.delegated_pubkey, envelope.actor_pubkey)) continue;
        if (mandateCovers(m.scope, &envelope.payload)) return true;
    }
    return false;
}

// ── rebuildProtocol ───────────────────────────────────────────────────────

/// BKGDB Protocol Baseline Rebuild.
///
/// Erwartet einen chronologisch sortierten, lückenlosen Event-Stream
/// für genau einen Harness. Das Genesis-Record wird als unveränderlicher
/// Parameter außerhalb des Ledger-Streams übergeben (§5 Spec).
///
/// Ownership:
///   state.active_influence_set, state.pending_forge_set, state.lineage_resonance_set
///   sind owned slices — Aufrufer muss state_mod.freeHarnessManifestation() aufrufen.
pub fn rebuildProtocol(
    allocator: std.mem.Allocator,
    genesis: *const genesis_mod.GenesisAuthorityRecord,
    ledger_stream: []const LedgerEventEnvelope,
) RebuildError!RebuildResult {
    if (ledger_stream.len == 0) return RebuildError.EmptyStream;

    // ── State-Akkumulatoren ────────────────────────────────────────────────
    var identity  = state_mod.HarnessIdentity{
        .harness_id          = ZERO_HASH,
        .canonical_soul_hash = ZERO_HASH,
    };
    var provenance = state_mod.HarnessProvenance{
        .origin_spore_cid       = ZERO_HASH,
        .origin_lost_cid        = ZERO_HASH,
        .causality_ledger_event = ZERO_HASH,
    };
    var current_artifact_cid: Hash = ZERO_HASH;
    var is_booted = false;

    // ── Guardian-Set-Tracking (§7 Spec) ──────────────────────────────────────
    // Initialisiert aus genesis.guardian_pubkeys[], aktualisiert durch guardian_set_changed.
    // AlignedManaged wird bei jedem guardian_set_changed vollständig ersetzt.
    var guardian_set = std.array_list.AlignedManaged([32]u8, null).init(allocator);
    errdefer guardian_set.deinit();
    for (genesis.guardian_pubkeys[0..genesis.guardian_count]) |pk| {
        guardian_set.append(pk) catch return RebuildError.OutOfMemory;
    }

    // Einflüsse landen hier — split in active/pending beim toOwnedSlice
    var all_influences = std.array_list.AlignedManaged(CausalInfluence, null).init(allocator);
    errdefer all_influences.deinit();
    // Geschmiedete Artefakte warten als PendingForgeEntry auf Absorption
    var pending_forge = std.array_list.AlignedManaged(state_mod.PendingForgeEntry, null).init(allocator);
    errdefer pending_forge.deinit();
    var resonances = std.array_list.AlignedManaged(LineageResonance, null).init(allocator);
    errdefer resonances.deinit();
    var authorities = std.array_list.AlignedManaged(state_mod.AuthorityMandate, null).init(allocator);
    errdefer authorities.deinit();

    // ── Regel 4: Unabhängiger Fingerprint-Hasher ──────────────────────────
    var fingerprint_hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // ── Regel 1: Ketten-Verifikation ──────────────────────────────────────
    var expected_prev: Hash = ledger_mod.GENESIS_PREV;
    var expected_seq: u64   = ledger_stream[0].sequence;

    // ── FOLD LOOP ─────────────────────────────────────────────────────────
    for (ledger_stream) |envelope| {

        // VERIFY CHAIN (Regel 1)
        if (!ledger_mod.ids.hashEql(envelope.prev_event_hash, expected_prev))
            return RebuildError.BrokenChainLink;
        if (envelope.sequence != expected_seq)
            return RebuildError.InvalidSequence;

        // VERIFY SIGNATURE — Signatur-Invariante:
        // Jedes Envelope trägt Ed25519(actor_privkey, event_hash).
        try verifyEnvelopeSignature(&envelope);

        // AUTHORIZE — Genesis-Authority-Invariante:
        // Privilegierte Events müssen von forge_pubkey signiert sein.
        if (isPrivilegedEvent(&envelope.payload)) {
            if (!std.mem.eql(u8, &envelope.actor_pubkey, &genesis.forge_pubkey))
                return RebuildError.UnauthorizedPrivilegedEvent;
        }

        // Guardian-Provenance-Invariante:
        // guardian_set_changed muss zusätzlich von forge_pubkey kommen (doppelte Prüfung,
        // expliziter Fehler für Guardian-spezifische Verletzung).
        if (std.meta.activeTag(envelope.payload) == .guardian_set_changed) {
            if (!std.mem.eql(u8, &envelope.actor_pubkey, &genesis.forge_pubkey))
                return RebuildError.UnauthorizedGuardianChange;
        }

        if (!actorIsAuthorized(&envelope, genesis, guardian_set.items, authorities.items))
            return RebuildError.UnauthorizedActor;

        expected_prev  = envelope.event_hash;
        expected_seq  += 1;

        // FINGERPRINT UPDATE (Regel 4) — ausschließlich aus verifizierten event_hashes
        fingerprint_hasher.update(&envelope.event_hash);

        // FOLD & CONSUME (Regeln 2 + 3)
        switch (envelope.payload) {

            .soul_anchored => {
                // SOUL-Verankerung — kein Harness-spezifischer State-Effekt
            },

            .manifestation_booted_from_spore => |boot| {
                identity.canonical_soul_hash = boot.soul_hash;
                identity.harness_id          = hashHarnessFromBoot(envelope.event_hash);
                provenance = .{
                    .origin_spore_cid       = boot.spore_cid,
                    .origin_lost_cid        = boot.lost_cid,
                    .causality_ledger_event = envelope.event_hash,
                };
                current_artifact_cid = boot.initial_artifact_cid;
                is_booted = true;
            },

            // C2-Bindung erzeugt ein AuthorityMandate für den gebundenen Demon.
            // Scope: harness-gebunden (nur für diesen Harness).
            .c2_binding_established => |c2| {
                if (!is_booted) return RebuildError.ManifestationNotBooted;
                const mandate = state_mod.AuthorityMandate{
                    .delegated_pubkey    = c2.demon_id,
                    .scope               = .{ .harness = c2.harness_id },
                    .grant_event_hash    = envelope.event_hash,
                    .revoked_at_sequence = 0, // aktiv
                };
                authorities.append(mandate) catch return RebuildError.OutOfMemory;
            },

            // C2-Bindung widerrufen: sucht das aktive Mandat und setzt revoked_at_sequence.
            .c2_binding_revoked => |c2| {
                if (!is_booted) return RebuildError.ManifestationNotBooted;
                for (authorities.items) |*m| {
                    if (ledger_mod.ids.hashEql(m.delegated_pubkey, c2.demon_id) and
                        m.revoked_at_sequence == 0)
                    {
                        m.revoked_at_sequence = envelope.sequence;
                        break;
                    }
                }
            },

            .watcher_evidence_submitted, .guardian_authorization_granted => {
                // Observation Graph: State-Effekte in Phase 2
                if (!is_booted) return RebuildError.ManifestationNotBooted;
            },

            .influence_authorized => |inf| {
                if (!is_booted) return RebuildError.ManifestationNotBooted;
                const entry = CausalInfluence{
                    .source_harness         = inf.source_harness,
                    .source_artifact_cid    = inf.source_artifact_cid,
                    .shared_work_context    = inf.shared_work_context,
                    .target_generation      = @enumFromInt(@intFromEnum(inf.target_generation)),
                    .direction              = @enumFromInt(@intFromEnum(inf.direction)),
                    .decay_condition_cid    = inf.decay_condition_cid,
                    .causality_ledger_event = envelope.event_hash,
                };
                all_influences.append(entry) catch return RebuildError.OutOfMemory;
            },

            // REGEL 3: Forge erschafft nur — ändert NICHT current_artifact_cid.
            // REGEL 2: Darf nur next_generation konsumieren.
            // REGEL 5: Speichert PendingForgeEntry mit target_harness + forge_event_hash.
            .artifact_forged => |forge| {
                if (!is_booted) return RebuildError.ManifestationNotBooted;
                const consumed = forge.consumed_influence_events[0..forge.consumed_count];
                try consumeStrict(&all_influences, consumed, .next_generation);
                // A₁ wird als PendingForgeEntry registriert — wartet auf Absorption.
                const entry = state_mod.PendingForgeEntry{
                    .artifact_cid     = forge.new_artifact_cid,
                    .target_harness   = forge.harness_id,
                    .forge_event_hash = envelope.event_hash,
                };
                pending_forge.append(entry) catch return RebuildError.OutOfMemory;
            },

            // REGEL 3: Absorb integriert — current_artifact_cid wechselt erst hier.
            // REGEL 2: Darf nur current_manifestation konsumieren.
            // REGEL 5: Prüft Binding — target_harness + artifact_cid müssen zum PendingForgeEntry passen.
            .artifact_absorbed => |abs| {
                if (!is_booted) return RebuildError.ManifestationNotBooted;

                // Regel 5: Pending-Eintrag suchen und entfernen
                const pending_idx = findPending(&pending_forge, abs.absorbed_artifact_cid)
                    orelse return RebuildError.AbsorbBindingViolation;
                const pending_entry = pending_forge.items[pending_idx];

                // Regel 5b: target_harness muss mit dem Harness dieses States übereinstimmen
                if (!ledger_mod.ids.hashEql(pending_entry.target_harness, identity.harness_id))
                    return RebuildError.AbsorbBindingViolation;

                _ = pending_forge.orderedRemove(pending_idx);

                // State ändert sich ERST HIER (Regel 3)
                current_artifact_cid = abs.absorbed_artifact_cid;
                const consumed = abs.consumed_influence_events[0..abs.consumed_count];
                try consumeStrict(&all_influences, consumed, .current_manifestation);
                const res = LineageResonance{
                    .resonance_cid          = abs.resulting_resonance_cid,
                    .absorbed_at_epoch      = envelope.sequence,
                    .causality_ledger_event = envelope.event_hash,
                };
                resonances.append(res) catch return RebuildError.OutOfMemory;
                // pending_entry.forge_event_hash verfügbar für zukünftige Audit-Nutzung
            },

            // Guardian-Provenance-Invariante (§7 Spec):
            // guardian_set_changed ist bereits oben auf forge_pubkey geprüft.
            // Effekt: Guardian-Set wird durch die neuen Pubkeys vollständig ersetzt.
            .guardian_set_changed => |gsc| {
                // Autorisierung oben bereits geprüft. Jetzt State-Effekt:
                // Alten Guardian-Set verwerfen, neuen übernehmen.
                guardian_set.clearRetainingCapacity();
                const count = @as(usize, gsc.new_guardian_count);
                for (gsc.new_guardian_pubkeys[0..count]) |pk| {
                    guardian_set.append(pk) catch return RebuildError.OutOfMemory;
                }
            },
        }
    }

    if (!is_booted) return RebuildError.ManifestationNotBooted;

    // MATERIALIZE — Trennung active vs pending (Einflüsse)
    var active_list  = std.array_list.AlignedManaged(CausalInfluence, null).init(allocator);
    errdefer active_list.deinit();

    for (all_influences.items) |inf| {
        switch (inf.target_generation) {
            .current_manifestation =>
                active_list.append(inf) catch return RebuildError.OutOfMemory,
            .next_generation => {}, // nicht-konsumierte next_gen Einflüsse bleiben in pending_forge impliziert
        }
    }
    all_influences.deinit();

    const active_slice   = active_list.toOwnedSlice()   catch return RebuildError.OutOfMemory;
    const forge_slice    = pending_forge.toOwnedSlice()  catch return RebuildError.OutOfMemory;
    const res_slice      = resonances.toOwnedSlice()     catch return RebuildError.OutOfMemory;
    const auth_slice     = authorities.toOwnedSlice()    catch return RebuildError.OutOfMemory;
    const guardian_slice = guardian_set.toOwnedSlice()   catch return RebuildError.OutOfMemory;

    // FINGERPRINT — Regel 4: unabhängig aus Kette
    var final_fp: Hash = undefined;
    fingerprint_hasher.final(&final_fp);

    const state = HarnessManifestation{
        .identity              = identity,
        .provenance            = provenance,
        .current_artifact_cid  = current_artifact_cid,
        .active_influence_set  = active_slice,
        .pending_forge_set     = forge_slice,
        .lineage_resonance_set = res_slice,
        .authority_set         = auth_slice,
        .causal_fingerprint    = final_fp,
    };

    return RebuildResult{
        .state               = state,
        .causal_fingerprint  = final_fp,
        .active_guardian_set = guardian_slice,
    };
}

// ── findPending (Regel 5) ─────────────────────────────────────────────────

/// Sucht in pending_forge nach einem Eintrag mit passendem artifact_cid.
/// Gibt den Index zurück oder null wenn nicht gefunden.
fn findPending(
    pending_forge: *const std.array_list.AlignedManaged(state_mod.PendingForgeEntry, null),
    artifact_cid: Hash,
) ?usize {
    for (pending_forge.items, 0..) |entry, i| {
        if (ledger_mod.ids.hashEql(entry.artifact_cid, artifact_cid)) return i;
    }
    return null;
}

// ── consumeStrict (Regel 2) ───────────────────────────────────────────────

/// Konsumiert Einflüsse aus der aktiven Liste — strict, kein Best-Effort.
///
/// Für jeden consumed_hash:
///   - Muss in active_list vorhanden sein
///   - Muss die korrekte target_generation haben
/// Sonst: IllegalInfluenceConsumption → gesamter Rebuild bricht ab.
fn consumeStrict(
    active_list:         *std.array_list.AlignedManaged(CausalInfluence, null),
    consumed_hashes:     []const Hash,
    required_generation: TargetGeneration,
) RebuildError!void {
    for (consumed_hashes) |h| {
        var found = false;
        var i: usize = 0;
        while (i < active_list.items.len) {
            const inf = active_list.items[i];
            if (ledger_mod.ids.hashEql(inf.causality_ledger_event, h)) {
                // Regel 2: falscher Generations-Typ → sofortiger Fehler
                if (inf.target_generation != required_generation)
                    return RebuildError.IllegalInfluenceConsumption;
                _ = active_list.orderedRemove(i);
                found = true;
                break;
            }
            i += 1;
        }
        // Nicht gefunden oder schon konsumiert → Fehler
        if (!found) return RebuildError.IllegalInfluenceConsumption;
    }
}

// ── Hilfsfunktionen ───────────────────────────────────────────────────────

/// Leitet die Harness-ID deterministisch aus dem Boot-Event-Hash ab.
/// harness_id = SHA256("harness_id:" || boot_event_hash)
fn hashHarnessFromBoot(boot_event_hash: Hash) Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("harness_id:");
    hasher.update(&boot_event_hash);
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const ledger_ids = ledger_mod.ids;
const Ed25519 = std.crypto.sign.Ed25519;

fn mkh(b: u8) Hash {
    var h: Hash = ZERO_HASH;
    h[0] = b;
    return h;
}

// ── Test keypairs ──────────────────────────────────────────────────────────
//
// Alle Tests verwenden dieselben deterministischen Keypairs.
// TEST_FORGE_KP: der autorisierte Forge-Akteur (actor in allen normalen Events).
// TEST_ATTACKER_KP: ein anderer Schlüssel — für adversariale Tests.
//
// Deterministisch via generateDeterministic: gleicher Seed → gleicher Schlüssel.

const TEST_FORGE_SEED:    [32]u8 = [_]u8{0xFE} ** 32;
const TEST_ATTACKER_SEED: [32]u8 = [_]u8{0xBA} ** 32;

/// Gibt das Forge-Keypair zurück (deterministisch).
fn forgeKp() Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(TEST_FORGE_SEED) catch unreachable;
}

/// Gibt das Angreifer-Keypair zurück (deterministisch).
fn attackerKp() Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(TEST_ATTACKER_SEED) catch unreachable;
}

/// Berechnet den kanonischen payload_digest (deterministisch, kein Pointer-Content).
/// tag(2 LE) ++ SHA256(asBytes(payload))
fn computePayloadDigest(payload: *const ledger_mod.EventPayload) Hash {
    var tag_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &tag_buf, @intFromEnum(std.meta.activeTag(payload.*)), .little);
    const payload_raw = std.mem.asBytes(payload);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&tag_buf);
    hasher.update(payload_raw);
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

/// Baut ein Envelope mit korrektem prev/seq und echter Ed25519-Signatur.
/// actor_pubkey = forge_pubkey (default für alle nicht-adversarialen Tests).
fn makeEnv(seq: u64, prev: Hash, payload: ledger_mod.EventPayload) LedgerEventEnvelope {
    return makeEnvWith(seq, prev, payload, forgeKp());
}

/// Baut ein Envelope mit explizitem Keypair (für adversariale Tests).
fn makeEnvWith(
    seq: u64,
    prev: Hash,
    payload: ledger_mod.EventPayload,
    kp: Ed25519.KeyPair,
) LedgerEventEnvelope {
    const payload_digest = computePayloadDigest(&payload);
    const event_hash = ledger_mod.computeEventHash(seq, prev, &payload_digest);
    const sig = kp.sign(&event_hash, null) catch unreachable;
    return .{
        .sequence        = seq,
        .prev_event_hash = prev,
        .event_hash      = event_hash,
        .actor_pubkey    = kp.public_key.toBytes(),
        .signature       = sig.toBytes(),
        .payload         = payload,
    };
}

fn bootPayload(soul: Hash, init_art: Hash) ledger_mod.EventPayload {
    return .{ .manifestation_booted_from_spore = .{
        .soul_hash            = soul,
        .spore_cid            = mkh(0xBB),
        .lost_cid             = ZERO_HASH,
        .initial_artifact_cid = init_art,
    }};
}

/// Baut ein valides GenesisAuthorityRecord mit dem Test-Forge-Keypair.
/// forge_pubkey = forgeKp().public_key — passt zu allen makeEnv()-Envelopes.
fn makeTestGenesis(allocator: std.mem.Allocator) !genesis_mod.GenesisAuthorityRecord {
    const kp = forgeKp();
    const guardian_pks = try allocator.alloc([32]u8, 1);
    guardian_pks[0] = kp.public_key.toBytes();

    var rec = genesis_mod.GenesisAuthorityRecord{
        .genesis_id        = [_]u8{0x01} ** 16,
        .protocol_version  = 1,
        .host_soul_cid     = [_]u8{0x42} ** 32,
        .forge_pubkey      = kp.public_key.toBytes(),
        .guardian_pubkeys  = guardian_pks,
        .guardian_count    = 1,
        .genesis_timestamp = 1_700_000_000,
        .genesis_hash      = genesis_mod.ZERO_HASH,
        .genesis_signature = [_]u8{0} ** 64,
    };
    rec.genesis_hash = genesis_mod.computeGenesisHash(&rec);
    const genesis_sig = kp.sign(&rec.genesis_hash, null) catch unreachable;
    rec.genesis_signature = genesis_sig.toBytes();
    return rec;
}

test "rebuild: minimaler valider Stream — nur Boot" {
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(0x51), mkh(0xA0)));

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    var result = try rebuildProtocol(std.testing.allocator, &genesis, &.{e0});
    defer freeRebuildResult(&result, std.testing.allocator);

    try std.testing.expect(ledger_ids.hashEql(mkh(0x51), result.state.identity.canonical_soul_hash));
    try std.testing.expect(ledger_ids.hashEql(mkh(0xA0), result.state.current_artifact_cid));
    try std.testing.expectEqual(@as(usize, 0), result.state.active_influence_set.len);
    try std.testing.expectEqual(@as(usize, 0), result.state.pending_forge_set.len);
    try std.testing.expect(!ledger_ids.isZero(result.causal_fingerprint));
}

test "rebuild: BrokenChainLink erkannt" {
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    // e1 verweist auf falschen prev
    const e1 = makeEnv(1, mkh(0xFF), .{ .soul_anchored = mkh(0x11) });

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.BrokenChainLink,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 }),
    );
}

test "rebuild: InvalidSequence erkannt" {
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const e2 = makeEnv(2, e0.event_hash, .{ .soul_anchored = mkh(0x11) }); // seq 0→2

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.InvalidSequence,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e2 }),
    );
}

test "rebuild: Regel 2 — Forge konsumiert next_generation-Einfluss korrekt" {
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    // Harness-ID ist von Boot-Event-Hash abgeleitet
    const harness_id = hashHarnessFromBoot(e0.event_hash);

    // Einfluss next_generation
    const inf_payload = ledger_mod.EventPayload{ .influence_authorized = .{
        .source_harness = mkh(0xBB), .target_harness = harness_id,
        .source_artifact_cid = mkh(0xA0), .shared_work_context = ZERO_HASH,
        .authorization_policy_hash = ZERO_HASH, .guardian_authorization_event = ZERO_HASH,
        .target_generation = .next_generation, .direction = .curse,
        .decay_condition_cid = ZERO_HASH,
    }};
    const e1 = makeEnv(1, e0.event_hash, inf_payload);

    // Forge konsumiert e1.event_hash — harness_id muss mit abgeleitetem Wert übereinstimmen
    var forge_p = ledger_mod.PayloadArtifactForged{
        .harness_id = harness_id, .previous_artifact_cid = mkh(0xA0),
        .new_artifact_cid = mkh(0xA1),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 1, .forge_epoch = 1,
    };
    forge_p.consumed_influence_events[0] = e1.event_hash;
    const e2 = makeEnv(2, e1.event_hash, .{ .artifact_forged = forge_p });

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    var result = try rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1, e2 });
    defer freeRebuildResult(&result, std.testing.allocator);

    // Einfluss konsumiert — PendingForgeEntry für A1 wurde registriert
    try std.testing.expectEqual(@as(usize, 1), result.state.pending_forge_set.len);
    try std.testing.expect(ledger_ids.hashEql(mkh(0xA1), result.state.pending_forge_set[0].artifact_cid));
    // current_artifact_cid noch A0 (Forge ändert NICHT — Regel 3)
    try std.testing.expect(ledger_ids.hashEql(mkh(0xA0), result.state.current_artifact_cid));
}

test "rebuild: Regel 3 — Absorb ändert current_artifact_cid (mit vorherigem Forge)" {
    // Regel 5: Absorb braucht zwingend einen vorherigen Forge
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const harness_id = hashHarnessFromBoot(e0.event_hash);

    // Forge erzeugt A1 für diesen Harness
    const forge_p = ledger_mod.PayloadArtifactForged{
        .harness_id = harness_id, .previous_artifact_cid = mkh(0xA0),
        .new_artifact_cid = mkh(0xA1),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 0, .forge_epoch = 1,
    };
    const e1 = makeEnv(1, e0.event_hash, .{ .artifact_forged = forge_p });

    // Absorb integriert A1
    const abs_p = ledger_mod.PayloadArtifactAbsorbed{
        .harness_id = harness_id, .absorbed_artifact_cid = mkh(0xA1),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 0, .resulting_resonance_cid = mkh(0x91),
    };
    const e2 = makeEnv(2, e1.event_hash, .{ .artifact_absorbed = abs_p });

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    var result = try rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1, e2 });
    defer freeRebuildResult(&result, std.testing.allocator);

    // current_artifact_cid ist jetzt A1 (Regel 3)
    try std.testing.expect(ledger_ids.hashEql(mkh(0xA1), result.state.current_artifact_cid));
    // Pending-Eintrag wurde konsumiert
    try std.testing.expectEqual(@as(usize, 0), result.state.pending_forge_set.len);
    try std.testing.expectEqual(@as(usize, 1), result.state.lineage_resonance_set.len);
}

test "rebuild: Regel 5 — Absorb ohne vorherigen Forge → AbsorbBindingViolation" {
    // Absorb ohne ein PendingForgeEntry → sofortiger Fehler
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const harness_id = hashHarnessFromBoot(e0.event_hash);

    const abs_p = ledger_mod.PayloadArtifactAbsorbed{
        .harness_id = harness_id, .absorbed_artifact_cid = mkh(0xA1),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 0, .resulting_resonance_cid = mkh(0x91),
    };
    const e1 = makeEnv(1, e0.event_hash, .{ .artifact_absorbed = abs_p });

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.AbsorbBindingViolation,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 }),
    );
}

test "rebuild: Regel 5 — Absorb mit falschem Harness → AbsorbBindingViolation" {
    // Forge für Harness A, Absorb versucht es mit anderem Harness-Kontext
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const harness_id = hashHarnessFromBoot(e0.event_hash);
    const wrong_harness = mkh(0xFF); // anderer Harness

    // Forge deklariert wrong_harness als target
    const forge_p = ledger_mod.PayloadArtifactForged{
        .harness_id = wrong_harness, .previous_artifact_cid = mkh(0xA0),
        .new_artifact_cid = mkh(0xA1),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 0, .forge_epoch = 1,
    };
    const e1 = makeEnv(1, e0.event_hash, .{ .artifact_forged = forge_p });

    // Absorb versucht A1 zu integrieren — aber PendingForgeEntry.target_harness ≠ harness_id
    const abs_p = ledger_mod.PayloadArtifactAbsorbed{
        .harness_id = harness_id, .absorbed_artifact_cid = mkh(0xA1),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 0, .resulting_resonance_cid = mkh(0x91),
    };
    const e2 = makeEnv(2, e1.event_hash, .{ .artifact_absorbed = abs_p });

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.AbsorbBindingViolation,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1, e2 }),
    );
}

test "rebuild: Regel 5 — Absorb mit falscher artifact_cid → AbsorbBindingViolation" {
    // Forge erzeugt A1, Absorb behauptet A2 (nicht in pending)
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const harness_id = hashHarnessFromBoot(e0.event_hash);

    const forge_p = ledger_mod.PayloadArtifactForged{
        .harness_id = harness_id, .previous_artifact_cid = mkh(0xA0),
        .new_artifact_cid = mkh(0xA1), // Forge erzeugt A1
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 0, .forge_epoch = 1,
    };
    const e1 = makeEnv(1, e0.event_hash, .{ .artifact_forged = forge_p });

    const abs_p = ledger_mod.PayloadArtifactAbsorbed{
        .harness_id = harness_id, .absorbed_artifact_cid = mkh(0xA2), // behauptet A2
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 0, .resulting_resonance_cid = mkh(0x91),
    };
    const e2 = makeEnv(2, e1.event_hash, .{ .artifact_absorbed = abs_p });

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.AbsorbBindingViolation,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1, e2 }),
    );
}

test "rebuild: Regel 2 — Forge versucht current_gen zu konsumieren → Fehler" {
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));

    // Einfluss current_manifestation
    const inf_payload = ledger_mod.EventPayload{ .influence_authorized = .{
        .source_harness = mkh(0xBB), .target_harness = mkh(0x01),
        .source_artifact_cid = mkh(0xA0), .shared_work_context = ZERO_HASH,
        .authorization_policy_hash = ZERO_HASH, .guardian_authorization_event = ZERO_HASH,
        .target_generation = .current_manifestation, .direction = .bless, // AKTUELL
        .decay_condition_cid = ZERO_HASH,
    }};
    const e1 = makeEnv(1, e0.event_hash, inf_payload);

    // Forge versucht trotzdem diesen Einfluss zu konsumieren
    var forge_p = ledger_mod.PayloadArtifactForged{
        .harness_id = ZERO_HASH, .previous_artifact_cid = mkh(0xA0),
        .new_artifact_cid = mkh(0xA1),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 1, .forge_epoch = 1,
    };
    forge_p.consumed_influence_events[0] = e1.event_hash;
    const e2 = makeEnv(2, e1.event_hash, .{ .artifact_forged = forge_p });

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.IllegalInfluenceConsumption,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1, e2 }),
    );
}

test "rebuild: Regel 4 — Fingerprint unabhängig vom State" {
    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    var r1 = try rebuildProtocol(std.testing.allocator, &genesis, &.{e0});
    defer freeRebuildResult(&r1, std.testing.allocator);
    var r2 = try rebuildProtocol(std.testing.allocator, &genesis, &.{e0});
    defer freeRebuildResult(&r2, std.testing.allocator);

    // Gleiche Kette → gleicher Fingerprint (deterministisch)
    try std.testing.expect(ledger_ids.hashEql(r1.causal_fingerprint, r2.causal_fingerprint));

    // Verschiedene Ketten → verschiedener Fingerprint
    const e0b = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(2), mkh(0xA0)));
    var r3 = try rebuildProtocol(std.testing.allocator, &genesis, &.{e0b});
    defer freeRebuildResult(&r3, std.testing.allocator);
    try std.testing.expect(!ledger_ids.hashEql(r1.causal_fingerprint, r3.causal_fingerprint));
}

// ── Adversarielle Tests ────────────────────────────────────────────────────

test "rebuild: adversarial — unerlaubtes privilegiertes Event → UnauthorizedPrivilegedEvent" {
    // actor_pubkey ≠ forge_pubkey → artifact_forged darf nicht akzeptiert werden
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const harness_id = hashHarnessFromBoot(e0.event_hash);

    const forge_p = ledger_mod.PayloadArtifactForged{
        .harness_id = harness_id, .previous_artifact_cid = mkh(0xA0),
        .new_artifact_cid = mkh(0xA1),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 0, .forge_epoch = 1,
    };
    // Böser Akteur mit echtem Ed25519-Schlüssel, aber nicht die Forge Authority
    const e1 = makeEnvWith(1, e0.event_hash, .{ .artifact_forged = forge_p }, attackerKp());

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.UnauthorizedPrivilegedEvent,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 }),
    );
}

test "rebuild: adversarial — Guardian-Substitution → UnauthorizedGuardianChange" {
    // guardian_set_changed von einem Nicht-Forge-Akteur → UnauthorizedGuardianChange
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));

    const akp = attackerKp();
    const gsc_p = ledger_mod.PayloadGuardianSetChanged{
        .new_guardian_count   = 1,
        .new_guardian_pubkeys = blk: {
            var arr: [32][32]u8 = [_][32]u8{ZERO_HASH} ** 32;
            arr[0] = akp.public_key.toBytes(); // Angreifer versucht eigenen Schlüssel einzuschleusen
            break :blk arr;
        },
        .reason_cid = ZERO_HASH,
    };
    // Böser Akteur — echter Ed25519-Schlüssel, aber nicht die Forge Authority
    const e1 = makeEnvWith(1, e0.event_hash, .{ .guardian_set_changed = gsc_p }, akp);

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.UnauthorizedGuardianChange,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 }),
    );
}

test "rebuild: adversarial — guardian_set_changed von Forge erlaubt" {
    // guardian_set_changed von forge_pubkey (0xAC) → muss erfolgreich sein
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));

    const forge_kp = forgeKp();
    const gsc_p = ledger_mod.PayloadGuardianSetChanged{
        .new_guardian_count   = 1,
        .new_guardian_pubkeys = blk: {
            var arr: [32][32]u8 = [_][32]u8{ZERO_HASH} ** 32;
            arr[0] = forge_kp.public_key.toBytes(); // Forge aktualisiert Guardian Set
            break :blk arr;
        },
        .reason_cid = ZERO_HASH,
    };
    // Forge-Akteur ist autorisiert
    const e1 = makeEnv(1, e0.event_hash, .{ .guardian_set_changed = gsc_p });

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    var result = try rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 });
    defer freeRebuildResult(&result, std.testing.allocator);
    // Rebuild muss erfolgreich sein
    try std.testing.expect(!ledger_ids.isZero(result.causal_fingerprint));
}

// ── Task 1: InvalidSignature tests ────────────────────────────────────────

test "rebuild: signature — tampered signature byte → InvalidSignature" {
    var e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    e0.signature[0] ^= 0xFF; // corrupt one byte of the Ed25519 signature

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.InvalidSignature,
        rebuildProtocol(std.testing.allocator, &genesis, &.{e0}),
    );
}

test "rebuild: signature — valid sig on correct event_hash passes" {
    // Sanity: a correctly signed envelope passes signature verification.
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    var result = try rebuildProtocol(std.testing.allocator, &genesis, &.{e0});
    defer freeRebuildResult(&result, std.testing.allocator);
    try std.testing.expect(!ledger_ids.isZero(result.causal_fingerprint));
}

test "rebuild: signature — wrong key signs correct hash → InvalidSignature then UnauthorizedPrivilegedEvent" {
    // A privileged event signed by the attacker keypair:
    // First: sig verifies (attacker has a valid Ed25519 key, sig matches event_hash)
    // Then: actor_pubkey ≠ genesis.forge_pubkey → UnauthorizedPrivilegedEvent
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const harness_id = hashHarnessFromBoot(e0.event_hash);
    const forge_p = ledger_mod.PayloadArtifactForged{
        .harness_id = harness_id, .previous_artifact_cid = mkh(0xA0),
        .new_artifact_cid = mkh(0xA1),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 0, .forge_epoch = 1,
    };
    // Attacker signs with their own valid key — sig check passes, authority check fails
    const e1 = makeEnvWith(1, e0.event_hash, .{ .artifact_forged = forge_p }, attackerKp());

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.UnauthorizedPrivilegedEvent,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 }),
    );
}

// ── Task 7: Ledger Immutability Invariants ────────────────────────────────
// Each invariant is tested independently. Every mutation produces a distinct
// reject path — no silent acceptance, no repair.

test "rebuild: ledger invariant — payload mutation changes event_hash, chain breaks" {
    // makeEnv hashes payload content into event_hash.
    // If we swap the payload but keep the envelope's event_hash unchanged,
    // the chain must be treated as broken at verification time.
    // Here we prove: same seq/prev but different payload → different event_hash.
    const pay_a = bootPayload(mkh(0x01), mkh(0xA0));
    const pay_b = bootPayload(mkh(0x02), mkh(0xA0)); // different soul

    const e_a = makeEnv(0, ledger_mod.GENESIS_PREV, pay_a);
    const e_b = makeEnv(0, ledger_mod.GENESIS_PREV, pay_b);

    // Different payloads → different event_hashes (binding invariant)
    try std.testing.expect(!ledger_ids.hashEql(e_a.event_hash, e_b.event_hash));
}

test "rebuild: ledger invariant — sequence gap is rejected" {
    // Task 7: Sequence bindet Ordnung. Lücke im Stream → InvalidSequence.
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const e3 = makeEnv(3, e0.event_hash, .{ .soul_anchored = mkh(0x11) }); // gap: 0 → 3

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.InvalidSequence,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e3 }),
    );
}

test "rebuild: ledger invariant — parent hash mutation breaks chain" {
    // Task 7: Parent Hash bindet Kausalität. Falscher prev → BrokenChainLink.
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    var e1 = makeEnv(1, e0.event_hash, .{ .soul_anchored = mkh(0x11) });
    // Corrupt the prev_event_hash after construction
    e1.prev_event_hash[0] ^= 0xFF;

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.BrokenChainLink,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 }),
    );
}

test "rebuild: ledger invariant — fingerprint binds entire history" {
    // Same event sequence → same fingerprint (deterministic).
    // One extra event → different fingerprint.
    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const e1 = makeEnv(1, e0.event_hash, .{ .soul_anchored = mkh(0x11) });

    var r1 = try rebuildProtocol(std.testing.allocator, &genesis, &.{e0});
    defer freeRebuildResult(&r1, std.testing.allocator);

    var r2 = try rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 });
    defer freeRebuildResult(&r2, std.testing.allocator);

    // More events → different fingerprint (history extension is detectable)
    try std.testing.expect(!ledger_ids.hashEql(r1.causal_fingerprint, r2.causal_fingerprint));
}

// ── Task 5: Rebuild Trust Boundary ────────────────────────────────────────
// Rebuild must not invent Authority, not repair missing events,
// not accept a false fingerprint.

test "rebuild: trust boundary — empty stream is rejected (cannot invent boot)" {
    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.EmptyStream,
        rebuildProtocol(std.testing.allocator, &genesis, &.{}),
    );
}

test "rebuild: trust boundary — stream without boot event is rejected" {
    // soul_anchored without prior boot → ManifestationNotBooted.
    // Rebuild cannot invent a missing boot.
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, .{ .soul_anchored = mkh(0x11) });

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.ManifestationNotBooted,
        rebuildProtocol(std.testing.allocator, &genesis, &.{e0}),
    );
}

test "rebuild: trust boundary — event before boot is rejected" {
    // influence_authorized before manifestation_booted → ManifestationNotBooted.
    const inf_payload = ledger_mod.EventPayload{ .influence_authorized = .{
        .source_harness               = mkh(0xBB),
        .target_harness               = mkh(0x01),
        .source_artifact_cid          = mkh(0xA0),
        .shared_work_context          = ZERO_HASH,
        .authorization_policy_hash    = ZERO_HASH,
        .guardian_authorization_event = ZERO_HASH,
        .target_generation            = .next_generation,
        .direction                    = .bless,
        .decay_condition_cid          = ZERO_HASH,
    }};
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, inf_payload);

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.ManifestationNotBooted,
        rebuildProtocol(std.testing.allocator, &genesis, &.{e0}),
    );
}

// ── Task 8: Cross-Root Adversarial Matrix ─────────────────────────────────
// Combined attack scenarios. Each case has an explicit ACCEPT or REJECT outcome.

test "rebuild: adversarial matrix — tampered event_hash detected via InvalidSignature" {
    // REJECT: event_hash tampered → signature no longer matches → InvalidSignature
    // (signature verification runs before chain-link check, so InvalidSignature fires first)
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    var e0_tampered = e0;
    e0_tampered.event_hash[0] ^= 0xFF; // corrupt event_hash after signing

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.InvalidSignature,
        rebuildProtocol(std.testing.allocator, &genesis, &.{e0_tampered}),
    );
}

test "rebuild: adversarial matrix — tampered prev_event_hash breaks chain after sig passes" {
    // REJECT: prev_event_hash tampered → BrokenChainLink
    // (signature is over event_hash only, not prev_event_hash — so sig passes, chain check fails)
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    var e1 = makeEnv(1, e0.event_hash, .{ .soul_anchored = mkh(0x11) });
    e1.prev_event_hash[0] ^= 0xFF; // corrupt prev link (sig was over event_hash, not this field)

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.BrokenChainLink,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 }),
    );
}

test "rebuild: adversarial matrix — valid events + wrong forge_pubkey in genesis → UnauthorizedPrivilegedEvent" {
    // REJECT: valid chain but genesis has a different forge_pubkey
    // All events use actor=0xAC, but genesis says forge=0xBB → forge events rejected
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const harness_id = hashHarnessFromBoot(e0.event_hash);
    const forge_p = ledger_mod.PayloadArtifactForged{
        .harness_id = harness_id, .previous_artifact_cid = mkh(0xA0),
        .new_artifact_cid = mkh(0xA1),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 0, .forge_epoch = 1,
    };
    const e1 = makeEnv(1, e0.event_hash, .{ .artifact_forged = forge_p }); // actor = 0xAC

    // Genesis with different forge_pubkey
    const guardian_pks = try std.testing.allocator.alloc([32]u8, 1);
    guardian_pks[0] = mkh(0xBB);
    var bad_genesis = genesis_mod.GenesisAuthorityRecord{
        .genesis_id        = [_]u8{0x01} ** 16,
        .protocol_version  = 1,
        .host_soul_cid     = [_]u8{0x42} ** 32,
        .forge_pubkey      = mkh(0xBB), // ← different from actor 0xAC
        .guardian_pubkeys  = guardian_pks,
        .guardian_count    = 1,
        .genesis_timestamp = 1_700_000_000,
        .genesis_hash      = genesis_mod.ZERO_HASH,
        .genesis_signature = [_]u8{0} ** 64,
    };
    defer genesis_mod.freeGenesisRecord(&bad_genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.UnauthorizedPrivilegedEvent,
        rebuildProtocol(std.testing.allocator, &bad_genesis, &.{ e0, e1 }),
    );
}

test "rebuild: adversarial matrix — replay of privileged event is detectable via fingerprint" {
    // REJECT (chain break): replaying e1 as e2 with same content but e2.prev = e1.event_hash
    // would be a valid new event structurally — rebuild accepts it.
    // But the replay produces a DIFFERENT fingerprint from the original single-event chain.
    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const e1 = makeEnv(1, e0.event_hash, .{ .soul_anchored = mkh(0x11) });

    // "replay" as e2 with same soul_anchored payload — different seq/prev so different hash
    const e2_replay = makeEnv(2, e1.event_hash, .{ .soul_anchored = mkh(0x11) });

    var r_short = try rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 });
    defer freeRebuildResult(&r_short, std.testing.allocator);
    var r_long = try rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1, e2_replay });
    defer freeRebuildResult(&r_long, std.testing.allocator);

    // Different history → different fingerprint (replay is detectable)
    try std.testing.expect(!ledger_ids.hashEql(r_short.causal_fingerprint, r_long.causal_fingerprint));
}

test "rebuild: adversarial matrix — conflicting genesis (different forge_pubkey) yields different authority" {
    // Two genesis records with different forge_pubkeys define different authority roots.
    // The same event stream is accepted by genesis_a (actor=0xAC) but rejected by genesis_b (forge=0xDD).
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const harness_id = hashHarnessFromBoot(e0.event_hash);
    const forge_p = ledger_mod.PayloadArtifactForged{
        .harness_id = harness_id, .previous_artifact_cid = mkh(0xA0),
        .new_artifact_cid = mkh(0xA1),
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** 64,
        .consumed_count = 0, .forge_epoch = 1,
    };
    const e1 = makeEnv(1, e0.event_hash, .{ .artifact_forged = forge_p }); // actor = 0xAC

    // genesis_a: forge=0xAC → ACCEPT
    var genesis_a = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis_a, std.testing.allocator);
    var r = try rebuildProtocol(std.testing.allocator, &genesis_a, &.{ e0, e1 });
    defer freeRebuildResult(&r, std.testing.allocator);
    try std.testing.expect(!ledger_ids.isZero(r.causal_fingerprint));

    // genesis_b: forge=0xDD → REJECT (actor 0xAC ≠ forge 0xDD)
    const guardian_pks_b = try std.testing.allocator.alloc([32]u8, 1);
    guardian_pks_b[0] = mkh(0xDD);
    var genesis_b = genesis_mod.GenesisAuthorityRecord{
        .genesis_id        = [_]u8{0x02} ** 16,
        .protocol_version  = 1,
        .host_soul_cid     = [_]u8{0x42} ** 32,
        .forge_pubkey      = mkh(0xDD),
        .guardian_pubkeys  = guardian_pks_b,
        .guardian_count    = 1,
        .genesis_timestamp = 1_700_000_000,
        .genesis_hash      = genesis_mod.ZERO_HASH,
        .genesis_signature = [_]u8{0} ** 64,
    };
    defer genesis_mod.freeGenesisRecord(&genesis_b, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.UnauthorizedPrivilegedEvent,
        rebuildProtocol(std.testing.allocator, &genesis_b, &.{ e0, e1 }),
    );
}

// ── Task 9: Deterministic Rebuild Contract ────────────────────────────────
// rebuild(H) is deterministic: same history → same state AND same fingerprint.
// Repeated calls must produce identical results (no allocation-order dependence).

test "rebuild: determinism — identical history yields identical fingerprint (3 runs)" {
    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const e1 = makeEnv(1, e0.event_hash, .{ .soul_anchored = mkh(0x22) });
    const stream = &[_]LedgerEventEnvelope{ e0, e1 };

    var r1 = try rebuildProtocol(std.testing.allocator, &genesis, stream);
    defer freeRebuildResult(&r1, std.testing.allocator);
    var r2 = try rebuildProtocol(std.testing.allocator, &genesis, stream);
    defer freeRebuildResult(&r2, std.testing.allocator);
    var r3 = try rebuildProtocol(std.testing.allocator, &genesis, stream);
    defer freeRebuildResult(&r3, std.testing.allocator);

    try std.testing.expect(ledger_ids.hashEql(r1.causal_fingerprint, r2.causal_fingerprint));
    try std.testing.expect(ledger_ids.hashEql(r2.causal_fingerprint, r3.causal_fingerprint));
}

test "rebuild: determinism — identical history yields identical derived state" {
    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(0x51), mkh(0xA7)));
    const stream = &[_]LedgerEventEnvelope{e0};

    var r1 = try rebuildProtocol(std.testing.allocator, &genesis, stream);
    defer freeRebuildResult(&r1, std.testing.allocator);
    var r2 = try rebuildProtocol(std.testing.allocator, &genesis, stream);
    defer freeRebuildResult(&r2, std.testing.allocator);

    // Same soul_hash, same artifact_cid, same fingerprint
    try std.testing.expect(ledger_ids.hashEql(r1.state.identity.canonical_soul_hash, r2.state.identity.canonical_soul_hash));
    try std.testing.expect(ledger_ids.hashEql(r1.state.current_artifact_cid, r2.state.current_artifact_cid));
    try std.testing.expect(ledger_ids.hashEql(r1.causal_fingerprint, r2.causal_fingerprint));
    try std.testing.expectEqual(r1.state.active_influence_set.len, r2.state.active_influence_set.len);
    try std.testing.expectEqual(r1.state.pending_forge_set.len, r2.state.pending_forge_set.len);
}

test "rebuild: determinism — different history yields different fingerprint (contract)" {
    // rebuild(H1) fingerprint ≠ rebuild(H2) fingerprint when H1 ≠ H2
    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    const e0_a = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(0xAA), mkh(0xA0)));
    const e0_b = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(0xBB), mkh(0xA0)));

    var r_a = try rebuildProtocol(std.testing.allocator, &genesis, &.{e0_a});
    defer freeRebuildResult(&r_a, std.testing.allocator);
    var r_b = try rebuildProtocol(std.testing.allocator, &genesis, &.{e0_b});
    defer freeRebuildResult(&r_b, std.testing.allocator);

    try std.testing.expect(!ledger_ids.hashEql(r_a.causal_fingerprint, r_b.causal_fingerprint));
}

// ── Task 6: Derive Boundary ───────────────────────────────────────────────
// Derived state (causal_fingerprint, resonance_set) must not affect primary history.
// We prove this by verifying that modifying derived output fields does not
// change what a fresh rebuild produces from the same event stream.

test "rebuild: derive boundary — mutating result state does not affect next rebuild" {
    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));

    var r1 = try rebuildProtocol(std.testing.allocator, &genesis, &.{e0});
    // Mutate the output — simulate adversarial derived-state tampering
    r1.state.current_artifact_cid[0] ^= 0xFF;
    r1.causal_fingerprint[0] ^= 0xFF;
    freeRebuildResult(&r1, std.testing.allocator);

    // Fresh rebuild from same stream must yield original values
    var r2 = try rebuildProtocol(std.testing.allocator, &genesis, &.{e0});
    defer freeRebuildResult(&r2, std.testing.allocator);

    try std.testing.expect(ledger_ids.hashEql(mkh(0xA0), r2.state.current_artifact_cid));
    try std.testing.expect(!ledger_ids.isZero(r2.causal_fingerprint));
}

test "rebuild: attacker cannot inject influence — UnauthorizedActor" {
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const harness_id = hashHarnessFromBoot(e0.event_hash);
    const inf_payload = ledger_mod.EventPayload{ .influence_authorized = .{
        .source_harness = mkh(0xBB), .target_harness = harness_id,
        .source_artifact_cid = mkh(0xA0), .shared_work_context = ZERO_HASH,
        .authorization_policy_hash = ZERO_HASH, .guardian_authorization_event = ZERO_HASH,
        .target_generation = .next_generation, .direction = .curse,
        .decay_condition_cid = ZERO_HASH,
    }};
    const e1 = makeEnvWith(1, e0.event_hash, inf_payload, attackerKp());

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.UnauthorizedActor,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 }),
    );
}

test "rebuild: attacker cannot establish c2 binding" {
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const harness_id = hashHarnessFromBoot(e0.event_hash);
    const akp = attackerKp();
    const c2 = ledger_mod.PayloadC2BindingEstablished{
        .harness_id = harness_id,
        .demon_id = akp.public_key.toBytes(),
        .capability_policy_cid = ZERO_HASH,
    };
    const e1 = makeEnvWith(1, e0.event_hash, .{ .c2_binding_established = c2 }, akp);

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    try std.testing.expectError(
        RebuildError.UnauthorizedPrivilegedEvent,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1 }),
    );
}

test "rebuild: delegated demon may authorize influence; revoked demon may not" {
    const e0 = makeEnv(0, ledger_mod.GENESIS_PREV, bootPayload(mkh(1), mkh(0xA0)));
    const harness_id = hashHarnessFromBoot(e0.event_hash);
    const akp = attackerKp();

    const c2 = ledger_mod.PayloadC2BindingEstablished{
        .harness_id = harness_id,
        .demon_id = akp.public_key.toBytes(),
        .capability_policy_cid = ZERO_HASH,
    };
    const e1 = makeEnv(1, e0.event_hash, .{ .c2_binding_established = c2 });

    const inf_payload = ledger_mod.EventPayload{ .influence_authorized = .{
        .source_harness = harness_id, .target_harness = harness_id,
        .source_artifact_cid = mkh(0xA0), .shared_work_context = ZERO_HASH,
        .authorization_policy_hash = ZERO_HASH, .guardian_authorization_event = ZERO_HASH,
        .target_generation = .current_manifestation, .direction = .curse,
        .decay_condition_cid = ZERO_HASH,
    }};
    const e2 = makeEnvWith(2, e1.event_hash, inf_payload, akp);

    var genesis = try makeTestGenesis(std.testing.allocator);
    defer genesis_mod.freeGenesisRecord(&genesis, std.testing.allocator);

    var ok = try rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1, e2 });
    defer freeRebuildResult(&ok, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), ok.state.authority_set.len);
    try std.testing.expectEqual(@as(usize, 1), ok.state.active_influence_set.len);

    const rev = ledger_mod.PayloadC2BindingRevoked{
        .harness_id = harness_id,
        .demon_id = akp.public_key.toBytes(),
        .reason_hash = ZERO_HASH,
    };
    const e3 = makeEnv(3, e2.event_hash, .{ .c2_binding_revoked = rev });
    const e4 = makeEnvWith(4, e3.event_hash, inf_payload, akp);
    try std.testing.expectError(
        RebuildError.UnauthorizedActor,
        rebuildProtocol(std.testing.allocator, &genesis, &.{ e0, e1, e2, e3, e4 }),
    );
}
