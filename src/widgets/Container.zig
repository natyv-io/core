//! Layout-only widget: a Clay flexbox grouping node with no visual
//! representation of its own -- just position/size. Needed because flexbox
//! needs internal nodes to group children under (e.g. a row that holds
//! three text fields side by side) that don't correspond to any drawn
//! widget. Added in L2 of the Clay layout integration (see the
//! layout-engine plan / project memory). Unlike Button/TextField/Label,
//! this has no `draw` method -- callers must special-case `.container` in
//! any switch over `Widget` that draws or hit-tests, the same way natyv
//! already special-cases `.label` (no click handling).

const c = @import("../c.zig").c;

const Self = @This();

rect: c.SDL_FRect,

pub fn init(rect: c.SDL_FRect) Self {
    return .{ .rect = rect };
}
