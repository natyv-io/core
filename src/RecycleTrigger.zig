//! Decides when Dispatch recycles the guest, from process RSS read after
//! each dispatch. Split out of Dispatch.zig (which imports SDL) so the
//! policy has its own test root.
//!
//! Two guards against thrashing:
//! - A cooldown: after a recycle, RSS isn't checked for
//!   `cooldown_dispatches` dispatches. RSS can drift past the threshold
//!   meanwhile, so the threshold is a soft ceiling.
//! - A floor check: the first reading after the cooldown is the
//!   post-recycle floor. If it's still at or over the threshold, another
//!   recycle can't bring RSS down -- guest compilation alone spikes RSS
//!   (130-200+ MB in Debug), and each recycle compiles a new instance, so
//!   a threshold near that peak recycled in a loop. The effective
//!   threshold is raised to the floor plus half the configured threshold
//!   instead, and drops back to the configured one on the first reading
//!   under it.
const RecycleTrigger = @This();

pub const cooldown_dispatches: u32 = 3;

configured: u64,
effective: u64,
cooldown_remaining: u32 = 0,
measuring_floor: bool = false,

pub const Decision = union(enum) {
    none,
    recycle,
    /// The post-recycle floor was at or over the threshold; the effective
    /// threshold is now `.raised_to` bytes.
    raised_to: u64,
};

pub fn init(threshold_bytes: u64) RecycleTrigger {
    return .{ .configured = threshold_bytes, .effective = threshold_bytes };
}

/// Called once per dispatch. False while cooling down, so the caller can
/// skip the RSS syscall entirely.
pub fn shouldMeasure(self: *RecycleTrigger) bool {
    if (self.cooldown_remaining > 0) {
        self.cooldown_remaining -= 1;
        return false;
    }
    return true;
}

pub fn observe(self: *RecycleTrigger, rss: u64) Decision {
    if (rss < self.configured) {
        self.effective = self.configured;
        self.measuring_floor = false;
        return .none;
    }
    if (self.measuring_floor) {
        self.measuring_floor = false;
        self.effective = rss +| self.configured / 2;
        return .{ .raised_to = self.effective };
    }
    return if (rss >= self.effective) .recycle else .none;
}

/// Called after every recycle attempt. The floor is only measured after
/// one that succeeded.
pub fn recycled(self: *RecycleTrigger, succeeded: bool) void {
    self.cooldown_remaining = cooldown_dispatches;
    self.measuring_floor = succeeded;
}

const std = @import("std");
const mb = 1024 * 1024;

fn coolDown(t: *RecycleTrigger) !void {
    for (0..cooldown_dispatches) |_| try std.testing.expect(!t.shouldMeasure());
    try std.testing.expect(t.shouldMeasure());
}

test "recycles at the threshold, then cools down" {
    var t = init(200 * mb);
    try std.testing.expect(t.shouldMeasure());
    try std.testing.expectEqual(Decision.none, t.observe(199 * mb));
    try std.testing.expectEqual(Decision.recycle, t.observe(200 * mb));
    t.recycled(true);
    try coolDown(&t);
}

test "a floor under the threshold keeps the configured threshold" {
    var t = init(200 * mb);
    try std.testing.expectEqual(Decision.recycle, t.observe(250 * mb));
    t.recycled(true);
    try coolDown(&t);
    try std.testing.expectEqual(Decision.none, t.observe(60 * mb));
    try std.testing.expectEqual(Decision.recycle, t.observe(200 * mb));
}

test "a floor over the threshold raises it instead of recycling again" {
    var t = init(200 * mb);
    try std.testing.expectEqual(Decision.recycle, t.observe(210 * mb));
    t.recycled(true);
    try coolDown(&t);
    try std.testing.expectEqual(Decision{ .raised_to = 310 * mb }, t.observe(210 * mb));
    try std.testing.expectEqual(Decision.none, t.observe(309 * mb));
    try std.testing.expectEqual(Decision.recycle, t.observe(310 * mb));
}

test "the raised threshold drops back once RSS falls under the configured one" {
    var t = init(200 * mb);
    _ = t.observe(210 * mb);
    t.recycled(true);
    try coolDown(&t);
    _ = t.observe(210 * mb);
    try std.testing.expectEqual(Decision.none, t.observe(50 * mb));
    try std.testing.expectEqual(Decision.recycle, t.observe(200 * mb));
}

test "a failed recycle cools down but doesn't measure a floor" {
    var t = init(200 * mb);
    try std.testing.expectEqual(Decision.recycle, t.observe(210 * mb));
    t.recycled(false);
    try coolDown(&t);
    try std.testing.expectEqual(Decision.recycle, t.observe(210 * mb));
}

test "the raised threshold saturates instead of overflowing" {
    var t = init(std.math.maxInt(u64));
    t.measuring_floor = true;
    try std.testing.expectEqual(Decision{ .raised_to = std.math.maxInt(u64) }, t.observe(std.math.maxInt(u64)));
}
