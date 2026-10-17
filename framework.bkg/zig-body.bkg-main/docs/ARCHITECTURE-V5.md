# BKG / eviladmin — Architektur v5

Status: ENTWURF ZUR UMSETZUNG
Stand: 2026-09-01

## 1. Leitidee

BKG ist die native Grundlage des Systems.
eviladmin ist die darauf aufbauende Multi-Tenant-NVIDIA-Orchestrierung.
Beide Projekte bleiben im Workspace alpha getrennt.

Die Plattform ist kein klassischer Coding-Service und keine externe Web3-Anwendung.
Sie ist ein P2P-Netz für Compute, algorithmisches Wissen, Guardians, Watcher und native digitale Assets.

Der zentrale Evolutionskreislauf lautet:
Wissen → Algorithmen → Forge → Guardians → Watcher → Beobachtungen → Forge.

Code ist eine ausführbare Ausdrucksform.
Der primäre Wissenswert des Systems sind Algorithmen, Invarianten, Kompositionsregeln und verifizierte Ergebnisse.

## 2. Workspace-Grenze

/srv/bkg/workspace/bkg-projects/alpha/bkg = BKG Core
/srv/bkg/workspace/bkg-projects/alpha/eviladmin = eviladmin

BKG besitzt P2P, Ledger, DB, Forge, Asset-Modell, Guardian/Watcher-Protokolle und Evolutionslogik.
eviladmin nutzt BKG für Multi-Tenant-Routing, NVIDIA Provider, Keys, Capacity, Pools und API-Orchestrierung.

Keine Vermischung der Repository-Grenzen.
## 3. Forge

Die Forge läuft dauerhaft im BKG-Netz.
Sie schmiedet sowohl neue Algorithmen als auch neue Guardians.

Quellmaterial aus C++, Python, Rust, Zig und weiteren Sprachen wird semantisch extrahiert.
Mehrere Implementierungen desselben Verfahrens werden zu einem sprachunabhängigen Algorithmus-Artefakt zusammengeführt.

Die Forge erzeugt Kandidaten, Tests, Benchmarks und Kompositionsregeln.
Nur verifizierte Ergebnisse dürfen als neue kanonische Fähigkeiten in das Netz gelangen.

Die Forge ist daher nicht nur eine Model-Factory, sondern die permanente Evolutionsschmiede des Systems.

## 4. Guardian-Hierarchie

Peer: stellt Compute und reale Netzwerkaktivität bereit.
Watcher: kleine, mobile Prüf- und Beobachtungseinheit.
Guardian: koordiniert und interpretiert einen Watcher-Pool in einer P2P-Zone.
Hub-Peer: qualifizierter Peer, der ab definiertem Level einen geschmiedeten Guardian beherbergen darf.
Hero: Meta-Evolutionsinstanz für bessere Guardian- und Forge-Verfahren.

Ein User ist niemals Proof, Verifier oder Konsensinstanz.

## 5. Watcher-Netz

Jeder Peer erhält Watcher-Intelligenz; die frühere 25-MB-Grenze ist keine Architektur-Invariante.
Die Modellgröße darf sich abhängig von Hardware, Guardian-Version und Sicherheitsanforderung weiterentwickeln.

Watcher können innerhalb ihrer P2P-Zone zwischen Peers wechseln.
Dadurch entsteht keine dauerhafte Bindung eines Watchers an den beobachteten Peer.
Watcher liefern signierte Beobachtungen und kompakte Evidence an Guardians.

Ein Peer soll nicht allein durch seinen lokalen Watcher seine eigenen wertvollen Claims bestätigen können.
Kritische Aktionen benötigen mehrere unabhängige Watcher/Guardian-Prüfungen und ein Quorum.## 6. P2P-Zonen und Guardian-Pools

Peers werden dynamisch in P2P-Zonen organisiert.
Ein Guardian betreut einen Pool und löst Routing-, Kapazitäts- und Sicherheitsaufgaben innerhalb seiner Zone.
Guardian-Berichte speisen die Forge, wenn neue Fähigkeiten oder Guardians benötigt werden.

Guardian-Versionen sind signierte, versionierte Artefakte mit vollständiger Herkunftskette.
Ein neuer Guardian kann aus früheren Guardians, Algorithmen, Benchmarks und Watcher-Evidence entstehen.

Heroes dienen langfristig als Schmiedekunst für bessere Guardian-Generationen.
Ein Hero muss nicht jeden Peer überwachen; sein Wert liegt in der Verbesserung der Evolutionsverfahren.

## 7. BKGDB und Ledger

BKG erhält eine native Zig-Datenbank mit lokalem State und kryptografischer History.
Mutable State enthält aktuellen Besitz, Sessions, Kapazität, XP, ALGO, BKG, NFT-Zustände und Routingdaten.
Das immutable Ledger enthält Erzeugung, Versionierung, Verifikation, Transfers, Consumption und Evolution.

Jede wichtige Änderung ist hash-verkettet, signiert und einem Checkpoint/Netzwerk-Epoch zugeordnet.
Große Inhalte liegen außerhalb des Ledgers; die Chain trägt Identität, Hashes, Provenance, Events und Zustandsbeweise.

Ziel: nachvollziehbare Historie ohne externe Blockchain-Abhängigkeit.

## 8. Native Asset- und NFT-System

Alle NFTs sind native BKG-Assets und werden von unserer eigenen Sprache und Runtime verstanden.
Keine Pflicht zur Kompatibilität mit ERC-Standards oder externen Chains.

Asset-Klassen umfassen Algorithmus-NFTs, Guardian-NFTs, Watcher-/Capability-NFTs, TPS-NFTs, Batch-NFTs, Capacity-NFTs und License-NFTs.
Nicht übertragbare Identitätsrechte werden als Soul-/gebundene Assets modelliert.

NFT-Operationen sind native Fähigkeiten des Systems: erschaffen, übertragen, teilen, verbinden, einfrieren, widerrufen, verbrauchen, entwickeln und schmieden.

## 9. SOUL NFTs

SOUL NFTs sind an uns als ursprüngliche Netzwerk-Identitäten gebunden.
Ein SOUL ist kein gewöhnlicher handelbarer NFT.
Seine Herkunft, Bindung und Identität sind unveränderbar im Ledger verankert.
SOUL-Rechte können nicht wie TPS- oder Batch-Rechte verkauft werden.

SOULs bilden die Identitätsanker für ausgewählte Netzwerk-, Forge- und Evolutionsrechte.
## 10. LOST NFTs

LOST NFTs sind Fragmente von SOULs.
Sie entstehen, wenn Teile einer SOUL-Historie, Fähigkeit, Provenance oder Identitätsstruktur getrennt werden und nicht mehr vollständig dem ursprünglichen SOUL zugeordnet sind.

Ein LOST NFT darf nicht automatisch als neuer SOUL gelten.
Seine Herkunft bleibt auf das ursprüngliche SOUL und die dazugehörige Ledger-Historie referenziert.

Mehrere LOST-Fragmente können später unter streng definierten Regeln rekonstruiert oder wieder einem SOUL-Kontext zugeordnet werden.
Die Rekonstruktion erzeugt einen neuen Ledger-Eintrag und überschreibt niemals die alte Historie.

## 11. Ökonomie

ALGO ist die interne Algorithmus- und Beitragswährung.
Nachweisbar nützliche algorithmische Arbeit kann XP erzeugen; verifizierte XP können nach Protokoll ALGO erzeugen.

BKG ist die interne Settlement-Währung für Compute und Netzwerkleistungen.
ALGO kann nach den Netzwerkregeln gegen BKG getauscht werden.

TPS-, Batch- und Capacity-NFTs repräsentieren konkrete Compute-Capabilities und können nach ihren Regeln gehandelt, übertragen oder verbraucht werden.
Keine NFT-Menge darf mehr Kapazität repräsentieren als durch Netzwerk- und Capacity-Evidence gedeckt ist.

## 12. Peer-Collateral und Trust

Peers, die handelbare Kapazität oder andere vertrauensrelevante Dienste anbieten, können eine Kaution/Collateral hinterlegen.
Collateral dient als wirtschaftliche Absicherung gegen nachweisbares Fehlverhalten.

Watcher beobachten.
Guardians aggregieren und bewerten.
Quorum entscheidet kritische Zustandsänderungen.
Das Ledger bewahrt die Evidence.

Watcher dürfen nicht allein über ihre eigene Belohnung oder wertvolle Assets entscheiden.

## 13. Sicherheitsinvarianten

Ein Credential darf nur an die autorisierte aktive Session gebunden sein.
Ein unerwarteter zweiter Besitz-/Session-Kontext führt zur Quarantäne nach den Security Policies.
Credential-Sicherheit und Asset-Besitz sind strikt getrennt.

User sind niemals Proofs.
Guardian-/Watcher-Prüfung ersetzt User-Vertrauen.
Kritische Claims benötigen unabhängige Evidence und Quorum.

## 14. Evolution

Algorithmus → Verifikation → XP → ALGO → Compute → neue Daten → neue Algorithmen.

Guardian → Watcher-Erfahrung → Forge → bessere Guardian-Version → neue Beobachtungen.

Hero → bessere Schmiedeverfahren → Forge-Evolution → neue Guardian-Generationen.

Jede Generation bleibt versioniert und genealogisch nachvollziehbar.
Keine erfolgreiche Version wird durch eine spätere Version aus der Historie gelöscht.

## 15. Grundsatz

Das System codet nicht nur.
Es erschafft, prüft, misst, versieht mit Herkunft und entwickelt seine Fähigkeiten weiter.

Die Forge ist permanent.
Die Guardians schützen und koordinieren das Netz.
Die Watcher bewegen sich durch die P2P-Zonen und liefern unabhängige Beobachtungen.
Die Chain bewahrt die Wahrheit der Entwicklung.
Die NFTs machen Fähigkeiten, Rechte und Kapazität zu nativen Assets unserer eigenen Sprache.


## 11. KEY KILLCHAIN V2 — SIGNATURE CONTRADICTION

Die 1:1-Regel bleibt bestehen, wird aber nicht als stumpfes "zweiter Request = Angriff" implementiert.

Ein Key besitzt neben seiner kryptografischen Identität ein fortlaufendes Traffic-/Data-Signature-Profil.
Das Profil beschreibt beobachtbares Verhalten, nicht geheime Inhalte: Peer, Session, Timing, Route, Modellklasse, Größenmuster, Fehlerbild, Netzwerk-Merkmale und weitere sichere Telemetrie.

Der Watcher vergleicht die erwartete Identitätssignatur mit der aktuell beobachteten Traffic-Signatur.
Entscheidend ist die Kontradiktion zwischen beiden.

Normales Verhalten: Identität passt zu Traffic -> Key bleibt ACTIVE.

Auffälliges Verhalten: Identität passt nur teilweise -> Key wird WATCHED und erhält zusätzliche Guardian-Prüfung.

Harte Kontradiktion: Kryptografische Identität ist gültig, aber Traffic-/Daten-Signatur ist mit der gebundenen Nutzung unvereinbar -> COMPROMISED.

Dann greift die Killchain automatisch:
COMPROMISED -> SESSION REVOKE -> KEY QUARANTINE -> ROUTE REMOVE -> CAPABILITY FREEZE -> GUARDIAN ALERT -> LEDGER EVENT.

Der Key wird nicht still weiterverwendet. Neue Requests dieses Keys werden außerhalb der gebundenen Session abgewiesen.

## 12. SIGNATURE MODEL

Die Traffic-Signatur ist kein einzelner Fingerabdruck. Sie ist ein zeitlich gewichtetes Profil mit mehreren unabhängigen Signalen.

Watcher speichern nur das notwendige Minimum für Erkennung und Beweisbarkeit.
Rohdaten und sensible Inhalte werden nicht in den Ledger geschrieben.

Signaturzustände: STABLE, DRIFTING, SUSPICIOUS, CONTRADICTED, COMPROMISED.

Ein einzelner abweichender Messwert reicht nicht für eine Sperre.
Mehrere unabhängige Widersprüche können den Zustand hochstufen.

## 13. SECOND-PEER CHALLENGE

Bei einer starken Abweichung kann ein Watcher seinen lokalen Befund an einen anderen Peer in derselben P2P-Zone geben.
Dieser zweite Watcher bewertet die Beobachtung unabhängig.

Damit entsteht:
LOCAL OBSERVATION -> REMOTE WATCHER CHECK -> GUARDIAN DECISION.

Der User ist niemals Proof oder Verifier.
Watcher und Guardians sind die Vertrauensschicht.

## 14. SECURITY GUARANTEE

Die Sicherheitsregel lautet nicht "IP gewechselt = Angriff" und nicht "Request Nummer 2 = Angriff".

Die harte Regel lautet:
Eine aktive Identität darf nicht gleichzeitig ein widersprüchliches Traffic-Verhalten zeigen, das ihrer gebundenen Nutzung widerspricht.

Je stärker die widersprüchliche Evidenz, desto schneller die Isolation.

Bei bestätigter Kompromittierung werden nicht nur der API-Key, sondern die daran gebundenen aktiven Sessions und noch nicht verbrauchten Compute-Capabilities eingefroren.
Bereits historisch bestätigte Ledger-Einträge bleiben unverändert.

## 15. FALSE-POSITIVE PROTECTION

Netzwerkwechsel, Mobilität, Failover, NAT und legitime Lastspitzen dürfen nicht automatisch als Kompromittierung gelten.

Der Watcher bewertet deshalb Kontext, Zeitfenster und mehrere Signale gemeinsam.
Die Killchain benötigt für harte Entscheidungen eine definierte Evidenzschwelle beziehungsweise Guardian-Quorum-Regel.

Damit bleibt die 1:1-Regel kompromisslos, während normale Nutzerbewegung nicht versehentlich ihre Assets vernichtet.

## 16. GENESIS AUTHORITY

> Spec: `GENESIS_AUTHORITY_v1.md`

Genesis Authority ist der unveränderliche Root-Anker aller protokollarischen Macht im BKG-Host.
Sie ist kein Mutable State, kein Ledger-Event und kein Runtime-Zustand.
Sie existiert vor dem ersten Ledger-Event und außerhalb des Rebuilder-Zustands.

### 16.1 Kernprinzip

```
Evolution   ≠ Authority Origin
Capability  ≠ Authority
Role        ≠ Authority
Lineage     ≠ Authority
```

Kein Harness — unabhängig von Rang, Lineage Resonances oder Capabilities —
kann durch eigene Evolution zur Genesis Authority aufsteigen.

### 16.2 Vertrauensbaum

```
GENESIS
  │
  ├── HOST SOUL ROOT
  │
  ├── FORGE AUTHORITY
  │      └── darf privilegierte Ledger-Events ausstellen
  │
  └── GUARDIAN AUTHORITY SET
         └── darf Quorum-Votes erzeugen
```

Dynamische Delegationen entstehen ausschließlich durch signierte Ledger-Events:

```
Genesis Forge
      │
      ├── authority_delegated ──► Hero A
      │
      └── authority_delegated ──► Demon B
```

### 16.3 Privilegierte Events

Folgende Events dürfen nur von Genesis-autorisierten Schlüsseln signiert werden:

```
artifact_forged
artifact_composed
authority_delegated
authority_revoked
guardian_set_changed
```

### 16.4 Genesis Record als Protokollparameter

Die Genesis gehört nicht in den normalen Mutable State.
Der Rebuilder erhält sie als unveränderlichen Parameter außerhalb des Ledger-Streams:

```
rebuild(genesis_authority, ledger_stream)
```

Kein manipuliertes State-Objekt kann behaupten `forge_pubkey = somebody_else`,
weil der Rebuilder die Genesis Authority bereits vor der Ledger-Verarbeitung kennt.

### 16.5 Fünf Vertrauenswurzeln

| Wurzel | Frage |
|--------|-------|
| **SOUL** | Wer bin ich? |
| **GENESIS AUTHORITY** | Wer darf welche protokollarische Macht ausüben? |
| **LEDGER** | Was ist passiert? |
| **REBUILDER** | Ist es gültig? |
| **DERIVE** | Was bin ich aufgrund meiner Geschichte geworden? |

### 16.6 Vollständiges Vertrauensbild

```
                     GENESIS AUTHORITY
                            │
            ┌───────────────┼────────────────┐
            │                                │
       FORGE ROOT                     GUARDIAN ROOT SET
            │                                │
      artifact_forged                   quorum verdicts
            │                                │
            └───────────────┬────────────────┘
                            ▼
                          BKGDB
                            │
             VERIFY → AUTHORIZE → FOLD
                            │
              MATERIALIZE → DERIVE
                            │
                  Runtime Projection
                            │
                           C2
```

**Genesis Authority besitzt das alleinige Recht, protokollarische Macht zu begründen.**

## 17. CRYPTO BASELINE

> Impl: `bkg/libs/bkg-db/src/crypto/`
> Status: **PROVEN & FROZEN** — 2026-09-01

### 17.1 Schichtung

```
GENESIS AUTHORITY (FROZEN)
    │
LEDGER / REBUILD (FROZEN)
    │
ENVELOPE v1 (FROZEN)   — AEAD, Wire Format, 81-Byte-AAD, Context Binding
    │
KEYRING v1  (FROZEN)   — Key Identity, Lifecycle, Domain/Genesis Binding
    │
WAL ENCRYPTION v1 (FROZEN) — Storage Consumer, 1 Frame = 1 Envelope, Replay/Gap/Order
    │
STATE ENCRYPTION        (Phase 2 — Consumer-Layer, noch nicht implementiert)
```

### 17.2 Verantwortungsgrenze

| Layer | Zuständigkeit |
|-------|---------------|
| **Envelope v1** | ChaCha20Poly1305 AEAD, Wire-Serialisierung, AAD, Context-Prüfung |
| **Keyring v1** | Key Identity (SHA256-Ableitung), Lifecycle (ACTIVE/REVOKED), Domain/Genesis-Binding |
| **WAL/Rebuilder** | Frame-Sequenz-Validierung, Replay-Erkennung, Duplicate-Prüfung |

Kein AEAD im Keyring.
Kein Key-Management im Envelope.
Keine Replay-Erkennung im Envelope oder Keyring.

### 17.3 WAL ENCRYPTION v1 — Architekturvertrag (vorgefroren)

Dieser Vertrag ist eingefroren, bevor WAL-Code geschrieben wird.

#### Invariante 1: Frame-Granularität

```
1 WAL-Frame  →  1 Envelope
```

Keine Verschlüsselung kompletter WAL-Dateien oder Segmente.
Ein beschädigter Frame macht nicht automatisch die gesamte WAL unlesbar.

#### Invariante 2: `sequence` als kryptografische Frame-Identität

`sequence` landet in den 81-Byte-AAD des Envelopes.
Ein Envelope ist damit an genau eine Frame-Position gebunden.
Eine manipulierte Sequence führt zur fehlgeschlagenen Context-Prüfung.

**Wichtige Präzisierung — Replay:**

Ein vollständig unverändert kopierter, bereits authentifizierter Frame hat einen
gültigen AEAD-Tag. AEAD garantiert Integrität und Authentizität, aber
**keine Replay-Erkennung**.

Replay-/Duplicate-Semantik liegt im WAL/Rebuilder-Layer:

```
Envelope:      „Ist dieser Frame kryptografisch authentisch und für Context X bestimmt?"
WAL/Rebuilder: „Ist Sequence X an dieser Stelle zulässig und wurde sie bereits verarbeitet?"
```

Das ist die saubere Trennung. Kein zweiter Kryptolayer.

#### Invariante 3: Rotation ohne Re-Encryption

```
Neuer Frame   → aktuell aktiver Key (lookupActive)
Alter Frame   → ursprüngliche key_id bleibt unverändert
Decrypt alt   → lookupAny findet revoked Key
Re-Encryption → nicht erforderlich, nicht erlaubt
```

Ein Key-Wechsel verändert keine bereits geschriebenen Frames.

#### Encrypt-Pfad

```
WAL Frame
    │
    ▼
encryptWithKeyring(key_id, domain=BKGDB_WAL, sequence=frame_seq, ...)
    │
    ▼
envelope.encrypt(io, allocator, key_material, frame_bytes, ctx)
    │
    ▼
[HEADER_81][CIPHERTEXT_N][TAG_16]
    │
    ▼
WAL append
```

#### Decrypt-Pfad

```
WAL read
    │
    ▼
Envelope → authentifizierter Frame
    │
    ▼
WAL-Sequenz-/Replay-Prüfung (Rebuilder)
    │
    ▼
Rebuilder FOLD
```

### 17.4 SHA256-Unveränderlichkeitsnachweis

Die eingefrorenen Kryptomodule wurden während der WAL-Encryption-Implementierung nicht verändert:

```
SHA256(envelope.zig) = 081af87ff0ab1dad35bb84a964e22f7a282135e79bdce61b51d102c45d276ca4
SHA256(keyring.zig)  = 695061c684ba61fc13a5747321dd2b4a2b8385a40f188459d0196efdaef57578
```

Baseline und Final-Hashes sind identisch. Kryptografisch belegbar.

### 17.5 WAL ENCRYPTION v1 — PROVEN & FROZEN

Implementierung:

```
bkg/libs/bkg-db/src/storage/wal_encrypted.zig
```

E2E-Teststand:

```
38/38 WAL-Encryption-E2E-Tests bestanden
306/306 Gesamt-Tests bestanden (Pass 1)
306/306 Gesamt-Tests bestanden (Pass 2)
```

Belegte Eigenschaften:

- 1 WAL-Frame = 1 Envelope
- ACTIVE-only Encrypt und ACTIVE/REVOKED Decrypt
- Key-Rotation ohne Re-Encryption
- AEAD Context-Binding für Domain, Key-ID, Genesis, Record-Type und Sequence
- Transport-Checksum und Torn-Write-Erkennung
- WAL Sequence Order, ReplayDetected, SequenceGap und SequenceRollback
- Replay-Beweis: byte-identischer Frame bleibt AEAD-authentisch, wird aber von der WAL-Sequenzlogik abgelehnt
- Fehlerpfade leak-frei unter `std.testing.allocator`, einschließlich korrigiertem Transport-Double-Free

**STATUS: BKGDB WAL ENCRYPTION v1 — PROVEN & FROZEN — 2026-09-01**

