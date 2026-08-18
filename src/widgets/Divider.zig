//! W11: a thin visual rule -- horizontal or vertical is entirely a
//! function of what sizing the guest requests (Fixed height + grow width
//! for a horizontal line, Fixed width + grow height for a vertical one),
//! same as how ProgressBar/Slider don't know their own "orientation"
//! either -- there's no separate field for it here, just a rect. Purely
//! decorative: no text, no focus, not hit-testable, no events -- the
//! simplest widget kind in the registry. Not built on top of Container's
//! `background` flag (a fixed panel-fill-plus-border meant for floating
//! backdrops, see Container.zig's doc comment) since a divider needs a
//! thinner, more subtle fill with no border at all -- reusing `background`
//! here would mean every divider in every app looks like a tiny bordered
//! panel, not a line.

const c = @import("../c.zig").c;

const Self = @This();

rect: c.SDL_FRect,

pub fn init(rect: c.SDL_FRect) Self {
    return .{ .rect = rect };
}

/// L4.5: same batched-fill precedent as every other widget's fillColor --
/// always returns a color (unlike Container's opt-in), since a divider
/// with nothing drawn isn't a divider at all.
pub fn fillColor(self: Self) c.SDL_Color {
    _ = self;
    return .{ .r = 70, .g = 74, .b = 86, .a = 255 };
}

/// Nothing beyond the batched fill above -- kept as a real (if trivial)
/// method rather than special-cased out of main.zig's generic per-kind
/// draw dispatch, matching every other widget kind's own drawDecorations.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    _ = self;
    _ = renderer;
}
