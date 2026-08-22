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
//! Scope, deliberate: only a filled circle and a ring (annulus) mask exist
//! today, matching RadioButton's own real need -- a proper circle outline
//! plus a filled dot, replacing the square-box-reused-for-radio placeholder
//! its own doc comment flagged as "next milestone's job." Checkbox needs no
//! mask at all: `SDL_RenderRect` already draws a perfectly sharp square
//! with zero anti-aliasing artifacts, which is exactly what `cornerRadius =
//! 0` wants -- there is no bug to fix there. General rounded-rect masks
//! (non-zero, non-half-size radius) are real future work once a Stage 5
//! widget (Card/Panel) actually needs one, not built speculatively here.
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

const std = @import("std");
const c = @import("../c.zig").c;

pub const aa_level: u32 = 4;
const max_entries = 32;
const circle_segments = 48;

const MaskKind = enum { circle, ring };

const MaskKey = struct {
    kind: MaskKind,
    size: i32,
    border_width: i32 = 0, // only meaningful for .ring
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
                if (e.key.kind == key.kind and e.key.size == key.size and e.key.border_width == key.border_width) return e.texture;
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

/// Renders `super_tex`'s content down to a new `size`x`size` texture via a
/// single linear-filtered blit -- this one blit is the entire anti-aliasing
/// step. Caller owns the returned texture (and `super_tex`, still).
fn downsample(renderer: ?*c.SDL_Renderer, super_tex: *c.SDL_Texture, size: i32) ?*c.SDL_Texture {
    const final_tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, size, size) orelse return null;
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
    return downsample(renderer, super_tex, size);
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
    return downsample(renderer, super_tex, size);
}

/// Draws a filled circle inscribed in `rect` (uses `min(w, h)` as the
/// diameter) in `color`, using/populating `cache`.
pub fn drawCircle(cache: *Cache, renderer: ?*c.SDL_Renderer, rect: c.SDL_FRect, color: c.SDL_Color) void {
    const size: i32 = @intFromFloat(@round(@min(rect.w, rect.h)));
    if (size <= 0) return;
    const key = MaskKey{ .kind = .circle, .size = size };
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
    const size: i32 = @intFromFloat(@round(@min(rect.w, rect.h)));
    if (size <= 0) return;
    const bw: i32 = @intFromFloat(@max(border_width, 1));
    const key = MaskKey{ .kind = .ring, .size = size, .border_width = bw };
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
