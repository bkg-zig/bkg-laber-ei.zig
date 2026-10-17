/// BKG Core — Clock
///
/// Zeitfunktionen für das gesamte Framework.
const std = @import("std");

/// Unix-Timestamp in Millisekunden
pub fn milliTimestamp() i64 {
    return std.time.milliTimestamp();
}

/// Unix-Timestamp in Sekunden
pub fn timestamp() i64 {
    return @divTrunc(std.time.milliTimestamp(), 1000);
}

/// Prüft ob ein Timestamp (Sekunden) in der Vergangenheit liegt
pub fn isExpired(ts: i64) bool {
    return ts < timestamp();
}

/// Gibt Timestamp + offset_seconds zurück
pub fn addSeconds(ts: i64, offset_seconds: i64) i64 {
    return ts + offset_seconds;
}

/// Timestamp in n Sekunden ab jetzt
pub fn inSeconds(n: i64) i64 {
    return timestamp() + n;
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "timestamp positive" {
    try std.testing.expect(timestamp() > 0);
}

test "isExpired past" {
    try std.testing.expect(isExpired(1000)); // weit in der Vergangenheit
}

test "isExpired future" {
    try std.testing.expect(!isExpired(inSeconds(3600)));
}

test "inSeconds" {
    const future = inSeconds(60);
    try std.testing.expect(future > timestamp());
}
