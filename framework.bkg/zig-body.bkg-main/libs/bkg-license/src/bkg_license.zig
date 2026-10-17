/// BKG License — RSA-SHA256 Lizenzvalidierung + Verwaltung
///
/// Lizenzformat: <base64url-payload>.<base64url-signature>
/// Payload = JSON: { name, host, issued, expires, type }
/// Typen: "enterprise" | "smb"
/// Signatur = RSA-SHA256 über den rohen Payload-Base64url-String.
pub const license = @import("license.zig");
pub const payload = @import("payload.zig");
pub const store = @import("store.zig");

test {
    _ = license;
    _ = payload;
    _ = store;
}
