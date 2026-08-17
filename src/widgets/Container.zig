//! A Clay flexbox grouping node. By default has no visual representation of
//! its own -- just position/size -- needed because flexbox needs internal
//! nodes to group children under (e.g. a row that holds three text fields
//! side by side) that don't correspond to any drawn widget. Added in L2 of
//! the Clay layout integration (see the layout-engine plan / project
//! memory).
//!
//! W5: `background` is an opt-in flag (default false, so every existing
//! plain layout Container is unaffected) that gives it a fixed panel fill +
//! border, same "hardcoded Zig constant, not guest-settable" treatment
//! every other widget's color already gets -- this is not the start of a
//! guest-controllable styling system (that's separately-scoped, unstarted
//! project work), just closing the gap where a floating panel (Dropdown,
//! Modal) had no visible backdrop box at all.

const c = @import("../c.zig").c;

const Self = @This();

rect: c.SDL_FRect,
background: bool = false,

pub fn init(rect: c.SDL_FRect, background: bool) Self {
    return .{ .rect = rect, .background = background };
}

/// L4.5: same batched-fill precedent as `Button.fillColor` -- returns null
/// when `background` is false so plain layout containers stay entirely
/// undrawn, matching every caller's existing expectation.
pub fn fillColor(self: Self) ?c.SDL_Color {
    return if (self.background) .{ .r = 45, .g = 48, .b = 58, .a = 255 } else null;
}

/// Border only, drawn when `background` is true -- mirrors
/// `Button.drawDecorations`'s focus-ring border shape, just always-on
/// instead of focus-gated.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    if (!self.background) return;
    _ = c.SDL_SetRenderDrawColor(renderer, 80, 85, 100, 255);
    _ = c.SDL_RenderRect(renderer, &self.rect);
}
