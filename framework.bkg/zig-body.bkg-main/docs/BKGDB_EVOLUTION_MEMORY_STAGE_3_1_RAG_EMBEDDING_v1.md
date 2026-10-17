# BKGDB Evolution Memory — Stage 3.1
## Multimodal RAG + Embedding Knowledge Layer

Status: DESIGN CONTRACT — 2026-09-01
Protokollentscheidungen: KANONISCH FESTGELEGT — 2026-09-01 (§A)
Truth Boundary Amendment: KANONISCH FESTGELEGT — 2026-09-01 (§C)
Protokollkorrekturen: §C.3 (Image: BKGP), §C.4 (Audio: 48 kHz), §C.10 (Hash-Hamming-Verbot)
Implementierungsfreigabe: **NOCH NICHT ERTEILT**
Freeze-Status: **NICHT FROZEN** — Implementierung nicht doppelt grün bestätigt
Parent: BKGDB EVOLUTION MEMORY v1
Predecessor: Stage 3.0 — Forge Knowledge (PROVEN & FROZEN Voraussetzung)

**Stage 3.1 darf erst implementiert werden, wenn:**
1. **Stage 3.0 den adversarial Freeze vollständig bestanden hat (Blocker).**
2. **Explizites Go-Signal erteilt wurde — kein automatischer Start nach Stage 3.0 Freeze.**

**Stage 3.1 darf erst als FROZEN markiert werden, wenn:**
1. Vollständige Implementierung aller Module (§3.1.A–§3.1.C oder äquivalente Stufen).
2. `zig build test --summary all` zweimal grün — ohne neue Failures oder Warnings.
3. `git diff --check` clean.
4. SHA256 aller Stage-3.1-Module berechnet und hier dokumentiert.
5. Adversarial Review durchgeführt und alle Befunde behoben oder dokumentiert.
6. §C-Freeze-Rule (§C.16) explizit nachgewiesen: keine verbotenen `Integrity→Truth`-Ableitungen.

Protokoll- und Wire-Vertrag sind festgelegt und dürfen als Designvertrag gelesen werden.
Implementierung: GESPERRT bis explizites Signal.

**Dieser Contract enthält §C (Truth Boundary & Multimodal Provenance Amendment) —
kanonisch festgelegt, bindend für alle Stage-3.1-Implementierungen.**

## Reifegradmatrix

| Komponente | Status |
|------------|--------|
| Kanonische Pipeline (§0) | FESTGELEGT |
| Canonical Media Format (Teil I) | FESTGELEGT |
| Media Segments (Teil II) | FESTGELEGT |
| Tag Set (Teil III) | FESTGELEGT |
| Embedding (Teil IV) | FESTGELEGT |
| Knowledge Snapshot (Teil V) | FESTGELEGT |
| RAG Query / Retrieval Record (Teil VI) | FESTGELEGT |
| Retrieval Evidence (Teil VII) | FESTGELEGT |
| Retrieval Policy (Teil VIII) | FESTGELEGT |
| Domain Registry (Teil XI) | FESTGELEGT |
| Truth Boundary Amendment (§C) | FESTGELEGT |
| Implementierung (Code) | GESPERRT — kein Go-Signal |
| Doppelter Testlauf | AUSSTEHEND |
| Adversarial Review | AUSSTEHEND |
| FROZEN | **NICHT ERTEILT** |

---

## Kanonische Pipeline

```
Quelle (beliebiges Format)
    ↓
Canonicalizer (versioniert, deterministisch)
    ↓
KnowledgeMediaRecord (canonical media_hash)
    ↓
Segmentierung (deterministisch, versioniert)
    ↓
Segments (segment_hash pro Segment)
    ↓
Embedding (EmbeddingRecord, model-bound)
    ↓
KnowledgeSnapshot (root_hash über alle Referenzen)
    ↓
Retrieval (RetrievalRecord, snapshot-bound)
    ↓
RetrievalEvidence (snapshot + query + ergebnisse)
```

**Diese Reihenfolge ist unveränderlich. Keine Abkürzung.**
**Media → Trust ist kein gültiger Pfad.**

---

## Teil I — Kanonische Medienformate (CANONICAL MEDIA FORMAT CONTRACT v1)

### §1 Grundprinzip

Quellformat und kanonisches BKG-Format sind zwei verschiedene Dinge.

Ein Nutzer darf beliebige Quellformate einspeisen:
MP3, WAV, AAC, OGG, FLAC, MP4, MOV, WebM, MKV, AVI,
PNG, JPEG, TIFF, BMP, WebP, GIF,
TXT, Markdown, HTML, PDF, DOCX, JSON usw.

Für die BKG-Identität wird daraus zuerst eine **kanonische Repräsentation** erzeugt.
Erst diese wird gehasht. Erst dieser Hash wird als `media_hash` verwendet.

```
Quelle (beliebiges Format) → Canonicalizer → kanonische Medienbytes → SHA256 → media_hash
```

Die kanonische Repräsentation ist das einzige, was für die Identität zählt.
Zwei Quellen mit identischem kanonischen Inhalt haben denselben `media_hash`.
Eine Quelle mit anderem kanonischen Inhalt hat immer einen anderen `media_hash`.

### §2 Kanonisches Textformat

**Canonical Format:** UTF-8, NFC-normalisiert, ohne BOM.

Normalisierungsregeln:
- Unicode NFC (Canonical Decomposition followed by Canonical Composition)
- Keine BOM (0xEF 0xBB 0xBF am Anfang verboten)
- Zeilenenden: LF (`\n`, 0x0A) — keine CRLF, kein CR
- Trailing Whitespace pro Zeile: entfernt
- Trailing Newline am Dateiende: genau eine LF (kein Doppel-Newline, kein fehlender Newline)

Der kanonische Inhalt ist der normalisierte Byte-Stream.

Hash-Domain: `"BKGT"` (Text)

Versionsfeld: `canonical_format_version = 1` (u16, little-endian)

### §3 Kanonisches Bildformat

**Canonical Format:** PNG, 32-bit RGBA (8 Bit pro Kanal), lossless.

Normalisierungsregeln:
- JPEG, TIFF, BMP, WebP, GIF → vor Hashbildung nach PNG RGBA konvertieren
- Alpha-Kanal für RGB-Quellen: voll opak (0xFF)
- Keine eingebetteten Metadaten (EXIF, XMP, ICC-Profile) im kanonischen Inhalt
- Keine Thumbnails, keine Kommentarblöcke
- Pixelreihenfolge: top-left nach bottom-right, Zeile für Zeile, RGBA
- Bildabmessungen (width, height) als separate Felder, nicht aus PNG-Header abgeleitet
- Skalierung: keine automatische Skalierung; Größe ist Teil der Identität

Der kanonische Inhalt ist der rohe RGBA-Pixel-Byte-Stream (ohne PNG-Container).
Der `media_hash` wird über diesen rohen Stream gebildet.

Hash-Domain: `"BKGI"` (Image)

Versionsfeld: `canonical_format_version = 1` (u16, little-endian)

**Begründung:** Unterschiedliche JPEG-Encoder erzeugen für dieselben Bilddaten
unterschiedliche Bytes. Nur die dekodierte, normalisierte Pixeldarstellung ist eindeutig.

### §4 Kanonisches Audioformat

**Canonical Format:** PCM signed integer, 48 kHz, 24-bit, little-endian, interleaved.

Normalisierungsregeln:
- Alle Eingangsformate (MP3, AAC, OGG, FLAC, WAV mit beliebigem Format) →
  vor Hashbildung in PCM 48 kHz / 24-bit / signed little-endian konvertieren
- Mono: 1 Kanal; Stereo: 2 Kanäle interleaved (L, R, L, R, ...)
- Keine Header-Bytes im kanonischen Inhalt (kein WAV-Header)
- Keine Metadaten (ID3, Vorbis-Comment, FLAC-Tags) im kanonischen Inhalt
- Kanalanzahl ist Teil der Identität (Mono ≠ Stereo)
- Sample-Rate 48 kHz ist fix; andere Sample-Raten müssen resampled werden
  (Resampling-Algorithmus ist Teil der `canonical_format_version`)
- Stille am Anfang/Ende: nicht automatisch entfernt (Länge ist Teil der Identität)

Der kanonische Inhalt ist der rohe PCM-Byte-Stream.
Der `media_hash` wird über diesen rohen Stream gebildet.

Hash-Domain: `"BKGW"` (kanonisch — §39 E2, Registry §XI)

`"BKGA"` (Artifacts, FROZEN) war Kandidat, ist aber belegt.
Kollision aufgelöst durch §39 E2: Audio-Media-Domain ist `"BKGW"`.

Versionsfeld: `canonical_format_version = 1` (u16, little-endian)
Eingebettetes Resampling-Policy-Feld: `resampling_policy_hash` ([32]u8)

### §5 Kanonisches Videoformat

**Canonical Format:** Matroska (`.mkv`), BKG-kanonische Konfiguration v1.

Videostream: FFV1 (lossless), BKG-Profil v1
Audiostream: FLAC (lossless), 48 kHz, 24-bit, identisch mit §4 Audio-Canonical
Container: Matroska, ohne eingebettete Metadaten außer BKG-Pflichtfeldern

BKG-Pflichtfelder im Container (kanonisch, little-endian codiert):
- `bkg_canonical_version`: u16 = 1
- `bkg_video_width`: u32
- `bkg_video_height`: u32
- `bkg_frame_rate_num`: u32 (Zähler)
- `bkg_frame_rate_den`: u32 (Nenner) — rational, nie float
- `bkg_audio_channels`: u8
- `bkg_duration_ns`: i64 (Integer Nanosekunden, nie float)

Normalisierungsregeln:
- Alle Eingangsformate (MP4, MOV, WebM, AVI, ...) → BKG-kanonische MKV-Repräsentation
- Keine eingebetteten Metadaten außer BKG-Pflichtfeldern
- Keine Thumbnails, keine Cover-Art
- Frame-Rate als rationaler Bruch (u32/u32), nie float
- Auflösung: ganzzahlig, nie float

Der `media_hash` wird über den vollständigen BKG-kanonischen MKV-Byte-Stream gebildet.

Hash-Domain: `"BKGV"` (Video)

Versionsfeld: `canonical_format_version = 1` (u16, little-endian)
Eingebettetes Policy-Feld: `canonicalization_policy_hash` ([32]u8)

**Begründung:** Die Canonicalization Policy ist selbst versioniert und hashbar.
Eine Änderung der Konvertierungsparameter erzeugt automatisch eine neue Identität.

### §6 Zeitdarstellung

**Alle Zeitangaben in BKG-Protokollstrukturen sind Integer-Nanosekunden (i64).**

```
Zeit = i64 (Nanosekunden seit Unix-Epoch)
```

- Keine `f32`/`f64` als Zeitidentitätsfeld
- Keine plattformabhängigen Zeittypen
- `start_ns: i64` — Segmentstart in Nanosekunden
- `end_ns: i64` — Segmentende in Nanosekunden
- Beide Werte müssen deterministisch und reproduzierbar sein
- `start_ns >= 0` für alle gültigen Zeitangaben
- `end_ns > start_ns` für alle gültigen Segmente

Little-endian encoding für alle Zeitfelder in kanonischen Strukturen.

### §7 Canonical Format Version Policy

- Jede Änderung am Canonicalization-Algorithmus erzeugt eine neue `canonical_format_version`
- Neue Version → neue Identität (neuer `media_hash`)
- Keine stille Überschreibung alter Identitäten
- Keine nachträgliche „Bequemlichkeitsänderung" an bestehenden kanonischen Formaten
- Versionsfelder sind Teil des kanonischen Records und werden mitgehasht

---

## Teil II — Objektmodell

### §8 KnowledgeMediaRecord

Generischer kanonischer Eintrag für alle Modalitäten.

```
KnowledgeMediaRecord {
    domain_prefix:            [4]u8    // "BKGZ" (kanonisch — §39 E3, Registry §XI)
    media_hash:               [32]u8   // SHA256("BKGZ" || canonical_bytes)
    media_kind:               u8       // MediaKind enum
    canonical_format_version: u16      // little-endian
    source_hash:              [32]u8   // SHA256 der Originalquelle (Provenance)
    provenance_hash:          [32]u8   // SHA256(Herkunftsbeweis-Kette)
    lineage_hash:             [32]u8   // Abstammungsreferenz
    content_size:             u64      // Größe der kanonischen Darstellung in Bytes
    metadata_hash:            [32]u8   // SHA256 der modality-spezifischen Metadaten
    knowledge_epoch:          u64      // Forge-Epoch zum Zeitpunkt der Aufnahme
    origin_event_hash:        [32]u8   // Ledger-Event-Hash (ZERO = kein Beweis)
    canonicalization_policy_hash: [32]u8 // Hash des verwendeten Canonicalizers
}
```

`media_kind` Enum (u8):
```
text  = 1
image = 2
audio = 3
video = 4
// Werte 5–255 für zukünftige BKG-definierte Medienformen reserviert
```

Keine implizite Typableitung aus Dateiendung.
Die semantische Identität kommt ausschließlich aus dem kanonischen Record.

### §9 Text-spezifische Metadaten

```
TextMediaMetadata {
    normalization_version: u16   // NFC-Version, Whitespace-Regel-Version
    encoding_version:      u16   // UTF-8 Encoding-Regelversion
    line_ending_policy:    u8    // 1 = LF-only
    byte_length:           u64   // Länge des normierten UTF-8-Streams
}
```

### §10 Image-spezifische Metadaten

```
ImageMediaMetadata {
    width:  u32
    height: u32
    channels: u8        // 4 = RGBA (kanonisch)
    bit_depth_per_channel: u8  // 8 (kanonisch)
    normalization_policy_hash: [32]u8
}
```

### §11 Audio-spezifische Metadaten

```
AudioMediaMetadata {
    sample_rate:              u32   // 48000 (kanonisch)
    channels:                 u8    // 1 = mono, 2 = stereo
    bit_depth:                u8    // 24 (kanonisch)
    byte_order:               u8    // 1 = little-endian
    duration_ns:              i64   // Gesamtlänge in Nanosekunden
    resampling_policy_hash:   [32]u8
}
```

### §12 Video-spezifische Metadaten

```
VideoMediaMetadata {
    width:                    u32
    height:                   u32
    frame_rate_num:           u32   // Zähler (rational)
    frame_rate_den:           u32   // Nenner (rational)
    duration_ns:              i64   // Gesamtlänge in Nanosekunden
    audio_presence:           u8    // 0 = kein Audio, 1 = Audio vorhanden
    audio_channels:           u8
    canonicalization_policy_hash: [32]u8
}
```

### §13 KnowledgeChunk (Text)

```
KnowledgeChunk {
    domain_prefix:         [4]u8    // "BKGK"
    chunk_hash:            [32]u8   // SHA256("BKGK" || parent_media_hash || chunk_index_le8 || canonical_content)
    parent_media_hash:     [32]u8
    chunk_index:           u64      // 0-basiert, deterministisch
    chunking_version:      u16
    normalization_version: u16
    byte_start:            u64      // Byteoffset im normierten Text
    byte_end:              u64
    parent_context_hash:   [32]u8   // Hash der umliegenden Chunks für Kontextrekonstruktion
    content_size:          u32      // Größe des Chunk-Inhalts in Bytes
}
```

Chunk-Reihenfolge ist semantisch relevant. Keine HashMap-basierte Reihenfolge.
Chunking-Version ist Teil der Identität.

### §14 AudioSegment

```
AudioSegment {
    domain_prefix:     [4]u8    // "BKGP" (kanonisch — §39 E3, Registry §XI)
    segment_hash:      [32]u8   // SHA256("BKGP" || parent_media_hash || segment_index_le8 || start_ns_le8 || end_ns_le8)
    parent_media_hash: [32]u8
    segment_index:     u64
    start_ns:          i64      // Integer-Nanosekunden
    end_ns:            i64
    sample_count:      u64      // Anzahl Samples in diesem Segment
    segmentation_version: u16
    transcript_hash:   [32]u8   // ZERO = kein Transkript
    acoustic_feature_hash:  [32]u8   // ZERO = nicht berechnet
    speaker_feature_hash:   [32]u8   // ZERO = nicht berechnet
    semantic_feature_hash:  [32]u8   // ZERO = nicht berechnet
}
```

Transkript ist NICHT automatisch Truth.
Eine Transkription ist ein abgeleitetes Wissensartefakt mit eigener Provenance (→ §22).

### §15 VideoSegment

```
VideoSegment {
    domain_prefix:       [4]u8    // "BKGJ" (kanonisch — §39 E3, Registry §XI)
    segment_hash:        [32]u8   // SHA256("BKGJ" || parent_media_hash || segment_index_le8 || start_ns_le8 || end_ns_le8)
    parent_media_hash:   [32]u8
    segment_index:       u64
    start_ns:            i64
    end_ns:              i64
    frame_count:         u64
    segmentation_version: u16
    // Abgeleitete Wissenspfade (ZERO = nicht berechnet):
    visual_feature_hash:    [32]u8
    transcript_hash:        [32]u8
    audio_feature_hash:     [32]u8
    multimodal_embed_hash:  [32]u8
}
```

Jeder abgeleitete Wissenspfad besitzt eigene Identity und Provenance.
Ein Video-Segment darf mehrere parallele abgeleitete Pfade haben.

### §16 ImageSegment (Region of Interest)

```
ImageSegment {
    domain_prefix:     [4]u8    // "BKGX" (kanonisch — §39 E3, Registry §XI)
    segment_hash:      [32]u8   // SHA256("BKGX" || parent_media_hash || segment_index_le8 || x_le4 || y_le4 || w_le4 || h_le4)
    parent_media_hash: [32]u8
    segment_index:     u64
    x:                 u32      // Pixel-Koordinate (top-left origin)
    y:                 u32
    width:             u32
    height:            u32
    visual_feature_hash: [32]u8   // ZERO = nicht berechnet
    ocr_artifact_hash:   [32]u8   // ZERO = kein OCR
    caption_artifact_hash: [32]u8 // ZERO = keine Caption
}
```

OCR und Caption sind abgeleitete Artefakte, keine ursprüngliche Wahrheit (→ §22).

### §17 FrameSample (Video)

```
FrameSample {
    domain_prefix:        [4]u8    // "BKGF" (kanonisch — §39 E3, Registry §XI)
    frame_hash:           [32]u8   // SHA256("BKGF" || source_media_hash || frame_index_le8 || timestamp_ns_le8)
    source_media_hash:    [32]u8
    frame_index:          u64
    timestamp_ns:         i64
    sampling_policy_hash: [32]u8   // Versioniertes Frame-Sampling-Policy
    width:                u32
    height:               u32
}
```

Frame-Sampling ist versioniert.
Keine zufällige Frame-Auswahl. Keine GPU-/CPU-spezifische Auswahl.
`sampling_policy_hash` ist Teil der Frame-Identität.

---

## Teil III — Embedding

### §18 EmbeddingRecord (monomodal)

```
EmbeddingRecord {
    domain_prefix:       [4]u8    // "BKGD" (kanonisch — §39 E4, Registry §XI)
    embedding_id:        [32]u8   // SHA256("BKGD" || media_hash || segment_hash || model_id || model_version_le2 || modality)
    media_hash:          [32]u8
    segment_hash:        [32]u8   // ZERO wenn ganzes Medium (kein Segment)
    modality:            u8       // MediaKind: 1=text, 2=image, 3=audio, 4=video
    model_id:            [32]u8   // SHA256 des Modell-Artefakts
    model_version:       u16
    dimension:           u32
    normalization:       u8       // 0=none, 1=L2, 2=softmax
    vector_hash:         [32]u8   // SHA256 der tatsächlichen Vektorbytes
    tag_set_hash:        [32]u8   // ZERO = keine Tags
    provenance_hash:     [32]u8
    creation_epoch:      u64
}
```

Text-, Audio-, Video- und Bild-Embeddings dürfen nicht allein anhand des Vektors identifiziert werden.
Der Vektor selbst ist kein Identifier.

### §19 MultimodalEmbeddingRecord

```
MultimodalEmbeddingRecord {
    domain_prefix:          [4]u8    // "BKGO" (kanonisch — §39 E3, Registry §XI)
    embedding_id:           [32]u8   // SHA256("BKGO" || alle input_source_hashes || model_id || fusion_policy_hash)
    // Input-Modalitäten und Quellen
    input_count:            u8       // Anzahl der Eingabemodalitäten (≥ 2)
    input_modalities:       [8]u8    // MediaKind-Werte, 0-padded
    input_source_hashes:    [8][32]u8 // media_hash oder segment_hash pro Eingabe
    // Modell und Policy
    model_id:               [32]u8
    model_version:          u16
    fusion_policy_hash:     [32]u8   // Wie werden Modalitäten kombiniert?
    alignment_version:      u16      // Alignment-Modell-Version
    // Ergebnis
    dimension:              u32
    normalization:          u8
    vector_hash:            [32]u8
    provenance_hash:        [32]u8
    creation_epoch:         u64
}
```

Unterstützte multimodale Paarungen (nicht-exhaustiv):
- Audio ↔ Text
- Video ↔ Text
- Bild ↔ Text
- Video ↔ Audio
- Video ↔ Text ↔ Audio

Keine implizite Vermischung verschiedener Modelle.
Kein unsichtbar installiertes Modell als Teil der Vertrauensbasis (→ §17 Modellartefakt).

### §20 Embedding-Invarianten

1. Embedding ohne Modell-/Versionsbindung: **ABORTED**
2. Embedding ohne Source-Bindung (media_hash): **ABORTED**
3. Multimodales Embedding ohne Input-Lineage: **ABORTED**
4. Semantische Ähnlichkeit erzeugt keine Identity, Authority, Truth, Reputation, Capability
5. Distance-/Similarity-Scores sind Retrieval-Metriken — nicht mehr

---

## Teil IV — Abgeleitete Artefakte und Provenance

### §21 Provenance-Kette

Jedes abgeleitete Artefakt muss seinen Ursprung vollständig referenzieren.

Beispiel Video-Pfad:
```
Video (media_hash)
    → VideoSegment (segment_hash)
        → FrameSample (frame_hash, sampling_policy_hash)
            → OCR-Artefakt (ocr_artifact_hash, source = frame_hash)
                → Caption (caption_artifact_hash, source = ocr_artifact_hash)
                    → Embedding (embedding_id, source = caption)
```

Beispiel Audio-Pfad:
```
Audio (media_hash)
    → AudioSegment (segment_hash, start_ns, end_ns)
        → Transkript (transcript_hash, model_id, source = segment_hash)
            → KnowledgeChunk (chunk_hash, source = transcript_hash)
                → Embedding (embedding_id, source = chunk_hash)
```

Jedes Glied ist separat hashbar.
Keine Herkunftsverkürzung.

### §22 TranscriptRecord

```
TranscriptRecord {
    domain_prefix:      [4]u8    // "BKGU" (kanonisch — §39 E3, Registry §XI)
    transcript_hash:    [32]u8   // SHA256("BKGU" || source_media_hash || segment_hash || model_id || model_version_le2 || language)
    source_media_hash:  [32]u8
    segment_hash:       [32]u8   // ZERO wenn gesamtes Medium transkribiert
    model_id:           [32]u8
    model_version:      u16
    language:           [8]u8    // BCP-47 ASCII-kodiert, ZERO-padded (z.B. "de\0\0\0\0\0\0")
    provenance_hash:    [32]u8
    content_hash:       [32]u8   // SHA256 des transkribierten Texts
    creation_epoch:     u64
}
```

Ändert sich die Transkriptionsmethode → neue Identity.
Kein Überschreiben eines alten Transkripts.
Transkript ist kein Truth-Beweis — nur abgeleitetes Wissensartefakt.

---

## Teil V — Retrieval

### §23 KnowledgeQuery

```
KnowledgeQuery {
    domain_prefix:        [4]u8    // "BKGQ"
    query_hash:           [32]u8   // SHA256("BKGQ" || query_modality || query_content_hash || model_id || snapshot_hash)
    query_modality:       u8       // MediaKind der Query-Eingabe
    query_content_hash:   [32]u8   // SHA256 des normierten Query-Inhalts
    query_embedding_hash: [32]u8   // EmbeddingRecord.embedding_id für diese Query
    model_id:             [32]u8
    model_version:        u16
    normalization:        u8
    snapshot_hash:        [32]u8   // KnowledgeSnapshot.root_hash — Pflichtfeld
    retrieval_policy_hash: [32]u8
    tag_filter_hash:      [32]u8   // ZERO = kein Tag-Filter
}
```

Query ohne Snapshot-Bindung ist ungültig → **ABORTED**.

### §24 SegmentRetrievalResult

```
SegmentRetrievalResult {
    media_hash:    [32]u8
    segment_hash:  [32]u8   // ZERO wenn ganzes Medium (kein Segment)
    modality:      u8
    start_ns:      i64      // ZERO wenn nicht zeitlich
    end_ns:        i64
    embedding_id:  [32]u8
    score_fixed:   u64      // Festkomma: round(similarity * 1_000_000) — §39 E8
    rank:          u32
}
```

Treffer auf Segmentebene, nicht nur auf Medium-Ebene.
Ein Guardian kann nachvollziehen: „Dieser Teil von Video X war relevant."

Score-Darstellung (§39 E8):
- `score_fixed` = `round(similarity_score * 1_000_000)`, Typ `u64`
- Float nur für interne Berechnung; vor Persistenz und Hashing deterministisch quantisiert
- Maximum `1_000_000` = perfekte Ähnlichkeit; Minimum `0` = keine Ähnlichkeit
- Für Ranking und Identität gilt ausschließlich `rank` (u32)
- Tie-Break-Regel ist Teil der `retrieval_policy_hash`

### §25 RetrievalRecord

```
RetrievalRecord {
    domain_prefix:           [4]u8    // "BKGR"
    retrieval_hash:          [32]u8   // SHA256("BKGR" || query_hash || snapshot_hash || alle result_hashes)
    query_hash:              [32]u8
    snapshot_hash:           [32]u8
    retrieval_policy_hash:   [32]u8
    result_count:            u8       // Anzahl Ergebnisse (≤ MAX_RETRIEVAL_RESULTS)
    results:                 [MAX_RETRIEVAL_RESULTS]SegmentRetrievalResult
    retrieval_epoch:         u64
    // Source-Concentration-Metriken (für Guardian/Nebel-Analyse)
    unique_source_count:     u32
    unique_media_count:      u32
    unique_modality_count:   u8
    dominant_source_hash:    [32]u8   // Source mit den meisten Treffern
    dominant_source_hits:    u32
}
```

`MAX_RETRIEVAL_RESULTS = 64` (kanonisch — §39 E6)

---

## Teil VI — Snapshot und Evidence

### §26 KnowledgeSnapshot (multimodal)

```
KnowledgeSnapshot {
    domain_prefix:        [4]u8    // "BKGN" (kanonisch — §39 E3, Registry §XI)
    root_hash:            [32]u8   // SHA256("BKGN" || alle referenzierten Hashes kanonisch sortiert)
    snapshot_epoch:       u64
    embedding_model_hash: [32]u8
    chunking_version:     u16
    retrieval_policy_hash: [32]u8
    // Referenzierte Wissensarten (counts + Merkle-ähnlicher Hash)
    document_count:       u32
    chunk_count:          u32
    image_count:          u32
    audio_segment_count:  u32
    video_segment_count:  u32
    transcript_count:     u32
    embedding_count:      u32
    // Hashes der Referenzmengen (deterministisch sortiert und gehasht)
    documents_hash:       [32]u8
    chunks_hash:          [32]u8
    images_hash:          [32]u8
    audio_segments_hash:  [32]u8
    video_segments_hash:  [32]u8
    transcripts_hash:     [32]u8
    embeddings_hash:      [32]u8
    // Policy
    canonicalization_policy_hash: [32]u8
}
```

Der Snapshot Root Hash bindet die **komplette** verwendete Wissensbasis.
Kein Retrieval ohne Snapshot-Bindung.

### §27 RetrievalEvidence

```
RetrievalEvidence {
    domain_prefix:          [4]u8    // "BKGY" (kanonisch — §39 E3, Registry §XI)
    evidence_hash:          [32]u8   // SHA256("BKGY" || query_hash || retrieval_hash || snapshot_hash)
    query_hash:             [32]u8
    query_modality:         u8
    snapshot_hash:          [32]u8
    retrieval_policy_hash:  [32]u8
    model_id:               [32]u8
    model_version:          u16
    retrieval_hash:         [32]u8   // RetrievalRecord.retrieval_hash
    result_count:           u8
    // Aggregierte Referenzen (kanonisch sortiert):
    source_hashes:          [MAX_EVIDENCE_SOURCES][32]u8
    lineage_hashes:         [MAX_EVIDENCE_SOURCES][32]u8
    tag_hashes:             [MAX_EVIDENCE_TAGS][32]u8
    source_count:           u8
    tag_count:              u8
    creation_epoch:         u64
}
```

`MAX_EVIDENCE_SOURCES = 32` (kanonisch — §39 E7)
`MAX_EVIDENCE_TAGS = 16` (kanonisch — §39 E7a)

---

## Teil VII — Cross-Modal Retrieval

### §28 Cross-Modal Query-Paarungen

Zulässige Query → Ergebnis Paarungen (nicht-exhaustiv):

| Query-Modalität | Ergebnis-Modalität | Hinweis |
|---|---|---|
| text | text | klassisch |
| text | image | Text-Query → Bild-Ergebnisse |
| text | audio | Text-Query → Audiosegmente |
| text | video | Text-Query → Videosegmente |
| audio | text | Audiosegment → Textpassagen |
| audio | audio | Audiosegment → ähnliche Audiosegmente |
| video | text | Videosegment → Textpassagen |
| video | audio | Videosegment → ähnliche Audiosegmente |
| image | text | Bild → Textpassagen |
| image | image | Bild → ähnliche Bilder |

Die Query-Identity muss immer die Query-Modalität enthalten (→ §23 KnowledgeQuery.query_modality).

### §29 Cross-Modal Invarianten

1. Keine Modalität erhält automatisch höhere Vertrauensstufe
2. Keine Textquelle dominiert automatisch Bild/Audio/Video
3. Keine einzelne Modalität darf allein Authority erzeugen
4. Cross-Modal-Similarity ist Retrieval-Metrik — kein Trust-Transfer

---

## Teil VIII — Tags

### §30 Tag-System

Tags gelten modalitätsübergreifend.

```
TagRecord {
    tag_hash:  [32]u8   // SHA256("BKGTAG" || tag_kind || tag_value_hash)
    tag_kind:  u8       // TagKind enum
    value_hash: [32]u8  // SHA256 des normierten Tag-Werts
}
```

TagKind (u8):
```
domain          = 1
capability      = 2
source_family   = 3
modality        = 4
risk_class      = 5
temporal_role   = 6
evolution_role  = 7
// 8–255 reserviert
```

`Tag != Truth`
`Tag != Authority`

Tags sind Kontext, keine Autorisierung.

---

## Teil IX — Poisoning- und Konzentrations-Metriken

### §31 Messbare Konzentrations-Signale

RAG sanktioniert in Stage 3.1 nichts. Sie bewahrt Messgrundlagen.
Die folgenden Signale müssen aus RetrievalRecord und RetrievalEvidence rekonstruierbar sein:

| Signal | Messbar über |
|---|---|
| Viele Treffer aus derselben Quelle | `dominant_source_hits` / `result_count` |
| Viele Treffer aus derselben Lineage | `lineage_hashes`-Konzentration in Evidence |
| Viele Treffer aus demselben Medium | `dominant_media_hash` |
| Viele Treffer aus derselben Modalität | `unique_modality_count` |
| Viele Treffer aus demselben Modell | `model_id` im EmbeddingRecord |

### §32 Adversarial Test-Matrix (Stage 3.1)

Tests müssen folgende Angriffsmuster nachweislich erkennen:

| Angriffsmuster | Test-Beschreibung |
|---|---|
| duplicate video segments | Gleiche Videosegmente mehrfach eingespeist → gleicher segment_hash erkannt |
| near duplicate audio | Minimal-veränderte Audiosegmente → verschiedene segment_hash, Konzentration messbar |
| copied images | Identische Bilder → gleicher media_hash, Konzentration erkannt |
| transcript spam | Massenhaft Transkripte derselben Quelle → source_concentration messbar |
| frame spam | Massenhaft ähnliche Frames → sampling_policy_hash divergiert |
| same-source multimedia flood | Viele Medien derselben source_hash → dominant_source_hits hoch |
| same-lineage multimedia flood | Viele Medien derselben lineage_hash → Lineage-Konzentration in Evidence |
| modality flooding | Viele Einträge einer Modalität → unique_modality_count niedrig |
| cross-modal ranking manipulation | Rankingreihenfolge manipuliert → deterministischer Tie-Break schlägt an |
| timestamp manipulation | Nicht-ganzzahlige/negative Timestamps → ABORTED |

---

## Teil X — Abort-Kriterien

### §33 Sofortige ABORTED-Bedingungen

Implementierung muss sofort als **ABORTED** gemeldet werden bei:

**Canonicalization:**
- Nondeterministisches Frame-Sampling (kein `sampling_policy_hash`)
- Nondeterministische Audiosegmentierung
- Nondeterministisches Text-Chunking
- Float-Zeitangabe als Identitätsfeld (`f32`/`f64` statt `i64`)
- Nicht reproduzierbares Timestamp-Encoding

**Embedding:**
- Embedding ohne Source-Bindung (`media_hash` fehlt)
- Embedding ohne Modell-/Versionsbindung
- Multimodales Embedding ohne vollständige Input-Lineage
- Unklare Float-/Vector-Repräsentation im Identitätsfeld

**Retrieval:**
- Retrieval ohne Snapshot-Bindung (`snapshot_hash` ZERO oder fehlend)
- Externe Vector-DB-Abhängigkeit
- Externe AI-API
- Semantischer Trust aus Similarity

**Provenance:**
- Anonymes abgeleitetes Artefakt (kein `provenance_hash`, kein `source_hash`)
- Herkunftsverkürzung (Kette unterbrochen)

**Authority:**
- Authority aus Embedding
- Capability aus Retrieval-Ergebnis
- Trust-Transfer durch semantische Ähnlichkeit

**Frozen-Module:**
- Jede Änderung an einem FROZEN-Modul
- Hash-Baseline eines FROZEN-Moduls verändert
- Testregression in existierendem Test

---

## Teil XI — Domain-Prefix-Registry (KANONISCH — 2026-09-01)

**Alle Domain-Prefixe sind exakt 4 Bytes `[4]u8`. Keine Ausnahmen.**

Kein bereits belegter Code darf für einen anderen Zweck wiederverwendet werden.
Jede Kollision ist ein Protokollfehler. Das Register ist die einzige kanonische Quelle.

### Harte Domain-Freeze-Regel (kanonisch — 2026-09-01)

> **Eine bereits registrierte Domain darf niemals umgewidmet werden.**
> Eine neue semantische Klasse bekommt einen neuen 4-Byte-Code und eine neue Protokollversion.

Konsequenzen:
- `"BKGM"` = Manifest Magic (FROZEN) — für immer. Kein anderer Zweck. Nie.
- `"BKGS"` = Spore + Snapshot (FROZEN) — für immer. Kein anderer Zweck. Nie.
- `"BKGE"` = Agent-Lineage (Stage 4) — für immer, sobald Stage 4 frozen ist.
- Jeder neue Stage bekommt einen eigenen Repository-Scan vor dem ersten Commit.
- Ein Agent, der eine bestehende Domain umwidmen würde, meldet sofort **ABORTED**.
- „Temporäre Umbelegung" existiert nicht. Es gibt keine temporären Domain-Codes.

### Vollständiger Repository-Scan (Stand: Stage 3.0/4 Freeze)

Scan-Ergebnis aus `grep -rn '"BKG[A-Z]"' libs/ --include="*.zig"`:

| Code | Belegt durch | Datei | Status |
|---|---|---|---|
| `"BKGA"` | Artifact-Store, Domain-Separation-Hash | `evolution/artifact_store.zig` | **FROZEN** |
| `"BKGC"` | ForgeCandidate | `evolution/forge_knowledge.zig` | **FROZEN** |
| `"BKGE"` | Agent-Lineage | `evolution/agent_lineage.zig` | Stage 4, nicht frozen |
| `"BKGL"` | Lineage-Index | `evolution/lineage_index.zig` | **FROZEN** |
| `"BKGM"` | Manifest Magic Bytes | `bkg-model/src/manifest.zig` | **FROZEN** |
| `"BKGS"` | Spore-Store + Snapshot-Domain (Model Layer) | `evolution/spore_store.zig`, `bkg-model/src/knowledge_snapshot.zig` | **FROZEN** (beide) |

**Alle 6 belegten Codes sind damit gesperrt für neue Verwendungen.**

### Kanonische Domain-Registry (vollständig, 2026-09-01)

| Code | Domäne | Vergeben in Stage | Unveränderlich ab |
|---|---|---|---|
| `"BKGA"` | Artifact-Store | Stage 1 | FROZEN |
| `"BKGC"` | ForgeCandidate / Candidate-Hash | Stage 3.0 | FROZEN |
| `"BKGE"` | Agent-Lineage | Stage 4 | nach Stage 4 Freeze |
| `"BKGL"` | Lineage-Index | Stage 2 | FROZEN |
| `"BKGM"` | Manifest Magic (Model Layer) | Model Layer v1 | FROZEN |
| `"BKGS"` | Spore-Store + Knowledge-Snapshot-Domain | Stage 1 + Model Layer v1 | FROZEN |
| `"BKGD"` | Embedding / Dense Vector Identity | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGF"` | Frame Sample | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGI"` | Image-Media (kanonischer Pixelstream) | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGK"` | Knowledge-Chunk (Text) | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGN"` | Knowledge-Snapshot (multimodal) | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGO"` | Multimodal-Embedding | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGP"` | Audio-Segment | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGQ"` | Knowledge-Query | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGR"` | Retrieval-Record | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGT"` | Text-Media (kanonischer UTF-8-Stream) | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGU"` | Transcript-Record | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGV"` | Video-Media (BKG-kanonisches MKV) | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGW"` | Audio-Media / Wave-PCM (kanonisch) | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGX"` | Image-Segment (Region of Interest) | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGY"` | Retrieval-Evidence | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGZ"` | Media-Record (generisch, KnowledgeMediaRecord) | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGH"` | Tag-Record | Stage 3.1 | nach Stage 3.1 Freeze |
| `"BKGJ"` | Video-Segment | Stage 3.1 | nach Stage 3.1 Freeze |

**Nicht vergeben / reserviert:** `"BKGB"`, `"BKGG"`, `"BKGI"` bis `"BKGZ"` (außer den obigen)

### Registry-Invarianten

1. Kein Code darf zwei Verwendungen haben — niemals, nicht temporär, nicht „solange noch nicht frozen"
2. Neue Codes werden ausschließlich in diesem Register eingetragen, bevor sie in Code erscheinen
3. Jede Stage-Implementierung prüft vor Beginn gegen dieses Register
4. Ein Agent, der einen Code verwenden will, der nicht in der Registry steht, meldet **ABORTED**
5. Ein Agent, der einen bereits belegten Code neu vergeben würde, meldet **ABORTED**

---

## Teil XII — Speicher-Architektur

### §34 Was BKGDB speichert

BKGDB speichert in Stage 3.1:
- `KnowledgeMediaRecord` (Metadaten, Hashes, Provenance)
- Segment Records (Audio/Video/Image)
- `KnowledgeChunk` (Text-Chunks)
- `TranscriptRecord`
- `EmbeddingRecord` + `MultimodalEmbeddingRecord`
- `KnowledgeSnapshot`
- `RetrievalRecord`
- `RetrievalEvidence`

Große Rohmedien (Videodateien, Audiodateien, Bilder) liegen außerhalb des normalen
Record-Layouts. Der BKGDB-Ledger trägt nur kanonische Identität, Hashes,
Provenance und Zustandsbeweise.

Keine externe Vector-DB.
Keine externe Media-DB.

### §35 Embedding-Vektor-Speicherung

Embedding-Vektoren selbst (float-Arrays) liegen außerhalb des Ledgers.
Der `EmbeddingRecord` trägt nur den `vector_hash` — den SHA256 der Vektorbytes.
Der tatsächliche Vektor ist ein Blob, adressiert über seinen Hash.

Die Retrieval-Engine arbeitet gegen diese Blobs.
BKGDB speichert nur die kanonischen Identitätsfelder und Nachweise.

---

## Teil XIII — Modellartefakt-Bindung

### §36 Embedding-Modell als `.bkg`-Artefakt

Jedes Embedding-Modell muss als `.bkg`-Artefakt referenzierbar sein:

```
Embedding Model → .bkg Artifact → content_hash → model_id in EmbeddingRecord
```

Kein unsichtbar installiertes Modell darf Teil der kanonischen Vertrauensbasis sein.

Der `model_id` in `EmbeddingRecord` ist der `content_hash` des Modell-Artefakts.

Die Forge ist zuständig für die Schmiedung und Registrierung von Embedding-Modellen
als `.bkg`-Artefakte.

---

## Teil XIV — Acceptance-Kriterien (Stage 3.1 Freeze)

### §37 Pflicht-Tests

Stage 3.1 darf erst gefrozen werden, wenn folgende Tests **zweimal** vollständig grün sind:

**Canonical Format:**
- [ ] Text: UTF-8 NFC-Normalisierung deterministisch und reproduzierbar
- [ ] Image: PNG RGBA Pixelstream-Hash deterministisch
- [ ] Audio: PCM 48kHz/24bit Byte-Stream-Hash deterministisch
- [ ] Video: BKG-kanonische MKV-Repräsentation deterministisch
- [ ] Zeitdarstellung: Integer-Nanosekunden, keine float-Identitätsfelder
- [ ] Canonical Format Version: Versionsänderung → neue Identität

**Content Identity:**
- [ ] Gleicher kanonischer Inhalt → gleicher `media_hash` (alle Modalitäten)
- [ ] Veränderte Pixel → anderer `media_hash`
- [ ] Veränderte Samples → anderer `media_hash`
- [ ] Veränderte Frames → anderer `media_hash`

**Chunking (Text):**
- [ ] Chunk-Hash deterministisch
- [ ] Chunk-Index und Normalisierungs-Version gebunden
- [ ] Gleiche Chunk-Reihenfolge bei gleicher Eingabe

**Segment Identity:**
- [ ] AudioSegment: start_ns/end_ns Integer, reproduzierbar
- [ ] VideoSegment: start_ns/end_ns Integer, reproduzierbar
- [ ] FrameSample: timestamp_ns Integer, sampling_policy_hash gebunden
- [ ] Temporale Identität: Timestamps als i64, kein float

**Embedding:**
- [ ] Embedding-Hash und Modell-Hash gebunden
- [ ] Dimensions-/Format-Mismatch → abgelehnt
- [ ] Embedding ohne Modell-Bindung → ABORTED
- [ ] Embedding ohne Source-Bindung → ABORTED
- [ ] Multimodales Embedding ohne Input-Lineage → ABORTED
- [ ] Embedding ≠ Authority (Test: kein Capability-Effekt aus Embedding)

**Retrieval:**
- [ ] Query-Hash deterministisch
- [ ] Retrieval-Tie-Break deterministisch
- [ ] Snapshot-Tampering erkannt
- [ ] Retrieval-Tampering erkannt
- [ ] Falsches Modell erkannt
- [ ] Retrieval ohne Snapshot → ABORTED
- [ ] Retrieval ≠ Truth (Test)

**Cross-Modal:**
- [ ] Text Query → Image Retrieval
- [ ] Text Query → Audio Retrieval
- [ ] Text Query → Video Retrieval
- [ ] Audio Query → Text Retrieval
- [ ] Video Query → Text Retrieval
- [ ] Image Query → Text Retrieval

**Provenance:**
- [ ] Vollständige Provenance rekonstruierbar (Video→Frame→OCR→Caption→Embedding)
- [ ] Vollständige Provenance rekonstruierbar (Audio→Segment→Transkript→Chunk→Embedding)
- [ ] Transkript-Provenance: Modell-ID gebunden, Änderung → neue Identity
- [ ] Frame-Provenance: sampling_policy_hash gebunden, Änderung → neue Identity

**Transcript:**
- [ ] Transcript-Hash deterministisch
- [ ] Transkript ist abgeleitetes Artefakt, kein Truth-Beweis (Test)

**Snapshot:**
- [ ] Snapshot-Binding: RetrievalRecord ohne Snapshot → ABORTED
- [ ] Snapshot-Root-Hash über alle Modalitäten

**Evidence:**
- [ ] Evidence-Binding: vollständige Rückverfolgbarkeit (Evidence → Retrieval → Query → Snapshot)

**Poisoning-Resistenz:**
- [ ] Duplicate-Detection (identische Segmente erkannt)
- [ ] Source-Concentration messbar
- [ ] Timestamp-Manipulation → ABORTED
- [ ] Modality-Flooding messbar

**Multimodal Snapshot:**
- [ ] Snapshot referenziert alle Modalitäten
- [ ] Root-Hash bindet alle Referenzmengen

**Memory Safety:**
- [ ] Alle neuen Records leak-frei unter `std.testing.allocator`

**Serialisierung:**
- [ ] Deterministisch über mehrere Läufe
- [ ] Little-endian, feste Feldreihenfolge

---

## Teil XV — Reihenfolge und Abhängigkeiten

### §38 Implementierungsreihenfolge (nach Freeze-Freigabe)

```
Stage 3.0 — PROVEN & FROZEN (Voraussetzung)
    ↓
Stage 3.1.A — Canonical Media Format + KnowledgeMediaRecord
    ↓ PROVEN & FROZEN
Stage 3.1.B — Segment Records (Audio/Video/Image/Frame)
    ↓ PROVEN & FROZEN
Stage 3.1.C — TranscriptRecord + Derived Artifacts
    ↓ PROVEN & FROZEN
Stage 3.1.D — EmbeddingRecord + MultimodalEmbeddingRecord
    ↓ PROVEN & FROZEN
Stage 3.1.E — KnowledgeSnapshot (multimodal)
    ↓ PROVEN & FROZEN
Stage 3.1.F — RetrievalRecord + KnowledgeQuery
    ↓ PROVEN & FROZEN
Stage 3.1.G — RetrievalEvidence + Concentration Metrics
    ↓ PROVEN & FROZEN
Stage 3.1 — GESAMTTEST: alle Tests 2× grün
    ↓ PROVEN & FROZEN
Stage 4 — Agent Lineage (bereits implementiert, wartet auf Stage 3.1 Freeze)
```

**Aktueller Stand:** Stage 4 (`agent_lineage.zig`) wurde bereits implementiert,
da es strukturell nicht von Stage 3.1 abhängt. Stage 3.1 und Stage 4 sind
parallele Wissensdimensionen. Die ursprüngliche Aussage „Stage 4 wartet auf
Stage 3.1 Freeze" bleibt aber als **Freeze-Reihenfolge** gültig:
Stage 3.1 muss vor Stage 4 frozen werden.

### §39 Protokollentscheidungen — KANONISCH FESTGELEGT (2026-09-01)

Alle Entscheidungen sind hiermit kanonisch. Keine erneute Diskussion vor Implementierung nötig.
Änderungen erfordern eine explizite neue Version dieses Vertrags.

---

**Entscheidung 1 — Domain-Prefix-Länge: exakt 4 Bytes.**

Alle Domain-Prefixe sind `[4]u8`. Keine 5-Byte-, keine 6-Byte-Sonderfälle.
Begründung: Konsistenz, keine Variationsfläche, kein Parsing-Sonderfall.

---

**Entscheidung 2 — Audio-Media-Domain: `"BKGW"` (Wave/PCM).**

`W` steht für die kanonische Wave/PCM-Repräsentation.
`"BKGS"` bleibt ausschließlich Spore. Kein Konflikt.

---

**Entscheidung 3 — Alle Segment- und RAG-Domains: 4 Bytes, eindeutig.**

Kanonische Zuordnung (aus Teil XI Registry):
- Audio-Segment: `"BKGP"`
- Video-Segment: `"BKGJ"`
- Image-Segment (ROI): `"BKGX"`
- Frame-Sample: `"BKGF"`
- Embedding (Dense/monomodal): `"BKGD"`
- Multimodal-Embedding: `"BKGO"`
- Transcript: `"BKGU"`
- Chunk (Text): `"BKGK"`
- Query: `"BKGQ"`
- Retrieval-Record: `"BKGR"`
- Snapshot (multimodal): `"BKGN"`
- Evidence: `"BKGY"`
- Tag-Record: `"BKGH"`
- Media-Record (generisch): `"BKGZ"`

---

**Entscheidung 4 — Embedding-Domain: `"BKGD"` (Dense).**

`D = Dense Vector Identity`.
`"BKGE"` ist bereits durch Agent-Lineage belegt und darf nicht verwendet werden.
`"BKGD"` ist unbelegt, eindeutig, kein Konflikt.

---

**Entscheidung 5 — Audio-Resampling: versionierter Canonicalizer, kein freier Resampler.**

Regel: Wenn Quelle bereits exakt 48.000 Hz → kein Resampling, kanonische PCM-Bytes direkt.

Für alle anderen Sample-Raten gilt **Canonicalizer v1**:
- Algorithmus: linear-phase windowed-sinc (Kaiser-Fenster, β = 8.0)
- Filterlänge: 128 Taps (konstant, nicht frequenzabhängig variabel)
- Cutoff: 0.5 × min(source_rate, 48000) Hz (Anti-Aliasing)
- Normalisierung: Peak-Normalisierung auf 0 dBFS nach Resampling (verhindert Clipping)
- Byte-Repräsentation: signed 24-bit little-endian PCM, identisch mit §4

Jede Änderung an diesen Parametern erzeugt eine neue `canonical_format_version`.
Die exakte Kernel-Spezifikation wird bytegenau in einem separaten
`AUDIO_CANONICAL_RESAMPLER_v1.md` dokumentiert (vor Stage 3.1.B Implementierung).

---

**Entscheidung 6 — `MAX_RETRIEVAL_RESULTS = 64`.**

64 ist groß genug für multimodale Kontexte, begrenzt genug für deterministische Evidence.
Überschreitung ist `LimitExceeded` — niemals stilles Abschneiden.

---

**Entscheidung 7 — `MAX_EVIDENCE_SOURCES = 32`, `MAX_EVIDENCE_TAGS = 16`.**

Passend zum Anti-Concentration-/Anti-Flooding-Modell.
Überschreitung ist `LimitExceeded` — niemals stilles Abschneiden.

---

**Entscheidung 8 — Score-Repräsentation: Festkomma `u64`, Skalierung 1.000.000.**

```
score_fixed: u64 = round(similarity_score * 1_000_000)
```

- Float für interne Berechnung (Embedding-Engine)
- Vor Persistenz und Hashing: deterministisch zu Festkomma quantisiert
- Keine CPU-/Compiler-/Floating-Rundungsunterschiede im Protokollwert
- Auflösung: 1 ppm (ausreichend für alle Retrieval-Kontexte)
- Maximum: `1_000_000` = perfekte Ähnlichkeit (1.0)
- Minimum: `0` = keine Ähnlichkeit
- Tie-Break bei identischem `score_fixed`: deterministisch per `rank`-Policy aus `retrieval_policy_hash`

Das Feld heißt `score_fixed: u64` (nicht `score_bits`). Der alte Name `score_bits` ist
hiermit obsolet und darf nicht implementiert werden.

---

**Entscheidung 9 — Domain-Registry als einzige kanonische Quelle.**

Alle Domain-Codes existieren ausschließlich in Teil XI dieses Vertrags.
Kein Code darf in Implementierungs-Code erscheinen, der nicht hier registriert ist.
Bei Widerspruch zwischen Code und Registry: Registry hat Vorrang, Code ist falsch.

---

## Schlussvermerke

Dieser Vertrag ist **DESIGN CONTRACT — Protokollentscheidungen KANONISCH FESTGELEGT**.

Implementierungssignal: **ERTEILT — wartet auf Stage 3.0 adversarial Freeze**

Sobald Stage 3.0 frozen ist, darf mit Stage 3.1.A begonnen werden.
Kein weiteres Protokoll-Signal erforderlich — alle Entscheidungen sind festgelegt.

Bedingungen:
1. Stage 3.0 adversarial Freeze vollständig bestanden
2. Repository-Scan vor erstem Commit in Stage 3.1 wiederholen (neue Domains prüfen)

Alle Entscheidungen aus §39 sind kanonisch (2026-09-01).
Keine erneute Verhandlung. Keine Protokoll-Improvisation.

Änderungen an diesem Vertrag nach Implementierungsbeginn erfordern eine neue Version
dieses Dokuments und gelten als Breaking Change mit vollständigem adversarial Re-Review.

**Stage 3.0 → Stage 3.1 → Stage 4 → Stage 5 → ...**
**Kein Schritt darf übersprungen werden.**

---

## Anhang §A — Protokollentscheidungs-Zusammenfassung

| # | Entscheidung | Wert | Festgelegt |
|---|---|---|---|
| 1 | Domain-Prefix-Länge | exakt 4 Bytes `[4]u8` | 2026-09-01 |
| 2 | Audio-Media-Domain | `"BKGW"` | 2026-09-01 |
| 3 | Alle Segment/RAG-Domains | siehe §39 E3 + Teil XI Registry | 2026-09-01 |
| 4 | Embedding-Domain | `"BKGD"` (Dense) | 2026-09-01 |
| 5 | Audio-Resampler | Canonicalizer v1: windowed-sinc, Kaiser β=8.0, 128 Taps | 2026-09-01 |
| 5a | Resampling-Bypass | Quelle = 48 kHz exakt → kein Resampling | 2026-09-01 |
| 6 | MAX_RETRIEVAL_RESULTS | 64 | 2026-09-01 |
| 7 | MAX_EVIDENCE_SOURCES | 32 | 2026-09-01 |
| 7a | MAX_EVIDENCE_TAGS | 16 | 2026-09-01 |
| 8 | Score-Repräsentation | Festkomma `u64`, Skalierung ×1.000.000 | 2026-09-01 |
| 8a | Score-Feldname | `score_fixed: u64` | 2026-09-01 |
| 9 | Domain-Registry | Teil XI ist einzige kanonische Quelle | 2026-09-01 |

## Anhang §B — Bekannte Kollisionen und Auflösung

Repository-Scan-Ergebnis (vollständig, 2026-09-01):

| Code | Bekannte Kollision | Auflösung |
|---|---|---|
| `"BKGE"` war Embedding-Kandidat | Agent-Lineage in Stage 4 | → Embedding-Domain ist `"BKGD"` |
| `"BKGS"` war AudioSegment-Kandidat | Spore-Store (FROZEN) + Snapshot-Domain (FROZEN) | → AudioSegment-Domain ist `"BKGP"` |
| `"BKGA"` war Audio-Kandidat | Artifact-Store (FROZEN) | → Audio-Media-Domain ist `"BKGW"` |
| `"BKGM"` war Media-Record-Kandidat | Manifest Magic (FROZEN, bkg-model) | → Media-Record-Domain ist `"BKGZ"` |
| `"BKGV"` war Video-Segment-Kandidat | (unbelegt) | → `"BKGV"` = Video-Media, Segment = `"BKGJ"` |

Alle Kollisionen sind aufgelöst. Keine offenen Konflikte.

---

## Anhang §C — Truth Boundary & Multimodal Provenance Amendment

Status: KANONISCH FESTGELEGT — 2026-09-01
Gilt für: Stage 3.1 und alle nachfolgenden Schichten, die auf Stage-3.1-Daten aufbauen.

Dieser Amendment ist Bestandteil des Stage-3.1-Vertrags.
Er korrigiert zwei konkrete Protokollfehler (§C.3, §C.4) und legt die epistemischen
Grenzen des Layers verbindlich fest.

---

### §C.1 — Fundamental Truth Boundary

Stage 3.1 beweist:

- welche Bytes vorlagen
- welche Canonicalization angewendet wurde (versioniert, deterministisch)
- welche Media Identity entstand (kanonischer Hash)
- welche Provenance referenziert wurde
- welches Embedding-Modell verwendet wurde (model_id, version gebunden)
- welche Retrieval Policy verwendet wurde
- welche Ergebnisse zurückgegeben wurden

Stage 3.1 beweist NICHT:

- faktische Wahrheit eines Inhalts
- ethische Richtigkeit
- politische Neutralität
- semantische Wahrheit
- rechtmäßiges Eigentum ohne gültige Entitlement-Evidence
- Vertrauenswürdigkeit eines Modells

Normative Gleichungen:

```
Cryptographic Integrity != Truth
Provenance              != Truth
Embedding               != Truth
Similarity              != Truth
Retrieval               != Truth
```

Stage 3.1 soll nicht behaupten: „Wir haben Wahrheit gespeichert."

Sondern: „Wir haben Wissen mit überprüfbarer Identität, Herkunft, Version,
Kontext und reproduzierbarem Retrieval gespeichert."

Das ist die epistemische Grenze dieses Layers.

---

### §C.2 — Media Identity vs. Context

Kanonische Media Identity darf nur die dafür definierten Identitätsdaten enthalten.

Externe Metadaten, die die kanonische Payload nicht unkontrolliert verändern dürfen:

- EXIF, XMP, GPS
- Dateiname, Dateipfad
- ursprünglicher Container-Timestamp

Diese Metadaten dürfen nicht Teil der kanonischen Payload-Identität sein.
Sie dürfen aber als separate Provenance-/Metadata-Records erhalten bleiben.

```
Canonical Content != Context
```

Der Kontext darf nicht verloren gehen.
Er besitzt jedoch eine eigene Identität und eigene Provenance.

Erlaubtes Modell:

```
Raw Source  →  Canonical Media  →  Media Hash

Raw Source  →  Metadata Record  →  Metadata Hash  →  Media Hash Reference
```

Dadurch bleibt der Kontext erhalten, ohne Bestandteil der nackten Content Identity
zu werden.

---

### §C.3 — Canonical Image Domain (Protokollkorrektur)

**Fehler in früheren Entwürfen: `BKGI = Image`.**

`BKGI` war unassigned/reserviert und wurde niemals für Image ALLOCATED.

Die kanonische Image Domain für Stage 3.1 ist und bleibt:

```
BKGP  =  Image Knowledge Unit
```

`BKGI` darf nicht für Image verwendet werden, solange es nicht ausdrücklich durch eine
neue Registry-Version (Teil XI) ALLOCATED wurde.

Keine nachträgliche Umwidmung. Domain-Freeze-Regel (Teil XI) gilt uneingeschränkt.

---

### §C.4 — Canonical Audio Contract (Protokollkorrektur)

**Fehler in früheren Entwürfen: 28 kHz Samplingrate.**

Der Canonical Audio Contract ist und bleibt:

```
Format:      signed PCM
Sample rate: 48 kHz  (nicht 28 kHz, nicht 44.1 kHz)
Bit depth:   24 bit
Byte order:  little-endian
Container:   kanonische Payload ohne Container-Header
```

Resampler:

```
Algorithmus: windowed-sinc
Kaiser beta: 8.0
Taps:        128
Bypass:      exakter 48-kHz-Bypass (keine Resampling-Kette bei Quellaudio mit 48 kHz)
```

Eine Änderung auf 28 kHz, andere Bitbreite oder einen anderen Resampler ist eine
Protokolländerung und nicht mit Stage 3.1 v1 kompatibel.

---

### §C.5 — Metadata Preservation

Das Entfernen von Metadaten aus der kanonischen Identity bedeutet NICHT deren
Löschung aus dem BKG-Wissen.

Modell: siehe §C.2 (Dual-Pipeline: Canonical Media + Metadata Record).

---

### §C.6 — Provenance Strength

Ein Provenance Record ist selbst ein überprüfbares Artefakt.

Mindestfelder:

- `source_hash`
- `media_hash`
- creator / reference identity
- transformation identity
- `origin_event_hash`
- `provenance_version`

Provenance darf nicht allein dadurch vertrauenswürdig werden, dass ein Watcher sie
gespeichert hat. Ein Watcher ist kein Wahrheitsanker.

---

### §C.7 — Originality

Proof-of-Originality darf nicht als einfacher Vergleich

```
file_hash == genesis_hash
```

implementiert werden.

Stattdessen muss Originality mehrere Ebenen unterscheiden:

```
Byte Identity
Canonical Media Identity
Provenance
Lineage
Perceptual / Content Fingerprint
License / Entitlement
```

Eine legitime Transformation darf einen neuen Byte-Hash besitzen, ohne automatisch
ein neues unabhängiges Werk zu sein.

---

### §C.8 — Retrieval Evidence

Retrieval Evidence beweist:

> „Diese Wissenseinheiten wurden unter Snapshot X, Policy Y und Modell Z zurückgegeben."

Sie beweist nicht:

> „Diese Wissenseinheiten sind wahr."

Guardian-/Forge-Schichten dürfen Retrieval Evidence als Input verwenden.
Sie müssen dessen epistemische Grenze berücksichtigen.

---

### §C.9 — RAG Flooding

`MAX_RETRIEVAL_RESULTS = 64` ist ein Ergebnislimit, kein Wahrheitslimit.

Ein gefüllter Retrieval-Satz darf nicht als Beweis interpretiert werden, dass nur diese
64 Wissenseinheiten existieren.

Ein Retrieval-System muss später erkennen können:

- source concentration
- lineage concentration
- media concentration
- modality concentration
- model concentration
- duplicate concentration

---

### §C.10 — Diversity (Hash-Hamming-Verbot)

**Verboten als semantisches Ähnlichkeitsmaß:**

```
HammingDistance(SHA256(A), SHA256(B))
```

SHA-256-Hamming-Distance darf ausschließlich als kryptographisches Bit-Distanzsignal
behandelt werden. Es liefert keine Aussage über semantische Verwandtschaft.

Semantische Diversity muss getrennt über geeignete Signale bewertet werden:

- Lineage
- Source Set
- Tags
- Embedding Similarity
- Provenance
- Capability Context

Keine dieser Metriken allein ist Wahrheit.
Anti-Inzucht-/Diversity-Logik muss auf diesen Signalen basieren, nicht auf Hash-Distanz.

---

### §C.11 — Model Bias

Ein korrekt gehashter und versionierter Embedding-/Retrieval-Algorithmus kann
trotzdem systematisch falsch oder voreingenommen sein.

```
Model Identity != Model Correctness
```

Stage 3.1 macht Modellverhalten reproduzierbar.
Es erklärt das Modell nicht automatisch für korrekt.

---

### §C.12 — Guardian Boundary

Guardians dürfen später:

- Evidence prüfen
- Provenance vergleichen
- unabhängige Quellen vergleichen
- Retrieval Concentration erkennen
- Fake-/Manipulationssignale untersuchen
- Lizenz-/Entitlement-Verletzungen feststellen

Guardians dürfen dabei nicht:

- historische Ledger-Wahrheit überschreiben
- SOUL löschen
- Genesis Authority ersetzen
- Media Identity umschreiben

---

### §C.13 — Nebel Boundary

Der Nebel darf aus diesen Messdaten Evolutionsbedingungen ableiten.

Er darf:

- Hotspots erkennen
- Repetition erkennen
- lokale Evolution bremsen
- temporäre Modifier erzeugen
- Farming-Druck erhöhen

Er darf nicht:

- Media Identity verändern
- historische Provenance löschen
- Genesis Authority verändern
- einen Inhalt durch bloße Similarity zu „wahr" erklären

---

### §C.14 — Anti-Piracy Boundary

Eine erkannte unlizenzierte Kopie ist nicht dasselbe wie ein verändertes Medium.

```
Different Hash              != Piracy
Same Content + Valid License  != Piracy
Same Content + Missing Entitlement  = potential policy violation
Contradictory Provenance    = evidence signal
```

Die endgültige Policy-Ausführung erfolgt über die dafür vorgesehenen
Runtime-/Guardian-Schichten.

---

### §C.15 — Registry Integrity

Die Domain Registry (Teil XI) bleibt die alleinige Quelle der Domain-Semantik.
Eine registrierte Domain darf niemals umgewidmet werden.

Insbesondere unveränderlich:

```
BKGP  ≠  „etwas anderes"        (bleibt: Image Knowledge Unit)
BKGE  ≠  Embedding               (bleibt: Agent Lineage, FROZEN Stage 4)
BKGM  ≠  Media                   (bleibt: Manifest Magic, FROZEN bkg-model)
BKGS  ≠  RAG                     (bleibt: Spore + Snapshot, FROZEN Stage 1)
```

---

### §C.16 — Freeze Rule für Implementierung

Dieser Amendment ist Bestandteil des Stage-3.1-Vertrags.

Vor Implementierungs-Freeze müssen die in §C genannten Trennungen durch
Tests und Canonical Encoding nachgewiesen werden.

Eine Implementierung, die eine der folgenden Ableitungen direkt zieht, ist:

```
ABORTED — TRUTH BOUNDARY VIOLATION
```

Verbotene direkte Ableitungen:

```
Integrity  →  Truth
Similarity →  Trust
Hash       →  Originality
```

---

### §C — Änderungshistorie

| Datum | Änderung |
|-------|----------|
| 2026-09-01 | Amendment §C erstellt und in Stage-3.1-Contract integriert. Protokollkorrekturen §C.3 (BKGP, nicht BKGI) und §C.4 (48 kHz, nicht 28 kHz). Hash-Hamming-Verbot §C.10. Truth-Boundary §C.1–§C.16 festgelegt. |
