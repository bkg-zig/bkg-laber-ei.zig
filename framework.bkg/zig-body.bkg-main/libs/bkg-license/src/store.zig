// bkg-license: Lizenzspeicherung (in-memory + Datei-Persistenz)
const std = @import("std");
const payload_mod = @import("payload.zig");
const license_mod = @import("license.zig");

pub const LicenseType    = payload_mod.LicenseType;
pub const LicensePayload = payload_mod.LicensePayload;
pub const LicenseStatus  = payload_mod.LicenseStatus;
pub const StoredLicense  = payload_mod.StoredLicense;

pub const ActivateResult = struct {
    success: bool,
    err:     ?[]const u8   = null,
    license: ?StoredLicense = null,
};

/// In-Memory-Lizenzverwaltung.
/// Für persistente Speicherung: `save()`/`load()` mit Dateipfad nutzen.
pub const LicenseStore = struct {
    allocator: std.mem.Allocator,
    stored:    ?StoredLicense = null,

    pub fn init(allocator: std.mem.Allocator) LicenseStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LicenseStore) void {
        if (self.stored) |s| s.deinit(self.allocator);
        self.stored = null;
    }

    /// Lizenz aktivieren: validieren + speichern.
    pub fn activate(
        self: *LicenseStore,
        name: []const u8,
        key:  []const u8,
        current_host: ?[]const u8,
    ) ActivateResult {
        const status = license_mod.validate(self.allocator, key, current_host);

        if (!status.valid) {
            return .{ .success = false, .err = status.err };
        }

        // Name-Prüfung gegen Payload
        if (status.payload) |p| {
            const trimmed_name = std.mem.trim(u8, name, " ");
            if (!std.mem.eql(u8, p.name, trimmed_name)) {
                p.deinit(self.allocator);
                return .{ .success = false, .err = "Name stimmt nicht mit Lizenz überein" };
            }
            p.deinit(self.allocator);
        }

        // Alten Eintrag freigeben
        if (self.stored) |s| s.deinit(self.allocator);

        // Bereinigten Key speichern
        const clean_key = cleanKey: {
            var buf = std.ArrayList(u8).empty;
            for (key) |c| {
                if (c != ' ' and c != '\n' and c != '\r' and c != '\t')
                    buf.append(self.allocator, c) catch {
                        buf.deinit(self.allocator);
                        return .{ .success = false, .err = "OutOfMemory" };
                    };
            }
            break :cleanKey buf.toOwnedSlice(self.allocator) catch
                return .{ .success = false, .err = "OutOfMemory" };
        };

        var ts_spec: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.REALTIME, &ts_spec);
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts_spec.sec) };
        const day = epoch.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        var date_buf: [24]u8 = undefined;
        const date_str = std.fmt.bufPrint(&date_buf, "{d:0>4}-{d:0>2}-{d:0>2}T00:00:00Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
        }) catch "1970-01-01T00:00:00Z";

        const stored = StoredLicense{
            .name         = self.allocator.dupe(u8, std.mem.trim(u8, name, " ")) catch {
                self.allocator.free(clean_key);
                return .{ .success = false, .err = "OutOfMemory" };
            },
            .key          = clean_key,
            .activated_at = self.allocator.dupe(u8, date_str) catch {
                self.allocator.free(clean_key);
                return .{ .success = false, .err = "OutOfMemory" };
            },
        };

        self.stored = stored;
        return .{ .success = true, .license = stored };
    }

    /// Lizenz deaktivieren.
    pub fn deactivate(self: *LicenseStore) void {
        if (self.stored) |s| s.deinit(self.allocator);
        self.stored = null;
    }

    /// Prüft ob eine aktive Enterprise-Lizenz vorhanden ist.
    pub fn isEnterprise(self: *const LicenseStore) bool {
        const s = self.stored orelse return false;
        const status = license_mod.validate(self.allocator, s.key, null);
        const p = status.payload orelse return false;
        defer p.deinit(self.allocator);
        return p.type == .enterprise;
    }

    /// Prüft ob überhaupt eine gültige Lizenz vorhanden ist.
    pub fn isActive(self: *const LicenseStore) bool {
        const s = self.stored orelse return false;
        const status = license_mod.validate(self.allocator, s.key, null);
        const valid = status.valid;
        if (status.payload) |p| p.deinit(self.allocator);
        return valid;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "LicenseStore.init + deactivate" {
    var store = LicenseStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expect(!store.isEnterprise());
    store.deactivate(); // doppeltes deactivate sicher
}

test "LicenseStore.activate: ungültiges Format" {
    var store = LicenseStore.init(std.testing.allocator);
    defer store.deinit();

    const result = store.activate("Test", "kein-gültiger-key", null);
    try std.testing.expect(!result.success);
}
