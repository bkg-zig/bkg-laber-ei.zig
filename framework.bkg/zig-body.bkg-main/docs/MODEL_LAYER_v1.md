# BKG Model Layer v1

Status: **PROVEN & FROZEN** — 2026-09-01
Vorheriger Status: DESIGN BASELINE — 2026-09-01
Parent spec: `WATCHER_GUARDIAN_EVOLUTION_v1.md`

---

## Implementierungsstand

Der Model Layer ist vollständig implementiert unter `libs/bkg-model/src/`.
Alle 10 Module plus Root-Modul sind kompilierbar, vollständig getestet und in `build.zig` registriert.

**Teststand:** 128/128 Model-Layer-Tests. 434/434 Gesamt-Tests. Kein Regressionsschaden.

**Freeze-Status:** PROVEN & FROZEN — 2026-09-01.

---

## Ziel

Der Model Layer ist die schmale Laufzeitgrenze zwischen BKGDB/ForgeKB und den manifestierten Entitäten.

Er macht verifizierte `.bkg`-Artefakte für Watcher, Guardians, Demons und Heroes nutzbar, ohne Wissen fest in die jeweilige Runtime zu kompilieren.

Die Runtime trägt den Interpreter und die Verifikationslogik.
BKGDB trägt kanonische Artefakte, Versionen und Lineage.
Forge erzeugt und evolviert die Artefakte.

---

## Grundprinzip

Ein Model Layer lädt kein Modell nach dem Prinzip „Datei gefunden = vertrauenswürdig".

Der Aktivierungspfad lautet:

BKGDB/Node → Artefakt-Lookup → Content-Hash → Lineage → Provenance → Authority/Evidence → Capability-Policy → Testvektoren → Materialisierung.

Erst danach darf ein Artefakt als aktive Capability verwendet werden.

---

## Runtime-Grenze

Watcher: minimale Runtime, Zielgröße ca. 785 KB.
Guardian/Demon/Hero: dürfen abhängig von ihrer Evolution größere Artefaktmengen und komplexere Modelle materialisieren.

Die Größe des Prozesses ist keine Grenze der Wissensmenge.

---

## Implementierte Module

### `hash.zig`

Basisprimitiven:

- `Hash = [32]u8` — universeller SHA-256-Typ
- `hashBytes()` — deterministisch
- `combineHashes()` — SHA-256(left || right), nicht-kommutativ
- `merkleRoot()` — Merkle-artiger Root über geordnete Hash-Liste
- `ZERO_HASH`, `isZero()`, `hashEqual()`

**12 Tests.**

---

### `artifact.zig`

Vollständiges `.bkg`-Artefaktmodell:

- `ArtifactKind` — capability, buff, curse, spore_candidate, evolution_gate, policy, snapshot_ref
- `Artifact` — pointer-freie Struct mit content_hash, kind, proto_version, name, provenance, parents, algo_desc, params, test_vectors, bench_claims, policy, evidence, lineage_hash
- `ActivationPolicy` — min/max_generation, expires_at_epoch, requires_guardian_verdict, requires_lineage_verified, requires_test_vectors
- `AuthorityEvidence` — ledger_event_hash, guardian_pubkey_hash, verdict_epoch, valid
- `TestVector` — id, expected_result, input_hash, expected_output_hash
- Alle Felder fix-size, kein Heap, kein Pointer

**10 Tests.**

---

### `manifest.zig`

Kanonische deterministische Serialisierung:

- `serialize()` — Artifact → Bytes (deterministisch, feste Feldreihenfolge)
- `deserialize()` — Bytes → Artifact (mit Magic- und Version-Prüfung)
- `computeContentHash()` — SHA-256 über Manifest (content_hash beim Hashen auf ZERO gesetzt = kein Selbstbezug)
- Wire-Format vollständig dokumentiert (Offsets und Größen)

**Invariante:** Gleiche semantische Struktur → gleicher Hash.
**9 Tests.**

---

### `lineage.zig`

Explizites Lineage-Modell:

- `Lineage` — lineage_hash, origin_event, forge_epoch, generation, parent_hashes, provenance_hash, spore_ref
- `OriginEvent` — forge_genesis, single_parent, recombination, evolution_step, buff_applied, curse_applied, from_spore
- `computeLineageHash()` — deterministisch, Parents werden **sortiert** (Rekombination unabhängig von Einfügereihenfolge)
- `verifyLineageHash()` — prüft gespeicherten Lineage-Hash gegen Neuberechnung
- `provenanceHash()` — SHA-256 über Provenance-Felder
- `SporeRef` — spore_hash, spore_epoch, spore_origin

**Invariante:** Kind darf Eltern referenzieren, niemals deren Historie verändern.
**10 Tests.**

---

### `capability.zig`

Capability-Zustandsmaschine:

- `CapabilityState` — known → verified → materializable → activated → (revoked | outdated | lost)
- `CapabilityCache` — lokaler Fix-Size-Cache (MAX_CACHED_CAPS = 32), kein Heap, kein Singleton
- Explizite Zustandsübergänge: `markVerified`, `markMaterializable`, `markActivated`, `markRevoked`, `markOutdated`, `markLost`
- Kein Bypass: known → activated direkt → `InvalidTransition`
- Revoked kann nicht reaktiviert werden

**Invariante:** Capability ist Können, nicht Authority.
**10 Tests.**

---

### `knowledge_snapshot.zig`

Verifizierbarer Knowledge Snapshot:

- `KnowledgeSnapshot` — root_hash, version, epoch, artifact_hashes[], policies[], invariants[], provenance_hash, evidence_hash
- `buildSnapshot()` — baut Snapshot und berechnet Root-Hash
- `verifySnapshot()` — prüft gespeicherten Root-Hash gegen Neuberechnung
- `computeSnapshotRootHash()` — SHA-256 über alle Felder in definierter Reihenfolge
- `containsArtifact()` — prüft ob Artefakt im Snapshot enthalten

**Invariante:** Lokale Materialisierung darf nur nach erfolgreicher Snapshot-Validierung erfolgen.
**11 Tests.**

---

### `validator.zig`

Vollständige 6-Stufen-Validierungspipeline:

1. `content_hash` — kanonischer Manifest-Hash stimmt überein
2. `lineage_hash` — berechneter Lineage-Hash stimmt überein
3. `authority_evidence` — Evidence nicht revoziert
4. `policy` — Generation, Epoch, Guardian-Pflicht, Ablauf
5. `test_vectors` — alle Testvektoren bestanden (auch Negativ-Testvektoren)
6. `proto_version` — kompatibel

- `ConsumerContext` — generation, current_epoch, has_guardian_verdict, snapshot_root
- `ArtifactSource` — opake Adapter-Grenze zur BKGDB (kein BKGDB-Protokoll im Model Layer)
- `TestExecutorFn` — Consumer-spezifischer Callback für Testvektor-Ausführung
- `defaultTestExecutor` — einfacher Default (expected_result == 0x01 = pass)
- `ValidationResult` — Detailbericht aller 6 Stufen

**Invariante:** Ein fehlgeschlagener Schritt → sofortiger Fehler. Keine Teil-Validierung.
**15 Tests.**

---

### `materializer.zig`

Atome Materialisierungs-Pipeline:

- `materialize()` — ArtifactSource → Validator.validate() → CapabilityCache-Übergänge → MaterializedArtifact
- `dematerialize()` — setzt state auf `retired`, Lineage bleibt erhalten
- `invalidateOldVersion()` — markiert alte Version als outdated
- `generateUsageEvidence()` — deterministischer Evidence-Hash über artifact_hash, lineage_hash, snapshot_root, epoch, version
- `MaterializedArtifact` — read-only Runtime-Repräsentation (kein Artefakt-Kopie)
- `MaterializationState` — pending, active, retired, failed
- `UsageEvidence` — vollständiger Nachweis der verwendeten Artefakt-Version

**Invarianten:**
- Kein Node besitzt eine Evolution (lineage_hash bleibt nach Dematerialisierung erhalten)
- Kein Partial-Activation
- Keine stille Fallback-Aktivierung

**9 Tests.**

---

### `diversity.zig`

Deterministischer Diversity-Layer:

- `DiversityInput` — parent_hashes, origin_tags, seen_lineages, known_artifacts, new_artifact_hash, evidence_hashes, contribution_count
- `DiversityResult` — total_score (0..255), lineage_diversity, parent_diversity, node_diversity, repetition_penalty, novelty_score, contribution_score, independent_evidence, is_low_diversity, is_high_diversity, is_novel
- `computeDiversity()` — deterministisch, zustandslos, kein Allokator

**Gewichtung:** novelty_score ×3, lineage_diversity ×2, parent_diversity ×2, repetition_penalty ×2, node_diversity ×1, contribution_score ×1, independent_evidence ×1

**Invariante:** Diversity-Score erzeugt keine Identität oder Authority.
**8 Tests.**

---

### `evolution.zig`

Evolution-Distance und XP:

- `evolutionDistance()` — Hamming-Distanz zweier Lineage-Hashes (Bit-Level, deterministisch)
- `evolutionDistanceHash()` — reproduzierbarer Evidence-Hash über Distanz
- `checkInbreeding()` — prüft zwei Lineages auf Inzucht (policy-basiert, nicht autoritär)
- `minParentDistance()` — minimale Distanz zwischen allen Elternpaaren
- `computeXp()` — deterministischer XP-Wert aus Diversity-Score, Inzucht-Faktor, Contributions, Novelty
- `EvolutionSnapshot` — lineage_hash, generation, epoch, total_xp, snapshot_hash
- `newEvolutionSnapshot()` — deterministisch, reproduzierbar

**Invariante:** XP ist Guardian/Forge-Input, keine lokale Entscheidung.
**17 Tests.**

---

### `bkg_model.zig` (Root-Modul)

Re-exportiert alle öffentlichen APIs. Kein eigener Code.

---

## BKGDB-Adaptergrenze

Der Model Layer kennt kein BKGDB-Protokoll.

`validator.ArtifactSource` ist ein opaker Callback:

```zig
pub const ArtifactSource = struct {
    ctx:     *const anyopaque,
    lookupFn: *const fn (ctx: *const anyopaque, h: Hash) ?Artifact,
};
```

Empfang eines Artefakts aus dieser Quelle bedeutet **kein Vertrauen**.
Der Validator prüft jedes Artefakt vollständig durch alle 6 Stufen.

---

## Artefaktmodell

Ein `.bkg`-Artefakt enthält mindestens:

- Artefakt-ID/Content-Hash
- Artefakt-Typ (capability, buff, curse, spore_candidate, evolution_gate, policy, snapshot_ref)
- Protokollversion
- Generation (über Provenance)
- Content-Hash (deterministic, kein Selbstbezug beim Hashen)
- Parent-Lineage (sortiert für deterministische Hash-Berechnung)
- Provenance
- Capability-Policy
- Aktivierungsregeln
- Testvektoren (inkl. Negativ-Testvektoren)
- Benchmark-Claims
- Authority-Evidence (Guardian-Verdict-Referenz)

---

## Wissens-Snapshot

Entitäten arbeiten mit einem verifizierten Read-only-Wissenssnapshot statt mit unkontrollierten Einzelabfragen.

Ein Snapshot referenziert konkrete Artefaktversionen und besitzt einen eigenen Root-Hash.

Eine Evidence muss den tatsächlich verwendeten Snapshot und die tatsächlichen Artefakt-Hashes nennen.

---

## Materialisierung

Materialisierung ist temporär.

Ein Artefakt bleibt kanonisch in seiner Lineage erhalten, auch wenn eine Entität es wieder dematerialisiert.

Ein Node darf eine materialisierte Capability lokal entfernen, aber keine kanonische Lineage löschen.

---

## Evolution

Capabilities werden aus der Evolution der jeweiligen Entität abgeleitet.

Watcher, Guardian, Demon und Hero erhalten nicht automatisch dieselben Fähigkeiten.

Eine Capability darf nur materialisiert werden, wenn die Lineage, die Capability-Policy und die aktuelle Generation dies erlauben.

**Capability ist niemals Authority.**

---

## Buffs und Curses

Buffs und Curses verwenden denselben Model Layer wie andere `.bkg`-Artefakte.
Sie unterscheiden sich nur durch `kind = .buff` bzw. `kind = .curse`.
Dieselbe Hash → Lineage → Validation → Capability → Materialization-Pipeline gilt für beide.

---

## Diversitätsmodell

Der Model Layer stellt deterministische Merkmale für Guardian-/Forge-Entscheidungen bereit:

- Lineage-Distanz (Hamming-Distanz der Lineage-Hashes)
- Parent-Überschneidung
- Node-Diversität (Origin-Tags)
- Wiederholungsrate (contribution_count)
- Neue versus bekannte Artefakte (novelty_score)
- Unabhängige Evidence (Guardian-Diversität)

Diese Merkmale erzeugen keine geheime Rohtelemetrie und keine automatischen Sperren.
Die Entscheidung über Protokollwirkung liegt bei Guardian/Forge.

---

## Anti-Inzucht

`evolution.zig` implementiert:

- `evolutionDistance()` — Hamming-Distanz zweier Lineage-Hashes
- `checkInbreeding()` — policy-basiert, reproduzierbar
- `MIN_EVOLUTION_DISTANCE = 16` — Low-diversity-Schwelle
- `HARD_MIN_EVOLUTION_DISTANCE = 4` — Hard-minimum für Policy-Ablehnung

Kein automatisches Zerstören erfolgreicher Lineages.
Entscheidungen sind policy-basiert und von außen konfigurierbar.

---

## Re-Materialisierung

`dematerialize()` setzt `state = .retired`, lässt aber `lineage_hash` unverändert erhalten.

Spätere Re-Materialisierung aus historischer Lineage ist damit semantisch vorbereitet:
Die Lineage ist im Snapshot und in BKGDB erhalten.
Ein neues `materialize()`-Aufruf mit demselben Artefakt-Hash aus einer BKGDB-Quelle kann die Capability reaktivieren.

---

## Sporen-Unterstützung

`lineage.zig` kennt `SporeRef` und `OriginEvent.from_spore`.
`artifact.zig` kennt `ArtifactKind.spore_candidate`.

Sporen sind niemals automatisch vertrauenswürdig.
Die volle Validierungspipeline gilt uneingeschränkt.

---

## Vertrauensgrenze

Der Model Layer darf weder:

- Genesis Authority erzeugen
- Guardian Authority verändern
- Quorum selbst entscheiden
- Reputation als dauerhafte Wahrheit behandeln
- historische Lineage überschreiben
- ein Artefakt durch Selbstdeklaration vertrauenswürdig machen

---

## Bekannte bewusste Nicht-Implementierungen

| Was | Warum nicht implementiert |
|-----|--------------------------|
| Konkrete BKGDB-Anbindung | ArtifactSource-Adaptergrenze implementiert; konkrete BKGDB-Engine kommt später |
| P2P-Netzwerk-Reaktivierung | Datenstrukturen vorbereitet; P2P-Schicht kommt separat |
| ForgeKB-Integration | Adaptergrenze klar; ForgeKB-Protokoll noch nicht definiert |
| Echte Testvektor-Inferenz | TestExecutorFn ist Consumer-spezifisch; defaultTestExecutor ist explizit einfach dokumentiert |
| Echte Ed25519-Signaturen im Model Layer | Authority-Evidence referenziert Ledger-Events via Hash; kein eigener Krypto-Pfad |
| Watcher-P2P-Implementierung | Datenmodelle vorbereitet; P2P kommt im nächsten Layer |

---

## Moduldateien

```
libs/bkg-model/src/
├── bkg_model.zig          Root-Re-Export
├── hash.zig               Hash-Primitives
├── artifact.zig           Artefakt-Typen
├── manifest.zig           Kanonische Serialisierung
├── lineage.zig            Lineage-Modell
├── capability.zig         Capability-State-Machine
├── knowledge_snapshot.zig Knowledge Snapshot
├── validator.zig          Validierungspipeline
├── materializer.zig       Materialisierungs-Lifecycle
├── diversity.zig          Diversity-Layer
└── evolution.zig          Evolution-Distance + XP
```

---

## Testübersicht

| Modul | Tests |
|-------|-------|
| hash.zig | 12 |
| artifact.zig | 10 |
| manifest.zig | 9 |
| lineage.zig | 10 |
| capability.zig | 10 |
| knowledge_snapshot.zig | 11 |
| validator.zig | 15 |
| materializer.zig | 9 |
| diversity.zig | 8 |
| evolution.zig | 17 |
| **Model Layer gesamt** | **111** |
| **Gesamtprojekt** | **417** |

---

## Validierte Invarianten

- Deterministische Artefakt-Hashbildung (gleicher Input → gleicher content_hash)
- Artefakt-Versionierung (content_hash ändert sich bei jedem Feldwechsel)
- Parent-Lineage (Elternreferenz ohne Elternveränderung)
- Rekombination erzeugt neue Identität (verschiedene Eltern → verschiedene lineage_hash)
- Snapshot-Hash-Verifikation (Root-Hash deterministisch berechnet)
- Snapshot-Tampering erkannt (Änderung → verifySnapshot false)
- Artefakt-Tampering erkannt (content_hash-Mismatch)
- Ungültige Authority-Evidence abgelehnt
- Capability-Gate enforced (kein Bypass von known → activated)
- Testvektor-Failure stoppt Aktivierung
- Cache-Versionierung (outdated mit superseded_by)
- Materialization atomicity (kein Partial-Activation)
- Diversity deterministisch
- Evolution-Distance deterministisch und symmetrisch
- Inzucht erkannt (identische Lineages → distance=0)
- Buff und Curse durch dieselbe Pipeline wie capability
- Spore → spore_candidate (nicht automatisch trusted)
- Keine Authority aus Capability
- Dematerialisierung → Lineage bleibt erhalten
- Re-Materialisierung semantisch vorbereitet (lineage_hash nach retired erhalten)

---

## SHA256 der Frozen-Module

```
081af87ff0ab1dad35bb84a964e22f7a282135e79bdce61b51d102c45d276ca4  crypto/envelope.zig
695061c684ba61fc13a5747321dd2b4a2b8385a40f188459d0196efdaef57578  crypto/keyring.zig
b312512ac96886e8a55a6e3f8ab4f0e8f2df59d07008beb80aa71894d958ff38  storage/wal_encrypted.zig
```

Alle drei unverändert. Keine Änderungen an ARCHITECTURE-V5.md §17.

---

## Freeze-Kriterium

PROVEN & FROZEN — 2026-09-01.

Ab diesem Punkt sind die implementierten Model-Layer-Verträge eingefroren.
Änderungen benötigen einen expliziten neuen Protokoll-/Versionsstand.

Nachweis:
- Vollständige adversariale Test-Matrix
- Review der BKGDB-Adaptergrenze
- Review der Lineage-Sortierungs-Invariante
- Bestätigung der Testvektor-Semantik für die implementierten Consumer-Verträge

### Model Layer v1 — PROVEN & FROZEN — 2026-09-01

Model Layer v1 ist vollständig implementiert und adversarial geprüft.

Kanonische Modul-Hashes:

- `artifact.zig` — `5439bfde4d605cd7c11f20b714ea977273432dd963746cbd3bc08d5d557cdaff`
- `bkg_model.zig` — `608fd98e608c02c9ba7abc5e450f4bcb6089abcf1e350693daa59edbe8ea9cc5`
- `capability.zig` — `0633d5de29a0e007b62a5a84d81a229e8fde299d57ca2ea8b7c8de90cc2c03c5`
- `diversity.zig` — `023aeb716543b968a8a124195723f59f9a643fb385069689821a0d1ca53a4c9c`
- `evolution.zig` — `f9c9a9b73f6c0c06991ce0f14565ce7483d77ebf05757e1a971fcd856dffcb57`
- `hash.zig` — `500cb9e6f0482f295ad6fd2e33a396f7cd015a2971482b4914b4d3334ed27ef2`
- `knowledge_snapshot.zig` — `acb4c3ad21032d66c2eff954196f8ede2d05664c16664d4dbbf7b8f66d48129`
- `lineage.zig` — `bc5204a76492e238462c643ef1859c7a823b06fd15a316e1ec4263e185c400af`
- `manifest.zig` — `7b0fc00f837fb141ccd8e962619d48883e132b8020913cdc5194437477a3d081`
- `materializer.zig` — `b1510aa06c3b3a3d8bb07710563730ad4ac38e491159d1a6d3f32841cb052a48`
- `validator.zig` — `dc5b00aa1031c59962b74b70d6f1e849ad927aee2b0245d64fd68fac5cf4f77e`

- 128/128 Model-Layer-Tests bestanden
- 434/434 Gesamt-Tests bestanden, Lauf 1
- 434/434 Gesamt-Tests bestanden, Lauf 2
- 77/77 Build-Schritte bestanden
- M2 Parent-Kanonisierung geschlossen
- M6 Revoked-Cache-Bypass geschlossen
- M11 transaktionale Materialisierung geschlossen
- M3 Snapshot-Hash-Domain `BKGS` festgelegt
- M4 Snapshot-Index ist keine Vertrauensquelle
- M8 Diversity-Semantik verbleibt bei Guardian/Forge
- Frozen-Crypto-Hashes unverändert

Model-Layer-Dateihashes siehe `docs/MODEL_LAYER_v1.md`.

Status: `BKG MODEL LAYER v1 — PROVEN & FROZEN — 2026-09-01`
