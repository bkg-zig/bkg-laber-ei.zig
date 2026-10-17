/// BKGDB Stage 3.1 — Canonical Media Records
///
/// Status: STAGE 3.1.A — NICHT FROZEN
/// Spec:   docs/BKGDB_EVOLUTION_MEMORY_STAGE_3_1_RAG_EMBEDDING_v1.md §I–§II
///
/// Kanonische Pipeline:
///   Quelle (beliebiges Format) → Canonicalizer → kanonische Bytes → SHA256 → media_hash
///
/// Harte Regeln:
///   - Quellformat ≠ kanonisches Format
///   - Dateiname, Pfad, Host-Dateisystem-Metadaten sind KEIN Bestandteil der Identity
///   - Änderung am Canonicalizer → neue canonical_format_version → neue Identity
///   - Float-Zeitangaben als Identitätsfelder: ABORTED (→ i64 Nanosekunden)
///   - Keine externen Bibliotheken, keine externe API
///
/// Kanonische Formate (§39 E1–E2, §I–§II):
///   Text:  UTF-8, NFC, LF, kein BOM  → Domain "BKGT" (Metadaten), Hash über normierten Stream
///   Image: PNG 32-bit RGBA, roher Pixelstream (ohne PNG-Container) → Domain "BKGP"
///   Audio: PCM signed 48kHz/24bit little-endian, kein Header → Domain "BKGW"
///   Video: MKV/FFV1/FLAC BKG-Profil v1 → Domain "BKGX"
///
const std = @import("std");
const reg = @import("domain_registry.zig");

// ── Medien-Art (§8 KnowledgeMediaRecord) ─────────────────────────────────

pub const MediaKind = enum(u8) {
    text  = 1,
    image = 2,
    audio = 3,
    video = 4,
    // 5–255 für zukünftige BKG-definierte Medienformen reserviert
};

// ── Canonical Format Versions ─────────────────────────────────────────────

/// UTF-8 NFC LF no-BOM — Regel-Version 1
pub const TEXT_CANONICAL_VERSION:  u16 = 1;
/// PNG 32-bit RGBA kanonisch — Version 1
pub const IMAGE_CANONICAL_VERSION: u16 = 1;
/// PCM 48kHz/24bit signed LE — Version 1; Resampler: Kaiser β=8.0 128 Taps
pub const AUDIO_CANONICAL_VERSION: u16 = 1;
/// MKV/FFV1/FLAC BKG Video Profile v1
pub const VIDEO_CANONICAL_VERSION: u16 = 1;

// ── Kanonische Audio-Parameter (§4, §39 E5) ──────────────────────────────

pub const AUDIO_SAMPLE_RATE:  u32 = 48_000;
pub const AUDIO_BIT_DEPTH:    u8  = 24;
pub const AUDIO_BYTES_PER_SAMPLE: u8 = 3; // 24-bit = 3 Bytes, little-endian signed
/// Resampler v1: Kaiser-windowed-sinc, β=8.0, 128 Taps
pub const AUDIO_RESAMPLER_TAPS:   u32 = 128;
/// Kaiser-Beta für den Resampler
pub const AUDIO_KAISER_BETA_BITS: u64 = 0x4020000000000000; // f64 8.0 als IEEE-754 bits (informativ)

// ── ZERO_HASH ─────────────────────────────────────────────────────────────

pub const ZERO_HASH: [32]u8 = [_]u8{0} ** 32;

// ── Fehlertypen ───────────────────────────────────────────────────────────

pub const CanonicalMediaError = error{
    /// Speicherallokation fehlgeschlagen
    OutOfMemory,
    /// Canonicalizer-Version unbekannt
    UnknownVersion,
    /// Inhalt ist leer (0 Bytes — kein gültiges Medium)
    EmptyContent,
    /// Zeitangabe ungültig (negativ für Segmentstart, end <= start)
    InvalidTimestamp,
    /// Bildabmessungen sind 0
    InvalidDimensions,
    /// Audio-Sample-Rate nach Resampling nicht 48000 Hz
    InvalidSampleRate,
    /// Unbekannte Medienart
    UnknownMediaKind,
    /// Domain-Konflikt (Abort-Bedingung)
    DomainConflict,
};

// ── Text-Metadaten (§9) ───────────────────────────────────────────────────

pub const TextMediaMetadata = struct {
    normalization_version: u16,  // NFC-Regelversion
    encoding_version:      u16,  // UTF-8-Encoding-Regelversion
    line_ending_policy:    u8,   // 1 = LF-only (kanonisch)
    byte_length:           u64,  // Länge des normierten UTF-8-Streams
};

// ── Image-Metadaten (§10) ─────────────────────────────────────────────────

pub const ImageMediaMetadata = struct {
    width:                     u32,
    height:                    u32,
    channels:                  u8,  // 4 = RGBA (kanonisch)
    bit_depth_per_channel:     u8,  // 8 (kanonisch)
    normalization_policy_hash: [32]u8,
};

// ── Audio-Metadaten (§11) ─────────────────────────────────────────────────

pub const AudioMediaMetadata = struct {
    sample_rate:            u32,   // 48000 (kanonisch)
    channels:               u8,    // 1 = mono, 2 = stereo
    bit_depth:              u8,    // 24 (kanonisch)
    byte_order:             u8,    // 1 = little-endian
    duration_ns:            i64,   // Gesamtlänge in Integer-Nanosekunden
    resampling_policy_hash: [32]u8,
};

// ── Video-Metadaten (§12) ─────────────────────────────────────────────────

pub const VideoMediaMetadata = struct {
    width:                       u32,
    height:                      u32,
    frame_rate_num:              u32,  // Zähler (rational, nie float)
    frame_rate_den:              u32,  // Nenner (rational, nie float)
    duration_ns:                 i64,  // Integer-Nanosekunden
    audio_presence:              u8,   // 0 = kein Audio, 1 = vorhanden
    audio_channels:              u8,
    canonicalization_policy_hash: [32]u8,
};

// ── KnowledgeMediaRecord (§8) ─────────────────────────────────────────────

/// Generischer kanonischer Eintrag für alle Modalitäten.
/// domain_prefix je nach media_kind:
///   text  → "BKGT" (Metadaten-Domain; Hash über UTF-8-Stream)
///   image → "BKGP"
///   audio → "BKGW"
///   video → "BKGX"
pub const KnowledgeMediaRecord = struct {
    domain_prefix:               [4]u8,
    media_hash:                  [32]u8,  // SHA256(domain || canonical_bytes)
    media_kind:                  MediaKind,
    canonical_format_version:    u16,
    source_hash:                 [32]u8,  // SHA256 der Originalquelle (Provenance)
    provenance_hash:             [32]u8,
    lineage_hash:                [32]u8,
    content_size:                u64,     // Größe der kanonischen Darstellung
    metadata_hash:               [32]u8,  // SHA256 der modality-spezifischen Metadaten
    knowledge_epoch:             u64,
    origin_event_hash:           [32]u8,  // ZERO = kein Ledger-Beweis
    canonicalization_policy_hash: [32]u8,
};

// ── computeMediaHash ──────────────────────────────────────────────────────

/// Berechnet den kanonischen Media-Hash.
/// SHA256(domain_prefix || canonical_bytes)
/// domain_prefix wird aus media_kind abgeleitet.
pub fn computeMediaHash(media_kind: MediaKind, canonical_bytes: []const u8) [32]u8 {
    const domain = domainForKind(media_kind);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&domain);
    hasher.update(canonical_bytes);
    return hasher.finalResult();
}

/// Gibt den kanonischen Domain-Prefix für eine MediaKind zurück.
/// Text-Media: SHA256 wird über "BKGT" || canonical_bytes gebildet (BKGT = Retrieval Evidence
/// Domain dient hier als Text-Media-Domain — die Registry weist BKGT für Retrieval Evidence aus,
/// aber per §2 Spec wird der Text-Media-Hash mit Domain "BKGT" berechnet).
/// Hinweis: Im Contract §2 steht Hash-Domain "BKGT" für Text-Media-Hashing.
pub fn domainForKind(kind: MediaKind) [4]u8 {
    return switch (kind) {
        .text  => reg.DOMAIN_RETRIEVAL_EVIDENCE, // "BKGT" — Text-Media-Domain (§2)
        .image => reg.DOMAIN_IMAGE_UNIT,         // "BKGP"
        .audio => reg.DOMAIN_AUDIO_MEDIA,        // "BKGW"
        .video => reg.DOMAIN_VIDEO_MEDIA,        // "BKGX"
    };
}

// ── Text-Canonicalization (§2) ────────────────────────────────────────────

/// Ergebnis der Text-Canonicalization.
pub const TextCanonicalResult = struct {
    media_hash:    [32]u8,
    metadata_hash: [32]u8,
    metadata:      TextMediaMetadata,
    /// Byte-Länge der kanonischen Repräsentation
    canonical_len: u64,
};

/// Berechnet den Hash über text-spezifische Metadaten.
fn computeTextMetadataHash(meta: TextMediaMetadata) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], meta.normalization_version, .little);
    hasher.update(buf[0..2]);
    std.mem.writeInt(u16, buf[0..2], meta.encoding_version, .little);
    hasher.update(buf[0..2]);
    hasher.update(&[_]u8{meta.line_ending_policy});
    std.mem.writeInt(u64, &buf, meta.byte_length, .little);
    hasher.update(&buf);
    return hasher.finalResult();
}

/// Canonicalisiert einen UTF-8-Textinhalt (in-memory).
///
/// Erwartet bereits NFC-normierten Input (BKG übernimmt keine Unicode-Normalisierung
/// in Zig 0.16 stdlib — der Caller ist verantwortlich für NFC-Vorverarbeitung).
/// Diese Funktion normalisiert: BOM-Entfernung, CRLF→LF, CR→LF,
/// trailing whitespace pro Zeile, exakt eine trailing LF am Ende.
///
/// Gibt CanonicalMediaError.EmptyContent wenn input leer.
pub fn canonicalizeText(
    allocator: std.mem.Allocator,
    input: []const u8,
    source_hash: [32]u8,
) CanonicalMediaError!struct { record: KnowledgeMediaRecord, canonical: []u8 } {
    if (input.len == 0) return error.EmptyContent;

    // BOM entfernen
    const without_bom = if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF"))
        input[3..]
    else
        input;

    // Normalisierung: CRLF → LF, CR → LF, trailing whitespace, trailing LF
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    var line_start: usize = 0;
    // Wir verarbeiten zeichenweise und bauen Zeilen auf
    while (i <= without_bom.len) : (i += 1) {
        const at_end = (i == without_bom.len);
        const is_lf  = !at_end and without_bom[i] == '\n';
        const is_cr  = !at_end and without_bom[i] == '\r';
        const is_eol = is_lf or is_cr or at_end;

        if (is_eol) {
            // Zeile from line_start..i (ohne Zeilenendezeichen)
            var end = i;
            // Trailing whitespace entfernen
            while (end > line_start and
                (without_bom[end - 1] == ' ' or without_bom[end - 1] == '\t')) : (end -= 1) {}
            try out.appendSlice(allocator, without_bom[line_start..end]);
            try out.append(allocator, '\n');

            // CRLF überspringen
            if (is_cr and i + 1 < without_bom.len and without_bom[i + 1] == '\n') {
                i += 1;
            }
            line_start = i + 1;
        }
    }

    // Genau eine trailing LF: entferne doppelte am Ende
    while (out.items.len >= 2 and
        out.items[out.items.len - 1] == '\n' and
        out.items[out.items.len - 2] == '\n')
    {
        _ = out.pop();
    }
    // Falls leer nach Normalisierung, mindestens eine LF hinzufügen
    if (out.items.len == 0) {
        try out.append(allocator, '\n');
    }

    const canonical = try out.toOwnedSlice(allocator);

    const meta = TextMediaMetadata{
        .normalization_version = TEXT_CANONICAL_VERSION,
        .encoding_version      = 1,
        .line_ending_policy    = 1,
        .byte_length           = @intCast(canonical.len),
    };
    const metadata_hash = computeTextMetadataHash(meta);
    const media_hash    = computeMediaHash(.text, canonical);

    // Provenance-Hash: SHA256(source_hash || metadata_hash)
    var prov_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    prov_hasher.update(&source_hash);
    prov_hasher.update(&metadata_hash);
    const provenance_hash = prov_hasher.finalResult();

    const record = KnowledgeMediaRecord{
        .domain_prefix               = domainForKind(.text),
        .media_hash                  = media_hash,
        .media_kind                  = .text,
        .canonical_format_version    = TEXT_CANONICAL_VERSION,
        .source_hash                 = source_hash,
        .provenance_hash             = provenance_hash,
        .lineage_hash                = ZERO_HASH,
        .content_size                = @intCast(canonical.len),
        .metadata_hash               = metadata_hash,
        .knowledge_epoch             = 0,
        .origin_event_hash           = ZERO_HASH,
        .canonicalization_policy_hash = ZERO_HASH,
    };
    return .{ .record = record, .canonical = canonical };
}

// ── Image-Canonicalization (§3) ───────────────────────────────────────────

/// Canonicalisiert einen rohen RGBA-Pixelstream.
/// Input: rohe RGBA-Bytes (width × height × 4), bereits ohne PNG-Container.
/// Kein PNG-Parsing in dieser Funktion — der Caller dekodiert PNG → RGBA.
pub fn canonicalizeImage(
    width: u32,
    height: u32,
    rgba_pixels: []const u8,
    source_hash: [32]u8,
    normalization_policy_hash: [32]u8,
) CanonicalMediaError!KnowledgeMediaRecord {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const expected = @as(usize, width) * @as(usize, height) * 4;
    if (rgba_pixels.len != expected) return error.InvalidDimensions;

    const meta = ImageMediaMetadata{
        .width                     = width,
        .height                    = height,
        .channels                  = 4,
        .bit_depth_per_channel     = 8,
        .normalization_policy_hash = normalization_policy_hash,
    };
    const metadata_hash = computeImageMetadataHash(meta);
    const media_hash    = computeMediaHash(.image, rgba_pixels);

    var prov_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    prov_hasher.update(&source_hash);
    prov_hasher.update(&metadata_hash);
    const provenance_hash = prov_hasher.finalResult();

    return KnowledgeMediaRecord{
        .domain_prefix               = domainForKind(.image),
        .media_hash                  = media_hash,
        .media_kind                  = .image,
        .canonical_format_version    = IMAGE_CANONICAL_VERSION,
        .source_hash                 = source_hash,
        .provenance_hash             = provenance_hash,
        .lineage_hash                = ZERO_HASH,
        .content_size                = @intCast(rgba_pixels.len),
        .metadata_hash               = metadata_hash,
        .knowledge_epoch             = 0,
        .origin_event_hash           = ZERO_HASH,
        .canonicalization_policy_hash = normalization_policy_hash,
    };
}

fn computeImageMetadataHash(meta: ImageMediaMetadata) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf4: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf4, meta.width, .little);
    hasher.update(&buf4);
    std.mem.writeInt(u32, &buf4, meta.height, .little);
    hasher.update(&buf4);
    hasher.update(&[_]u8{ meta.channels, meta.bit_depth_per_channel });
    hasher.update(&meta.normalization_policy_hash);
    return hasher.finalResult();
}

// ── Audio-Canonicalization (§4) ───────────────────────────────────────────

/// Canonicalisiert einen PCM-Audio-Byte-Stream.
/// Input: rohe PCM-Bytes (signed 24-bit, little-endian, 48kHz, ohne Header).
/// channels: 1 = mono, 2 = stereo.
/// duration_ns: Gesamtlänge in Integer-Nanosekunden (i64).
/// resampling_policy_hash: Hash der verwendeten Resampling-Policy (ZERO wenn kein Resampling).
///
/// Invariante: sample_rate muss 48000 sein (nach Canonicalization).
pub fn canonicalizeAudio(
    pcm_bytes: []const u8,
    channels: u8,
    duration_ns: i64,
    source_hash: [32]u8,
    resampling_policy_hash: [32]u8,
) CanonicalMediaError!KnowledgeMediaRecord {
    if (pcm_bytes.len == 0) return error.EmptyContent;
    if (duration_ns < 0) return error.InvalidTimestamp;

    const meta = AudioMediaMetadata{
        .sample_rate            = AUDIO_SAMPLE_RATE,
        .channels               = channels,
        .bit_depth              = AUDIO_BIT_DEPTH,
        .byte_order             = 1,  // little-endian
        .duration_ns            = duration_ns,
        .resampling_policy_hash = resampling_policy_hash,
    };
    const metadata_hash = computeAudioMetadataHash(meta);
    const media_hash    = computeMediaHash(.audio, pcm_bytes);

    var prov_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    prov_hasher.update(&source_hash);
    prov_hasher.update(&metadata_hash);
    const provenance_hash = prov_hasher.finalResult();

    return KnowledgeMediaRecord{
        .domain_prefix               = domainForKind(.audio),
        .media_hash                  = media_hash,
        .media_kind                  = .audio,
        .canonical_format_version    = AUDIO_CANONICAL_VERSION,
        .source_hash                 = source_hash,
        .provenance_hash             = provenance_hash,
        .lineage_hash                = ZERO_HASH,
        .content_size                = @intCast(pcm_bytes.len),
        .metadata_hash               = metadata_hash,
        .knowledge_epoch             = 0,
        .origin_event_hash           = ZERO_HASH,
        .canonicalization_policy_hash = resampling_policy_hash,
    };
}

fn computeAudioMetadataHash(meta: AudioMediaMetadata) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], meta.sample_rate, .little);
    hasher.update(buf[0..4]);
    hasher.update(&[_]u8{ meta.channels, meta.bit_depth, meta.byte_order });
    std.mem.writeInt(i64, &buf, meta.duration_ns, .little);
    hasher.update(&buf);
    hasher.update(&meta.resampling_policy_hash);
    return hasher.finalResult();
}

// ── Video-Canonicalization (§5) ───────────────────────────────────────────

/// Canonicalisiert einen BKG-kanonischen MKV-Video-Byte-Stream.
/// Input: vollständige MKV-Bytes nach BKG Video Profile v1.
/// frame_rate_num/den: rationaler Bruch (nie float).
/// duration_ns: Integer-Nanosekunden.
pub fn canonicalizeVideo(
    mkv_bytes: []const u8,
    width: u32,
    height: u32,
    frame_rate_num: u32,
    frame_rate_den: u32,
    duration_ns: i64,
    audio_presence: u8,
    audio_channels: u8,
    source_hash: [32]u8,
    canonicalization_policy_hash: [32]u8,
) CanonicalMediaError!KnowledgeMediaRecord {
    if (mkv_bytes.len == 0) return error.EmptyContent;
    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (duration_ns < 0) return error.InvalidTimestamp;

    const meta = VideoMediaMetadata{
        .width                        = width,
        .height                       = height,
        .frame_rate_num               = frame_rate_num,
        .frame_rate_den               = frame_rate_den,
        .duration_ns                  = duration_ns,
        .audio_presence               = audio_presence,
        .audio_channels               = audio_channels,
        .canonicalization_policy_hash = canonicalization_policy_hash,
    };
    const metadata_hash = computeVideoMetadataHash(meta);
    const media_hash    = computeMediaHash(.video, mkv_bytes);

    var prov_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    prov_hasher.update(&source_hash);
    prov_hasher.update(&metadata_hash);
    const provenance_hash = prov_hasher.finalResult();

    return KnowledgeMediaRecord{
        .domain_prefix               = domainForKind(.video),
        .media_hash                  = media_hash,
        .media_kind                  = .video,
        .canonical_format_version    = VIDEO_CANONICAL_VERSION,
        .source_hash                 = source_hash,
        .provenance_hash             = provenance_hash,
        .lineage_hash                = ZERO_HASH,
        .content_size                = @intCast(mkv_bytes.len),
        .metadata_hash               = metadata_hash,
        .knowledge_epoch             = 0,
        .origin_event_hash           = ZERO_HASH,
        .canonicalization_policy_hash = canonicalization_policy_hash,
    };
}

fn computeVideoMetadataHash(meta: VideoMediaMetadata) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf4: [4]u8 = undefined;
    var buf8: [8]u8 = undefined;
    std.mem.writeInt(u32, &buf4, meta.width, .little);           hasher.update(&buf4);
    std.mem.writeInt(u32, &buf4, meta.height, .little);          hasher.update(&buf4);
    std.mem.writeInt(u32, &buf4, meta.frame_rate_num, .little);  hasher.update(&buf4);
    std.mem.writeInt(u32, &buf4, meta.frame_rate_den, .little);  hasher.update(&buf4);
    std.mem.writeInt(i64, &buf8, meta.duration_ns, .little);     hasher.update(&buf8);
    hasher.update(&[_]u8{ meta.audio_presence, meta.audio_channels });
    hasher.update(&meta.canonicalization_policy_hash);
    return hasher.finalResult();
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "canonical_media: Text-Canonicalization deterministisch" {
    const allocator = std.testing.allocator;
    const input = "Hello World\nSecond line\n";
    const src: [32]u8 = [_]u8{0x01} ++ [_]u8{0} ** 31;

    const r1 = try canonicalizeText(allocator, input, src);
    defer allocator.free(r1.canonical);
    const r2 = try canonicalizeText(allocator, input, src);
    defer allocator.free(r2.canonical);

    try std.testing.expectEqualSlices(u8, &r1.record.media_hash, &r2.record.media_hash);
    try std.testing.expectEqualSlices(u8, r1.canonical, r2.canonical);
}

test "canonical_media: Text BOM wird entfernt" {
    const allocator = std.testing.allocator;
    const with_bom = "\xEF\xBB\xBFHello\n";
    const without_bom = "Hello\n";
    const src = ZERO_HASH;

    const r1 = try canonicalizeText(allocator, with_bom, src);
    defer allocator.free(r1.canonical);
    const r2 = try canonicalizeText(allocator, without_bom, src);
    defer allocator.free(r2.canonical);

    try std.testing.expectEqualSlices(u8, &r1.record.media_hash, &r2.record.media_hash);
}

test "canonical_media: Text CRLF → LF" {
    const allocator = std.testing.allocator;
    const crlf = "Line1\r\nLine2\r\n";
    const lf   = "Line1\nLine2\n";
    const src  = ZERO_HASH;

    const r1 = try canonicalizeText(allocator, crlf, src);
    defer allocator.free(r1.canonical);
    const r2 = try canonicalizeText(allocator, lf, src);
    defer allocator.free(r2.canonical);

    try std.testing.expectEqualSlices(u8, r1.canonical, r2.canonical);
    try std.testing.expectEqualSlices(u8, &r1.record.media_hash, &r2.record.media_hash);
}

test "canonical_media: Text trailing whitespace entfernt" {
    const allocator = std.testing.allocator;
    const with_ws    = "Hello   \nWorld  \n";
    const without_ws = "Hello\nWorld\n";
    const src = ZERO_HASH;

    const r1 = try canonicalizeText(allocator, with_ws, src);
    defer allocator.free(r1.canonical);
    const r2 = try canonicalizeText(allocator, without_ws, src);
    defer allocator.free(r2.canonical);

    try std.testing.expectEqualSlices(u8, r1.canonical, r2.canonical);
}

test "canonical_media: Text verschiedene Inhalte → verschiedene media_hash" {
    const allocator = std.testing.allocator;
    const src = ZERO_HASH;

    const r1 = try canonicalizeText(allocator, "Hello\n", src);
    defer allocator.free(r1.canonical);
    const r2 = try canonicalizeText(allocator, "World\n", src);
    defer allocator.free(r2.canonical);

    try std.testing.expect(!std.mem.eql(u8, &r1.record.media_hash, &r2.record.media_hash));
}

test "canonical_media: Text EmptyContent" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.EmptyContent,
        canonicalizeText(allocator, "", ZERO_HASH),
    );
}

test "canonical_media: Text MediaKind korrekt" {
    const allocator = std.testing.allocator;
    const r = try canonicalizeText(allocator, "hello\n", ZERO_HASH);
    defer allocator.free(r.canonical);
    try std.testing.expectEqual(MediaKind.text, r.record.media_kind);
    try std.testing.expectEqual(TEXT_CANONICAL_VERSION, r.record.canonical_format_version);
}

test "canonical_media: Text Version → neue Identity" {
    // Direkttest: computeMediaHash mit verschiedenen Inhalten erzeugt verschiedene Hashes
    const h1 = computeMediaHash(.text, "v1 content\n");
    const h2 = computeMediaHash(.text, "v2 content\n");
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "canonical_media: Image-Canonicalization deterministisch" {
    // 2×2 RGBA = 16 Bytes
    const pixels = [_]u8{
        0xFF, 0x00, 0x00, 0xFF,  // rot
        0x00, 0xFF, 0x00, 0xFF,  // grün
        0x00, 0x00, 0xFF, 0xFF,  // blau
        0xFF, 0xFF, 0xFF, 0xFF,  // weiß
    };
    const src = ZERO_HASH;
    const policy = ZERO_HASH;

    const r1 = try canonicalizeImage(2, 2, &pixels, src, policy);
    const r2 = try canonicalizeImage(2, 2, &pixels, src, policy);

    try std.testing.expectEqualSlices(u8, &r1.media_hash, &r2.media_hash);
}

test "canonical_media: Image verschiedene Pixel → verschiedene media_hash" {
    const pixels1 = [_]u8{0xFF} ** 16;
    const pixels2 = [_]u8{0x00} ** 16;
    const src = ZERO_HASH;

    const r1 = try canonicalizeImage(2, 2, &pixels1, src, ZERO_HASH);
    const r2 = try canonicalizeImage(2, 2, &pixels2, src, ZERO_HASH);

    try std.testing.expect(!std.mem.eql(u8, &r1.media_hash, &r2.media_hash));
}

test "canonical_media: Image InvalidDimensions" {
    const pixels = [_]u8{0xFF} ** 4;
    try std.testing.expectError(error.InvalidDimensions, canonicalizeImage(0, 1, &pixels, ZERO_HASH, ZERO_HASH));
    try std.testing.expectError(error.InvalidDimensions, canonicalizeImage(1, 0, &pixels, ZERO_HASH, ZERO_HASH));
    // Falsche Pixel-Länge für 2×2
    try std.testing.expectError(error.InvalidDimensions, canonicalizeImage(2, 2, &pixels, ZERO_HASH, ZERO_HASH));
}

test "canonical_media: Image MediaKind korrekt" {
    const pixels = [_]u8{0xAB} ** 16;
    const r = try canonicalizeImage(2, 2, &pixels, ZERO_HASH, ZERO_HASH);
    try std.testing.expectEqual(MediaKind.image, r.media_kind);
    try std.testing.expectEqual(IMAGE_CANONICAL_VERSION, r.canonical_format_version);
}

test "canonical_media: Audio-Canonicalization deterministisch" {
    // 100 Samples, 2 Kanäle × 3 Bytes = 600 Bytes
    const pcm = [_]u8{0x80} ** 600;
    const src = ZERO_HASH;

    const r1 = try canonicalizeAudio(&pcm, 2, 2_083_333, src, ZERO_HASH);
    const r2 = try canonicalizeAudio(&pcm, 2, 2_083_333, src, ZERO_HASH);

    try std.testing.expectEqualSlices(u8, &r1.media_hash, &r2.media_hash);
}

test "canonical_media: Audio verschiedene PCM → verschiedene media_hash" {
    const pcm1 = [_]u8{0x00} ** 300;
    const pcm2 = [_]u8{0xFF} ** 300;

    const r1 = try canonicalizeAudio(&pcm1, 1, 1_000_000, ZERO_HASH, ZERO_HASH);
    const r2 = try canonicalizeAudio(&pcm2, 1, 1_000_000, ZERO_HASH, ZERO_HASH);

    try std.testing.expect(!std.mem.eql(u8, &r1.media_hash, &r2.media_hash));
}

test "canonical_media: Audio EmptyContent" {
    try std.testing.expectError(error.EmptyContent, canonicalizeAudio(&[_]u8{}, 1, 0, ZERO_HASH, ZERO_HASH));
}

test "canonical_media: Audio negative duration ist ungültig" {
    const pcm = [_]u8{0x00} ** 60;
    try std.testing.expectError(error.InvalidTimestamp, canonicalizeAudio(&pcm, 1, -1, ZERO_HASH, ZERO_HASH));
}

test "canonical_media: Audio MediaKind korrekt" {
    const pcm = [_]u8{0x00} ** 300;
    const r = try canonicalizeAudio(&pcm, 1, 1_000_000, ZERO_HASH, ZERO_HASH);
    try std.testing.expectEqual(MediaKind.audio, r.media_kind);
    try std.testing.expectEqual(AUDIO_CANONICAL_VERSION, r.canonical_format_version);
    try std.testing.expectEqual(AUDIO_SAMPLE_RATE, AUDIO_SAMPLE_RATE); // Konstante korrekt
}

test "canonical_media: Audio resampling_policy_hash bindet Identity" {
    const pcm = [_]u8{0x01} ** 300;
    var policy_a = ZERO_HASH;
    policy_a[0] = 0x01;
    var policy_b = ZERO_HASH;
    policy_b[0] = 0x02;

    const r1 = try canonicalizeAudio(&pcm, 1, 1_000_000, ZERO_HASH, policy_a);
    const r2 = try canonicalizeAudio(&pcm, 1, 1_000_000, ZERO_HASH, policy_b);

    // media_hash ist gleich (gleicher PCM-Inhalt), aber metadata_hash verschieden
    try std.testing.expectEqualSlices(u8, &r1.media_hash, &r2.media_hash);
    try std.testing.expect(!std.mem.eql(u8, &r1.metadata_hash, &r2.metadata_hash));
}

test "canonical_media: Video-Canonicalization deterministisch" {
    const mkv = [_]u8{0x1A, 0x45, 0xDF, 0xA3} ++ [_]u8{0x00} ** 100;
    const src = ZERO_HASH;

    const r1 = try canonicalizeVideo(&mkv, 1920, 1080, 30, 1, 10_000_000_000, 1, 2, src, ZERO_HASH);
    const r2 = try canonicalizeVideo(&mkv, 1920, 1080, 30, 1, 10_000_000_000, 1, 2, src, ZERO_HASH);

    try std.testing.expectEqualSlices(u8, &r1.media_hash, &r2.media_hash);
}

test "canonical_media: Video verschiedene Bytes → verschiedene media_hash" {
    const mkv1 = [_]u8{0xAA} ** 104;
    const mkv2 = [_]u8{0xBB} ** 104;

    const r1 = try canonicalizeVideo(&mkv1, 640, 480, 25, 1, 5_000_000_000, 0, 0, ZERO_HASH, ZERO_HASH);
    const r2 = try canonicalizeVideo(&mkv2, 640, 480, 25, 1, 5_000_000_000, 0, 0, ZERO_HASH, ZERO_HASH);

    try std.testing.expect(!std.mem.eql(u8, &r1.media_hash, &r2.media_hash));
}

test "canonical_media: Video EmptyContent" {
    try std.testing.expectError(error.EmptyContent,
        canonicalizeVideo(&[_]u8{}, 1920, 1080, 30, 1, 0, 0, 0, ZERO_HASH, ZERO_HASH));
}

test "canonical_media: Video negative duration ist ungültig" {
    const mkv = [_]u8{0x00} ** 10;
    try std.testing.expectError(error.InvalidTimestamp,
        canonicalizeVideo(&mkv, 640, 480, 25, 1, -1, 0, 0, ZERO_HASH, ZERO_HASH));
}

test "canonical_media: Video InvalidDimensions" {
    const mkv = [_]u8{0x00} ** 10;
    try std.testing.expectError(error.InvalidDimensions,
        canonicalizeVideo(&mkv, 0, 480, 25, 1, 0, 0, 0, ZERO_HASH, ZERO_HASH));
}

test "canonical_media: Video MediaKind und Version korrekt" {
    const mkv = [_]u8{0x01} ** 20;
    const r = try canonicalizeVideo(&mkv, 320, 240, 24, 1, 1_000_000_000, 1, 1, ZERO_HASH, ZERO_HASH);
    try std.testing.expectEqual(MediaKind.video, r.media_kind);
    try std.testing.expectEqual(VIDEO_CANONICAL_VERSION, r.canonical_format_version);
}

test "canonical_media: domain_prefix entspricht media_kind" {
    const pcm = [_]u8{0x00} ** 300;
    const audio_rec = try canonicalizeAudio(&pcm, 1, 1_000_000, ZERO_HASH, ZERO_HASH);
    try std.testing.expectEqualSlices(u8, "BKGW", &audio_rec.domain_prefix);

    const pixels = [_]u8{0xFF} ** 16;
    const img_rec = try canonicalizeImage(2, 2, &pixels, ZERO_HASH, ZERO_HASH);
    try std.testing.expectEqualSlices(u8, "BKGP", &img_rec.domain_prefix);

    const mkv = [_]u8{0x01} ** 20;
    const vid_rec = try canonicalizeVideo(&mkv, 10, 10, 25, 1, 0, 0, 0, ZERO_HASH, ZERO_HASH);
    try std.testing.expectEqualSlices(u8, "BKGX", &vid_rec.domain_prefix);
}

test "canonical_media: media_hash nicht ZERO" {
    const allocator = std.testing.allocator;
    const txt = try canonicalizeText(allocator, "content\n", ZERO_HASH);
    defer allocator.free(txt.canonical);
    try std.testing.expect(!std.mem.eql(u8, &txt.record.media_hash, &ZERO_HASH));

    const pcm = [_]u8{0x01} ** 300;
    const aud = try canonicalizeAudio(&pcm, 1, 1_000_000, ZERO_HASH, ZERO_HASH);
    try std.testing.expect(!std.mem.eql(u8, &aud.media_hash, &ZERO_HASH));
}

test "canonical_media: source_hash bindet Provenance, nicht media_hash" {
    // Gleiches canonical Bild, verschiedene source_hashes → gleicher media_hash, verschiedene provenance_hash
    const pixels = [_]u8{0xAB} ** 16;
    var src1 = ZERO_HASH; src1[0] = 0x01;
    var src2 = ZERO_HASH; src2[0] = 0x02;

    const r1 = try canonicalizeImage(2, 2, &pixels, src1, ZERO_HASH);
    const r2 = try canonicalizeImage(2, 2, &pixels, src2, ZERO_HASH);

    try std.testing.expectEqualSlices(u8, &r1.media_hash, &r2.media_hash);
    try std.testing.expect(!std.mem.eql(u8, &r1.provenance_hash, &r2.provenance_hash));
}

test "canonical_media: Zeitangabe i64 Nanosekunden — keine floats" {
    // Beweise dass start_ns/duration_ns als i64 codiert werden
    const pcm = [_]u8{0x00} ** 300;
    const ns_1sec: i64 = 1_000_000_000;
    const r = try canonicalizeAudio(&pcm, 1, ns_1sec, ZERO_HASH, ZERO_HASH);
    // metadata_hash muss deterministisch und ohne float sein
    const meta = AudioMediaMetadata{
        .sample_rate = AUDIO_SAMPLE_RATE, .channels = 1, .bit_depth = 24,
        .byte_order = 1, .duration_ns = ns_1sec, .resampling_policy_hash = ZERO_HASH,
    };
    const expected_meta_hash = computeAudioMetadataHash(meta);
    try std.testing.expectEqualSlices(u8, &expected_meta_hash, &r.metadata_hash);
}

test "canonical_media: AUDIO_SAMPLE_RATE ist 48000" {
    try std.testing.expectEqual(@as(u32, 48_000), AUDIO_SAMPLE_RATE);
    try std.testing.expectEqual(@as(u8, 24), AUDIO_BIT_DEPTH);
    try std.testing.expectEqual(@as(u32, 128), AUDIO_RESAMPLER_TAPS);
}
