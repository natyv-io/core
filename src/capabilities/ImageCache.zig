//! Decoded-image texture cache for texture-fill background images --
//! separate from ShapeCache's own `Cache` (which holds shape masks keyed
//! by geometry) since this one is keyed by asset id and holds the actual
//! decoded pixel content, reused across any shape/size that references the
//! same image. One `Cache` per window (SDL textures are renderer-scoped),
//! same per-window-resource shape as ShapeCache.Cache and
//! WindowManager.WindowContext's own text_engine field.
//!
//! Decoding goes through stb_image (vendor/stb) via stbi_load_from_memory
//! only -- natyv never reads an image from a filesystem path at runtime,
//! only already-`@embedFile`'d bytes the build baked in (see the styling
//! system's texture-fill asset-staging design), matching this codebase's
//! closed-input-surface convention.

const std = @import("std");
const c = @import("../c.zig").c;

const max_entries = 16;

const Entry = struct {
    asset_id: u32,
    texture: *c.SDL_Texture,
};

pub const Cache = struct {
    entries: [max_entries]?Entry = [_]?Entry{null} ** max_entries,
    count: usize = 0,

    pub fn deinit(self: *Cache) void {
        for (self.entries[0..self.count]) |entry| {
            if (entry) |e| c.SDL_DestroyTexture(e.texture);
        }
        self.count = 0;
    }

    fn find(self: *Cache, asset_id: u32) ?*c.SDL_Texture {
        for (self.entries[0..self.count]) |entry| {
            if (entry) |e| {
                if (e.asset_id == asset_id) return e.texture;
            }
        }
        return null;
    }

    /// Silently drops the decoded texture instead of caching it once
    /// `max_entries` is exhausted -- mirrors ShapeCache.Cache's own
    /// insert() precedent exactly: still decodes and draws correctly this
    /// frame, just re-decodes next frame instead of being remembered. Bump
    /// the cap if a real app references more than 16 distinct texture-fill
    /// images in one window.
    fn insert(self: *Cache, asset_id: u32, texture: *c.SDL_Texture) void {
        if (self.count < max_entries) {
            self.entries[self.count] = .{ .asset_id = asset_id, .texture = texture };
            self.count += 1;
        }
    }
};

/// Returns the decoded texture for `asset_id`, decoding `bytes` via
/// stb_image and caching the result on first use -- `bytes` is only read
/// on a cache miss, so the caller can pass the same `@embedFile`d slice
/// every frame with no repeated decode cost once cached. Returns null on a
/// genuine decode failure (corrupt/unsupported image bytes); callers
/// should skip the draw for this frame rather than crash, the same
/// convention ShapeCache.zig's own mask-creation functions already use for
/// an `SDL_CreateTexture` failure.
pub fn getOrLoad(self: *Cache, renderer: ?*c.SDL_Renderer, asset_id: u32, bytes: []const u8) ?*c.SDL_Texture {
    if (self.find(asset_id)) |t| return t;

    var w: c_int = 0;
    var h: c_int = 0;
    var channels_in_file: c_int = 0;
    // 4 == force RGBA regardless of the source's real channel count (a
    // grayscale PNG, an opaque JPEG, ...) -- ShapeCache.drawRoundedRectTexture
    // always composites through this texture's alpha channel, so every
    // decoded image needs one, real source alpha or not.
    const pixels = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &channels_in_file, 4) orelse return null;
    defer c.stbi_image_free(pixels);

    const tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, w, h) orelse return null;
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);
    // stb_image always outputs tightly-packed rows (no padding) when asked
    // for 4 channels -- pitch is exactly w * 4.
    if (!c.SDL_UpdateTexture(tex, null, pixels, w * 4)) {
        c.SDL_DestroyTexture(tex);
        return null;
    }

    self.insert(asset_id, tex);
    return tex;
}

// Minimal hand-built 2x2 uncompressed 32bpp TGA (no PNG/JPEG chunk
// checksums to get right by hand, unlike PNG -- TGA's true-color path is a
// plain 18-byte header followed by raw BGRA rows, easy to construct
// correctly for a test fixture). Image descriptor 0x28 = top-left origin
// (rows stored top-to-bottom) + 8 bits of alpha. Row 0: opaque red, opaque
// green. Row 1: opaque blue, opaque white.
//
// `pub` and real tests live in WindowManager.zig, not here -- see that
// file's own test for why (a real SDL-backed test needs `../c.zig`, which
// is outside this file's own module root when it's compiled as a
// standalone test target; a test declared *in* this file would simply
// never be discovered/run at all).
pub const test_tga = [_]u8{
    0, 0, 2,   0,   0, 0,   0, 0,   0,   0, 0, 0,   2,   0,   2,   0,   32, 0x28,
    0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255,
};
