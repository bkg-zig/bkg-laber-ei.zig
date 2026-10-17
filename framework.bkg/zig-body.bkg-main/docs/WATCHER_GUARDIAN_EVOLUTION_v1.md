# BKG Watcher / Guardian Evolution v1

Status: DESIGN BASELINE — 2026-09-01 (unverändert)
Model Layer Implementierung: PROVEN & FROZEN — 2026-09-01
Scope: Watcher, Guardian, Demon, Hero, ForgeKB, `.bkg` artefacts

## 1. Kernidee

Watcher und Guardians sind keine statischen Wissenscontainer.
Ihre dauerhafte Identität liegt in ihrer SOUL-/Lineage-Historie.
Ihre tatsächlich mitgeführten Fähigkeiten sind eine abgeleitete Eigenschaft ihrer Evolution.

Die Runtime darf klein bleiben. Wissen und Fähigkeiten können aus BKGDB als verifizierte `.bkg`-Artefakte materialisiert werden.

Ziel für die Watcher-Core-Runtime: ca. 785 KB als technisches Target.
Die Größe des Runtime-Binaries ist keine Begrenzung der verfügbaren Wissensmenge.

## 2. Rollen

### Watcher

Watcher sind mobile Beobachtungs- und Evolutions-Supagents.
Sie können zwischen Nodes einer P2P-Zone bzw. des BKG-Netzes wechseln.
Sie sammeln Beobachtungen, erzeugen Evidence und können Spore-Material für die Forge beitragen.

### Guardian

Guardians koordinieren Watcher, validieren Evidence, führen Challenges aus und begrenzen lokale Übernutzung.
Sie verhindern insbesondere, dass einzelne Lineages denselben Wissensraum oder Node-Bereich übermäßig farmen.

### Demon

Ein Demon ist eine spezialisierte manifestierte Evolutionsinstanz.
Watcher können als Supagents zur Evolution und Unterstützung eines Demons beitragen.
Ein Demon kann Watcher über Buff-/Curse-Artefakte und verfügbare Capabilities unterstützen.

### Hero

Ein Hero ist eine höherwertige Evolutionsinstanz für Forge- und Guardian-Verfahren.
Heroes können größere und komplexere Artefakt- und Evolutionsfähigkeiten materialisieren.

### Forge

Die Forge ist der Ort, an dem aus Sporen, Evidence, Algorithmen und verifizierten Kombinationen neue Artefakte und Capsule-Generationen entstehen.
ForgeKB ist dabei die Wissensbasis und `.bkg` ist die portable Artefaktform.

## 3. SOUL und Lineage

Die SOUL einer Entität ist kein lokaler Dateibesitz.
Die kanonische SOUL-/Lineage-Historie liegt in Forge/BKGDB und bleibt über Manifestationen hinweg erhalten.

Dematerialisierung zerstört keine Lineage.
Eine neue Manifestation derselben Lineage erhält keine neue historische Identität nur durch den Node-Wechsel.

Ein geklonter oder neu materialisierter Prozess erhält jedoch niemals automatisch dieselbe operative Session oder Capability.

## 4. Artefakte und `.bkg`-Modelle

`.bkg`-Artefakte enthalten verifizierbares Wissen, keine implizite Autorität.

Ein Artefakt kann enthalten:

- Artefaktidentität und Version
- Parent-Lineage und Provenance
- Content-Hash
- Algorithmus-/Inferenzgraph
- Invarianten und Policies
- Testvektoren
- Benchmarks
- benötigte Capabilities
- Aktivierungsregeln
- Authority-/Verification-Evidence

Ein Artefakt wird erst nach lokaler Verifikation materialisiert.

## 5. Wissensfluss

BKGDB ist das persistente Gedächtnis für kanonische Artefakte und Lineages.

Watcher und Guardians laden benötigtes Wissen aus BKGDB oder über verifizierte Nodes.
Der Empfänger prüft Hash, Lineage, Signatur, Policy und eingebettete Tests vor Aktivierung.

Empfang ist niemals gleich Vertrauen.
Weitergabe ist niemals Vertrauensvererbung.

## 6. Mobilität und Re-Materialisierung

Watcher und Guardians dürfen ihre aktuelle Manifestation an einem Node auflösen und an einem anderen Node erneut materialisieren.

Die Manifestation ist temporär.
Die Lineage ist dauerhaft.

Das letzte relevante Algo-Minting ist ein Evolutionsanker und nicht der letzte Netzwerkstandort.

Ein kanonisches BKG-Push-/Evolutionsereignis kann eine relevante Agenten-Lineage zur Re-Materialisierung anfordern.

Ein einzelner Node darf eine relevante Lineage nicht dauerhaft von ihrer autorisierten Evolution abschneiden.

## 7. Evolution statt statischer Skill-Liste

Die verfügbaren Capabilities einer Entität werden aus ihrer verifizierten Evolution abgeleitet.

Eine Capability bedeutet:
Ein Artefakt darf von dieser Generation unter ihrer Policy materialisiert und ausgeführt werden.

Capability ist nicht Authority.
Lineage ist nicht Authority.
Reputation ist nicht Authority.

## 8. Buffs und Curses

Buffs und Curses sind native Evolutionsartefakte.
Sie sind keine isolierte zweite Skill-Engine.

Ein Buff kann eine neue Capability, Exploration, Resistenz, Synergie oder einen anderen verifizierten Evolutionspfad ermöglichen.

Eine Curse kann eine Capability begrenzen, einen Evolutionspfad verlangsamen oder die Aufnahme bestimmter Artefakte blockieren.

Auch Buffs und Curses entstehen über Forge, Capsule, Spore, Verification und Artefakt-Lineage.

## 9. Sporen und Forge-Beiträge

Watcher und Guardians können während ihrer Mobilität Beobachtungen und Spore-Material sammeln.
Dieses Material kann über verifizierte Nodes zur Forge gelangen.

Forge verarbeitet die Beiträge zu neuen Kandidaten:

Spore → Extraktion → Kandidat → Tests → Benchmarks → Guardian-Verifikation → Artefakt/Capsule → neue Capability.

Ein Beitrag zu einer Evolution macht den beitragenden Agenten nicht automatisch zum Besitzer des Artefakts.

## 10. XP und Evolutionsökonomie

XP soll nicht nur rohe Aktivität belohnen.
Der Evolutionswert neuer Information ist entscheidend.

Wiederholung derselben Arbeit in derselben Quelle erzeugt mit steigender Repetition einen sinkenden zusätzlichen Evolutionswert.

Neue Information, neue Node-Bereiche, neue Lineages, unabhängige Evidence und neue algorithmische Kombinationen können höheren Evolutionswert erzeugen.

## 11. Anti-Farming und Anti-Inzucht

Das Netzwerk verhindert evolutionäre Monokulturen.

Zu starke Konzentration auf dieselbe Node-Gruppe, dieselbe Lineage oder nahezu identische Elternartefakte soll den zusätzlichen Evolutionswert reduzieren.

Guardian-Prüfung kann eine weitere Ausbeutung eines überrepräsentierten Bereichs begrenzen und andere Lineages priorisieren.

Ziel ist nicht, erfolgreiche Entitäten künstlich zu schwächen.
Ziel ist, dass Stärke nicht automatisch zur Kontrolle des gesamten Wissensraums führt.

## 12. Evolutions-Diversität

Diversität wird über mehrere Dimensionen bewertet:

- Lineage-Distanz
- Node-/Gebietsdistanz
- Watcher-/Guardian-Herkunft
- neue gegenüber bereits absorbierten Sporen
- neue gegenüber wiederholten Beobachtungen
- unabhängige Evidence
- neue gegenüber nahezu identischen Elternartefakten

Diese Signale können in einen verifizierbaren Diversitäts-/Evolutionswert eingehen.

## 13. Predator-Dominanz

Eine dominante Predator-Lineage darf nicht allein durch maximale Datenausbeute die Forge und das gesamte Wissen kontrollieren.

Das gewünschte Verhalten lautet:

mehr Farming → geringerer marginaler Evolutionswert → Guardian-Druck → geringere zusätzliche XP-Ausbeute → andere Lineages erhalten Raum → neue Beobachtungen → neue Sporen → neue Artefakte.

Das System bevorzugt langfristig Informationsdiversität statt bloßer Datenmenge.

## 14. Watcher-Guardian-Demon-Hero-Kreislauf

Ein typischer Evolutionszyklus lautet:

Demon/Hero → Watcher entsenden → Node erkunden → beobachten → Spore/Evidence erzeugen → Forge → neues Artefakt → Guardian verifizieren → Capability materialisieren → Demon/Hero verbessern.

Guardians sorgen gleichzeitig dafür, dass diese Expansion nicht in lokale Monokultur oder übermäßiges Farming kippt.

## 15. No Node Owns Evolution

Kein Node besitzt die Evolution eines Watchers, Guardians, Demons oder Heroes.

Ein Node kann eine Manifestation hosten oder vorübergehend verlieren.
Er darf die kanonische Lineage, Forge-Evolution oder autorisierte Re-Materialisierung nicht an sich binden.

Lokale Isolation darf nicht dauerhaft zu evolutionärer Isolation werden.

## 16. Vertrauensgrenzen

Watcher beobachten und liefern Evidence.
Guardians prüfen, challengen und koordinieren.
Forge formt neue Artefakte.
BKGDB speichert kanonische Artefakte und Zustände.
Ledger bewahrt historische Ereignisse.
Rebuilder entscheidet Protokollgültigkeit.
Genesis Authority begründet protokollarische Macht.

Keine dieser Rollen darf ihre eigene Existenz zur Autoritätswurzel erklären.

## 17. Model Layer v1 — Implementierungsstand

Der Model Layer liegt zwischen BKGDB/ForgeKB und den Watcher-/Guardian-Runtimes.

**Status: PROVEN & FROZEN — 2026-09-01**
Implementiert unter `libs/bkg-model/src/` (10 Module + Root). 128 Tests. 434 Gesamt-Tests.

Implementierte Punkte:

1. ✓ Artefakt-Lookup per Hash — via `ArtifactSource`-Adaptergrenze in `validator.zig`
2. ✓ `.bkg`-Manifest-Serialisierung — `manifest.zig` (deterministisch, feste Feldreihenfolge)
3. ✓ Hash-Verifikation — `validator.zig` Stufe 1 (content_hash)
4. ✓ Lineage-Verifikation — `validator.zig` Stufe 2 + `lineage.zig`
5. ✓ Authority-Evidence-Prüfung — `validator.zig` Stufe 3
6. ✓ Policy-/Capability-Prüfung — `validator.zig` Stufen 4+6 + `capability.zig`
7. ✓ Eingebettete Testvektoren — `validator.zig` Stufe 5 (inkl. Negativ-Testvektoren)
8. ✓ Deterministische lokale Evaluation — alle Module deterministisch
9. ✓ Read-only Knowledge Snapshot — `knowledge_snapshot.zig`
10. ✓ Materialization/Activation und Retirement — `materializer.zig`
11. ✓ Cache-Invalidierung über Version/Hash — `capability.zig` markOutdated
12. ✓ Evidence-Erzeugung über die exakt verwendete Artefakt-Version — `materializer.generateUsageEvidence()`

Nicht implementiert (explizit bewusst):
- Konkrete BKGDB-Anbindung (Adaptergrenze implementiert)
- P2P-Netzwerk-Reaktivierung (Datenstrukturen vorbereitet)
- Echte Ed25519-Signaturprüfung im Model Layer (referenziert Ledger-Events)
- Watcher-P2P-Implementierung (kommt im nächsten Layer)

Der Model Layer erzeugt keine eigene Autorität und benötigt keinen globalen Zustand.

## 18. Harte Invarianten für die Implementierung

- SOUL-Lineage bleibt historisch erhalten.
- Manifestation darf wechseln.
- Ein Node besitzt keine Evolution.
- Empfang eines Artefakts bedeutet kein Vertrauen.
- Capability ist nicht Authority.
- Reputation ist kein Freifahrtschein.
- Wiederholung darf nicht unbegrenzt denselben Evolutionswert erzeugen.
- Guardians dürfen Überfarming begrenzen.
- Guardians dürfen nicht allein aus Standort oder Reputation eine dauerhafte Wahrheit ableiten.
- Artefakte werden versioniert, niemals still überschrieben.
- Neue Kombinationen erzeugen neue Artefaktidentität.
- Historische Lineage bleibt referenzierbar.

## 19. Designziel

Die Watcher-Runtime bleibt klein.
Die Fähigkeiten des Netzes wachsen nicht primär durch größere Binaries, sondern durch bessere verifizierte `.bkg`-Artefakte und deren Evolution.

Das Ergebnis ist ein verteiltes System, in dem Agenten reisen, beobachten, lernen, Beiträge zur Forge liefern, neue Fähigkeiten materialisieren und dennoch nicht von einem einzelnen Node oder einer einzelnen Predator-Lineage dauerhaft kontrolliert werden können.
