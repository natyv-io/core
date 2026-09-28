//! A drawing surface: the guest's display list, drawn host-side. The slot
//! itself holds only the laid-out rect -- the drawing lives in
//! `WidgetHost.canvases` (`CanvasStore.zig`), since a list of up to 8192
//! commands inline here would make every registry slot that large, and its
//! rendered texture lives per window in `capabilities/CanvasRender.zig`,
//! since textures are renderer-scoped and main-thread only.
//!
//! A click fires `.click` with the point relative to the canvas's top-left
//! (`{"x":..,"y":..}`), and each change to its laid-out size fires
//! `.canvas_resized` (`{"w":..,"h":..}`) -- see `FrameLoop.zig`. No hover.
//! It draws nothing of its own beyond the drawing, so an empty canvas is
//! transparent unless styled.

const c = @import("../c.zig").c;

const Self = @This();

rect: c.SDL_FRect,

pub fn init(rect: c.SDL_FRect) Self {
    return .{ .rect = rect };
}

pub fn containsPoint(self: Self, x: f32, y: f32) bool {
    return x >= self.rect.x and x < self.rect.x + self.rect.w and
        y >= self.rect.y and y < self.rect.y + self.rect.h;
}
