# BKGDB / BKG Model Layer — Next Tasks

> **Current baseline:** `zig build test` = **764/764 pass, 0 failures, 0 crashes**
> **Previous baseline:** 571/571
> **Delta this session:** durable ledger/WAL/engine recovery tests now compile as standalone roots (Zig 0.16 `std.Io`); AUTHORIZE default-deny; genesis persist+verify-on-load
> **Build steps:** 105/105
> **Genesis Authority:** ✅ PROVEN & FROZEN
> **WAL Encryption v1:** ✅ PROVEN & FROZEN
> **BKG Model Layer v1:** ✅ PROVEN & FROZEN — 2026-09-01
> **BKGDB durable recovery:** ✅ fail-closed hash/CRC/signature; crash-tail truncate only at EOF

---

## Frozen Modules — READ ONLY

| Modul | SHA256 | Status |
|-------|--------|--------|
| `crypto/envelope.zig` | `081af87ff0ab1dad35bb84a964e22f7a282135e79bdce61b51d102c45d276ca4` | FROZEN |
| `crypto/keyring.zig` | `695061c684ba61fc13a5747321dd2b4a2b8385a40f188459d0196efdaef57578` | FROZEN |
| `storage/wal_encrypted.zig` | `b312512ac96886e8a55a6e3f8ab4f0e8f2df59d07008beb80aa71894d958ff38` | FROZEN |

Keine Änderungen an diesen Dateien ohne expliziten Protokollfehler-Nachweis.

---

## ✅ ABGESCHLOSSEN — Model Layer v1 Adversarial Review

### Ergebnis (2026-09-01)

Der Model Layer hat alle Tasks M1–M13 bestanden.
128/128 Model-Tests grün. 434/434 Gesamt-Tests grün (2 Läufe).
Status: **PROVEN & FROZEN — 2026-09-01**

Tasks M1–M13: vollständig abgeschlossen und in Modul-Headern dokumentiert.

---

### Task M1 — Kanonische Encoding-Vollständigkeit

**Zu prüfen:** Gibt es für dasselbe semantische Artefakt mehr als eine gültige
Byte-Darstellung in `manifest.zig`?

Konkrete Prüfpunkte:

1. Alle fixen Array-Felder werden vollständig serialisiert (padding-Nullen müssen
   Teil des kanonischen Outputs sein, nicht ignoriert).
2. `parent_count` steuert die semantische Anzahl, aber alle `MAX_PARENTS`-Slots
   werden serialisiert — damit ist die Serialisierung über den Zählwert hinaus
   immer identisch für dieselbe logische Struktur.
3. `name.data` jenseits von `name.len` enthält immer Nullen — sichergestellt durch
   `makeArtifactName` (kopiert, kein uninitialisierter Tail).
4. `algo_desc.data`, `params.data` analog.
5. Testvektoren jenseits von `tv_count` und `bench_claims` jenseits von
   `bench_count` sind in festen Slots — alle serialisiert.

**Acceptance:** Test der Form `serialize(a) == serialize(b)` für zwei
unabhängig konstruierte Artefakte mit identischer Semantik.
Kein uninitialisierter Byte darf die Ausgabe beeinflussen.

**Risiko:** `makeArtifactName` kopiert korrekt, aber direktes Struct-Bauen
ohne Helper könnte uninitialisierte Tail-Bytes hinterlassen.
Entweder Invariante dokumentieren oder Konstruktoren erzwingen.

---

### Task M2 — Parent-Sortierungs-Invariante

**Zu prüfen:** `lineage.computeLineageHash()` sortiert Parent-Hashes vor dem
Hashen — aber `manifest.serialize()` serialisiert `parents[]` in der
gespeicherten Reihenfolge (nicht sortiert).

Das bedeutet: Zwei Artefakte, die semantisch dieselben Parents haben,
aber in verschiedener Reihenfolge eingetragen sind, haben:
- **denselben** `lineage_hash` (wegen Sortierung in `computeLineageHash`)
- **verschiedene** `content_hash` (weil `manifest.serialize` die Reihenfolge erhält)

**Frage:** Ist das gewollt?

Optionen:
- **Option A (aktuell implizit):** Parent-Reihenfolge ist Teil der Artefakt-Identität.
  Zwei Artefakte mit gleichen Parents in anderer Reihenfolge sind verschiedene Artefakte
  (verschiedene `content_hash`), aber mit derselben Lineage-Zugehörigkeit.
- **Option B:** Parent-Hashes werden auch in `manifest.serialize` sortiert.
  Dann sind beide content_hash identisch.

**Acceptance:** Explizite Entscheidung dokumentieren und mit einem Test absichern,
der beide Reihenfolgen testet und das erwartete Verhalten beschreibt.

---

### Task M3 — Hash-Domain-Trennung

**Zu prüfen:** Können zwei verschiedene semantische Objekte denselben Hash
erzeugen (Collision durch fehlende Domain-Separation)?

Prüfpunkte:

1. `computeContentHash` — SHA-256 über Manifest-Bytes. Magic `"BKGM"` am Anfang
   trennt von anderen SHA-256-Inputs (Lineage, Snapshot, Evidence). ✓ Struktur OK.
2. `computeLineageHash` — SHA-256 über Parents + origin_event byte + epoch + gen + prov_hash.
   Frage: Könnte ein Artefakt ohne Parents + passendem origin_event-Byte denselben
   Hash wie ein Parent-Hash-Prefix erzeugen (Length-Extension-artiger Angriff)?
   Antwort: Nein, weil `origin_event` (u8) + `epoch` (u64) + `gen` (u64) + `prov_hash` (32)
   als feste Suffixe anhängen — kein reiner Prefix-Hash möglich.
3. `computeSnapshotRootHash` — kein eigenes Magic-Byte. Könnte theoretisch mit
   einem Manifest-Hash kollidieren, wenn die Byte-Folge identisch wäre. In der Praxis
   unwahrscheinlich, aber formal nicht ausgeschlossen.
4. `generateUsageEvidence.evidence_hash` — SHA-256 über artifact_hash + lineage_hash +
   snapshot_root + epoch + version. Keine Domain-Separation gegenüber anderen Hashes.

**Acceptance:** Entweder formale Analyse zeigt, dass alle Hash-Domains durch
Längen-/Struktur-Unterschiede automatisch getrennt sind, oder explizite
Domain-Präfixe werden eingeführt.

---

### Task M4 — Snapshot-Einschleusung

**Zu prüfen:** Kann ein manipulierter Snapshot ein nicht-validiertes Artefakt
als „enthalten" deklarieren und damit die Materialisierungspipeline täuschen?

Prüfpunkte:

1. `containsArtifact(snapshot, hash)` prüft nur ob der Hash in `artifact_hashes[]`
   enthalten ist — es prüft nicht ob das Artefakt selbst validiert wurde.
2. Der Materializer ruft `validator.validate()` unabhängig vom Snapshot auf.
3. Ein manipulierter Snapshot (falscher root_hash) wird von `verifySnapshot()` erkannt.
4. **Aber:** Wenn ein Caller `materialize()` ohne vorherigen `verifySnapshot()`-Call
   aufruft, ist der Snapshot-Schutz nicht enforced.

**Acceptance:** Entweder `materialize()` prüft intern `verifySnapshot()` (und gibt
`SnapshotInvalid` zurück wenn root_hash falsch), oder die Invariante ist explizit
im Caller-Vertrag dokumentiert: „Caller MUSS snapshot vor materialize() verifizieren."

Test: `materialize()` mit tampertem Snapshot-root_hash — erwartet Fehler oder explizite
Caller-Verantwortung dokumentiert.

---

### Task M5 — Capability-Authority-Grenze

**Zu prüfen:** Kann eine aktivierte Capability sich selbst zur Authority erklären
oder eine andere Capability direkt aktivieren?

Prüfpunkte:

1. `CapabilityCache.markActivated()` erfordert den Weg `known→verified→materializable→activated`.
   Kein externer Code kann einen `activated`-Zustand herstellen ohne diesen Pfad.
2. Eine aktivierte Capability hat keinen Pointer auf andere Capabilities.
3. `MaterializedArtifact` enthält keine `activate()` Methode — ist read-only.

**Acceptance:** Test der Form: „Eine aktivierte Capability kann keine weitere
Capability direkt aktivieren — jede Aktivierung erfordert einen vollständigen
`materialize()`-Aufruf durch den Caller."

---

### Task M6 — Stale/Revoked Cache-Sicherheit

**Zu prüfen:** Kann ein als `revoked` oder `outdated` markierter Cache-Eintrag
reaktiviert werden, ohne die volle Validierungspipeline zu durchlaufen?

Prüfpunkte:

1. `markRevoked()` → Zustand `revoked` → `markActivated()` schlägt mit
   `InvalidTransition` fehl (da state != materializable). ✓
2. `markOutdated()` → Zustand `outdated` → `markActivated()` schlägt fehl. ✓
3. Was passiert wenn `addKnown()` für dieselbe `CapabilityId` zweimal aufgerufen wird?
   Derzeit: Zweiter Eintrag wird als neuer Slot hinzugefügt (kein Duplikat-Check).
   `findById()` gibt den **ersten** Treffer zurück — das ist der revozierte Eintrag,
   nicht der neue.

**Risiko:** Ein re-`addKnown()` + erneuter Aktivierungspfad für dieselbe capability_id
würde einen neuen Slot anlegen, den alten revoked-Eintrag ignorieren, und könnte
eine neue Aktivierung über einen frischen Slot ermöglichen — ohne dass der revoked-
Status des Vorgängers blockiert.

**Acceptance:** Entweder `addKnown()` prüft auf Duplikat-ID und gibt `error.DuplicateId`
zurück, oder die Invariante wird explizit dokumentiert: Caller ist verantwortlich,
keine doppelten IDs einzutragen.

---

### Task M7 — Buff/Curse-Capability-Gate

**Zu prüfen:** Kann ein Buff-Artefakt das Capability-Gate einer anderen Capability
umgehen?

Prüfpunkte:

1. Buffs und Curses durchlaufen dieselbe 6-Stufen-Pipeline wie alle anderen Artefakte.
2. Es gibt keine „Bypass"-API für Buffs.
3. Ein Buff kann theoretisch eine `ActivationPolicy` tragen, die `requires_guardian_verdict = false`
   setzt und `min_generation = 0` — das ist kein Bypass, sondern eine gültige Policy.

**Acceptance:** Dokumentiert, dass Buffs keine privilegierte Aktivierung erhalten.
Test: Buff-Artefakt mit strikter Policy (min_generation = 10) — muss abgelehnt werden,
wenn Consumer-Generation = 1.

---

### Task M8 — Diversity-Manipulation

**Zu prüfen:** Kann `computeDiversity()` durch triviale Identitätsvariationen
gefälscht werden?

Prüfpunkte:

1. Novelty basiert auf Hash-Vergleich (`new_artifact_hash` nicht in `known_artifacts[]`).
   Wäre trivial zu fälschen: Neuer Hash für identischen Inhalt → `novelty_score = 255`.
2. Das ist by design: `computeDiversity()` kennt keinen Artefakt-Inhalt, nur Hashes.
   Die Qualität der `known_artifacts[]`-Liste liegt beim Caller (Guardian/Forge).
3. Parent-Diversity: `parentNovelty()` prüft ob Parents in `seen_lineages[]` enthalten.
   Neue Parent-Hashes → hoher Score, auch wenn Parents semantisch identisch sind.

**Acceptance:** Explizite Invariante dokumentieren: „`computeDiversity()` ist nur so
gut wie die `DiversityInput`-Daten. Die Vollständigkeit und Korrektheit der
`seen_lineages[]`- und `known_artifacts[]`-Listen ist Guardian/Forge-Verantwortung.
Der Model Layer prüft Hashes, keine Semantik."

---

### Task M9 — Re-Materialisierungs-Identitätsschutz

**Zu prüfen:** Erzeugt eine Re-Materialisierung eine unerlaubte Identitätsübernahme?

Prüfpunkte:

1. `materialize()` erzeugt ein neues `MaterializedArtifact` mit `lineage_hash` aus dem Artefakt.
2. Zwei `materialize()`-Aufrufe für dasselbe Artefakt auf verschiedenen Nodes erzeugen
   zwei unabhängige `MaterializedArtifact`-Instanzen mit demselben `lineage_hash`.
3. Es gibt kein globales Session-/Identity-Token in `MaterializedArtifact`.
4. `capability_id` ist deterministisch aus `content_hash` abgeleitet — identisch für
   dasselbe Artefakt auf allen Nodes.

**Risiko:** Wenn zwei Nodes gleichzeitig dasselbe Artefakt materialisieren und beide
eine `UsageEvidence` erzeugen, sind beide Evidences strukturell gültig.
Die Unterscheidung, welcher Node die legitime Materialisierung hatte, ist Aufgabe
des Ledgers/Rebuilders, nicht des Model Layers.

**Acceptance:** Explizit dokumentieren: „Der Model Layer verhindert keine parallele
Materialisierung auf mehreren Nodes. Die Eindeutigkeit einer Manifestation ist
Ledger-/Rebuilder-Aufgabe." Test: Zwei `materialize()`-Calls erzeugen zwei
unabhängige `MaterializedArtifact`-Instanzen — kein Konflikt.

---

### Task M10 — Spore-Untrusted-Invariante

**Zu prüfen:** Bleibt eine Spore nach Weitergabe über `lineage_mod.SporeRef`
untrusted?

Prüfpunkte:

1. `SporeRef` enthält `spore_hash`, `spore_epoch`, `spore_origin` — keine Authority-Evidence.
2. Ein Artefakt mit `kind = .spore_candidate` und gültiger Evidence kann die volle
   Validierungspipeline bestehen — aber nur wenn eine externe Stelle eine gültige
   `AuthorityEvidence` eingetragen hat.
3. Frage: Kann eine Spore sich selbst eine gültige Evidence einschreiben?

**Acceptance:** Dokumentiert, dass `spore_candidate`-Artefakte dieselbe Evidence-
Anforderung wie alle anderen Artefakte haben. Ein Spore-Artefakt ohne Guardian-
Verdict-Referenz (zero `ledger_event_hash`) kann trotzdem validiert werden, wenn
die Policy `requires_guardian_verdict = false` setzt.
Test: Spore-Kandidat ohne Guardian-Verdict mit policy `requires_guardian_verdict = false` →
Validator akzeptiert → korrekt (das ist Policy-Entscheidung).
Test: Spore-Kandidat mit `requires_guardian_verdict = true` ohne Verdict → abgelehnt.

---

### Task M11 — Materialisierungs-Atomizität unter Fehler

**Zu prüfen:** Bleibt der CapabilityCache in einem konsistenten Zustand wenn
`materialize()` nach einem der Zwischenschritte fehlschlägt?

Aktueller Ablauf in `materialize()`:
```
addKnown()           → Eintrag im Zustand `known`
markVerified()       → kann fehlschlagen
markMaterializable() → kann fehlschlagen
markActivated()      → kann fehlschlagen
```

Bei Fehler in `markVerified()`: Eintrag bleibt im Zustand `known` im Cache.
Bei Fehler in `markMaterializable()`: Eintrag bleibt im Zustand `verified`.
Bei Fehler in `markActivated()`: Eintrag bleibt im Zustand `materializable`.

Diese „halbfertigen" Einträge belegen Cache-Slots und könnten bei erneutem
`addKnown()` für dieselbe ID zu Duplikaten führen (vgl. Task M6).

**Acceptance:** Entweder `materialize()` rollback des Cache-Eintrags bei Fehler
(Eintrag entfernen oder auf `failed` setzen), oder die Invariante ist dokumentiert
und `addKnown()` hat Duplikat-Schutz.

---

### Task M12 — Vollständige Adversarial Test-Matrix

Nach Abschluss der Tasks M1–M11: Alle identifizierten Risiken durch Tests abgedeckt.

Mindestens neue Tests für:

- [ ] Zwei unabhängig konstruierte Artefakte mit identischer Semantik → gleicher content_hash
- [ ] Parent-Reihenfolge: explizit dokumentiertes Verhalten (M2)
- [ ] Hash-Domain-Separation formal geprüft (M3)
- [ ] `materialize()` ohne vorherigen `verifySnapshot()` — Caller-Vertrag klar
- [ ] Duplicate capability_id in Cache → definiertes Verhalten
- [ ] Buff mit strikter Policy abgelehnt wenn Generation zu niedrig
- [ ] Diversity-Input-Qualität liegt beim Caller (M8)
- [ ] Re-Materialisierung auf zwei Nodes — kein Konflikt (M9)
- [ ] Spore mit und ohne Guardian-Verdict-Policy (M10)
- [ ] Cache-Zustand nach fehlgeschlagenem `materialize()` (M11)

---

### Task M13 — Freeze-Nachweis

Nach Abschluss aller Tasks M1–M12:

```
zig build test --summary all
```

Erwartetes Ergebnis:
- Alle bestehenden 417 Tests grün
- Alle neuen Adversarial-Tests grün
- 0 Failures, 0 Crashes
- `git diff --check` = clean

Danach:
- SHA256 aller 11 `bkg-model`-Dateien berechnen
- Status in allen relevanten Dateien auf `PROVEN & FROZEN` setzen
- Freeze-Datum und Hash im Modul-Header eintragen

---

## NEXT BLOCK — BKGDB Evolution Memory v1

### Stand (2026-09-01)

Vertrag: `docs/BKGDB_EVOLUTION_MEMORY_v1.md`
Gesamtprojekt: NON-FROZEN bis Abschluss aller Stufen

Implementierungsreihenfolge (je Stufe erst PROVEN & FROZEN, dann nächste):

- [x] **Stufe 1** — Basis-Persistenz: IdTypes (0x0B–0x0E) + `artifact_store.zig` + `spore_store.zig` — **PROVEN & FROZEN — 2026-09-01**
- [x] **Stufe 2** — Lineage-Index: `lineage_index.zig` — **PROVEN & FROZEN — 2026-09-01**
- [x] **Stufe 3** — Forge-Wissens-Dimension: `forge_knowledge.zig` — **PROVEN & FROZEN — 2026-09-01** (64 Tests · SHA256: `2b2d1261…ffc79f`)
- [-] **Stufe 4** — Agenten-Lineage-Projektion: `agent_lineage.zig` — IMPLEMENTED (25 Tests · SHA256: `82d9be74…011ff`) · adversarial review ausstehend
- [ ] **Stufe 5** — Evidence-Dimension: `evidence_store.zig`
- [ ] **Stufe 6** — Asset-State-Projektion: `asset_state.zig`
- [ ] **Stufe 7** — ArtifactSource-Adapter: `artifact_source_adapter.zig`
- [ ] **Stufe 8** — Integration + Gesamttest (alle 465+ Tests grün)

Danach: ForgeKB/Forge → Watcher Runtime → Guardian Runtime → P2P Materialization

---

## Bereits erledigt (this session)

### Genesis Block — FROZEN

Genesis Authority ist **complete and frozen** als Protokoll-Baseline.

| Component | File | Tests |
|-----------|------|-------|
| `GenesisAuthorityRecord` struct | `genesis/genesis.zig` | — |
| `computeGenesisHash()` — canonical SHA256, fixed field order | `genesis/genesis.zig` | ✅ |
| `verifyGenesisRecord()` — fail-closed, 6 explicit errors | `genesis/genesis.zig` | ✅ |
| `rebuildProtocol(allocator, genesis, events)` | `engine/rebuild.zig` | ✅ |
| Cross-root adversarial matrix | `engine/rebuild.zig` | ✅ |

### WAL Encryption v1 — FROZEN

| Component | File | Tests |
|-----------|------|-------|
| `EncryptedWalWriter` + `EncryptedWalReader` | `storage/wal_encrypted.zig` | ✅ 38 |
| Replay-Beweis-Test | `storage/wal_encrypted.zig` | ✅ |
| Tamper-Matrix (Transport + Envelope) | `storage/wal_encrypted.zig` | ✅ |

### BKG Model Layer v1 — ✅ PROVEN & FROZEN — 2026-09-01

| Component | File | Tests |
|-----------|------|-------|
| `hash.zig` — SHA-256 Primitiven | `bkg-model/src/hash.zig` | ✅ 12 |
| `artifact.zig` — Artefakt-Typen, pointer-frei | `bkg-model/src/artifact.zig` | ✅ 10 |
| `manifest.zig` — kanonische Serialisierung | `bkg-model/src/manifest.zig` | ✅ 9 |
| `lineage.zig` — sortiertes Lineage-Modell | `bkg-model/src/lineage.zig` | ✅ 10 |
| `capability.zig` — State Machine | `bkg-model/src/capability.zig` | ✅ 10 |
| `knowledge_snapshot.zig` — verifizierbarer Snapshot | `bkg-model/src/knowledge_snapshot.zig` | ✅ 11 |
| `validator.zig` — 6-Stufen-Pipeline + BKGDB-Adapter | `bkg-model/src/validator.zig` | ✅ 15 |
| `materializer.zig` — atomare Materialisierung | `bkg-model/src/materializer.zig` | ✅ 9 |
| `diversity.zig` — deterministischer Diversity-Layer | `bkg-model/src/diversity.zig` | ✅ 8 |
| `evolution.zig` — Hamming-Distanz, XP, Anti-Inzucht | `bkg-model/src/evolution.zig` | ✅ 17 |

**Offene Punkte vor Freeze:** Tasks M1–M13 (siehe oben).

---

## Protokoll-Backlog

### Task 1 — Ed25519 Actor Signature Verification — DONE

`verifyEnvelopeSignature` prüft `Ed25519.verify(signature, event_hash, actor_pubkey)` fail-closed.

### Task 2 — authority_set State Effects — DONE

C2-Bindung erzeugt Mandate. AUTHORIZE ist default-deny: Forge, aktiver Guardian (Observation/Influence) oder unwiderrufenes Mandat. Delegierte dürfen keine Privilegien (Forge, C2, Identity, Guardian-Set) ausüben. Revoke schließt den Scope für nachfolgende Events.

### Task 3 — Genesis Persistence — DONE

Kanonische Binärform `BKGG` + `verifyGenesisRecord` beim Laden. Tamper → fail-closed.

### Task 4 — Guardian-Set State Accumulation — DONE

`guardian_set_changed` nur von Forge; Set wird vollständig ersetzt.

### Task 5 — Full Regression Gate

```
zig build test
```

Acceptance:
- all tests green
- 0 failures, 0 crashes
- deterministic repeated runs
