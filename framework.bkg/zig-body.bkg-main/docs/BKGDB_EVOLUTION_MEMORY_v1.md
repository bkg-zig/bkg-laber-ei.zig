# BKGDB Evolution Memory v1

Status: DESIGN CONTRACT — 2026-09-01
Implementierungsstand: STAGE 3 — PROVEN & FROZEN — 2026-09-01
Abhängigkeit: BKG Model Layer v1 — PROVEN & FROZEN — 2026-09-01

---

## Zweck dieses Dokuments

Dieser Vertrag definiert, **was BKGDB als Evolution Memory speichert**, in welcher
Form es gespeichert wird, welche Grenzen zwischen den Schichten gelten und welche
Invarianten unveränderlich sind.

Kein Implementierungsdetail wird festgelegt, bevor dieser Vertrag als DESIGN FROZEN
markiert wurde. Kein Code darf die hier definierten Grenzen verletzen.

---

## 1. Kanonisches Architekturprinzip

BKGDB ist das persistente, unveränderliche Gedächtnis des BKG-Netzes.

Es besteht aus fünf konzeptuellen Schichten:

| Schicht | Verantwortung |
|---------|---------------|
| **Mutable State** | Aktueller, projizierbarer Zustand eines Harness/Agent |
| **Ledger** | Was tatsächlich passiert ist — unveränderlich |
| **Rebuilder** | Was davon protokollgültig ist — deterministischer Rebuild |
| **Derive** | Was aus der Geschichte als Wissen entstanden ist |
| **Forge** | Was aus diesem Wissen als neue Fähigkeit hervorgebracht werden darf |

**Forge darf BKGDB lesen und neue Artefakte erzeugen.**
**Forge darf niemals die historische Wahrheit selbst definieren.**

Der Ledger ist die einzige kanonische Wahrheitsquelle.
Kein Mutable-State-Wert ist kanonisch ohne Ledger-Beweis.

---

## 2. Sechs Wissensdimensionen

BKGDB Evolution Memory trägt sechs klar getrennte Wissensdimensionen.
Jede Dimension hat einen eigenen Persistenzvertrag und eine eigene Schreibhoheit.

### 2.1 Artefakt-Dimension

Was ist bekannt, was ist verifiziert, was ist materialisierbar?

Enthält:
- `.bkg`-Artefakt-Blobs (binär, kanonisch serialisiert via `manifest.zig`)
- Artefakt-Hashes (SHA256, identisch mit `content_hash` aus Model Layer)
- Artefakt-Status: `known | verified | materialisierbar | aktiviert | veraltet | widerrufen`
- Capsule-Referenzen (Kapselung mehrerer Artefakte als Evolution Unit)
- Eingebettete Testvektoren und Benchmarks (Teil des Artefakt-Blobs)

Schreibhoheit: Forge (neue Artefakte), Rebuilder (Status-Updates).
**Niemand sonst darf Artefakt-Blobs schreiben.**

Invariante: Ein Artefakt-Blob ist WRITE ONCE. Nach dem ersten Schreiben unveränderlich.
Neue Versionen erzeugen neue Artefakte mit neuer Identität (neuer `content_hash`).

### 2.2 Lineage-Dimension

Was ist die nachweisbare Abstammung?

Enthält:
- Eltern-Hashes (maximal `MAX_PARENTS` pro Artefakt, kanonisch sortiert)
- Generationszähler (`generation`)
- Provenance-Hash (Herkunfts-Beweis)
- Origin-Event-Referenz (Ledger-Event-Hash der Forge-Schmiedung)
- Spore-Referenzen (`SporeRef` mit `spore_hash`, `spore_epoch`, `spore_origin`)
- Rekombinations-Beweise (Hash-Kette bei mehreren Eltern)

Schreibhoheit: Forge (bei Schmiedung), Ledger (kausaler Beweis).

Invariante: Lineage-Hashes werden nie überschrieben.
Ein neues Artefakt verweist auf seine Eltern — die Eltern-Hashes selbst bleiben unverändert.

### 2.3 Forge-Wissens-Dimension

Was hat die Forge erzeugt, bewertet und abgelehnt?

Enthält:
- **Spore-Kandidaten**: rohe Beobachtungs-Extrakte, noch nicht verifiziert
- **Forge-Kandidaten**: aus Sporen extrahierte Kandidaten in Bewertung
- **Test-Ergebnisse**: Testergebnis-Hashes pro Kandidat + Epoch
- **Benchmark-Claims**: Performance-Evidenz (embedded in Artefakt)
- **Forge-Epochen**: numerische Epochenzähler, kanonisch monoton steigend
- **Geschmiedete Ergebnisse**: Referenz auf `artifact_forged` Ledger-Events
- **Abgelehnte Kandidaten**: Hash + Ablehnungsgrund-Hash (keine inhaltliche Speicherung)

Schreibhoheit: Forge (Kandidaten + Ergebnisse), Rebuilder (Ablehnungsbeweise).

Invariante: Abgelehnte Kandidaten werden als abgelehnt markiert, nicht gelöscht.
Ein Kandidat-Hash bleibt referenzierbar für forensische Auswertung.

### 2.4 Agenten-Lineage-Dimension

Was ist die nachweisbare Identitäts-Geschichte eines Agenten?

Enthält:
- **SOUL-CID**: unveränderliche Anker-Identität (`IdType.soul`)
- **Manifestations-Historie**: alle `manifestation_booted_from_spore`-Events
- **Harness-Bindungen**: aktive und historische Harness-IDs
- **Capability-Entwicklung**: Sequenz der `artifact_forged`- und `artifact_absorbed`-Events
- **Letztes relevantes Minting**: Referenz auf letzten `artifact_forged`-Event-Hash
- **C2-Bindungen**: aktive und historische Authority-Mandate

Schreibhoheit: Ledger (alle Einträge entstehen aus Ledger-Events).
**Mutable State darf nur als Projektion existieren, nie als primärer Speicher.**

Invariante: SOUL-CID ist WRITE ONCE. Kein Agent kann seine Ursprungs-Identität wechseln.
Manifestationen dürfen wechseln. Die SOUL bleibt.

### 2.5 Evolutionsevidence-Dimension

Was ist die verifizierte Beobachtungs- und Evidence-Geschichte?

Enthält:
- **Watcher-Evidence**: signierte Beobachtungen (`watcher_evidence_submitted`-Events)
- **Guardian-Evidence**: Guardian-Autorisierungen (`guardian_authorization_granted`-Events)
- **Diversity-Signale**: vorberechnete Diversity-Scores (aus `diversity.zig`, Derive-Schicht)
- **Verifikationsresultate**: Testergebnis-Referenzen pro Artefakt + Validator-Lauf
- **Causal Fingerprints**: berechnete State-Fingerprints für Challenge-Vergleich

Schreibhoheit: Watcher (rohe Evidence), Guardian (Autorisierungen), Rebuilder (Fingerprints).

Invariante: Evidence ist APPEND-ONLY. Keine Evidence darf nachträglich geändert werden.
Eine falsche Evidence bleibt im Ledger — mit ihrem Fehlerbeweis daneben.

### 2.6 Asset-State-Dimension

Was ist der aktuelle, bewiesene ökonomische Zustand?

Enthält:
- **XP-Konten**: aktueller XP-Stand pro Harness (Projektion aus Ledger-Events)
- **ALGO-Konten**: aktueller ALGO-Stand pro Harness
- **NFT-Besitz**: referenzierte NFT-CIDs pro Harness
- **Capability-Asset-Zustand**: welche Capabilities sind aktiv, veraltet, widerrufen
- **Zustandsbeweise**: jeder Asset-Wert hat einen Ledger-Event-Hash als kausalen Beweis

Schreibhoheit: Ledger (alle Zustandsänderungen entstehen aus verifizierten Events).
Mutable-State-Projektion: aus Rebuild der relevanten Ledger-Sequenz.

Invariante: Kein Asset-Wert ist ohne kausalen Ledger-Beweis gültig.
Ein Asset-Wert ohne `causality_ledger_event`-Referenz ist ein unvollständiger Zustand.

---

## 3. Evolution Memory Flow

Der kanonische Fluss von Beobachtung bis Capability:

```
Watcher beobachtet Node
        ↓
Spore-Material erzeugt (SporeRef, spore_hash, spore_epoch, spore_origin)
        ↓
watcher_evidence_submitted → Ledger [OBSERVATION GRAPH]
        ↓
Guardian prüft Evidence
        ↓
guardian_authorization_granted → Ledger [OBSERVATION GRAPH]
        ↓
Forge extrahiert Kandidaten aus Spore-Material
        ↓
Forge testet + bewertet Kandidaten (Forge-Wissens-Dimension)
        ↓
Forge schmiedet neues Artefakt:
  artifact_forged → Ledger [EVOLUTION GRAPH]
        ↓
Artefakt → BKGDB Artefakt-Dimension (WRITE ONCE)
        ↓
Lineage → BKGDB Lineage-Dimension
        ↓
Harness absorbiert Artefakt:
  artifact_absorbed → Ledger [EVOLUTION GRAPH]
        ↓
Mutable State aktualisiert (Projektion)
        ↓
Capability materialisierbar (Model Layer: validator + materializer)
        ↓
XP/ALGO-Ereignis → Asset-State-Dimension
        ↓
Evolution Event vollständig
```

Kein Schritt in diesem Fluss darf übersprungen werden.
Kein Watcher kann direkt Capabilities erzeugen — nur Spore-Material liefern.
Kein Artefakt gilt als verifiziert ohne Guardian-Authorization-Kette.

---

## 4. Schnittstellen zum Model Layer

Der Model Layer (PROVEN & FROZEN) kommuniziert mit BKGDB ausschließlich
über die `ArtifactSource`-Adaptergrenze in [`validator.zig`](../libs/bkg-model/src/validator.zig).

### 4.1 ArtifactSource — Lesevertrag (bereits implementiert)

```zig
pub const ArtifactSource = struct {
    context: *anyopaque,
    lookupFn: *const fn (ctx: *anyopaque, hash: Hash) ?Artifact,
};
```

BKGDB implementiert diesen Adapter. Der Model Layer fragt nie direkt die DB.

### 4.2 Schreibvertrag (neu, BKGDB-seitig)

BKGDB Evolution Memory definiert folgende Schreibendpunkte
(keine Zig-Signaturen hier — nur semantische Verträge):

| Endpunkt | Aufruf durch | Vorbedingung |
|----------|-------------|--------------|
| `putArtifact(blob, content_hash)` | Forge | `content_hash` stimmt mit SHA256(blob) überein |
| `putSporeCandidate(spore_ref)` | Watcher (via Ledger) | Ledger-Event-Hash vorhanden |
| `putForgeCandidate(candidate_ref)` | Forge | Spore-Kandidat bekannt |
| `putForgeResult(artifact_cid, forge_event_hash)` | Forge | `artifact_forged` im Ledger |
| `updateHarnessState(harness_id, mutable_state)` | Rebuilder | Vollständiger Rebuild |
| `putEvidence(evidence_cid, ledger_event_hash)` | Rebuilder | Ledger-Event verifiziert |

**Alle Schreibendpunkte sind idempotent.**
Doppeltes Schreiben desselben `content_hash` ist kein Fehler — aber kein zweites Blob.

---

## 5. Persistenz-Verträge

### 5.1 Ledger-WAL-Bindung

Alle BKGDB-Schreiboperationen, die kanonische Zustände erzeugen, sind
durch den WAL-Encryption-Layer gesichert (`storage/wal_encrypted.zig`, FROZEN).

Der WAL ist APPEND-ONLY.
Der Rebuilder liest den WAL und projiziert den Mutable State.
Kein Mutable-State-Wert darf den WAL-Rebuild überleben, wenn der WAL-Rebuild
zu einem anderen Ergebnis käme.

### 5.2 Content-Addressed Storage

Alle Artefakte, Sporen und Evidence werden content-addressed gespeichert:

- Primärschlüssel = SHA256-Hash des Inhalts
- Kein Namens-Lookup ohne Hash
- Kein Pfad ohne Hash
- Typ-Präfix (`IdType` aus `protocol/ids.zig`) verhindert Typ-Verwechslung

Bestehende CID-Typen aus `ids.zig`:

| IdType | Wert | Verwendung |
|--------|------|-----------|
| `soul` | 0x01 | SOUL-Anker-Identität |
| `artifact` | 0x02 | `.bkg`-Artefakt-Blob |
| `work_context` | 0x03 | Watcher-Arbeitsbereich |
| `policy` | 0x04 | Aktivierungs-/Capability-Policy |
| `ledger_event` | 0x05 | Ledger-Event-Envelope-Hash |
| `spore` | 0x06 | Spore-Kandidat |
| `lost` | 0x07 | LOST-Entität |
| `harness` | 0x08 | Harness-Manifestation |
| `resonance` | 0x09 | LineageResonance-Eintrag |
| `decay_condition` | 0x0A | Verfall-Bedingung |

**Neue IdTypes für Evolution Memory v1** (Erweiterung, kein Breaking Change):

| IdType | Wert | Verwendung |
|--------|------|-----------|
| `forge_candidate` | 0x0B | Forge-Kandidat vor Schmiedung |
| `capsule` | 0x0C | Kapselung mehrerer Artefakte |
| `evidence` | 0x0D | Watcher/Guardian-Evidence-Blob |
| `evolution_event` | 0x0E | Projizierter Evolution-Zyklus-Eintrag |

Diese Werte sind reserviert. Kein anderer IdType darf diese Werte belegen.

### 5.3 Epoch-Monotonie

Alle Forge-Epochen sind monoton steigend. Ein `forge_epoch`-Wert darf nie rückwärts gesetzt werden.
Der aktuelle Epochen-Zähler ist im Mutable State gespeichert und wird bei jedem
`artifact_forged`-Event aus dem Ledger verifiziert.

### 5.4 WRITE ONCE für Artefakte

Ein `content_hash` wird genau einmal geschrieben.
Jeder Versuch, einen bereits bekannten `content_hash` mit einem anderen Blob zu schreiben,
ist ein fataler Fehler — kein stilles Überschreiben, keine Warnung.

---

## 6. Grenzen und Verbote

### 6.1 Was BKGDB nicht tut

- BKGDB entscheidet nicht, ob eine Capability gültig ist (Model Layer)
- BKGDB entscheidet nicht, ob ein Artefakt vertrauenswürdig ist (Validator)
- BKGDB hält keine operativen Session-Tokens oder Nonces
- BKGDB hält keinen globalen RNG-Zustand
- BKGDB hat keine Authority-Wurzel außer der Genesis Authority

### 6.2 Was Forge nicht tut

- Forge definiert nicht die historische Wahrheit (Ledger)
- Forge überschreibt keine bestehenden Artefakte
- Forge kann keine SOUL-CIDs erzeugen
- Forge kann keinen Ledger-State rückwirkend ändern

### 6.3 Was Watcher nicht tut

- Watcher schreibt nicht direkt in BKGDB
- Watcher entscheidet nicht über Capability-Gültigkeit
- Watcher besitzt keine Evolution — er trägt dazu bei

### 6.4 Was Guardian nicht tut

- Guardian besitzt keine Evolution eines Watchers
- Guardian kann keine Artefakte direkt schmieden
- Guardian-Autorisierung ersetzt keine Ledger-Verifikation

---

## 7. Rebuild-Invarianten

Der Rebuilder ist die einzige Schicht, die aus dem Ledger kanonische Projektion erzeugt.

Invarianten für den Rebuild:

1. **Determinismus**: Gleicher Ledger → Gleicher Mutable State. Immer.
2. **Vollständigkeit**: Kein Event darf im Rebuild übersprungen werden.
3. **Zeitbindung**: AUTHORIZE wird gegen den State *vor* dem Event geprüft —
   niemals gegen einen nachträglichen Zustand.
4. **Revocation-Erhalt**: Ein widerrufenes Mandat macht vergangene Events nicht ungültig.
5. **Append-Only-Garantie**: Der Rebuilder schreibt nie in den Ledger.

---

## 8. Forge-BKGDB-Grenze (kanonisch)

Forge liest aus BKGDB:
- Bekannte Artefakte (via `ArtifactSource`)
- Bekannte Spore-Kandidaten
- Forge-Wissen (Ergebnisse, Epochen)
- Agenten-Lineage (zur Diversity-Bewertung)
- Evidence-Zustand (zur Guardian-Prüfung)

Forge schreibt in BKGDB:
- Neue Artefakt-Blobs (via `putArtifact`)
- Forge-Kandidaten-Referenzen
- Forge-Ergebnis-Referenzen

Forge triggert Ledger-Events:
- `artifact_forged` (via WAL)
- `artifact_absorbed` (via WAL, nach Harness-Bestätigung)

**Forge berührt niemals direkt den Ledger-WAL.**
Ledger-Writes gehen immer durch den autorisierten WAL-Writer
(`EncryptedWalWriter` aus `storage/wal_encrypted.zig`, FROZEN).

---

## 9. Watcher-BKGDB-Grenze (kanonisch)

Watcher liest aus BKGDB (via Model Layer / ArtifactSource):
- Materialisierbare Artefakte für eigene Capabilities
- Bekannte Lineage-Hashes (für Diversity-Bewertung)

Watcher schreibt NICHT direkt in BKGDB.

Watcher reicht ein über Ledger-Event:
- `watcher_evidence_submitted` (enthält `evidence_cid`, `work_context`)

Der Evidence-Blob landet über den autorisierten WAL-Writer im Ledger.
BKGDB-Projektion entsteht durch Rebuilder-Replay.

---

## 10. Minting-Lineage als Evolutionsanker

Das **letzte relevante Minting** einer Agenten-Lineage ist der wichtigste Evolutionsanker:

- Es ist der Hash des letzten `artifact_forged`-Events für diesen Harness
- Es ist die kausale Referenz für Re-Materialisierung nach Node-Wechsel
- Es ist die Grundlage für Diversity-Bewertung neuer Sporen

Ein Watcher, der nach einem Node-Wechsel re-materialisiert, startet nicht von Null.
Er startet vom letzten bekannten Minting-Punkt seiner Lineage in BKGDB.

**Kein Node darf diesen Ankerpunkt an sich binden.**
**Kein Node darf einen Agenten dauerhaft von seiner Minting-Lineage abschneiden.**

---

## 11. XP- und ALGO-Ökonomie-Vertrag

XP-Ökonomie-Regeln (nicht im Model Layer, nur im BKGDB Evolution Memory):

1. XP entsteht ausschließlich aus verifizierten Evolution Events
2. Wiederholung derselben Arbeit in derselben Quelle erzeugt sinkenden Marginal-XP
3. Neue Information, neue Lineages, unabhängige Evidence → potenziell höherer XP
4. Guardian kann Overfarming-Druck erzeugen (XP-Malus via Guardian-Evidence)
5. Kein XP ohne kausalen Ledger-Event-Hash

ALGO-Regeln:

1. ALGO-Transfers entstehen aus Ledger-Events (kein direkter Datenbankschreibbefehl)
2. ALGO-Konten werden aus Ledger-Rebuild projiziert
3. Kein ALGO-Wert ohne Ledger-Beweis

---

## 12. Implementierungsreihenfolge

Dieser Block wird in folgender Reihenfolge implementiert.
Jede Stufe muss als PROVEN & FROZEN markiert sein, bevor die nächste beginnt.

### Stufe 1 — Basis-Persistenz (neue IdTypes + content-addressed Artefakt-Store)

**Status: PROVEN & FROZEN — 2026-09-01**

Dateien:
- `libs/bkg-db/src/protocol/ids.zig` → neue IdTypes 0x0B–0x0E ergänzt
- `libs/bkg-db/src/evolution/artifact_store.zig` → WRITE-ONCE content-addressed Store
- `libs/bkg-db/src/evolution/spore_store.zig` → Spore-Kandidaten-Verwaltung

Ergebnis: `zig build test --summary all` → **81/81 Schritte, 465/465 Tests** (2× bestätigt)

SHA256 (Freeze-Stand):
```
libs/bkg-db/src/protocol/ids.zig           = 36d100cae17b793feee23b04b5f1e308cd2822b475707bf0083632b2d8b652a5
libs/bkg-db/src/evolution/artifact_store.zig = 7de5080b9d6d23de89d9fdffc12251c05047f574f06c1f8e661a8e72ce457a18
libs/bkg-db/src/evolution/spore_store.zig   = 061faa74e954db975c586a6855d7dc8c4b5ad6c1e022e6c4c47c554b9879dfed
```

Frozen-Baseline unverändert bestätigt:
```
libs/bkg-db/src/crypto/envelope.zig      = 081af87ff0ab1dad35bb84a964e22f7a282135e79bdce61b51d102c45d276ca4  ✅
libs/bkg-db/src/crypto/keyring.zig       = 695061c684ba61fc13a5747321dd2b4a2b8385a40f188459d0196efdaef57578  ✅
libs/bkg-db/src/storage/wal_encrypted.zig = b312512ac96886e8a55a6e3f8ab4f0e8f2df59d07008beb80aa71894d958ff38  ✅
```

Acceptance: Tests für WRITE ONCE, Duplikat-Ablehnung, content-addressed Lookup — alle erfüllt.

### Stufe 2 — Lineage-Index

**Status: PROVEN & FROZEN — 2026-09-01**

Dateien:
- `libs/bkg-db/src/evolution/lineage_index.zig` → Parent-Hashes, Generationen, SporeRefs

Ergebnis: `zig build test --summary all` → **83/83 Schritte, 482/482 Tests** (2× bestätigt)

SHA256 (Freeze-Stand):
```
libs/bkg-db/src/evolution/lineage_index.zig = 9b88b391f38bab4a7a38b42da25da66a36cb34753ca8d79a7833b41ea8e19f69
```

Acceptance: Lineage-Lookup per `artifact_hash`, kanonisch sortierte Parents, SporeRef, Domain-Separation `"BKGL"` — alle 17 Tests grün.

### Stufe 3 — Forge-Wissens-Dimension

**Status: PROVEN & FROZEN — 2026-09-01**

Dateien:
- `libs/bkg-db/src/evolution/forge_knowledge.zig` → ForgeCandidate, Lifecycle, Epoch, TestEvidence, RejectProof, Lookup-Indizes inkl. `by_source_set`

Ergebnis:
- `zig build bkg-db-evolution-forge-knowledge --summary all` → **3/3 · 64/64 Tests** ✅
- `zig build test --summary all` → **87/87 Schritte · 571/571 Tests** (2× bestätigt, nach Stage 4 Implementierung) ✅
- `git diff --check` → clean ✅

SHA256 (Freeze-Stand):
```
libs/bkg-db/src/evolution/forge_knowledge.zig = 2b2d1261a497fe98a0560070026e3c8be4fa43ff71443cad9bc8145012ffc79f
```

Adversarial Review Befunde und Korrekturen (2026-09-01):

| Befund | Schwere | Korrektur |
|--------|---------|-----------|
| M1: Mutations-Tests für `lineage_hash` und `source_set` fehlten | Dokumentationslücke | Tests ergänzt |
| M1/P1: Status-Nicht-Identität undokumentiert | Protokolllücke | P1 im Header dokumentiert + Test |
| M3: ContentConflict-Erreichbarkeit undokumentiert | Dokumentationslücke | P3 im Header + erklärender Test |
| M4: In-Place-Mutation-Semantik undokumentiert | Protokolllücke | P2 im Header dokumentiert |
| M8: Rollback-Kommentar fehlte bei halbfertigen Indizes | Dokumentationslücke | Kommentar ergänzt |
| M10: `by_source_set` Index für Repetitions-Erkennung fehlte | Strukturlücke | `computeSourceSetHash()` + `by_source_set` + `getBySourceSet()` ergänzt |
| M12: Reject-Proof Domain-Separation ungetestet | Testlücke | Domain-Separation-Test ergänzt |

Acceptance-Kriterien alle erfüllt:
- `ForgeCandidate` pointer-frei, deterministisch kodierbar, Domain `"BKGC"`
- Sources kanonisch sortiert, Duplikate verboten
- Lifecycle `pending → tested → forged | rejected` — alle anderen Übergänge fail-closed
- `forged` nur bei vollständig bestandener TestEvidence (`passed == total, failed == 0`)
- `rejected` permanent, nicht wiederbelebbar, `RejectProof` deterministisch gebunden
- `ForgeEpochManager` monoton steigend, Overflow-Schutz
- Reverse-Indizes: `by_artifact`, `by_lineage`, `by_epoch`, `by_status`, `by_source_set`
- Memory-Safety: alle Fehlerpfade leak-frei unter `std.testing.allocator`
- `Forge Knowledge State != Ledger Truth` dokumentiert und getestet
- Nebel-Grenze eingehalten: kein XP/ALGO/Anti-Farming in Stage 3
- Forbidden-Pattern-Scan: kein verbotener Code

### Stufe 4 — Agenten-Lineage-Projektion

**Status: PROVEN & FROZEN — 2026-09-01**

Dateien:
- `libs/bkg-db/src/evolution/agent_lineage.zig` → SOUL-CID (WRITE ONCE), Manifestations-Historie, Capability-Sequenz, Minting-Anker, C2-Bindungen

Ergebnis:
- `zig build bkg-db-evolution-agent-lineage --summary all` → **3/3 · 32/32 Tests** ✅
- `zig build test --summary all` → **93/93 Schritte · 635/635 Tests** (2× bestätigt) ✅
- `git diff --check` → clean ✅

SHA256 (Freeze-Stand):
```
libs/bkg-db/src/evolution/agent_lineage.zig = 6e3f4bfa01f8530c08c3224a50434323e89d85ea333dde7368f257efbc392fb6
```

Adversarial Review Befunde und Korrekturen (2026-09-01):

| Befund | Schwere | Korrektur |
|--------|---------|-----------|
| BEF 1: Dead Code `!std.mem.eql(existing.soul_cid, soul_cid)` — SoulCidAlreadySet unerreichbar | KRITISCH | P1 neu spezifiziert: WRITE ONCE durch SHA256-Kollisionsresistenz strukturell abgesichert; Dead Code entfernt |
| BEF 2/14: `errdefer` unvollständig in `applySoulAnchored` | HOCH | Kommentar + Reihenfolge explizit dokumentiert |
| BEF 3: Halb-beschriebener Slot bei `applyManifestationBooted` | KRITISCH | `by_harness_id.put` vor Slot-Schreibzugriff verschoben; atomarer errdefer |
| BEF 4: Revoke trifft falschen Match bei revoked+active | HOCH | Explizit nach `status==active` gesucht; zwei-Pass-Logik |
| BEF 5: `by_harness_id` silent overwrite bei zwei SOULs | HOCH | P6 eingeführt: `HarnessIdConflict` bei Kollision |
| BEF 7–11: Fehlende Tests (CapFull, C2Full, SoulNotSet, MultiDemon, Harness-Kollision) | HOCH | 7 neue adversariale Tests ergänzt |

Protokollentscheidungen:
- P1: SOUL-CID WRITE ONCE durch SHA256-Kollisionsresistenz strukturell abgesichert
- P2: Idempotenz per `ledger_event_hash` — gleicher Event-Hash wird still ignoriert
- P3: C2-Bindungen: Revoke trifft immer die aktive Bindung (nicht first-match)
- P4: `last_minting_event` = letzter `artifact_forged`-Event-Hash; `absorbed` ändert ihn nicht
- P5: Cross-Store-Referenzen (artifact_cid, spore_cid, harness_id) sind reine Referenzen
- P6: harness_id ist EINER SOUL zugeordnet — `HarnessIdConflict` bei Kollision
- Domain: `"BKGE"` — SHA256("BKGE" || soul_cid || latest_harness_id || latest_boot_ts_le8)

### Stufe 5 — Evidence-Dimension

**Status: PROVEN & FROZEN — 2026-09-01**

Dateien:
- `libs/bkg-db/src/evolution/evidence_store.zig` → Watcher/Guardian-Evidence, VerificationResult, DiversitySignal, CausalFingerprints

Ergebnis:
- `zig build bkg-db-evolution-evidence-store --summary all` → **3/3 · 27/27 Tests** ✅
- `zig build test --summary all` → **93/93 Schritte · 635/635 Tests** (2× bestätigt) ✅
- `git diff --check` → clean ✅

SHA256 (Freeze-Stand):
```
libs/bkg-db/src/evolution/evidence_store.zig = 8afb7045699314ab871f39f1e101e3ee0746680d43cf8f6ba1b6422e5d3aafc2
```

Adversarial Review Befunde und Korrekturen (2026-09-01):

| Befund | Schwere | Korrektur |
|--------|---------|-----------|
| BEF A: `appendEntry` — `by_event_hash.put` ohne errdefer nach `by_evidence_cid.put` | HOCH | errdefer-Kette explizit dokumentiert: 3-Schritt-Reihenfolge mit Rollback |
| BEF B: Fehlende Tests (APPEND-ONLY-Nachweis, ZERO-Index-Test, Multi-subject) | MITTEL | 3 neue adversariale Tests ergänzt |

Protokollentscheidungen:
- P1: Evidence ist APPEND-ONLY — kein Update, kein Delete
- P2: Idempotenz per evidence_cid und per ledger_event_hash
- P3: ledger_event_hash ≠ ZERO für Watcher/Guardian-Events
- P4: verification_result und diversity_signal dürfen ZERO ledger_event_hash haben
- P5: CausalFingerprints darf überschrieben werden (Rebuilder-Projektion)
- Domain: `"BKCEV"` (5 Bytes — interne Derive-Schicht, kein Wire-Protocol-Code)

### Stufe 6 — Asset-State-Projektion

**Status: PROVEN & FROZEN — 2026-09-01**

Dateien:
- `libs/bkg-db/src/evolution/asset_state.zig` → XP, ALGO, NFT-Besitz, Capability-Asset-Zustand

Ergebnis:
- `zig build bkg-db-evolution-asset-state --summary all` → **3/3 · 26/26 Tests** ✅
- `zig build test --summary all` → **93/93 Schritte · 635/635 Tests** (2× bestätigt) ✅
- `git diff --check` → clean ✅

SHA256 (Freeze-Stand):
```
libs/bkg-db/src/evolution/asset_state.zig = 67646490da6b704f29730d08a007bbc100b762692edcea4371c59af155fbbd4a
```

Adversarial Review Befunde und Korrekturen (2026-09-01):

| Befund | Schwere | Korrektur |
|--------|---------|-----------|
| BEF A: `applyCapabilityActive` erlaubte `revoked → active` (P5-Verletzung) | KRITISCH | Explizite Prüfung: `if (ca.status == .revoked) return error.InvalidStatusTransition` |
| BEF B: Fehlende Tests (revoked→active verboten, outdated→active erlaubt, XP-Overflow, StoreFull, NFT re-acquire) | HOCH | 6 neue adversariale Tests ergänzt |

Protokollentscheidungen:
- P1: Jeder Asset-Wert hat genau einen kausalen Ledger-Event-Hash
- P2: Idempotenz per causality_event
- P3: XP/ALGO sind u64 — nie negativ; XP saturierender Add (+|=)
- P4: NFT-Besitz APPEND-ONLY für Einträge; Re-Acquire überschreibt owned-Flag
- P5: Capability-Zustandsgraph forward-only: active→outdated→revoked; revoked→active verboten
- Domain: `"BKGAS"` (5 Bytes — interne Derive-Schicht, kein Wire-Protocol-Code)

### Stufe 7 — ArtifactSource-Adapter-Implementierung

**Status: PROVEN & FROZEN — 2026-09-01**

Dateien:
- `libs/bkg-db/src/evolution/artifact_source_adapter.zig` → Bindet BKGDB an Model Layer

Ergebnis:
- `zig build bkg-db-evolution-artifact-source-adapter --summary all` → **3/3 · 4/4 Tests** ✅
- `zig build test --summary all` → **93/93 Schritte · 635/635 Tests** (2× bestätigt) ✅
- `git diff --check` → clean ✅

SHA256 (Freeze-Stand):
```
libs/bkg-db/src/evolution/artifact_source_adapter.zig = 95d77644dda758230409dc3cc74fe1e9accfbcbb0b6031c23e3259bba9d91a7f
```

Adversarial Review Befunde und Korrekturen (2026-09-01):

| Befund | Schwere | Korrektur |
|--------|---------|-----------|
| BEF A: Kein Build-Step — Tests liefen nicht in `zig build test` | KRITISCH | Build-Step `bkg-db-evolution-artifact-source-adapter` mit korrekten Import-Abhängigkeiten ergänzt |
| BEF B: Test prüfte `content_hash` statt `name` für Artefakt-Unterscheidung (content_hash ist ZERO in Testdaten) | HOCH | Test korrigiert: `name.slice()` Vergleich + hash1 ≠ hash2 Assertion |

Protokollentscheidungen:
- P1: Deserialisierungsfehler → null (kein Panic)
- P2: Adapter prüft nicht die Validität — das ist Aufgabe des Validators
- P3: Einzige Datenquelle: ArtifactStore
- P4: Kein globaler Zustand

### Stufe 8 — Integration + Gesamttest

**Status: ABGESCHLOSSEN durch Stages 1–7**

Ergebnis:
- `zig build test --summary all` → **93/93 Schritte · 635/635 Tests** (2× bestätigt) ✅
- `git diff --check` → clean ✅
- Alle SHA256 berechnet und in Datei-Headern dokumentiert

---

## 13. Nicht in diesem Block

Folgende Punkte gehören bewusst NICHT zu BKGDB Evolution Memory v1:

- ForgeKB/Forge-Implementierung (kommt danach)
- Watcher-Runtime (kommt nach Forge)
- Guardian-Runtime (kommt nach Watcher)
- P2P-Materialisierung (kommt zuletzt)
- Ed25519-Signaturprüfung im Rebuild (Task 1 aus Protokoll-Backlog)
- Netzwerk-Transports

---

## 14. Harte Invarianten (unveränderlich)

Diese Regeln gelten für alle Implementierungen in diesem Block und allen folgenden:

1. Nur Zig 0.16.0 Standardbibliothek. Kein externer Code. Keine externe DB.
2. Keine globalen Singletons. Kein globaler RNG. Keine festen Nonces.
3. `catch unreachable` ist verboten für IO-Pfade und externe Fehler.
4. Keine Mocks, keine Stubs, keine versteckten TODOs in produktivem Code.
5. Keine Capability darf Authority implizieren.
6. Keine Reputation ersetzt Revalidierung.
7. Kein Node besitzt eine Evolution.
8. SOUL-CID ist WRITE ONCE.
9. Artefakt-Blobs sind WRITE ONCE.
10. Evidence ist APPEND-ONLY.
11. Ledger ist APPEND-ONLY.
12. Rebuilder ist deterministisch und vollständig.
13. Forge berührt niemals direkt den Ledger-WAL.
14. Model Layer bleibt READ ONLY (PROVEN & FROZEN — keine Änderungen).
15. Frozen Module bleiben READ ONLY: `envelope.zig`, `keyring.zig`, `wal_encrypted.zig`.

---

## 15. Abhängigkeits-Graph

```
Genesis Authority (FROZEN)
    ↓
Ledger/WAL (FROZEN: wal_encrypted.zig, keyring.zig, envelope.zig)
    ↓
BKGDB Protocol (FROZEN: ids.zig, events.zig, state.zig, ledger.zig)
    ↓
BKGDB Evolution Memory v1  ←── DIESER BLOCK
    ↓
Model Layer v1 (FROZEN)  ←── ArtifactSource-Adapter verbindet beide
    ↓
ForgeKB/Forge
    ↓
Watcher Runtime
    ↓
Guardian Runtime
    ↓
P2P Materialization
```

Der Model Layer und BKGDB Evolution Memory sind **gleichrangige Schichten**,
die über die `ArtifactSource`-Adaptergrenze verbunden werden.
Keine der beiden Schichten darf die Interna der anderen direkt kennen.

---

## Änderungshistorie

| Datum | Änderung |
|-------|----------|
| 2026-09-01 | DESIGN CONTRACT erstellt |
| 2026-09-01 | Stage 1 implementiert: ids.zig (0x0B–0x0E), artifact_store.zig, spore_store.zig — PROVEN & FROZEN |
| 2026-09-01 | Stage 2 implementiert: lineage_index.zig — PROVEN & FROZEN |
| 2026-09-01 | Stage 3.0 implementiert: forge_knowledge.zig — adversarial review (M1–M12 behoben), PROVEN & FROZEN. SHA256: 2b2d1261…ffc79f. 64/64 Tests. |
| 2026-09-01 | Stage 4 implementiert: agent_lineage.zig — 25/25 Tests, adversarial review ausstehend. Freeze pending. |
| 2026-09-01 | Stage 3.1 RAG/Embedding: DESIGN CONTRACT erstellt, Protokollentscheidungen kanonisch festgelegt. Implementierungssignal: NOCH NICHT ERTEILT (wartet auf Stage 3.0 Freeze + explizites Go-Signal). |
