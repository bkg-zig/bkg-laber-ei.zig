/// BKG Model Layer — Root-Modul
///
/// Status: PROVEN & FROZEN — 2026-09-01
/// Spec:   docs/MODEL_LAYER_v1.md
///
/// Re-exportiert alle öffentlichen Model-Layer-APIs.
///
/// Modul-Hierarchie (keine Zyklen):
///   hash.zig          — Basis-Primitives (keine Deps)
///   artifact.zig      — Artefakt-Typen (→ hash)
///   manifest.zig      — Serialisierung (→ artifact, hash)
///   lineage.zig       — Lineage-Modell (→ artifact, hash)
///   capability.zig    — Capability-State-Machine (→ artifact, hash)
///   knowledge_snapshot.zig — Snapshot (→ artifact, hash)
///   validator.zig     — Validierungspipeline (→ manifest, lineage, artifact)
///   materializer.zig  — Materialisierungs-Lifecycle (→ validator, capability, lineage)
///   diversity.zig     — Diversity-Layer (→ hash)
///   evolution.zig     — Evolution-Distance + XP (→ hash, diversity)
///
/// BKGDB-Adaptergrenze:
///   ArtifactSource in validator.zig — kein BKGDB-Protokoll im Model Layer.
///   Empfang eines Artefakts bedeutet kein Vertrauen.
///   Jedes Artefakt wird vollständig validiert bevor Aktivierung.
///
/// Sicherheitsinvarianten:
///   - Keine Capability impliziert Authority
///   - Keine Reputation ersetzt Revalidierung
///   - Kein Artefakt wird allein durch BKGDB-Empfang vertrauenswürdig
///   - Kein Node besitzt eine Evolution
///   - Historische Lineages werden niemals überschrieben

pub const hash_mod       = @import("hash.zig");
pub const artifact_mod   = @import("artifact.zig");
pub const manifest_mod   = @import("manifest.zig");
pub const lineage_mod    = @import("lineage.zig");
pub const capability_mod = @import("capability.zig");
pub const snapshot_mod   = @import("knowledge_snapshot.zig");
pub const validator_mod  = @import("validator.zig");
pub const materializer_mod = @import("materializer.zig");
pub const diversity_mod  = @import("diversity.zig");
pub const evolution_mod  = @import("evolution.zig");

// ── Re-Exporte der wichtigsten Typen ─────────────────────────────────────

pub const Hash              = hash_mod.Hash;
pub const Artifact          = artifact_mod.Artifact;
pub const ArtifactKind      = artifact_mod.ArtifactKind;
pub const Lineage           = lineage_mod.Lineage;
pub const CapabilityCache   = capability_mod.CapabilityCache;
pub const CapabilityState   = capability_mod.CapabilityState;
pub const KnowledgeSnapshot = snapshot_mod.KnowledgeSnapshot;
pub const ValidationResult  = validator_mod.ValidationResult;
pub const ConsumerContext   = validator_mod.ConsumerContext;
pub const ArtifactSource    = validator_mod.ArtifactSource;
pub const MaterializedArtifact = materializer_mod.MaterializedArtifact;
pub const UsageEvidence     = materializer_mod.UsageEvidence;
pub const DiversityResult   = diversity_mod.DiversityResult;
pub const DiversityInput    = diversity_mod.DiversityInput;
pub const EvolutionSnapshot = evolution_mod.EvolutionSnapshot;
pub const InbreedingResult  = evolution_mod.InbreedingResult;
pub const XpInput           = evolution_mod.XpInput;
