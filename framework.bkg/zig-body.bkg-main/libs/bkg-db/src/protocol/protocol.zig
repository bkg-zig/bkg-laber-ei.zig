/// BKGDB Protocol — Re-export aller Protokoll-Module
///
/// Baseline verriegelt: 2026-09-01
///
/// Import-Pfad aus bkg-db:
///   const protocol = @import("bkg-db").protocol;
///   protocol.events.EventType
///   protocol.ledger.LedgerEventEnvelope
///   protocol.state.HarnessManifestation
///   protocol.ids.CID
pub const events = @import("events.zig");
pub const ids    = @import("ids.zig");
pub const ledger = @import("ledger.zig");
pub const state  = @import("state.zig");
