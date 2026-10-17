/// BKGDB Protocol — Ledger Event Types
///
/// Feature Freeze: 2026-09-01
///
/// Jeder Eintrag im Immutable Ledger ist ein strikt typisiertes Event.
/// Events sind unveränderlich. Einmal geschrieben, nie gelöscht.
///
/// Die fünf Graphen des BKG-Protokolls:
///   1. IDENTITY GRAPH    — SOUL, Manifestation, Harness-Bindung
///   2. AUTHORITY GRAPH   — C2-Bindung zwischen Harness und Demon/Agent
///   3. OBSERVATION GRAPH — Watcher-Evidenz, Guardian-Autorisierung
///   4. INFLUENCE GRAPH   — Bless/Curse: Einfluss zwischen Artefakten
///   5. EVOLUTION GRAPH   — Forge (Schmiedung), Absorption, Resonanz
///
/// Kanten-Validierung und State-Transitions: protocol/validate.zig
/// Materialized View:                        protocol/state.zig
/// Forensisches Traversal:                   protocol/traverse.zig
const std = @import("std");

// ── Basis-Typen ───────────────────────────────────────────────────────────

/// Content-Hash (SHA256). Identifiziert Artefakte und Events eindeutig.
/// CID = Content Identifier — kein Name, kein Pfad, nur der Hash des Inhalts.
pub const Hash = [32]u8;

pub const ZERO_HASH: Hash = [_]u8{0} ** 32;

pub fn hashEql(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, &a, &b);
}

pub fn isZero(h: Hash) bool {
    return hashEql(h, ZERO_HASH);
}

// ── EventType ─────────────────────────────────────────────────────────────

/// Alle gültigen Ledger-Event-Typen.
/// Wert-Bereiche sind reserviert und dürfen nicht überlappen:
///   100–199  Identity Graph
///   200–299  Authority Graph
///   300–399  Observation Graph
///   400–499  Influence Graph
///   500–599  Evolution Graph
pub const EventType = enum(u16) {
    // 1. IDENTITY GRAPH
    soul_anchored                  = 100,
    manifestation_booted_from_spore = 101,

    // 2. AUTHORITY GRAPH
    c2_binding_established         = 200,
    c2_binding_revoked             = 201,

    // 3. OBSERVATION GRAPH
    watcher_evidence_submitted     = 300,
    guardian_authorization_granted = 301,

    // 4. INFLUENCE GRAPH
    influence_authorized           = 400,

    // 5. EVOLUTION GRAPH
    artifact_forged                = 500,
    artifact_absorbed              = 501,

    // 6. GENESIS AUTHORITY GRAPH
    /// Ändert den Guardian Root Set — ausschließlich von Forge Authority signierbar.
    guardian_set_changed           = 600,

    pub fn graph(self: EventType) Graph {
        return switch (@intFromEnum(self)) {
            100...199 => .identity,
            200...299 => .authority,
            300...399 => .observation,
            400...499 => .influence,
            500...599 => .evolution,
            600...699 => .genesis_authority,
            else      => unreachable,
        };
    }
};

pub const Graph = enum { identity, authority, observation, influence, evolution, genesis_authority };

// ── 1. IDENTITY GRAPH ─────────────────────────────────────────────────────

/// soul_anchored: Verankerung einer SOUL-Identität im Ledger.
/// Einmalig pro SOUL. Kann nie überschrieben werden.
pub const EventSoulAnchored = struct {
    soul_cid: Hash,       // Content-Hash der SOUL-Definition
    anchor_ts: i64,       // Timestamp der Verankerung
};

/// manifestation_booted_from_spore: Eine neue Manifestation (Harness) entsteht aus einer Spore.
/// Jede Manifestation ist an genau eine SOUL gebunden.
pub const EventManifestationBootedFromSpore = struct {
    harness_id: Hash,     // Eindeutige ID dieser Manifestation
    soul_cid: Hash,       // Zugehörige SOUL
    spore_cid: Hash,      // Die Spore, aus der gebootet wurde
    initial_artifact_cid: Hash, // Erster Codekörper dieser Manifestation
};

// ── 2. AUTHORITY GRAPH ────────────────────────────────────────────────────

/// c2_binding_established: Harness autorisiert einen Demon/Agent als C2-Instanz.
/// C2 = Command & Control. Ohne dieses Event darf kein Demon im Namen dieses Harness handeln.
pub const EventC2BindingEstablished = struct {
    harness_id: Hash,
    demon_id: Hash,
    capability_policy_cid: Hash,  // Was der Demon darf
    binding_ts: i64,
};

/// c2_binding_revoked: C2-Bindung wird aufgehoben.
/// Nach diesem Event sind alle Aktionen des Demons für diesen Harness ungültig.
pub const EventC2BindingRevoked = struct {
    harness_id: Hash,
    demon_id: Hash,
    reason_hash: Hash,    // Hash des Revocation-Grunds (Ledger-Referenz)
    revoke_ts: i64,
};

// ── 3. OBSERVATION GRAPH ──────────────────────────────────────────────────

/// watcher_evidence_submitted: Watcher reicht signierte Beobachtung ein.
/// Keine Entscheidung — nur Beweis.
pub const EventWatcherEvidenceSubmitted = struct {
    watcher_id: Hash,
    harness_id: Hash,       // Beobachteter Harness
    evidence_cid: Hash,     // Content-Hash der Beobachtung
    work_context: Hash,     // In welchem Raum wurde beobachtet
    submit_ts: i64,
};

/// guardian_authorization_granted: Guardian autorisiert eine Interaktion.
/// Nur nach diesem Event darf influence_authorized geschrieben werden.
pub const EventGuardianAuthorizationGranted = struct {
    guardian_id: Hash,
    harness_source: Hash,
    harness_target: Hash,
    work_context: Hash,
    evidence_refs: [8]Hash, // Max. 8 Watcher-Evidence-Events als Basis (0-padded)
    evidence_count: u8,
    authorization_ts: i64,
};

// ── 4. INFLUENCE GRAPH ────────────────────────────────────────────────────

/// TargetGeneration: Auf welche Generation des Ziel-Harness wirkt der Einfluss?
pub const TargetGeneration = enum(u8) {
    /// Wirkt auf die aktuelle Manifestation (A₀). Konsum via artifact_absorbed.
    current_manifestation = 0,
    /// Wirkt auf die nächste Generation (A₁). Konsum via artifact_forged.
    next_generation       = 1,
};

/// InfluenceDirection: Typ des Einflusses.
pub const InfluenceDirection = enum(u8) {
    bless = 1, // Positiver Einfluss — wird zur LineageResonance bei Absorption
    curse = 2, // Negativer Einfluss — unumgängliche Kausal-Schuld in der Forge
};

/// influence_authorized: Das zentrale Event des Influence Graph.
/// Entsteht ERST nach guardian_authorization_granted.
/// Einmal geschrieben — kann nicht zurückgezogen werden.
/// Kann nur durch artifact_forged oder artifact_absorbed konsumiert werden.
pub const EventInfluenceAuthorized = struct {
    source_harness: Hash,
    target_harness: Hash,

    source_artifact_cid: Hash,    // CID des Quell-Artefakts zum Zeitpunkt der Autorisierung
    shared_work_context: Hash,    // Work Context in dem der Einfluss entstand

    authorization_policy_hash: Hash,   // Policy die diese Interaktion erlaubt hat
    guardian_authorization_event: Hash, // Referenz auf EventGuardianAuthorizationGranted

    target_generation: TargetGeneration,
    direction: InfluenceDirection,

    decay_condition_cid: Hash,    // Bedingung unter der der Einfluss verfällt (ZERO = kein Verfall)
};

// ── 5. EVOLUTION GRAPH ────────────────────────────────────────────────────

/// MAX_CONSUMED_INFLUENCES: Maximale Anzahl an consumed_influence_events pro Forge/Absorption.
/// Begrenzt Stack-Allokation. Kann mit Phase 2 erhöht werden.
pub const MAX_CONSUMED_INFLUENCES: usize = 64;

/// artifact_forged: Forge-Schmiedung erzeugt eine neue Artefakt-Generation.
/// Konsumiert alle next_generation-Einflüsse (Flüche/Segen) der Queue.
/// INVARIANTE: consumed_influence_events darf keine current_manifestation-Einflüsse enthalten.
pub const EventArtifactForged = struct {
    harness_id: Hash,
    previous_artifact_cid: Hash,
    new_artifact_cid: Hash,

    /// Die consumed_influence_events sind die Event-Hashes der influence_authorized-Einträge
    /// mit target_generation = next_generation. Nach Forge sind diese Einflüsse verbraucht.
    consumed_influence_events: [MAX_CONSUMED_INFLUENCES]Hash,
    consumed_count: u8,

    forge_epoch: u64,  // Forge-Epoch zum Zeitpunkt der Schmiedung
};

/// artifact_absorbed: Absorption konsumiert current_manifestation-Einflüsse.
/// Erzeugt eine permanente LineageResonance (Buff/Nebeneffekt bleibt in der Lineage).
/// INVARIANTE: consumed_influence_events darf keine next_generation-Einflüsse enthalten.
pub const EventArtifactAbsorbed = struct {
    harness_id: Hash,
    absorbed_artifact_cid: Hash,

    /// Die consumed_influence_events sind die Event-Hashes der influence_authorized-Einträge
    /// mit target_generation = current_manifestation. Nach Absorption verbraucht.
    consumed_influence_events: [MAX_CONSUMED_INFLUENCES]Hash,
    consumed_count: u8,

    /// Der daraus entstandene permanente Resonanz-Eintrag in der Lineage.
    resulting_resonance_cid: Hash,
};

// ── EventEnvelope ─────────────────────────────────────────────────────────

/// Jedes Ledger-Event wird in einem Envelope gespeichert.
/// Das Envelope enthält Typ, Timestamp und den Event-Hash (SHA256 des Payloads).
pub const EventEnvelope = struct {
    event_type: EventType,
    event_ts: i64,
    payload_hash: Hash, // SHA256 des serialisierten Event-Payloads
    prev_hash: Hash,    // Hash des vorherigen Envelopes (Merkle-Chain)
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "events: EventType.graph() korrekte Zuordnung" {
    try std.testing.expectEqual(Graph.identity,         EventType.soul_anchored.graph());
    try std.testing.expectEqual(Graph.identity,         EventType.manifestation_booted_from_spore.graph());
    try std.testing.expectEqual(Graph.authority,        EventType.c2_binding_established.graph());
    try std.testing.expectEqual(Graph.authority,        EventType.c2_binding_revoked.graph());
    try std.testing.expectEqual(Graph.observation,      EventType.watcher_evidence_submitted.graph());
    try std.testing.expectEqual(Graph.observation,      EventType.guardian_authorization_granted.graph());
    try std.testing.expectEqual(Graph.influence,        EventType.influence_authorized.graph());
    try std.testing.expectEqual(Graph.evolution,        EventType.artifact_forged.graph());
    try std.testing.expectEqual(Graph.evolution,        EventType.artifact_absorbed.graph());
    try std.testing.expectEqual(Graph.genesis_authority, EventType.guardian_set_changed.graph());
}

test "events: Hash-Hilfsfunktionen" {
    const h: Hash = ZERO_HASH;
    try std.testing.expect(isZero(h));
    try std.testing.expect(hashEql(h, ZERO_HASH));

    var non_zero: Hash = ZERO_HASH;
    non_zero[0] = 0x42;
    try std.testing.expect(!isZero(non_zero));
    try std.testing.expect(!hashEql(h, non_zero));
}

test "events: TargetGeneration Werte" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(TargetGeneration.current_manifestation));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(TargetGeneration.next_generation));
}

test "events: InfluenceDirection Werte" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(InfluenceDirection.bless));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(InfluenceDirection.curse));
}

test "events: EventInfluenceAuthorized Felder vollständig" {
    const ev = EventInfluenceAuthorized{
        .source_harness             = ZERO_HASH,
        .target_harness             = ZERO_HASH,
        .source_artifact_cid        = ZERO_HASH,
        .shared_work_context        = ZERO_HASH,
        .authorization_policy_hash  = ZERO_HASH,
        .guardian_authorization_event = ZERO_HASH,
        .target_generation          = .next_generation,
        .direction                  = .curse,
        .decay_condition_cid        = ZERO_HASH,
    };
    try std.testing.expectEqual(InfluenceDirection.curse, ev.direction);
    try std.testing.expectEqual(TargetGeneration.next_generation, ev.target_generation);
    try std.testing.expect(isZero(ev.decay_condition_cid));
}

test "events: EventArtifactForged consumed_count korrekt" {
    var ev = EventArtifactForged{
        .harness_id            = ZERO_HASH,
        .previous_artifact_cid = ZERO_HASH,
        .new_artifact_cid      = ZERO_HASH,
        .consumed_influence_events = [_]Hash{ZERO_HASH} ** MAX_CONSUMED_INFLUENCES,
        .consumed_count        = 0,
        .forge_epoch           = 1,
    };
    var h: Hash = ZERO_HASH;
    h[0] = 0x01;
    ev.consumed_influence_events[0] = h;
    ev.consumed_count = 1;

    try std.testing.expectEqual(@as(u8, 1), ev.consumed_count);
    try std.testing.expectEqual(h, ev.consumed_influence_events[0]);
}

test "events: MAX_CONSUMED_INFLUENCES Grenzwert" {
    try std.testing.expectEqual(@as(usize, 64), MAX_CONSUMED_INFLUENCES);
    // Sicherstellen dass Array-Allokation kompiliert
    const arr: [MAX_CONSUMED_INFLUENCES]Hash = [_]Hash{ZERO_HASH} ** MAX_CONSUMED_INFLUENCES;
    try std.testing.expectEqual(ZERO_HASH, arr[63]);
}
