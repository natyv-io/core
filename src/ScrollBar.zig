//! W2: pure geometry for a scrollbar thumb drawn over a Clay scroll
//! container. Given the container's own on-screen rect (from its `Slot`)
//! and Clay's live scroll-container data (offset + container/content
//! dimensions, via `ClayLayout.scrollContainerData`), computes the thumb
//! rect for each axis -- or null if that axis doesn't overflow, matching
//! native scrollbars hiding entirely rather than showing a full-length,
//! undraggable bar. No SDL/Clay calls in here -- pure and unit-tested,
//! same split as ScrollClip.zig.
//!
//! v1 scope: display-only (not draggable/clickable), always-visible when an
//! axis overflows. A drag-to-scroll thumb would need its own hit-testing +
//! mouse-capture wiring in main.zig's event loop; deliberately out of scope
//! for this pass -- the wheel is still the only way to move the content, the
//! bar is purely a position indicator.

const std = @import("std");
const c = @import("c.zig").c;

pub const thickness: f32 = 6;
pub const inset: f32 = 2;
pub const min_thumb_length: f32 = 20;

/// Mirrors the fields of `Clay_ScrollContainerData` this file actually
/// needs -- kept as a plain struct (not the real Clay type) so the pure
/// functions below don't need a live Clay context to unit test.
pub const Data = struct {
    scroll_offset_x: f32,
    scroll_offset_y: f32,
    container_w: f32,
    container_h: f32,
    content_w: f32,
    content_h: f32,
};

/// `container_rect` is the scroll container's own on-screen rect (its
/// `Slot.widget`'s rect, same one `ScrollClip` reads). Returns null if
/// content doesn't overflow vertically -- nothing to scroll, so no thumb.
pub fn verticalThumb(container_rect: c.SDL_FRect, data: Data) ?c.SDL_FRect {
    if (data.content_h <= data.container_h + 0.5) return null;
    const track_h = container_rect.h;
    const thumb_h = @max(min_thumb_length, track_h * (data.container_h / data.content_h));
    const max_scroll = data.content_h - data.container_h;
    // Clay's scrollPosition.y is <= 0, more negative the further the
    // content has scrolled up -- see Clay_UpdateScrollContainers.
    const progress = std.math.clamp(-data.scroll_offset_y / max_scroll, 0, 1);
    return .{
        .x = container_rect.x + container_rect.w - thickness - inset,
        .y = container_rect.y + progress * (track_h - thumb_h),
        .w = thickness,
        .h = thumb_h,
    };
}

pub fn horizontalThumb(container_rect: c.SDL_FRect, data: Data) ?c.SDL_FRect {
    if (data.content_w <= data.container_w + 0.5) return null;
    const track_w = container_rect.w;
    const thumb_w = @max(min_thumb_length, track_w * (data.container_w / data.content_w));
    const max_scroll = data.content_w - data.container_w;
    const progress = std.math.clamp(-data.scroll_offset_x / max_scroll, 0, 1);
    return .{
        .x = container_rect.x + progress * (track_w - thumb_w),
        .y = container_rect.y + container_rect.h - thickness - inset,
        .w = thumb_w,
        .h = thickness,
    };
}

fn testData(container_h: f32, content_h: f32, scroll_offset_y: f32) Data {
    return .{
        .scroll_offset_x = 0,
        .scroll_offset_y = scroll_offset_y,
        .container_w = 100,
        .container_h = container_h,
        .content_w = 100,
        .content_h = content_h,
    };
}

test "content shorter than container -- no vertical thumb" {
    const rect: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expectEqual(@as(?c.SDL_FRect, null), verticalThumb(rect, testData(100, 80, 0)));
}

test "content exactly filling container -- no vertical thumb" {
    const rect: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expectEqual(@as(?c.SDL_FRect, null), verticalThumb(rect, testData(100, 100, 0)));
}

test "unscrolled overflowing content -- thumb at the top, proportional height" {
    const rect: c.SDL_FRect = .{ .x = 10, .y = 20, .w = 100, .h = 100 };
    // 100/200 of content visible -> thumb is half the track height.
    const thumb = verticalThumb(rect, testData(100, 200, 0)).?;
    try std.testing.expectEqual(@as(f32, 20), thumb.y);
    try std.testing.expectEqual(@as(f32, 50), thumb.h);
    try std.testing.expectEqual(@as(f32, 10 + 100 - thickness - inset), thumb.x);
}

test "fully scrolled content -- thumb at the bottom of the track" {
    const rect: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    // max_scroll = 200 - 100 = 100; scrollPosition.y = -100 is fully scrolled.
    const thumb = verticalThumb(rect, testData(100, 200, -100)).?;
    try std.testing.expectEqual(@as(f32, 50), thumb.h);
    try std.testing.expectEqual(@as(f32, 100 - 50), thumb.y); // track_h - thumb_h
}

test "thumb never shrinks below the minimum length even for huge overflow" {
    const rect: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const thumb = verticalThumb(rect, testData(100, 10000, 0)).?;
    try std.testing.expectEqual(min_thumb_length, thumb.h);
}

test "horizontal thumb mirrors the vertical case on the x axis" {
    const rect: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    var data = testData(100, 100, 0); // vertical doesn't overflow
    data.content_w = 300; // horizontal does
    const thumb = horizontalThumb(rect, data).?;
    try std.testing.expectEqual(@as(f32, 100 - thickness - inset), thumb.y);
    try std.testing.expect(thumb.w < rect.w);
}
