// bkg-docker/stream.zig — Docker Streaming-Response
//
// Verarbeitet unbegrenzte Docker-API-Streams (Events, Logs ohne --follow,
// Stats einmalig) zeilenweise via Callback.
//
// Docker-Events und Log-Streams sind newline-delimited JSON oder Plaintext.
// Jede Zeile wird sofort an den Callback übergeben — kein Puffern bis EOF.
//
// Zig 0.16: std.ArrayList(u8).empty, appendRemaining über Reader-Interface.
const std = @import("std");

/// Callback-Typ: wird für jede gelesene Zeile aufgerufen.
/// - `line` ist gültig nur für die Dauer des Aufrufs (kein eigenes Lifetime)
/// - `ctx` ist ein opaker Zeiger auf den Aufrufer-Kontext
/// Rückgabe `true` → weiterlesen, `false` → Stream abbrechen.
pub const LineFn = *const fn (ctx: ?*anyopaque, line: []const u8) bool;

/// Liest einen Docker-HTTP-Response-Stream zeilenweise.
/// Erwartet einen bereits-gepufferten rohen Response-Body (kein Live-Socket).
/// Ruft `on_line` für jede \n-terminierte Zeile auf.
pub fn eachLine(
    body: []const u8,
    ctx: ?*anyopaque,
    on_line: LineFn,
) void {
    var remaining = body;
    while (remaining.len > 0) {
        const nl = std.mem.indexOfScalar(u8, remaining, '\n') orelse {
            // Letzte Zeile ohne \n: noch ausgeben, falls nicht leer
            const trimmed = std.mem.trimEnd(u8, remaining, "\r");
            if (trimmed.len > 0) _ = on_line(ctx, trimmed);
            break;
        };
        const line = std.mem.trimEnd(u8, remaining[0..nl], "\r");
        if (line.len > 0) {
            if (!on_line(ctx, line)) break;
        }
        remaining = remaining[nl + 1 ..];
    }
}

/// Sammelt alle Zeilen eines Response-Bodys in einem ArrayList.
/// Aufrufer ist verantwortlich für `result.deinit(allocator)`.
pub fn collectLines(
    allocator: std.mem.Allocator,
    body: []const u8,
    max_lines: usize,
) error{OutOfMemory}!std.ArrayList([]u8) {
    var lines = std.ArrayList([]u8).empty;
    errdefer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit(allocator);
    }

    var remaining = body;
    var count: usize = 0;
    while (remaining.len > 0 and count < max_lines) {
        const nl = std.mem.indexOfScalar(u8, remaining, '\n') orelse {
            const trimmed = std.mem.trimEnd(u8, remaining, "\r");
            if (trimmed.len > 0) {
                const owned = try allocator.dupe(u8, trimmed);
                try lines.append(allocator, owned);
                count += 1;
            }
            break;
        };
        const line = std.mem.trimEnd(u8, remaining[0..nl], "\r");
        if (line.len > 0) {
            const owned = try allocator.dupe(u8, line);
            try lines.append(allocator, owned);
            count += 1;
        }
        remaining = remaining[nl + 1 ..];
    }

    return lines;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "eachLine – drei Zeilen" {
    const body = "line1\nline2\nline3\n";
    var count: usize = 0;

    const S = struct {
        fn cb(ctx: ?*anyopaque, line: []const u8) bool {
            _ = line;
            const c: *usize = @alignCast(@ptrCast(ctx.?));
            c.* += 1;
            return true;
        }
    };

    eachLine(body, &count, S.cb);
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "eachLine – letzte Zeile ohne \\n" {
    const body = "hello\nworld";
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(std.testing.allocator);

    const S = struct {
        fn cb(ctx: ?*anyopaque, line: []const u8) bool {
            const list: *std.ArrayList([]const u8) = @alignCast(@ptrCast(ctx.?));
            list.append(std.testing.allocator, line) catch {};
            return true;
        }
    };

    eachLine(body, &lines, S.cb);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("hello", lines.items[0]);
    try std.testing.expectEqualStrings("world", lines.items[1]);
}

test "eachLine – CRLF wird getrimmt" {
    const body = "line1\r\nline2\r\n";
    var last: []const u8 = "";

    const S = struct {
        fn cb(ctx: ?*anyopaque, line: []const u8) bool {
            const p: *[]const u8 = @alignCast(@ptrCast(ctx.?));
            p.* = line;
            return true;
        }
    };

    eachLine(body, &last, S.cb);
    try std.testing.expectEqualStrings("line2", last);
}

test "eachLine – Abbruch via false" {
    const body = "a\nb\nc\n";
    var count: usize = 0;

    const S = struct {
        fn cb(ctx: ?*anyopaque, _: []const u8) bool {
            const c: *usize = @alignCast(@ptrCast(ctx.?));
            c.* += 1;
            return c.* < 2; // Nach der zweiten Zeile abbrechen
        }
    };

    eachLine(body, &count, S.cb);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "collectLines – max_lines limit" {
    const body = "a\nb\nc\nd\n";
    var result = try collectLines(std.testing.allocator, body, 2);
    defer {
        for (result.items) |l| std.testing.allocator.free(l);
        result.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("a", result.items[0]);
    try std.testing.expectEqualStrings("b", result.items[1]);
}
