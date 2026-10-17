/// BKG Core — Application Lifecycle
///
/// Definiert den Lebenszyklus einer Anwendung.
const std = @import("std");

pub const LifecycleState = enum {
    created,
    configuring,
    initializing,
    starting,
    running,
    stopping,
    stopped,
};

pub const Lifecycle = struct {
    state: LifecycleState = .created,

    pub fn transition(self: *Lifecycle, next: LifecycleState) !void {
        const valid = switch (self.state) {
            .created => next == .configuring,
            .configuring => next == .initializing,
            .initializing => next == .starting,
            .starting => next == .running,
            .running => next == .stopping,
            .stopping => next == .stopped,
            .stopped => false,
        };
        if (!valid) return error.InvalidTransition;
        self.state = next;
    }

    pub fn isRunning(self: Lifecycle) bool {
        return self.state == .running;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "Lifecycle valid transitions" {
    var lc = Lifecycle{};
    try lc.transition(.configuring);
    try lc.transition(.initializing);
    try lc.transition(.starting);
    try lc.transition(.running);
    try std.testing.expect(lc.isRunning());
    try lc.transition(.stopping);
    try lc.transition(.stopped);
}

test "Lifecycle invalid transition" {
    var lc = Lifecycle{};
    try std.testing.expectError(error.InvalidTransition, lc.transition(.running));
}
