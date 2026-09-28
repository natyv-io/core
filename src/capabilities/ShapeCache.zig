//! Styling system Stage 3, post-pivot (see amber-woven-lantern.md's
//! 2026-08-22 pivot note): plain-SDL tessellation + supersample + cache,
//! replacing the removed SDF shader path (`ShapeShader.zig`, deleted along
//! with `src/shaders/`). No custom shader, no `SDL_GPURenderState` -- works
//! on any `SDL_Renderer`, including the software fallback.
//!
//! Technique: tessellate real geometry (a triangle fan) at `aa_level`x the
//! shape's final pixel size, render it into an offscreen
//! `SDL_TEXTUREACCESS_TARGET` alpha mask, then downsample with one
//! `SDL_SCALEMODE_LINEAR` blit back to real size -- the linear filtering
//! during that blit *is* the anti-aliasing, no shader math anywhere. Live-
//! compared against 2x/3x/5x in the scratchpad `aa_passes_demo.zig`
//! reference; Quinn's confirmed default is 4x (`aa_level` below).
//!
//! Stage 3 scope, deliberate: shipped with only a filled circle and a ring
//! (annulus) mask, matching RadioButton's own real need -- a proper circle
//! outline plus a filled dot, replacing the square-box-reused-for-radio
//! placeholder its own doc comment flagged as "next milestone's job."
//! Checkbox needed no mask at all: `SDL_RenderRect` already draws a
//! perfectly sharp square with zero anti-aliasing artifacts, which is
//! exactly what `cornerRadius = 0` wants -- there was no bug to fix there.
//! General rounded-rect masks (non-zero, non-half-size, independent
//! per-corner radius) are Stage 5a's real addition below.
//!
//! The ring mask is a true annulus baked directly into alpha (draw the
//! outer circle, then draw the inner circle with `SDL_BLENDMODE_NONE` and
//! alpha 0 to genuinely erase those pixels back to transparent) rather than
//! a color-matched "punch a hole and hope it matches the background"
//! trick -- same reasoning the original SDF shader's stroke technique used
//! a second distance threshold for, just done with real geometry instead of
//! a distance field.
//!
//! Masks are cached lazily on first draw, not eagerly, keyed by the
//! integer pixel size (+ border width for a ring) that determines their
//! geometry -- most widgets in one app reuse a small handful of distinct
//! sizes. One `Cache` per window (masks are textures, textures are
//! renderer-scoped) -- owned by `WindowManager.WindowContext`, same
//! per-window-resource shape its `text_engine` field already established.
//!
//! Styling system Stage 5a: generalized beyond circle/ring to a real
//! per-corner-radius rounded rectangle (`drawRoundedRect`) and its matching
//! border (`drawRoundedRectBorder`) -- what Container/Button-style widgets
//! actually need (arbitrary radius 0..half-size per corner, usually
//! non-square). `drawCircle`/`drawRing` are left untouched rather than
//! reimplemented on top of the new general path -- they're already
//! verified correct (real click-through, RadioButton), and the general
//! rect path covers a genuinely different shape (non-square, independent
//! w/h) with its own clamping rules, so unifying them would trade proven
//! code for a refactor with no functional upside.

const std = @import("std");
const c = @import("../c.zig").c;

pub const aa_level: u32 = 4;
/// Largest mask edge (and ring/border width), in real pixels. A mask only
/// picks a resolution -- `SDL_RenderTexture` scales it onto the real rect --
/// so capping it is safe, and it keeps `dim * aa_level` inside both `i32`
/// and the 16384 px texture limit most GPUs have (past which
/// `SDL_CreateTexture` fails and the shape silently doesn't draw). The
/// sizes come from guest layout values, so without the cap a huge width
/// overflowed that multiply.
const max_mask_dim: i32 = @intCast(16384 / aa_level);
const max_entries = 32;

/// Float -> mask dimension: saturating (NaN -> 0, see `lossyCast`) and
/// capped at `max_mask_dim`. Callers keep their own rounding.
fn maskInt(f: f32) i32 {
    return @min(std.math.lossyCast(i32, f), max_mask_dim);
}
const circle_segments = 48;
// Each of the 4 corners gets an independent quarter-turn arc; the space
// between one corner's arc and the next is implicitly the straight edge
// (the fan triangulation connects consecutive listed points directly, and
// that connecting chord *is* the real boundary when it's genuinely
// straight) -- same technique the scratchpad `aa_passes_demo.zig`
// reference used for its (uniform-radius) rounded rect. `corner_segments`
// is chosen so 4 corners produce exactly `circle_segments` total points,
// reusing `fillConvexPolygon`'s existing fixed-size backing arrays as-is.
const corner_segments = circle_segments / 4 - 1;

const MaskKind = enum { circle, ring, rect, rect_border };

const MaskKey = struct {
    kind: MaskKind,
    w: i32,
    h: i32,
    radii: [4]i32 = .{ 0, 0, 0, 0 }, // unused (zero) for .circle/.ring
    border_width: i32 = 0, // only meaningful for .ring/.rect_border
};

const Entry = struct {
    key: MaskKey,
    texture: *c.SDL_Texture,
};

/// Per-window cache -- see file doc comment for why textures can't be
/// shared across windows/renderers.
pub const Cache = struct {
    entries: [max_entries]?Entry = [_]?Entry{null} ** max_entries,
    count: usize = 0,

    pub fn deinit(self: *Cache) void {
        for (self.entries[0..self.count]) |entry| {
            if (entry) |e| c.SDL_DestroyTexture(e.texture);
        }
        self.count = 0;
    }

    fn find(self: *Cache, key: MaskKey) ?*c.SDL_Texture {
        for (self.entries[0..self.count]) |entry| {
            if (entry) |e| {
                if (std.meta.eql(e.key, key)) return e.texture;
            }
        }
        return null;
    }

    /// Silently drops the mask instead of caching it once `max_entries` is
    /// exhausted -- still renders correctly this frame (the caller gets the
    /// texture back either way), it just won't be remembered next frame.
    /// A real app cycling through more than 32 distinct (kind, size,
    /// border) combinations for round widgets in one window would be
    /// unusual; bump the cap if that ever shows up for real.
    fn insert(self: *Cache, key: MaskKey, texture: *c.SDL_Texture) void {
        if (self.count < max_entries) {
            self.entries[self.count] = .{ .key = key, .texture = texture };
            self.count += 1;
        }
    }
};

fn circlePoints(cx: f32, cy: f32, r: f32) [circle_segments][2]f32 {
    var pts: [circle_segments][2]f32 = undefined;
    for (0..circle_segments) |i| {
        const theta = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(circle_segments));
        pts[i] = .{ cx + r * @cos(theta), cy + r * @sin(theta) };
    }
    return pts;
}

/// Fan triangulation around the polygon's own centroid -- correct for any
/// convex point set, which every shape this module draws is.
fn fillConvexPolygon(renderer: ?*c.SDL_Renderer, points: []const [2]f32, color: c.SDL_FColor) void {
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (points) |p| {
        cx += p[0];
        cy += p[1];
    }
    cx /= @floatFromInt(points.len);
    cy /= @floatFromInt(points.len);

    var verts: [circle_segments + 1]c.SDL_Vertex = undefined;
    verts[0] = .{ .position = .{ .x = cx, .y = cy }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } };
    for (points, 0..) |p, i| {
        verts[i + 1] = .{ .position = .{ .x = p[0], .y = p[1] }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } };
    }
    var indices: [circle_segments * 3]c_int = undefined;
    for (0..points.len) |i| {
        indices[i * 3 + 0] = 0;
        indices[i * 3 + 1] = @intCast(i + 1);
        indices[i * 3 + 2] = @intCast(if (i + 2 > points.len) 1 else i + 2);
    }
    _ = c.SDL_RenderGeometry(renderer, null, &verts, @intCast(points.len + 1), &indices, @intCast(points.len * 3));
}

/// Renders `super_tex`'s content down to a new `w`x`h` texture via a
/// single linear-filtered blit -- this one blit is the entire anti-aliasing
/// step. Caller owns the returned texture (and `super_tex`, still).
fn downsample(renderer: ?*c.SDL_Renderer, super_tex: *c.SDL_Texture, w: i32, h: i32) ?*c.SDL_Texture {
    const final_tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, w, h) orelse return null;
    _ = c.SDL_SetTextureBlendMode(final_tex, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetTextureScaleMode(super_tex, c.SDL_SCALEMODE_LINEAR);

    const prev_target = c.SDL_GetRenderTarget(renderer);
    _ = c.SDL_SetRenderTarget(renderer, final_tex);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_RenderTexture(renderer, super_tex, null, null);
    _ = c.SDL_SetRenderTarget(renderer, prev_target);

    return final_tex;
}

fn renderCircleMask(renderer: ?*c.SDL_Renderer, size: i32) ?*c.SDL_Texture {
    const super: i32 = size * @as(i32, @intCast(aa_level));
    const white: c.SDL_FColor = .{ .r = 1, .g = 1, .b = 1, .a = 1 };

    const super_tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, super, super) orelse return null;
    defer c.SDL_DestroyTexture(super_tex);
    _ = c.SDL_SetTextureBlendMode(super_tex, c.SDL_BLENDMODE_BLEND);

    const prev_target = c.SDL_GetRenderTarget(renderer);
    _ = c.SDL_SetRenderTarget(renderer, super_tex);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    const r: f32 = @as(f32, @floatFromInt(super)) / 2.0;
    const pts = circlePoints(r, r, r);
    fillConvexPolygon(renderer, &pts, white);

    _ = c.SDL_SetRenderTarget(renderer, prev_target);
    return downsample(renderer, super_tex, size, size);
}

fn renderRingMask(renderer: ?*c.SDL_Renderer, size: i32, border_width: i32) ?*c.SDL_Texture {
    const super: i32 = size * @as(i32, @intCast(aa_level));
    const super_border: f32 = @floatFromInt(border_width * @as(i32, @intCast(aa_level)));
    const white: c.SDL_FColor = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const clear: c.SDL_FColor = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    const super_tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, super, super) orelse return null;
    defer c.SDL_DestroyTexture(super_tex);
    _ = c.SDL_SetTextureBlendMode(super_tex, c.SDL_BLENDMODE_BLEND);

    const prev_target = c.SDL_GetRenderTarget(renderer);
    _ = c.SDL_SetRenderTarget(renderer, super_tex);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
    _ = c.SDL_RenderClear(renderer);

    const center: f32 = @as(f32, @floatFromInt(super)) / 2.0;
    const outer_r: f32 = center;
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    const outer_pts = circlePoints(center, center, outer_r);
    fillConvexPolygon(renderer, &outer_pts, white);

    // Erase the interior back to real transparency (BLENDMODE_NONE
    // overwrites rather than blends, so alpha=0 here genuinely punches a
    // hole) instead of drawing a color-matched "fill" that would only look
    // right against one specific background.
    const inner_r: f32 = @max(outer_r - super_border, 0);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
    const inner_pts = circlePoints(center, center, inner_r);
    fillConvexPolygon(renderer, &inner_pts, clear);

    _ = c.SDL_SetRenderTarget(renderer, prev_target);
    return downsample(renderer, super_tex, size, size);
}

/// Draws a filled circle inscribed in `rect` (uses `min(w, h)` as the
/// diameter) in `color`, using/populating `cache`.
pub fn drawCircle(cache: *Cache, renderer: ?*c.SDL_Renderer, rect: c.SDL_FRect, color: c.SDL_Color) void {
    const size = maskInt(@round(@min(rect.w, rect.h)));
    if (size <= 0) return;
    const key = MaskKey{ .kind = .circle, .w = size, .h = size };
    const tex = if (cache.find(key)) |t| t else blk: {
        const t = renderCircleMask(renderer, size) orelse return;
        cache.insert(key, t);
        break :blk t;
    };

    _ = c.SDL_SetTextureColorMod(tex, color.r, color.g, color.b);
    _ = c.SDL_SetTextureAlphaMod(tex, color.a);
    // `rect` (not a rect rebuilt from the integer `size`) is the real
    // destination -- centering is the caller's job (it already computed
    // `rect` to sit centered in some parent box), and re-deriving w/h from
    // a truncated/rounded `size` while keeping the original x/y would bias
    // the drawn shape toward the top-left corner of that intended box,
    // opening up a visible gap on the bottom-right instead of shrinking
    // symmetrically. `size` exists only to pick/generate a mask at a
    // stable integer resolution; SDL_RenderTexture scales that mask into
    // whatever float-precision `rect` actually is.
    _ = c.SDL_RenderTexture(renderer, tex, null, &rect);
}

/// Draws a ring (circle outline, `border_width` thick) inscribed in `rect`
/// in `color`, using/populating `cache`.
pub fn drawRing(cache: *Cache, renderer: ?*c.SDL_Renderer, rect: c.SDL_FRect, border_width: f32, color: c.SDL_Color) void {
    const size = maskInt(@round(@min(rect.w, rect.h)));
    if (size <= 0) return;
    const bw = maskInt(@max(border_width, 1));
    const key = MaskKey{ .kind = .ring, .w = size, .h = size, .border_width = bw };
    const tex = if (cache.find(key)) |t| t else blk: {
        const t = renderRingMask(renderer, size, bw) orelse return;
        cache.insert(key, t);
        break :blk t;
    };

    _ = c.SDL_SetTextureColorMod(tex, color.r, color.g, color.b);
    _ = c.SDL_SetTextureAlphaMod(tex, color.a);
    // See drawCircle's doc comment -- same reasoning, `rect` is the real
    // destination, not a rect rebuilt from the integer `size`.
    _ = c.SDL_RenderTexture(renderer, tex, null, &rect);
}

/// Each corner radius clamped to `min(w, h) / 2` -- prevents adjacent
/// corners' arcs from overlapping/inverting on a radius larger than the
/// shape can actually support, same safety margin every real rounded-rect
/// implementation needs regardless of technique.
fn clampRadii(radii: [4]f32, w: f32, h: f32) [4]f32 {
    const max_r = @min(w, h) / 2.0;
    var out: [4]f32 = undefined;
    for (radii, 0..) |r, i| out[i] = std.math.clamp(r, 0, max_r);
    return out;
}

fn quantizeRadii(radii: [4]f32) [4]i32 {
    var out: [4]i32 = undefined;
    for (radii, 0..) |r, i| out[i] = std.math.lossyCast(i32, @round(r));
    return out;
}

/// Per-corner-radius rounded rect, traced as 4 independent quarter-turn
/// arcs (TL, TR, BR, BL -- matches the stylesheet's real CSS-clockwise
/// order) with the straight edges between them left implicit (see this
/// file's own `corner_segments` doc comment for why that's exact, not an
/// approximation).
fn roundedRectPoints(x: f32, y: f32, w: f32, h: f32, radii: [4]f32) [circle_segments][2]f32 {
    var pts: [circle_segments][2]f32 = undefined;
    const half_pi = std.math.pi / 2.0;
    const Corner = struct { cx: f32, cy: f32, start: f32, r: f32 };
    const corners = [4]Corner{
        .{ .cx = x + radii[0], .cy = y + radii[0], .start = std.math.pi, .r = radii[0] }, // TL
        .{ .cx = x + w - radii[1], .cy = y + radii[1], .start = -half_pi, .r = radii[1] }, // TR
        .{ .cx = x + w - radii[2], .cy = y + h - radii[2], .start = 0, .r = radii[2] }, // BR
        .{ .cx = x + radii[3], .cy = y + h - radii[3], .start = half_pi, .r = radii[3] }, // BL
    };
    var idx: usize = 0;
    for (corners) |corner| {
        for (0..corner_segments + 1) |i| {
            const t = corner.start + half_pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(corner_segments));
            pts[idx] = .{ corner.cx + corner.r * @cos(t), corner.cy + corner.r * @sin(t) };
            idx += 1;
        }
    }
    return pts;
}

fn renderRectMask(renderer: ?*c.SDL_Renderer, w: i32, h: i32, radii: [4]f32) ?*c.SDL_Texture {
    const aa_i: i32 = @intCast(aa_level);
    const super_w: i32 = w * aa_i;
    const super_h: i32 = h * aa_i;
    const white: c.SDL_FColor = .{ .r = 1, .g = 1, .b = 1, .a = 1 };

    const super_tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, super_w, super_h) orelse return null;
    defer c.SDL_DestroyTexture(super_tex);
    _ = c.SDL_SetTextureBlendMode(super_tex, c.SDL_BLENDMODE_BLEND);

    const prev_target = c.SDL_GetRenderTarget(renderer);
    _ = c.SDL_SetRenderTarget(renderer, super_tex);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    const aa_f: f32 = @floatFromInt(aa_level);
    const clamped = clampRadii(radii, @floatFromInt(w), @floatFromInt(h));
    const scaled_radii = [4]f32{ clamped[0] * aa_f, clamped[1] * aa_f, clamped[2] * aa_f, clamped[3] * aa_f };
    const pts = roundedRectPoints(0, 0, @floatFromInt(super_w), @floatFromInt(super_h), scaled_radii);
    fillConvexPolygon(renderer, &pts, white);

    _ = c.SDL_SetRenderTarget(renderer, prev_target);
    return downsample(renderer, super_tex, w, h);
}

fn renderRectBorderMask(renderer: ?*c.SDL_Renderer, w: i32, h: i32, radii: [4]f32, border_width: f32) ?*c.SDL_Texture {
    const aa_i: i32 = @intCast(aa_level);
    const super_w: i32 = w * aa_i;
    const super_h: i32 = h * aa_i;
    const white: c.SDL_FColor = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const clear: c.SDL_FColor = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    const super_tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, super_w, super_h) orelse return null;
    defer c.SDL_DestroyTexture(super_tex);
    _ = c.SDL_SetTextureBlendMode(super_tex, c.SDL_BLENDMODE_BLEND);

    const prev_target = c.SDL_GetRenderTarget(renderer);
    _ = c.SDL_SetRenderTarget(renderer, super_tex);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
    _ = c.SDL_RenderClear(renderer);

    const aa_f: f32 = @floatFromInt(aa_level);
    const clamped = clampRadii(radii, @floatFromInt(w), @floatFromInt(h));
    const outer_scaled = [4]f32{ clamped[0] * aa_f, clamped[1] * aa_f, clamped[2] * aa_f, clamped[3] * aa_f };
    const super_w_f: f32 = @floatFromInt(super_w);
    const super_h_f: f32 = @floatFromInt(super_h);

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    const outer_pts = roundedRectPoints(0, 0, super_w_f, super_h_f, outer_scaled);
    fillConvexPolygon(renderer, &outer_pts, white);

    // Erase the interior back to real transparency, same reasoning as
    // renderRingMask -- BLENDMODE_NONE + alpha 0 genuinely punches a hole
    // rather than drawing a color-matched fake fill that would only look
    // right against one specific background.
    const super_border: f32 = border_width * aa_f;
    const inner_w = @max(super_w_f - 2 * super_border, 0);
    const inner_h = @max(super_h_f - 2 * super_border, 0);
    var inner_radii: [4]f32 = undefined;
    for (outer_scaled, 0..) |r, i| inner_radii[i] = @max(r - super_border, 0);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
    const inner_pts = roundedRectPoints(super_border, super_border, inner_w, inner_h, inner_radii);
    fillConvexPolygon(renderer, &inner_pts, clear);

    _ = c.SDL_SetRenderTarget(renderer, prev_target);
    return downsample(renderer, super_tex, w, h);
}

/// Draws a filled, per-corner-rounded rectangle (`radii` in TL/TR/BR/BL
/// order, matching the stylesheet's real CSS-clockwise convention) in
/// `color`, using/populating `cache`. Unlike `drawCircle`, `rect` need not
/// be square -- this is the shape Container/Button-style widgets actually
/// want (e.g. 8px corners on a 200x40 button).
pub fn drawRoundedRect(cache: *Cache, renderer: ?*c.SDL_Renderer, rect: c.SDL_FRect, radii: [4]f32, color: c.SDL_Color) void {
    const w = maskInt(@round(rect.w));
    const h = maskInt(@round(rect.h));
    if (w <= 0 or h <= 0) return;
    const key = MaskKey{ .kind = .rect, .w = w, .h = h, .radii = quantizeRadii(radii) };
    const tex = if (cache.find(key)) |t| t else blk: {
        const t = renderRectMask(renderer, w, h, radii) orelse return;
        cache.insert(key, t);
        break :blk t;
    };

    _ = c.SDL_SetTextureColorMod(tex, color.r, color.g, color.b);
    _ = c.SDL_SetTextureAlphaMod(tex, color.a);
    // See drawCircle's doc comment -- `rect` is the real destination, not a
    // rect rebuilt from the integer w/h used only for the mask/cache key.
    _ = c.SDL_RenderTexture(renderer, tex, null, &rect);
}

/// Draws a per-corner-rounded rectangle's border (`border_width` thick,
/// inset from the outer edge) in `color`, using/populating `cache`.
pub fn drawRoundedRectBorder(cache: *Cache, renderer: ?*c.SDL_Renderer, rect: c.SDL_FRect, radii: [4]f32, border_width: f32, color: c.SDL_Color) void {
    const w = maskInt(@round(rect.w));
    const h = maskInt(@round(rect.h));
    if (w <= 0 or h <= 0) return;
    const bw = maskInt(@max(@round(border_width), 1));
    const key = MaskKey{ .kind = .rect_border, .w = w, .h = h, .radii = quantizeRadii(radii), .border_width = bw };
    const tex = if (cache.find(key)) |t| t else blk: {
        const t = renderRectBorderMask(renderer, w, h, radii, @floatFromInt(bw)) orelse return;
        cache.insert(key, t);
        break :blk t;
    };

    _ = c.SDL_SetTextureColorMod(tex, color.r, color.g, color.b);
    _ = c.SDL_SetTextureAlphaMod(tex, color.a);
    _ = c.SDL_RenderTexture(renderer, tex, null, &rect);
}

fn lerpColor(a: c.SDL_FColor, b: c.SDL_FColor, t: f32) c.SDL_FColor {
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}

/// Draws a filled, per-corner-rounded rectangle with a linear gradient
/// fill, using/populating `cache` for the shape mask exactly like
/// `drawRoundedRect` (the mask is shape-only -- fill is applied at draw
/// time regardless of mode, per this file's own doc comment). Deliberately
/// anchor-agnostic: `start_uv`/`end_uv` are plain 0..1 shape-space
/// positions (0,0 = top-left, 1,1 = bottom-right), not the stylesheet's
/// named 8-direction vocabulary -- resolving an anchor name like `topLeft`
/// to a UV position is a stylesheet/codegen concern (Codegen.zig bakes it
/// in at `natyv prepare` time, the same place hex colors already get
/// resolved to floats), not something this rendering module needs to know.
///
/// The gradient axis runs from `start_uv` to `end_uv`; each of the
/// rectangle's 4 real corners gets a color by projecting its own position
/// onto that axis (`t = clamp(dot(corner - start, axis) / |axis|^2, 0, 1)`,
/// the standard two-point linear-gradient projection) and lerping
/// `start_color`/`end_color` by `t`. `SDL_RenderGeometry`'s native
/// per-vertex color interpolation then does the actual per-pixel blend
/// between those 4 corners while sampling the shape mask for alpha --
/// first real use of that interpolation in this codebase, but the same
/// mechanism `fillConvexPolygon` already relies on for flat colors (just
/// with a texture bound this time instead of `null`), not a new technique.
pub fn drawRoundedRectGradient(cache: *Cache, renderer: ?*c.SDL_Renderer, rect: c.SDL_FRect, radii: [4]f32, start_uv: [2]f32, start_color: c.SDL_FColor, end_uv: [2]f32, end_color: c.SDL_FColor) void {
    const w = maskInt(@round(rect.w));
    const h = maskInt(@round(rect.h));
    if (w <= 0 or h <= 0) return;
    const key = MaskKey{ .kind = .rect, .w = w, .h = h, .radii = quantizeRadii(radii) };
    const tex = if (cache.find(key)) |t| t else blk: {
        const t = renderRectMask(renderer, w, h, radii) orelse return;
        cache.insert(key, t);
        break :blk t;
    };
    // Reset any leftover flat-fill mod from a previous drawRoundedRect call
    // against this same cached texture -- the gradient's own per-vertex
    // colors below are the only modulation that should apply here.
    _ = c.SDL_SetTextureColorMod(tex, 255, 255, 255);
    _ = c.SDL_SetTextureAlphaMod(tex, 255);

    const axis: [2]f32 = .{ end_uv[0] - start_uv[0], end_uv[1] - start_uv[1] };
    const axis_len_sq = axis[0] * axis[0] + axis[1] * axis[1];

    const corner_uvs = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }; // TL,TR,BR,BL
    var corner_colors: [4]c.SDL_FColor = undefined;
    for (corner_uvs, 0..) |uv, i| {
        const rel: [2]f32 = .{ uv[0] - start_uv[0], uv[1] - start_uv[1] };
        const t: f32 = if (axis_len_sq > 0) std.math.clamp((rel[0] * axis[0] + rel[1] * axis[1]) / axis_len_sq, 0, 1) else 0;
        corner_colors[i] = lerpColor(start_color, end_color, t);
    }

    const corner_pos = [4][2]f32{
        .{ rect.x, rect.y },
        .{ rect.x + rect.w, rect.y },
        .{ rect.x + rect.w, rect.y + rect.h },
        .{ rect.x, rect.y + rect.h },
    };
    var verts: [4]c.SDL_Vertex = undefined;
    for (0..4) |i| {
        verts[i] = .{ .position = .{ .x = corner_pos[i][0], .y = corner_pos[i][1] }, .color = corner_colors[i], .tex_coord = .{ .x = corner_uvs[i][0], .y = corner_uvs[i][1] } };
    }
    var indices = [6]c_int{ 0, 1, 2, 0, 2, 3 };
    _ = c.SDL_RenderGeometry(renderer, tex, &verts, 4, &indices, 6);
}

/// Draws a filled, per-corner-rounded rectangle with a texture fill (the
/// user's own image, already decoded to `image` by ImageCache.getOrLoad)
/// instead of a flat color or gradient, using/populating `cache` for the
/// shape mask exactly like drawRoundedRect/drawRoundedRectGradient.
///
/// Compositing technique, no shader (matches this file's own "no custom
/// GPU shader anywhere" v1 constraint): three real SDL_BlendMode passes,
/// each formula taken directly from SDL3's own documented blend-mode
/// definitions (SDL_blendmode.h), not derived by trial and error --
///   1. Clear a scratch target `T` (sized to the mask, not the caller's
///      float `rect`) to fully transparent.
///   2. Draw the mask onto `T` with BLENDMODE_BLEND. Since the mask's own
///      color is pure white, BLEND's `dstRGB = srcRGB*srcA + dstRGB*(1-srcA)`
///      leaves `T.RGB = (coverage, coverage, coverage)` and `T.A = coverage`
///      -- i.e. `T` is now a valid *premultiplied*-alpha representation of
///      the mask alone (RGB already scaled by its own alpha).
///   3. Draw `image` onto `T`, stretched to fill it, with BLENDMODE_MOD.
///      MOD's `dstRGB = srcRGB*dstRGB` (alpha untouched) turns
///      `T.RGB` into `image.RGB * coverage` -- still premultiplied, now
///      holding the actual image color instead of white, alpha still
///      `coverage`.
///   4. Blit `T` onto the real destination with BLENDMODE_BLEND_PREMULTIPLIED
///      (`dstRGBA = srcRGBA + dstRGBA*(1-srcA)`) -- the correct composite
///      for an already-premultiplied source, unlike plain BLEND which would
///      multiply by `T.A` a second time.
///
/// `image`'s own alpha channel is deliberately ignored by this technique
/// (MOD's formula never reads `srcA`) -- a real v1 scope limitation, not an
/// oversight: a texture-fill image is expected to be an opaque photo/
/// pattern, not a further semi-transparent layer on top of the shape's own
/// mask alpha. Revisit if that need ever surfaces for real.
pub fn drawRoundedRectTexture(cache: *Cache, renderer: ?*c.SDL_Renderer, rect: c.SDL_FRect, radii: [4]f32, image: *c.SDL_Texture) void {
    const w = maskInt(@round(rect.w));
    const h = maskInt(@round(rect.h));
    if (w <= 0 or h <= 0) return;
    const key = MaskKey{ .kind = .rect, .w = w, .h = h, .radii = quantizeRadii(radii) };
    const mask = if (cache.find(key)) |t| t else blk: {
        const t = renderRectMask(renderer, w, h, radii) orelse return;
        cache.insert(key, t);
        break :blk t;
    };
    // Reset any leftover flat-fill/gradient mod from a previous draw
    // against this same cached mask -- see drawRoundedRectGradient's
    // identical reset for why -- and force BLEND explicitly since nothing
    // else in this file ever changes a cached mask's own blend mode away
    // from it, but this function's correctness genuinely depends on it.
    _ = c.SDL_SetTextureColorMod(mask, 255, 255, 255);
    _ = c.SDL_SetTextureAlphaMod(mask, 255);
    _ = c.SDL_SetTextureBlendMode(mask, c.SDL_BLENDMODE_BLEND);

    const scratch = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, w, h) orelse return;
    defer c.SDL_DestroyTexture(scratch);
    _ = c.SDL_SetTextureScaleMode(scratch, c.SDL_SCALEMODE_LINEAR);

    const prev_target = c.SDL_GetRenderTarget(renderer);
    _ = c.SDL_SetRenderTarget(renderer, scratch);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_RenderTexture(renderer, mask, null, null);

    // `image` is cached (ImageCache) and reused across frames/shapes, so
    // its blend mode is switched to MOD only for this one draw and
    // restored to BLEND immediately after -- leaving it on MOD would
    // corrupt any other real use of the same decoded texture.
    _ = c.SDL_SetTextureBlendMode(image, c.SDL_BLENDMODE_MOD);
    _ = c.SDL_RenderTexture(renderer, image, null, null);
    _ = c.SDL_SetTextureBlendMode(image, c.SDL_BLENDMODE_BLEND);

    _ = c.SDL_SetRenderTarget(renderer, prev_target);

    _ = c.SDL_SetTextureBlendMode(scratch, c.SDL_BLENDMODE_BLEND_PREMULTIPLIED);
    // See drawCircle's doc comment -- `rect` is the real destination, not a
    // rect rebuilt from the integer w/h used only for the mask/cache key.
    _ = c.SDL_RenderTexture(renderer, scratch, null, &rect);
}

test "maskInt saturates, maps NaN to 0, and keeps dim * aa_level inside i32" {
    try std.testing.expectEqual(@as(i32, 120), maskInt(120));
    try std.testing.expectEqual(max_mask_dim, maskInt(1e30));
    try std.testing.expectEqual(std.math.minInt(i32), maskInt(-1e30));
    try std.testing.expectEqual(@as(i32, 0), maskInt(std.math.nan(f32)));
    // The multiply every render*Mask does must not overflow at the cap.
    _ = maskInt(3e38) * @as(i32, @intCast(aa_level));
}
