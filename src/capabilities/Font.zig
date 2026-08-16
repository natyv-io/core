//! F1: proves the vendored FreeType + SDL_ttf toolchain compiles, links, and
//! actually rasterizes/measures real glyphs, before any widget code depends
//! on it. FreeType itself is never @cImport-ed (see src/c.zig) -- SDL_ttf's
//! public header only exposes opaque types (TTF_Font*, TTF_Text*, ...),
//! FreeType is consumed entirely inside the vendored .c sources.
//!
//! F2 will grow `Self` into the real per-app default-font capability
//! (TTF_Init/TTF_Quit lifecycle + the one loaded default TTF_Font* for the
//! app's lifetime) -- same "prove it standalone first, then grow into the
//! real capability" shape ClayLayout.zig's L1→L4 arc already used.

const std = @import("std");
const c = @import("../c.zig").c;

/// Bundled default font (Inter, OFL 1.1 -- see vendor/inter/OFL.txt). A
/// variable font (one file covering the whole weight axis) rather than
/// separate static files per weight -- smaller bundle, and leaves room to
/// expose weight selection later without shipping more font files.
const default_font_ttf = @embedFile("../assets/Inter.ttf");

pub const MeasuredSize = struct {
    w: i32,
    h: i32,
};

/// Point size the bundled default font is opened at. Every widget shares
/// this one size today -- natyv has no per-widget font-size field yet
/// (F3's scope is swapping the *rendering path*, not adding new style
/// surface); revisit if/when that becomes a real requirement.
pub const default_point_size: f32 = 16.0;

const Self = @This();

/// F2: the real per-app default-font capability. Owns the `TTF_Init`/
/// `TTF_Quit` lifecycle and the one loaded default `TTF_Font*` for the
/// app's lifetime -- `main.zig` constructs exactly one of these, right
/// after `SDL_Init`, unconditionally (every app gets the default font
/// regardless of `conf.natyv.json`, since it's not a declared capability
/// the way sqlite/network/widgets are -- see the font-rendering plan).
font: *c.TTF_Font,

pub fn init() !Self {
    if (!c.TTF_Init()) return error.TTFInitFailed;
    errdefer c.TTF_Quit();

    const stream = c.SDL_IOFromConstMem(default_font_ttf.ptr, default_font_ttf.len) orelse return error.IOStreamFailed;
    const font = c.TTF_OpenFontIO(stream, true, default_point_size) orelse return error.OpenFontFailed;

    return .{ .font = font };
}

pub fn deinit(self: *Self) void {
    c.TTF_CloseFont(self.font);
    c.TTF_Quit();
}

/// F1 self-test logic, exposed as a real callable function (not a bare
/// `test` block) for the same reason ClayLayout.zig's L1 proof is: an
/// otherwise-unreferenced import's `test` blocks don't get discovered under
/// Zig 0.16's lazy semantic analysis. Loads the real embedded Inter bytes
/// through FreeType (via TTF_OpenFontIO + SDL_IOFromConstMem, no temp file
/// on disk needed) and measures a real string -- proves vendor -> compile ->
/// link -> call chain end to end.
pub fn proveFontRenderingToolchain() !MeasuredSize {
    if (!c.TTF_Init()) return error.TTFInitFailed;
    defer c.TTF_Quit();

    const stream = c.SDL_IOFromConstMem(default_font_ttf.ptr, default_font_ttf.len) orelse return error.IOStreamFailed;
    const font = c.TTF_OpenFontIO(stream, true, 16.0) orelse return error.OpenFontFailed;
    defer c.TTF_CloseFont(font);

    var w: c_int = 0;
    var h: c_int = 0;
    const text = "natyv";
    if (!c.TTF_GetStringSize(font, text, text.len, &w, &h)) return error.MeasureFailed;

    return .{ .w = w, .h = h };
}
