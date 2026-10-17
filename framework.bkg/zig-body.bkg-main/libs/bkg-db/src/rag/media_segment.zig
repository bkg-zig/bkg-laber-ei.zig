/// BKGDB Stage 3.1.A — Media Segment Records
///
/// Implementiert Segment-Records für alle Modalitäten gemäß Contract §13–§17.
/// Domains: BKGT (KnowledgeChunk), BKGJ (AudioSegment), BKGK (VideoSegment),
///          BKGP (ImageSegment), BKGF (FrameSample)
///
const std = @import("std");
const dr = @import("domain_registry.zig");

// ── Fehlertypen ───────────────────────────────────────────────────────────

pub const SegmentError = error{
    /// end_ns <= start_ns
    InvalidTimestamp,
    /// chunk ohne Inhalt
    EmptyContent,
    /// ImageSegment-Dimensionen ungültig (z. B. Breite/Höhe = 0)
    InvalidDimensions,
};

// ── §13 KnowledgeChunk — BKGT (DOMAIN_RETRIEVAL_EVIDENCE) ────────────────

pub const KnowledgeChunk = struct {
    /// "BKGT"
    domain_prefix: [4]u8,
    /// SHA256("BKGT" || parent_media_hash || chunk_index_le8 || content_hash)
    chunk_hash: [32]u8,
    parent_media_hash: [32]u8,
    chunk_index: u64,
    chunking_version: u16,
    normalization_version: u16,
    byte_start: u64,
    byte_end: u64,
    parent_context_hash: [32]u8,
    /// SHA256 des Chunk-Inhalts
    content_hash: [32]u8,
    content_size: u32,
};

/// Berechnet chunk_hash = SHA256("BKGT" || parent_media_hash || chunk_index_le8 || content_hash)
pub fn computeChunkHash(
    parent_media_hash: [32]u8,
    chunk_index: u64,
    content_hash: [32]u8,
) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&dr.DOMAIN_RETRIEVAL_EVIDENCE);
    h.update(&parent_media_hash);
    var idx_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &idx_buf, chunk_index, .little);
    h.update(&idx_buf);
    h.update(&content_hash);
    return h.finalResult();
}

/// Konstruiert einen KnowledgeChunk aus rohem Content.
/// content_hash = SHA256(content), chunk_hash über computeChunkHash.
pub fn buildChunk(
    parent_media_hash: [32]u8,
    chunk_index: u64,
    chunking_version: u16,
    normalization_version: u16,
    byte_start: u64,
    byte_end: u64,
    parent_context_hash: [32]u8,
    content: []const u8,
) KnowledgeChunk {
    // content_hash
    var ch = std.crypto.hash.sha2.Sha256.init(.{});
    ch.update(content);
    const content_hash = ch.finalResult();

    const chunk_hash = computeChunkHash(parent_media_hash, chunk_index, content_hash);

    return KnowledgeChunk{
        .domain_prefix = dr.DOMAIN_RETRIEVAL_EVIDENCE,
        .chunk_hash = chunk_hash,
        .parent_media_hash = parent_media_hash,
        .chunk_index = chunk_index,
        .chunking_version = chunking_version,
        .normalization_version = normalization_version,
        .byte_start = byte_start,
        .byte_end = byte_end,
        .parent_context_hash = parent_context_hash,
        .content_hash = content_hash,
        .content_size = @intCast(content.len),
    };
}

// ── §14 AudioSegment — BKGJ (DOMAIN_AUDIO_SEGMENT) ───────────────────────

pub const AudioSegment = struct {
    /// "BKGJ"
    domain_prefix: [4]u8,
    /// SHA256("BKGJ" || parent_media_hash || segment_index_le8 || start_ns_le8 || end_ns_le8)
    segment_hash: [32]u8,
    parent_media_hash: [32]u8,
    segment_index: u64,
    /// Integer-Nanosekunden
    start_ns: i64,
    end_ns: i64,
    sample_count: u64,
    segmentation_version: u16,
    /// ZERO = kein Transkript
    transcript_hash: [32]u8,
    acoustic_feature_hash: [32]u8,
    speaker_feature_hash: [32]u8,
    semantic_feature_hash: [32]u8,
};

/// Berechnet segment_hash = SHA256("BKGJ" || parent_media_hash || segment_index_le8 || start_ns_le8 || end_ns_le8)
pub fn computeAudioSegmentHash(
    parent_media_hash: [32]u8,
    segment_index: u64,
    start_ns: i64,
    end_ns: i64,
) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&dr.DOMAIN_AUDIO_SEGMENT);
    h.update(&parent_media_hash);
    var buf8: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf8, segment_index, .little);
    h.update(&buf8);
    std.mem.writeInt(i64, &buf8, start_ns, .little);
    h.update(&buf8);
    std.mem.writeInt(i64, &buf8, end_ns, .little);
    h.update(&buf8);
    return h.finalResult();
}

/// Konstruiert ein AudioSegment. Gibt InvalidTimestamp wenn end_ns <= start_ns.
pub fn buildAudioSegment(
    parent_media_hash: [32]u8,
    segment_index: u64,
    segmentation_version: u16,
    start_ns: i64,
    end_ns: i64,
    sample_count: u64,
) SegmentError!AudioSegment {
    if (end_ns <= start_ns) return SegmentError.InvalidTimestamp;
    return AudioSegment{
        .domain_prefix = dr.DOMAIN_AUDIO_SEGMENT,
        .segment_hash = computeAudioSegmentHash(parent_media_hash, segment_index, start_ns, end_ns),
        .parent_media_hash = parent_media_hash,
        .segment_index = segment_index,
        .start_ns = start_ns,
        .end_ns = end_ns,
        .sample_count = sample_count,
        .segmentation_version = segmentation_version,
        .transcript_hash = [_]u8{0} ** 32,
        .acoustic_feature_hash = [_]u8{0} ** 32,
        .speaker_feature_hash = [_]u8{0} ** 32,
        .semantic_feature_hash = [_]u8{0} ** 32,
    };
}

// ── §15 VideoSegment — BKGK (DOMAIN_VIDEO_SEGMENT) ───────────────────────

pub const VideoSegment = struct {
    /// "BKGK"
    domain_prefix: [4]u8,
    /// SHA256("BKGK" || parent_media_hash || segment_index_le8 || start_ns_le8 || end_ns_le8)
    segment_hash: [32]u8,
    parent_media_hash: [32]u8,
    segment_index: u64,
    start_ns: i64,
    end_ns: i64,
    frame_count: u64,
    segmentation_version: u16,
    visual_feature_hash: [32]u8,
    transcript_hash: [32]u8,
    audio_feature_hash: [32]u8,
    multimodal_embed_hash: [32]u8,
};

/// Berechnet segment_hash = SHA256("BKGK" || parent_media_hash || segment_index_le8 || start_ns_le8 || end_ns_le8)
pub fn computeVideoSegmentHash(
    parent_media_hash: [32]u8,
    segment_index: u64,
    start_ns: i64,
    end_ns: i64,
) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&dr.DOMAIN_VIDEO_SEGMENT);
    h.update(&parent_media_hash);
    var buf8: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf8, segment_index, .little);
    h.update(&buf8);
    std.mem.writeInt(i64, &buf8, start_ns, .little);
    h.update(&buf8);
    std.mem.writeInt(i64, &buf8, end_ns, .little);
    h.update(&buf8);
    return h.finalResult();
}

/// Konstruiert ein VideoSegment. Gibt InvalidTimestamp wenn end_ns <= start_ns.
pub fn buildVideoSegment(
    parent_media_hash: [32]u8,
    segment_index: u64,
    segmentation_version: u16,
    start_ns: i64,
    end_ns: i64,
    frame_count: u64,
) SegmentError!VideoSegment {
    if (end_ns <= start_ns) return SegmentError.InvalidTimestamp;
    return VideoSegment{
        .domain_prefix = dr.DOMAIN_VIDEO_SEGMENT,
        .segment_hash = computeVideoSegmentHash(parent_media_hash, segment_index, start_ns, end_ns),
        .parent_media_hash = parent_media_hash,
        .segment_index = segment_index,
        .start_ns = start_ns,
        .end_ns = end_ns,
        .frame_count = frame_count,
        .segmentation_version = segmentation_version,
        .visual_feature_hash = [_]u8{0} ** 32,
        .transcript_hash = [_]u8{0} ** 32,
        .audio_feature_hash = [_]u8{0} ** 32,
        .multimodal_embed_hash = [_]u8{0} ** 32,
    };
}

// ── §16 ImageSegment (Region of Interest) — BKGP (DOMAIN_IMAGE_UNIT) ─────

pub const ImageSegment = struct {
    /// "BKGP"
    domain_prefix: [4]u8,
    /// SHA256("BKGP" || parent_media_hash || segment_index_le8 || x_le4 || y_le4 || w_le4 || h_le4)
    segment_hash: [32]u8,
    parent_media_hash: [32]u8,
    segment_index: u64,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    visual_feature_hash: [32]u8,
    ocr_artifact_hash: [32]u8,
    caption_artifact_hash: [32]u8,
};

/// Berechnet segment_hash = SHA256("BKGP" || parent_media_hash || segment_index_le8 || x_le4 || y_le4 || w_le4 || h_le4)
pub fn computeImageSegmentHash(
    parent_media_hash: [32]u8,
    segment_index: u64,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
) [32]u8 {
    var hsh = std.crypto.hash.sha2.Sha256.init(.{});
    hsh.update(&dr.DOMAIN_IMAGE_UNIT);
    hsh.update(&parent_media_hash);
    var buf8: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf8, segment_index, .little);
    hsh.update(&buf8);
    var buf4: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf4, x, .little);
    hsh.update(&buf4);
    std.mem.writeInt(u32, &buf4, y, .little);
    hsh.update(&buf4);
    std.mem.writeInt(u32, &buf4, w, .little);
    hsh.update(&buf4);
    std.mem.writeInt(u32, &buf4, h, .little);
    hsh.update(&buf4);
    return hsh.finalResult();
}

/// Konstruiert ein ImageSegment.
pub fn buildImageSegment(
    parent_media_hash: [32]u8,
    segment_index: u64,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) ImageSegment {
    return ImageSegment{
        .domain_prefix = dr.DOMAIN_IMAGE_UNIT,
        .segment_hash = computeImageSegmentHash(parent_media_hash, segment_index, x, y, width, height),
        .parent_media_hash = parent_media_hash,
        .segment_index = segment_index,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .visual_feature_hash = [_]u8{0} ** 32,
        .ocr_artifact_hash = [_]u8{0} ** 32,
        .caption_artifact_hash = [_]u8{0} ** 32,
    };
}

// ── §17 FrameSample — BKGF (DOMAIN_FRAME_SAMPLE) ─────────────────────────

pub const FrameSample = struct {
    /// "BKGF"
    domain_prefix: [4]u8,
    /// SHA256("BKGF" || source_media_hash || frame_index_le8 || timestamp_ns_le8)
    frame_hash: [32]u8,
    source_media_hash: [32]u8,
    frame_index: u64,
    /// Integer-Nanosekunden (i64)
    timestamp_ns: i64,
    sampling_policy_hash: [32]u8,
    width: u32,
    height: u32,
};

/// Berechnet frame_hash = SHA256("BKGF" || source_media_hash || frame_index_le8 || timestamp_ns_le8)
pub fn computeFrameHash(
    source_media_hash: [32]u8,
    frame_index: u64,
    timestamp_ns: i64,
) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&dr.DOMAIN_FRAME_SAMPLE);
    h.update(&source_media_hash);
    var buf8: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf8, frame_index, .little);
    h.update(&buf8);
    std.mem.writeInt(i64, &buf8, timestamp_ns, .little);
    h.update(&buf8);
    return h.finalResult();
}

/// Konstruiert ein FrameSample.
pub fn buildFrameSample(
    source_media_hash: [32]u8,
    frame_index: u64,
    timestamp_ns: i64,
    sampling_policy_hash: [32]u8,
    width: u32,
    height: u32,
) FrameSample {
    return FrameSample{
        .domain_prefix = dr.DOMAIN_FRAME_SAMPLE,
        .frame_hash = computeFrameHash(source_media_hash, frame_index, timestamp_ns),
        .source_media_hash = source_media_hash,
        .frame_index = frame_index,
        .timestamp_ns = timestamp_ns,
        .sampling_policy_hash = sampling_policy_hash,
        .width = width,
        .height = height,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "media_segment: computeChunkHash ist deterministisch" {
    const pmh = [_]u8{0xAA} ** 32;
    const ch = [_]u8{0xBB} ** 32;
    const h1 = computeChunkHash(pmh, 0, ch);
    const h2 = computeChunkHash(pmh, 0, ch);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "media_segment: computeChunkHash bindet parent_media_hash" {
    const ch = [_]u8{0xCC} ** 32;
    const h1 = computeChunkHash([_]u8{0x01} ** 32, 0, ch);
    const h2 = computeChunkHash([_]u8{0x02} ** 32, 0, ch);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "media_segment: chunk_index 0 != chunk_index 1 gleicher Inhalt" {
    const pmh = [_]u8{0x55} ** 32;
    const ch = [_]u8{0x66} ** 32;
    const h0 = computeChunkHash(pmh, 0, ch);
    const h1 = computeChunkHash(pmh, 1, ch);
    try std.testing.expect(!std.mem.eql(u8, &h0, &h1));
}

test "media_segment: chunk_hash ist nicht ZERO" {
    const pmh = [_]u8{0x11} ** 32;
    const ch = [_]u8{0x22} ** 32;
    const h = computeChunkHash(pmh, 42, ch);
    const zero = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &h, &zero));
}

test "media_segment: buildChunk setzt content_hash = SHA256(content)" {
    const pmh = [_]u8{0x33} ** 32;
    const pctx = [_]u8{0x44} ** 32;
    const content = "hello world";
    const chunk = buildChunk(pmh, 0, 1, 1, 0, 11, pctx, content);
    var expected_ch = std.crypto.hash.sha2.Sha256.init(.{});
    expected_ch.update(content);
    const expected = expected_ch.finalResult();
    try std.testing.expectEqualSlices(u8, &expected, &chunk.content_hash);
}

test "media_segment: buildChunk verschiedene Inhalte → verschiedene chunk_hash" {
    const pmh = [_]u8{0x77} ** 32;
    const pctx = [_]u8{0x88} ** 32;
    const c1 = buildChunk(pmh, 0, 1, 1, 0, 5, pctx, "hello");
    const c2 = buildChunk(pmh, 0, 1, 1, 0, 5, pctx, "world");
    try std.testing.expect(!std.mem.eql(u8, &c1.chunk_hash, &c2.chunk_hash));
}

test "media_segment: buildChunk domain_prefix korrekt" {
    const pmh = [_]u8{0} ** 32;
    const pctx = [_]u8{0} ** 32;
    const chunk = buildChunk(pmh, 0, 1, 1, 0, 4, pctx, "test");
    try std.testing.expectEqualSlices(u8, "BKGT", &chunk.domain_prefix);
}

test "media_segment: computeAudioSegmentHash ist deterministisch" {
    const pmh = [_]u8{0xAA} ** 32;
    const h1 = computeAudioSegmentHash(pmh, 0, 0, 1_000_000_000);
    const h2 = computeAudioSegmentHash(pmh, 0, 0, 1_000_000_000);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "media_segment: buildAudioSegment InvalidTimestamp wenn end_ns <= start_ns" {
    const pmh = [_]u8{0} ** 32;
    try std.testing.expectError(SegmentError.InvalidTimestamp, buildAudioSegment(pmh, 0, 1, 100, 100, 0));
    try std.testing.expectError(SegmentError.InvalidTimestamp, buildAudioSegment(pmh, 0, 1, 200, 100, 0));
}

test "media_segment: buildAudioSegment start_ns=0 ist gültig" {
    const pmh = [_]u8{0x10} ** 32;
    const seg = try buildAudioSegment(pmh, 0, 1, 0, 1_000_000, 44100);
    try std.testing.expectEqual(@as(i64, 0), seg.start_ns);
    try std.testing.expectEqual(@as(i64, 1_000_000), seg.end_ns);
}

test "media_segment: buildAudioSegment domain_prefix korrekt" {
    const pmh = [_]u8{0} ** 32;
    const seg = try buildAudioSegment(pmh, 0, 1, 0, 1000, 100);
    try std.testing.expectEqualSlices(u8, "BKGJ", &seg.domain_prefix);
}

test "media_segment: AudioSegment verschiedene segment_index → verschiedene segment_hash" {
    const pmh = [_]u8{0x20} ** 32;
    const h0 = computeAudioSegmentHash(pmh, 0, 0, 1000);
    const h1 = computeAudioSegmentHash(pmh, 1, 0, 1000);
    try std.testing.expect(!std.mem.eql(u8, &h0, &h1));
}

test "media_segment: computeVideoSegmentHash ist deterministisch" {
    const pmh = [_]u8{0xBB} ** 32;
    const h1 = computeVideoSegmentHash(pmh, 5, 0, 2_000_000_000);
    const h2 = computeVideoSegmentHash(pmh, 5, 0, 2_000_000_000);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "media_segment: buildVideoSegment InvalidTimestamp wenn end_ns <= start_ns" {
    const pmh = [_]u8{0} ** 32;
    try std.testing.expectError(SegmentError.InvalidTimestamp, buildVideoSegment(pmh, 0, 1, 500, 500, 0));
    try std.testing.expectError(SegmentError.InvalidTimestamp, buildVideoSegment(pmh, 0, 1, 500, 300, 0));
}

test "media_segment: buildVideoSegment domain_prefix korrekt" {
    const pmh = [_]u8{0} ** 32;
    const seg = try buildVideoSegment(pmh, 0, 1, 0, 1000, 30);
    try std.testing.expectEqualSlices(u8, "BKGK", &seg.domain_prefix);
}

test "media_segment: VideoSegment verschiedene start_ns → verschiedene segment_hash" {
    const pmh = [_]u8{0x30} ** 32;
    const h1 = computeVideoSegmentHash(pmh, 0, 0, 1000);
    const h2 = computeVideoSegmentHash(pmh, 0, 500, 1000);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "media_segment: computeImageSegmentHash ist deterministisch" {
    const pmh = [_]u8{0xCC} ** 32;
    const h1 = computeImageSegmentHash(pmh, 0, 10, 20, 100, 200);
    const h2 = computeImageSegmentHash(pmh, 0, 10, 20, 100, 200);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "media_segment: ImageSegment SHA256 bindet x, y, w, h" {
    const pmh = [_]u8{0x40} ** 32;
    const h_base = computeImageSegmentHash(pmh, 0, 10, 20, 100, 200);
    const h_x = computeImageSegmentHash(pmh, 0, 11, 20, 100, 200);
    const h_y = computeImageSegmentHash(pmh, 0, 10, 21, 100, 200);
    const h_w = computeImageSegmentHash(pmh, 0, 10, 20, 101, 200);
    const h_h = computeImageSegmentHash(pmh, 0, 10, 20, 100, 201);
    try std.testing.expect(!std.mem.eql(u8, &h_base, &h_x));
    try std.testing.expect(!std.mem.eql(u8, &h_base, &h_y));
    try std.testing.expect(!std.mem.eql(u8, &h_base, &h_w));
    try std.testing.expect(!std.mem.eql(u8, &h_base, &h_h));
}

test "media_segment: buildImageSegment domain_prefix korrekt" {
    const pmh = [_]u8{0} ** 32;
    const seg = buildImageSegment(pmh, 0, 0, 0, 640, 480);
    try std.testing.expectEqualSlices(u8, "BKGP", &seg.domain_prefix);
}

test "media_segment: computeFrameHash ist deterministisch" {
    const smh = [_]u8{0xDD} ** 32;
    const h1 = computeFrameHash(smh, 42, 1_000_000_000);
    const h2 = computeFrameHash(smh, 42, 1_000_000_000);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "media_segment: FrameSample timestamp_ns ist i64 (kein float)" {
    const smh = [_]u8{0xEE} ** 32;
    const policy = [_]u8{0x01} ** 32;
    const fs = buildFrameSample(smh, 0, -1_000_000_000, policy, 1920, 1080);
    // Negative Timestamps sind möglich (z. B. vor Epoch)
    try std.testing.expectEqual(@as(i64, -1_000_000_000), fs.timestamp_ns);
}

test "media_segment: sampling_policy_hash ist Teil der Frame-Identität (domain_prefix)" {
    const smh = [_]u8{0xFF} ** 32;
    const p1 = [_]u8{0x01} ** 32;
    const p2 = [_]u8{0x02} ** 32;
    // frame_hash hängt NICHT von policy ab (computeFrameHash nutzt kein policy)
    // sampling_policy_hash ist im Struct gespeichert (Identität des Records)
    const fs1 = buildFrameSample(smh, 0, 0, p1, 100, 100);
    const fs2 = buildFrameSample(smh, 0, 0, p2, 100, 100);
    // frame_hash identisch (policy ist kein Hash-Input per Spec)
    try std.testing.expectEqualSlices(u8, &fs1.frame_hash, &fs2.frame_hash);
    // sampling_policy_hash verschieden → Records verschieden
    try std.testing.expect(!std.mem.eql(u8, &fs1.sampling_policy_hash, &fs2.sampling_policy_hash));
}

test "media_segment: buildFrameSample domain_prefix korrekt" {
    const smh = [_]u8{0} ** 32;
    const policy = [_]u8{0} ** 32;
    const fs = buildFrameSample(smh, 0, 0, policy, 1920, 1080);
    try std.testing.expectEqualSlices(u8, "BKGF", &fs.domain_prefix);
}

test "media_segment: FrameSample verschiedene frame_index → verschiedene frame_hash" {
    const smh = [_]u8{0x50} ** 32;
    const h0 = computeFrameHash(smh, 0, 0);
    const h1 = computeFrameHash(smh, 1, 0);
    try std.testing.expect(!std.mem.eql(u8, &h0, &h1));
}

test "media_segment: FrameSample frame_hash ist nicht ZERO" {
    const smh = [_]u8{0x60} ** 32;
    const h = computeFrameHash(smh, 0, 0);
    const zero = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &h, &zero));
}
