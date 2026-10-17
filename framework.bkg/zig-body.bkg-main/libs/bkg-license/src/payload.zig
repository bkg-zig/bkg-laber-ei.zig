// bkg-license: Lizenz-Payload Typen
const std = @import("std");

/// Lizenztyp — enterprise hat RBAC + Environments + Audit-Log
pub const LicenseType = enum {
    enterprise,
    smb,
    unknown,

    pub fn fromString(s: []const u8) LicenseType {
        if (std.mem.eql(u8, s, "enterprise")) return .enterprise;
        if (std.mem.eql(u8, s, "smb")) return .smb;
        return .unknown;
    }

    pub fn toString(t: LicenseType) []const u8 {
        return switch (t) {
            .enterprise => "enterprise",
            .smb        => "smb",
            .unknown    => "unknown",
        };
    }
};

/// Dekodierter Lizenz-Payload (aus JSON)
pub const LicensePayload = struct {
    name:    []const u8,
    host:    []const u8,
    issued:  []const u8,
    expires: ?[]const u8, // null = kein Ablaufdatum
    type:    LicenseType,
    version: u32 = 2,     // v2 = RSA-signiert

    pub fn deinit(self: LicensePayload, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.host);
        allocator.free(self.issued);
        if (self.expires) |e| allocator.free(e);
    }
};

/// Validierungsergebnis
pub const LicenseStatus = struct {
    valid:   bool,
    active:  bool,
    payload: ?LicensePayload = null,
    err:     ?[]const u8     = null,

    pub const invalid_format = LicenseStatus{
        .valid = false, .active = false, .err = "Ungültiges Lizenzformat",
    };
    pub const invalid_signature = LicenseStatus{
        .valid = false, .active = false, .err = "Ungültige Lizenzsignatur",
    };
    pub const expired = LicenseStatus{
        .valid = false, .active = false, .err = "Lizenz abgelaufen",
    };

    pub fn deinit(self: LicenseStatus, allocator: std.mem.Allocator) void {
        if (self.payload) |p| p.deinit(allocator);
    }
};

/// Gespeicherte Lizenz (in der DB / Konfigurationsdatei)
pub const StoredLicense = struct {
    name:         []const u8,
    key:          []const u8, // bereinigter Lizenzschlüssel (kein Whitespace)
    activated_at: []const u8, // ISO 8601

    pub fn deinit(self: StoredLicense, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.key);
        allocator.free(self.activated_at);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "LicenseType.fromString" {
    const std2 = @import("std");
    try std2.testing.expectEqual(LicenseType.enterprise, LicenseType.fromString("enterprise"));
    try std2.testing.expectEqual(LicenseType.smb,        LicenseType.fromString("smb"));
    try std2.testing.expectEqual(LicenseType.unknown,    LicenseType.fromString("pro"));
}
