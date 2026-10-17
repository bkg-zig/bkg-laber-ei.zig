/// BKG Core — ID Generation
///
/// UUID v4 Generierung und ID-Typen.
const std = @import("std");

// ── UUID v4 ───────────────────────────────────────────────────────────────

pub const UUID = [36]u8;

/// Generiert eine neue UUID v4 als String (z.B. "550e8400-e29b-41d4-a716-446655440000")
pub fn newUUID(io: std.Io) UUID {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);

    // Version 4: bits 12-15 = 0100
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Variant: bits 6-7 = 10
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    var uuid: UUID = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    var j: usize = 0;

    while (i < 16) : (i += 1) {
        if (j == 8 or j == 13 or j == 18 or j == 23) {
            uuid[j] = '-';
            j += 1;
        }
        uuid[j] = hex[bytes[i] >> 4];
        uuid[j + 1] = hex[bytes[i] & 0x0f];
        j += 2;
    }

    return uuid;
}

/// Gibt die UUID als Slice zurück
pub fn uuidSlice(uuid: *const UUID) []const u8 {
    return uuid[0..];
}

/// Prüft ob ein String eine gültige UUID v4 ist
pub fn isValidUUID(s: []const u8) bool {
    if (s.len != 36) return false;
    if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "newUUID format" {
    const uuid = newUUID(std.testing.io);
    try std.testing.expectEqual(@as(usize, 36), uuid.len);
    try std.testing.expectEqual('-', uuid[8]);
    try std.testing.expectEqual('-', uuid[13]);
    try std.testing.expectEqual('-', uuid[18]);
    try std.testing.expectEqual('-', uuid[23]);
    // Version 4: Zeichen an Position 14 muss '4' sein
    try std.testing.expectEqual('4', uuid[14]);
}

test "isValidUUID" {
    try std.testing.expect(isValidUUID("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidUUID("not-a-uuid"));
    try std.testing.expect(!isValidUUID("550e8400-e29b-41d4-a716-44665544000")); // zu kurz
}

test "newUUID is unique" {
    const a = newUUID(std.testing.io);
    const b = newUUID(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
