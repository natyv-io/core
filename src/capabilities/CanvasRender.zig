//! Draws Canvas widgets: renders each canvas's drawing into a cached
//! texture and blits that texture every frame. Main thread only, like all
//! SDL drawing.
//!
//! Anti-aliasing is ShapeCache's technique (no shaders): the drawing is
//! rendered at `supersample`x into an offscreen target, then downsampled
//! with one `SDL_SCALEMODE_LINEAR` blit. 2x rather than ShapeCache's 4x,
//! because a canvas is a whole surface and 4x is 16x its pixels.
//!
//! Colour is premultiplied throughout. Drawing with `SDL_BLENDMODE_BLEND`
//! onto a target cleared to (0,0,0,0) leaves premultiplied pixels behind,
//! the linear downsample averages them correctly (straight alpha would
//! darken every anti-aliased edge), and the finished texture is composited
//! with `SDL_BLENDMODE_BLEND_PREMULTIPLIED`.
//!
//! Text is rasterized from a copy of the app font at `supersample`x its
//! size and drawn into the same supersampled pass, in command order, so a
//! render is one pass per tile rather than one per run of shapes between
//! labels. `y` is the top of the text's line box.
//!
//! Memory:
//! - Only canvases drawn this frame keep a texture. `sweep` (end of every
//!   `drawWindow`) frees the rest -- scrolled out of view, on a hidden tab,
//!   destroyed -- and they re-render from their drawing when they're back.
//!   No disk cache: reading pixels back from the GPU stalls, and a
//!   re-render is faster than reading them from disk.
//! - `budget_bytes` caps the textures alive across every window. A canvas
//!   that doesn't fit renders at a lower resolution (upscaled, so slightly
//!   blurry) instead of failing, down to `min_budget_scale`; past that it
//!   overshoots the budget, which the 32-canvas cap still bounds.
//! - The supersampled pass is tiled (`max_tile_super` pixels a side), so a
//!   4096 canvas never needs an 8192x8192 intermediate, and every texture
//!   stays under the renderer's maximum texture size. The intermediate is
//!   freed as soon as the render finishes.
//!
//! A cached texture is re-rendered when the drawing's version changes, the
//! canvas's laid-out size changes, or the budget now allows a sharper
//! render than it got.

const std = @import("std");
const c = @import("../c.zig").c;
const CanvasStore = @import("../CanvasStore.zig");
const CanvasTessellate = @import("../CanvasTessellate.zig");

const Point = CanvasStore.Point;
const Color = CanvasStore.Color;
const Drawing = CanvasStore.Drawing;

pub const supersample = 2;
pub const budget_bytes: usize = 256 * 1024 * 1024;
const min_budget_scale = 0.25;
/// Edge of the supersampled tile, in its own pixels.
const max_tile_super = 2048;
const batch_vertices = 3 * 1024;
const bytes_per_pixel = 4;

/// Device pixels per logical pixel. Always 1 today -- core renders at 1x
/// even on HiDPI displays -- but every size below already goes through it,
/// so the UI-wide Retina fix won't need to rework canvases.
pub const pixel_density: f32 = 1;

/// Bytes of canvas texture alive across every window's cache. Main thread
/// only, like everything else in this file.
var budget_used: usize = 0;

const Entry = struct {
    id: u32,
    texture: *c.SDL_Texture,
    bytes: usize,
    version: u32,
    /// The laid-out size it was rendered for.
    w: f32,
    h: f32,
    /// Device pixels per logical pixel it was rendered at.
    px: f32,
    used: bool,
};

/// Per window -- textures belong to one renderer. Owned by
/// `WindowManager.WindowContext` next to `shape_cache`.
pub const Cache = struct {
    entries: [CanvasStore.max_canvases]?Entry = [_]?Entry{null} ** CanvasStore.max_canvases,
    /// The app font at `supersample`x size, copied on first use.
    text_font: ?*c.TTF_Font = null,

    pub fn deinit(self: *Cache) void {
        for (&self.entries) |*slot| if (slot.*) |e| {
            destroyEntry(e);
            slot.* = null;
        };
        if (self.text_font) |f| c.TTF_CloseFont(f);
        self.text_font = null;
    }

    /// Frees every texture not drawn since the last sweep. Called once at
    /// the end of each frame.
    pub fn sweep(self: *Cache) void {
        for (&self.entries) |*slot| if (slot.*) |*e| {
            if (e.used) {
                e.used = false;
            } else {
                destroyEntry(e.*);
                slot.* = null;
            }
        };
    }

    fn find(self: *Cache, id: u32) ?*Entry {
        for (&self.entries) |*slot| if (slot.*) |*e| {
            if (e.id == id) return e;
        };
        return null;
    }

    /// Stores `entry`, replacing any entry for the same id. False if every
    /// slot is taken, in which case the caller still owns the texture.
    fn put(self: *Cache, entry: Entry) bool {
        const slot = for (&self.entries) |*s| {
            if (s.*) |e| if (e.id == entry.id) break s;
        } else for (&self.entries) |*s| {
            if (s.* == null) break s;
        } else return false;
        if (slot.*) |old| destroyEntry(old);
        slot.* = entry;
        budget_used += entry.bytes;
        return true;
    }

    fn textFont(self: *Cache, app_font: *c.TTF_Font) ?*c.TTF_Font {
        if (self.text_font == null) {
            const f = c.TTF_CopyFont(app_font) orelse return null;
            if (!c.TTF_SetFontSize(f, c.TTF_GetFontSize(app_font) * supersample)) {
                c.TTF_CloseFont(f);
                return null;
            }
            self.text_font = f;
        }
        return self.text_font;
    }
};

fn destroyEntry(e: Entry) void {
    c.SDL_DestroyTexture(e.texture);
    budget_used -|= e.bytes;
}

/// Draws canvas `id` into `rect` on `renderer`'s current target,
/// re-rendering its texture first if it's missing or stale. `source` gives
/// the drawing: `version(id) ?u32` and
/// `clone(id, allocator) !?struct { drawing: Drawing, version: u32 }`, an
/// owned copy so no lock is held while rendering. Failures (out of memory,
/// a texture SDL won't create) skip the canvas this frame, or keep showing
/// its previous texture.
pub fn draw(cache: *Cache, renderer: ?*c.SDL_Renderer, allocator: std.mem.Allocator, app_font: *c.TTF_Font, id: u32, rect: c.SDL_FRect, source: anytype) void {
    // Also rejects NaN.
    if (!(rect.w >= 1 and rect.h >= 1 and std.math.isFinite(rect.w) and std.math.isFinite(rect.h))) return;
    const version = source.version(id) orelse return;
    const max_dim = maxTextureDim(renderer);

    const existing = cache.find(id);
    const own: usize = if (existing) |e| e.bytes else 0;
    const px = pixelScale(rect.w, rect.h, pixel_density, (budget_bytes -| budget_used) + own, max_dim);
    const stale = if (existing) |e|
        e.version != version or e.w != rect.w or e.h != rect.h or e.px < px * 0.999
    else
        true;

    if (stale) refresh: {
        const snap = (source.clone(id, allocator) catch null) orelse break :refresh;
        var drawing = snap.drawing;
        defer drawing.deinit(allocator);
        const tex_w = textureDim(rect.w, px, max_dim);
        const tex_h = textureDim(rect.h, px, max_dim);
        const texture = render(renderer, allocator, &drawing, .{ .cache = cache, .app_font = app_font }, tex_w, tex_h, px, max_dim) orelse break :refresh;
        const entry: Entry = .{
            .id = id,
            .texture = texture,
            .bytes = @as(usize, @intCast(tex_w)) * @as(usize, @intCast(tex_h)) * bytes_per_pixel,
            .version = snap.version,
            .w = rect.w,
            .h = rect.h,
            .px = px,
            .used = false,
        };
        if (!cache.put(entry)) c.SDL_DestroyTexture(texture);
    }

    const e = cache.find(id) orelse return;
    e.used = true;
    _ = c.SDL_RenderTexture(renderer, e.texture, null, &rect);
}

fn maxTextureDim(renderer: ?*c.SDL_Renderer) i32 {
    const n = c.SDL_GetNumberProperty(c.SDL_GetRendererProperties(renderer), c.SDL_PROP_RENDERER_MAX_TEXTURE_SIZE_NUMBER, 2048);
    return std.math.clamp(std.math.lossyCast(i32, n), 64, 16384);
}

/// Device pixels per logical pixel for a `w`x`h` canvas: `density`,
/// lowered to fit the canvas size cap, the renderer's texture limit, and
/// then `available` bytes of budget (never below `min_budget_scale` of the
/// size-capped scale). `w` and `h` are finite and at least 1.
fn pixelScale(w: f32, h: f32, density: f32, available: usize, max_dim: i32) f32 {
    const longest = @max(w, h);
    const size_cap = @as(f32, CanvasStore.max_size) * density / longest;
    const texture_cap = @as(f32, @floatFromInt(max_dim)) / longest;
    var px = @min(density, @min(size_cap, texture_cap));
    const full = @ceil(w * px) * @ceil(h * px) * bytes_per_pixel;
    const avail: f32 = @floatFromInt(available);
    if (full > avail) px = @max(px * @sqrt(avail / full), px * min_budget_scale);
    return px;
}

fn textureDim(logical: f32, px: f32, max_dim: i32) i32 {
    return std.math.clamp(std.math.lossyCast(i32, @ceil(logical * px)), 1, max_dim);
}

/// Renders `drawing` into a new `tex_w`x`tex_h` texture at `px` device
/// pixels per logical pixel. Caller owns the result.
/// The supersampled text font, copied from the app font only once a
/// drawing actually has text.
const TextFont = struct {
    cache: *Cache,
    app_font: *c.TTF_Font,

    fn get(self: TextFont) ?*c.TTF_Font {
        return self.cache.textFont(self.app_font);
    }
};

fn render(renderer: ?*c.SDL_Renderer, allocator: std.mem.Allocator, drawing: *const Drawing, text_font: TextFont, tex_w: i32, tex_h: i32, px: f32, max_dim: i32) ?*c.SDL_Texture {
    const out = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, tex_w, tex_h) orelse return null;
    _ = c.SDL_SetTextureBlendMode(out, c.SDL_BLENDMODE_BLEND_PREMULTIPLIED);
    _ = c.SDL_SetTextureScaleMode(out, c.SDL_SCALEMODE_LINEAR);

    const tile = tileEdge(max_dim);
    const super_w = @min(tex_w, tile) * supersample;
    const super_h = @min(tex_h, tile) * supersample;
    const super_tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, super_w, super_h) orelse {
        c.SDL_DestroyTexture(out);
        return null;
    };
    defer c.SDL_DestroyTexture(super_tex);
    // Tiles don't overlap, so each is copied into place, not blended.
    _ = c.SDL_SetTextureBlendMode(super_tex, c.SDL_BLENDMODE_NONE);
    _ = c.SDL_SetTextureScaleMode(super_tex, c.SDL_SCALEMODE_LINEAR);

    const prev_target = c.SDL_GetRenderTarget(renderer);
    var prev_blend: c.SDL_BlendMode = c.SDL_BLENDMODE_NONE;
    _ = c.SDL_GetRenderDrawBlendMode(renderer, &prev_blend);
    defer {
        _ = c.SDL_SetRenderTarget(renderer, prev_target);
        _ = c.SDL_SetRenderDrawBlendMode(renderer, prev_blend);
    }
    _ = c.SDL_SetRenderTarget(renderer, out);
    clearTransparent(renderer);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var sink: Sink = .{ .renderer = renderer, .scale = px * supersample };
    const tiled = tex_w > tile or tex_h > tile;

    var ty: i32 = 0;
    while (ty < tex_h) : (ty += tile) {
        var tx: i32 = 0;
        while (tx < tex_w) : (tx += tile) {
            const tw = @min(tile, tex_w - tx);
            const th = @min(tile, tex_h - ty);
            _ = c.SDL_SetRenderTarget(renderer, super_tex);
            clearTransparent(renderer);
            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            sink.offset = .{ @floatFromInt(tx * supersample), @floatFromInt(ty * supersample) };
            // This tile in logical coordinates, for skipping shapes that
            // miss it.
            const tile_box: [4]f32 = .{
                @as(f32, @floatFromInt(tx)) / px,
                @as(f32, @floatFromInt(ty)) / px,
                @as(f32, @floatFromInt(tx + tw)) / px,
                @as(f32, @floatFromInt(ty + th)) / px,
            };

            for (drawing.commands) |cmd| switch (cmd) {
                .text => |t| {
                    sink.flush();
                    drawText(renderer, text_font.get(), drawing.textOf(t.text), t.pos, t.color, t.@"align", &sink, super_w, super_h);
                },
                else => {
                    if (tiled and !overlaps(CanvasTessellate.bounds(drawing, cmd), tile_box)) continue;
                    _ = arena.reset(.retain_capacity);
                    // Out of memory drops this one shape rather than the
                    // whole canvas.
                    CanvasTessellate.tessellate(drawing, cmd, sink.scale, arena.allocator(), &sink) catch {};
                },
            };
            sink.flush();

            _ = c.SDL_SetRenderTarget(renderer, out);
            const src: c.SDL_FRect = .{ .x = 0, .y = 0, .w = @floatFromInt(tw * supersample), .h = @floatFromInt(th * supersample) };
            const dst: c.SDL_FRect = .{ .x = @floatFromInt(tx), .y = @floatFromInt(ty), .w = @floatFromInt(tw), .h = @floatFromInt(th) };
            _ = c.SDL_RenderTexture(renderer, super_tex, &src, &dst);
        }
    }
    return out;
}

/// Output pixels along one edge of a tile, chosen so the supersampled tile
/// stays within both `max_tile_super` and the renderer's texture limit.
fn tileEdge(max_dim: i32) i32 {
    return @divFloor(@min(max_tile_super, max_dim), supersample);
}

fn clearTransparent(renderer: ?*c.SDL_Renderer) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
    _ = c.SDL_RenderClear(renderer);
}

fn overlaps(a: [4]f32, b: [4]f32) bool {
    return a[0] <= b[2] and a[2] >= b[0] and a[1] <= b[3] and a[3] >= b[1];
}

/// Takes the tessellator's triangles in logical coordinates, maps them into
/// the current tile, and batches them into `SDL_RenderGeometry` calls.
const Sink = struct {
    renderer: ?*c.SDL_Renderer,
    /// Supersampled pixels per logical pixel.
    scale: f32,
    /// The current tile's origin, in supersampled pixels.
    offset: [2]f32 = .{ 0, 0 },
    verts: [batch_vertices]c.SDL_Vertex = undefined,
    len: usize = 0,

    pub fn triangle(self: *Sink, a: Point, b: Point, d: Point, color: Color) void {
        if (self.len + 3 > batch_vertices) self.flush();
        const fc: c.SDL_FColor = .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
        for ([3]Point{ a, b, d }) |p| {
            self.verts[self.len] = .{
                .position = .{ .x = p[0] * self.scale - self.offset[0], .y = p[1] * self.scale - self.offset[1] },
                .color = fc,
                .tex_coord = .{ .x = 0, .y = 0 },
            };
            self.len += 1;
        }
    }

    fn flush(self: *Sink) void {
        if (self.len == 0) return;
        _ = c.SDL_RenderGeometry(self.renderer, null, &self.verts, @intCast(self.len), null, 0);
        self.len = 0;
    }
};

/// Draws one text command into the current tile, if any of it lands there.
/// `font` is the app font at `supersample`x, so its pixels are already
/// supersampled pixels at a density of 1.
fn drawText(renderer: ?*c.SDL_Renderer, font: ?*c.TTF_Font, text: []const u8, pos: Point, color: Color, alignment: CanvasStore.Align, sink: *const Sink, super_w: i32, super_h: i32) void {
    const f = font orelse return;
    if (text.len == 0) return;
    var w: c_int = 0;
    var h: c_int = 0;
    if (!c.TTF_GetStringSize(f, text.ptr, text.len, &w, &h) or w <= 0 or h <= 0) return;

    const k = sink.scale / supersample;
    const dw = @as(f32, @floatFromInt(w)) * k;
    const dh = @as(f32, @floatFromInt(h)) * k;
    var x = pos[0] * sink.scale - sink.offset[0];
    switch (alignment) {
        .left => {},
        .center => x -= dw / 2,
        .right => x -= dw,
    }
    const y = pos[1] * sink.scale - sink.offset[1];
    if (x >= @as(f32, @floatFromInt(super_w)) or y >= @as(f32, @floatFromInt(super_h)) or x + dw <= 0 or y + dh <= 0) return;

    const surface = c.TTF_RenderText_Blended(f, text.ptr, text.len, .{ .r = 255, .g = 255, .b = 255, .a = 255 }) orelse return;
    defer c.SDL_DestroySurface(surface);
    const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
    defer c.SDL_DestroyTexture(tex);
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);
    _ = c.SDL_SetTextureColorModFloat(tex, color.r, color.g, color.b);
    _ = c.SDL_SetTextureAlphaModFloat(tex, color.a);
    const dst: c.SDL_FRect = .{ .x = x, .y = y, .w = dw, .h = dh };
    _ = c.SDL_RenderTexture(renderer, tex, null, &dst);
}

// --- tests ---

const testing = std.testing;

test "pixelScale: full density when everything fits" {
    try testing.expectEqual(@as(f32, 1), pixelScale(400, 300, 1, budget_bytes, 16384));
}

test "pixelScale: capped by the canvas size limit and the texture limit" {
    try testing.expectApproxEqAbs(@as(f32, 0.5), pixelScale(8192, 100, 1, budget_bytes, 16384), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), pixelScale(4096, 100, 1, budget_bytes, 1024), 1e-6);
    try testing.expect(textureDim(4096, pixelScale(4096, 100, 1, budget_bytes, 1024), 1024) <= 1024);
}

test "pixelScale: reduced to fit the budget, but not below the floor" {
    const full: usize = 1000 * 1000 * bytes_per_pixel;
    const px = pixelScale(1000, 1000, 1, full / 4, 16384);
    try testing.expectApproxEqAbs(@as(f32, 0.5), px, 0.01);
    try testing.expect(@ceil(1000 * px) * @ceil(1000 * px) * bytes_per_pixel <= @as(f32, @floatFromInt(full / 4)) * 1.01);
    try testing.expectEqual(@as(f32, min_budget_scale), pixelScale(1000, 1000, 1, 0, 16384));
}

test "tileEdge: the supersampled tile fits both caps" {
    for ([_]i32{ 64, 1000, 2048, 4096, 16384 }) |max_dim| {
        const super = tileEdge(max_dim) * supersample;
        try testing.expect(super <= max_tile_super and super <= max_dim);
        try testing.expect(super >= @min(max_tile_super, max_dim) - 1);
    }
}

test "textureDim: never zero, never past the texture limit" {
    try testing.expectEqual(@as(i32, 1), textureDim(1, 0.25, 2048));
    try testing.expectEqual(@as(i32, 2048), textureDim(1e30, 1, 2048));
}

/// Hands `CanvasRender.draw` a fixed drawing, as `FrameLoop`'s
/// `CanvasSource` does from the widget registry.
const TestSource = struct {
    drawing: *const Drawing,
    current: u32 = 1,

    pub fn version(self: TestSource, id: u32) ?u32 {
        _ = id;
        return self.current;
    }

    pub fn clone(self: TestSource, id: u32, allocator: std.mem.Allocator) error{OutOfMemory}!?struct { drawing: Drawing, version: u32 } {
        _ = id;
        return .{ .drawing = try self.drawing.clone(allocator), .version = self.current };
    }
};

fn testDrawing(json: []const u8) !Drawing {
    var diag: CanvasStore.Diagnostic = .{};
    const parsed = try CanvasStore.parseSetRequest(testing.allocator, json, &diag);
    defer parsed.deinit();
    return CanvasStore.build(testing.allocator, parsed.value.commands, &diag);
}

fn expectPixel(surface: *c.SDL_Surface, x: c_int, y: c_int, want: [3]u8, tolerance: u8) !void {
    var px: [4]u8 = undefined;
    try testing.expect(c.SDL_ReadSurfacePixel(surface, x, y, &px[0], &px[1], &px[2], &px[3]));
    for (0..3) |i| {
        const diff = @as(i16, px[i]) - want[i];
        if (@abs(diff) > tolerance) {
            std.debug.print("pixel ({d},{d}) = {any}, want {any}\n", .{ x, y, px[0..3], want });
            return error.TestUnexpectedPixel;
        }
    }
}

/// A line chart, bars, a pie and a donut, a non-convex translucent area,
/// scatter points and labels. Canvas coordinates; the test draws the
/// canvas at (10, 10).
const sample_json =
    \\{"widget_id":1,"commands":[
    \\ {"polygon":{"points":[[40,280],[40,200],[120,150],[160,220],[220,120],[260,280]],"fill":{"r":0,"g":1,"b":0,"a":0.5}}},
    \\ {"line":{"x1":40,"y1":280,"x2":460,"y2":280,"width":1,"color":{"r":0.8,"g":0.8,"b":0.8}}},
    \\ {"line":{"x1":40,"y1":40,"x2":40,"y2":280,"width":1,"color":{"r":0.8,"g":0.8,"b":0.8}}},
    \\ {"rect":{"x":280,"y":180,"w":30,"h":100,"fill":{"r":0.2,"g":0.4,"b":0.9},"radius":4}},
    \\ {"rect":{"x":320,"y":140,"w":30,"h":140,"fill":{"r":0.2,"g":0.4,"b":0.9},"radius":4}},
    \\ {"rect":{"x":360,"y":200,"w":30,"h":80,"fill":{"r":0.2,"g":0.4,"b":0.9},"stroke":{"r":1,"g":1,"b":1},"stroke_width":2}},
    \\ {"polyline":{"points":[[40,250],[90,210],[140,230],[190,160],[240,180],[270,90]],"width":2.5,"color":{"r":1,"g":0.3,"b":0.2}}},
    \\ {"circle":{"cx":90,"cy":210,"r":4,"fill":{"r":1,"g":1,"b":1},"stroke":{"r":1,"g":0.3,"b":0.2},"stroke_width":2}},
    \\ {"circle":{"cx":190,"cy":160,"r":4,"fill":{"r":1,"g":1,"b":1},"stroke":{"r":1,"g":0.3,"b":0.2},"stroke_width":2}},
    \\ {"arc":{"cx":110,"cy":80,"r":50,"start":0,"end":2.5,"fill":{"r":0.9,"g":0.6,"b":0.1},"stroke":{"r":0.1,"g":0.1,"b":0.12},"stroke_width":2}},
    \\ {"arc":{"cx":110,"cy":80,"r":50,"start":2.5,"end":4.4,"fill":{"r":0.3,"g":0.7,"b":0.9},"stroke":{"r":0.1,"g":0.1,"b":0.12},"stroke_width":2}},
    \\ {"arc":{"cx":110,"cy":80,"r":50,"start":4.4,"end":6.2832,"fill":{"r":0.6,"g":0.3,"b":0.8},"stroke":{"r":0.1,"g":0.1,"b":0.12},"stroke_width":2}},
    \\ {"arc":{"cx":400,"cy":70,"r":40,"start":-1.5708,"end":2.5,"stroke":{"r":0.3,"g":0.9,"b":0.5},"stroke_width":12}},
    \\ {"text":{"x":400,"y":62,"text":"72%","color":{"r":1,"g":1,"b":1},"align":"center"}},
    \\ {"text":{"x":295,"y":286,"text":"Q1","color":{"r":0.9,"g":0.9,"b":0.9},"align":"center"}},
    \\ {"text":{"x":335,"y":286,"text":"Q2","color":{"r":0.9,"g":0.9,"b":0.9},"align":"center"}},
    \\ {"text":{"x":375,"y":286,"text":"Q3","color":{"r":0.9,"g":0.9,"b":0.9},"align":"center"}},
    \\ {"text":{"x":470,"y":10,"text":"Revenue","color":{"r":1,"g":1,"b":1,"a":0.6},"align":"right"}}
    \\]}
;

test "draw: renders a sample drawing through a real SDL renderer, premultiplied, and frees it on sweep" {
    const Font = @import("Font.zig");
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("canvas-render-test", 64, 64, c.SDL_WINDOW_HIDDEN) orelse return error.SdlWindowFailed;
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);
    var font = try Font.init(null, null);
    defer font.deinit();

    var drawing = try testDrawing(sample_json);
    defer drawing.deinit(testing.allocator);
    var cache: Cache = .{};
    defer cache.deinit();

    const frame = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, 500, 340) orelse return error.TextureFailed;
    defer c.SDL_DestroyTexture(frame);
    _ = c.SDL_SetRenderTarget(renderer, frame);
    const bg = [3]u8{ 0x18, 0x18, 0x1C };
    _ = c.SDL_SetRenderDrawColor(renderer, bg[0], bg[1], bg[2], 255);
    _ = c.SDL_RenderClear(renderer);

    draw(&cache, renderer, testing.allocator, font.font, 1, .{ .x = 10, .y = 10, .w = 480, .h = 320 }, TestSource{ .drawing = &drawing });
    try testing.expectEqual(@as(usize, 480 * 320 * bytes_per_pixel), budget_used);

    const surface = c.SDL_RenderReadPixels(renderer, null) orelse return error.ReadPixelsFailed;
    defer c.SDL_DestroySurface(surface);
    if (std.c.getenv("NATYV_CANVAS_DUMP")) |path| _ = c.SDL_SaveBMP(surface, path);

    // Untouched canvas area shows the window through it.
    try expectPixel(surface, 10 + 470, 10 + 300, bg, 0);
    // An opaque bar's middle is its exact colour.
    try expectPixel(surface, 10 + 335, 10 + 200, .{ 51, 102, 230 }, 2);
    // Half-transparent green over the background: 0.5 * green + 0.5 * bg.
    // Straight (non-premultiplied) alpha through the downsample or the
    // composite would come out darker.
    try expectPixel(surface, 10 + 60, 10 + 260, .{ 12, 140, 14 }, 3);

    // Redrawing an unchanged canvas reuses its texture; a sweep with no
    // draw in between frees it.
    const tex = cache.find(1).?.texture;
    draw(&cache, renderer, testing.allocator, font.font, 1, .{ .x = 10, .y = 10, .w = 480, .h = 320 }, TestSource{ .drawing = &drawing });
    try testing.expectEqual(tex, cache.find(1).?.texture);
    cache.sweep();
    try testing.expect(cache.find(1) != null);
    cache.sweep();
    try testing.expect(cache.find(1) == null);
    try testing.expectEqual(@as(usize, 0), budget_used);

    // A new drawing version, and separately a new laid-out size, each
    // re-render; the budget tracks the replacement, not both.
    draw(&cache, renderer, testing.allocator, font.font, 1, .{ .x = 10, .y = 10, .w = 480, .h = 320 }, TestSource{ .drawing = &drawing });
    try testing.expectEqual(@as(u32, 1), cache.find(1).?.version);
    draw(&cache, renderer, testing.allocator, font.font, 1, .{ .x = 10, .y = 10, .w = 480, .h = 320 }, TestSource{ .drawing = &drawing, .current = 2 });
    try testing.expectEqual(@as(u32, 2), cache.find(1).?.version);
    draw(&cache, renderer, testing.allocator, font.font, 1, .{ .x = 10, .y = 10, .w = 200, .h = 100 }, TestSource{ .drawing = &drawing, .current = 2 });
    try testing.expectEqual(@as(f32, 200), cache.find(1).?.w);
    try testing.expectEqual(@as(usize, 200 * 100 * bytes_per_pixel), budget_used);
    cache.sweep();
    cache.sweep();
    _ = c.SDL_SetRenderTarget(renderer, null);
}

test "draw: a canvas wider than one tile renders seamlessly across the tile edge" {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("canvas-tile-test", 64, 64, c.SDL_WINDOW_HIDDEN) orelse return error.SdlWindowFailed;
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);
    var font = try @import("Font.zig").init(null, null);
    defer font.deinit();

    // A band crossing x = 1024, the first tile edge at a 2048 tile.
    var drawing = try testDrawing(
        \\{"widget_id":1,"commands":[{"rect":{"x":900,"y":10,"w":300,"h":20,"fill":{"r":1,"g":0,"b":0}}}]}
    );
    defer drawing.deinit(testing.allocator);
    var cache: Cache = .{};
    defer cache.deinit();

    const frame = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, 1400, 40) orelse return error.TextureFailed;
    defer c.SDL_DestroyTexture(frame);
    _ = c.SDL_SetRenderTarget(renderer, frame);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(renderer);
    draw(&cache, renderer, testing.allocator, font.font, 1, .{ .x = 0, .y = 0, .w = 1400, .h = 40 }, TestSource{ .drawing = &drawing });

    const surface = c.SDL_RenderReadPixels(renderer, null) orelse return error.ReadPixelsFailed;
    defer c.SDL_DestroySurface(surface);
    for ([_]c_int{ 1020, 1023, 1024, 1025, 1028 }) |x| try expectPixel(surface, x, 20, .{ 255, 0, 0 }, 0);
    try expectPixel(surface, 1300, 20, .{ 0, 0, 0 }, 0);
    _ = c.SDL_SetRenderTarget(renderer, null);
}
