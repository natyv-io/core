//! L1: proves Clay's real (non-macro) C API is callable from Zig and
//! produces correct layout, before any of natyv's own widget/host-function
//! code depends on it.
//!
//! L4: `Self` is the real per-app Clay capability -- owns Clay's arena for
//! the lifetime of the running app and drives one real layout pass per
//! frame from the live widget registry, but *only* when
//! `WidgetHost.layout_generation` has actually moved since the last one
//! (see `layoutIfNeeded`'s doc comment for why: Clay itself has no
//! incremental-relayout API, so skipping the call entirely on an unchanged
//! frame is natyv's job, not Clay's).
//!
//! Clay's ergonomic `CLAY({...}) { children }` macro syntax doesn't survive
//! @cImport (it relies on C-preprocessor for-loop tricks Zig can't use),
//! but the macros expand to plain exported functions --
//! Clay__OpenElement/Clay__OpenElementWithId/Clay__ConfigureOpenElement/
//! Clay__CloseElement/Clay__OpenTextElement -- which @cImport does expose.
//! Zig code drives Clay by calling these directly instead of the macros.

const std = @import("std");
const Io = std.Io;
const c = @import("../c.zig").c;
const WidgetHost = @import("../widgets/WidgetHost.zig");

const Self = @This();

fn onClayError(errorData: c.Clay_ErrorData) callconv(.c) void {
    std.debug.print("[clay] error: {s}\n", .{errorData.errorText.chars[0..@intCast(errorData.errorText.length)]});
}

// F3: real font-driven measurement, replacing the old 8x8-per-character
// bitmap-font heuristic -- `userData` is the default `*c.TTF_Font`, passed
// through by `Clay_SetMeasureTextFunction` (see `init`/
// `proveTwoGrowChildrenSplitEvenly`). Not yet exercised by any real Clay
// layout pass today: natyv's widgets are declared as plain sized elements
// (`openChildren` below), never as Clay TEXT children via
// `Clay__OpenTextElement` -- so Clay never actually calls this function
// yet, and a FIT-sized leaf widget still collapses to its min (0) exactly
// as `sdk/go/ui/clay`'s `Fit()` doc comment already says. Fixed now anyway
// so it's correct the moment something does declare Clay text content,
// rather than leaving a heuristic that would silently need revisiting
// again later.
fn measureText(text: c.Clay_StringSlice, config: [*c]c.Clay_TextElementConfig, userData: ?*anyopaque) callconv(.c) c.Clay_Dimensions {
    _ = config;
    const font: *c.TTF_Font = @ptrCast(userData orelse return .{ .width = 0, .height = 0 });
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.TTF_GetStringSize(font, text.chars, @intCast(text.length), &w, &h);
    return .{ .width = @floatFromInt(w), .height = @floatFromInt(h) };
}

fn hashId(comptime label: []const u8) c.Clay_ElementId {
    const str: c.Clay_String = .{ .isStaticallyAllocated = true, .length = label.len, .chars = label.ptr };
    return c.Clay__HashString(str, 0);
}

pub const GrowSplitResult = struct {
    child_a: c.Clay_BoundingBox,
    child_b: c.Clay_BoundingBox,
};

/// L1 self-test logic, exposed as a real callable function (not just a
/// `test` block) so `Runtime.zig`'s own tests can call it directly -- an
/// import that's merely referenced but never actually called doesn't get
/// its own `test` blocks discovered under Zig's lazy analysis (confirmed
/// empirically: importing this file alone, even via
/// `std.testing.refAllDecls`, left this file's tests silently unrun).
/// Actually invoking a real function is a more robust pattern regardless,
/// and is what L2/L3 will need from this file anyway.
pub fn proveTwoGrowChildrenSplitEvenly(allocator: std.mem.Allocator) !GrowSplitResult {
    const arena_size = c.Clay_MinMemorySize();
    const memory = try allocator.alloc(u8, arena_size);
    defer allocator.free(memory);
    // Clay keeps its "current context" as global state (by design, to
    // support Clay_SetCurrentContext-based multi-instance use). Clearing it
    // before `memory` above gets freed is required, not just tidy: L4's
    // real per-app ClayLayout.init() calls Clay_MinMemorySize() too, and
    // that function dereferences the current context if one is set.
    // Leaving a dangling pointer here after this function returns segfaults
    // the *next* unrelated Clay caller in the same process -- caught
    // empirically once a second Clay lifecycle (L4's test) actually ran
    // after this one in the same `zig build test` binary. Deferred *after*
    // the `allocator.free(memory)` above so it runs first (defers are
    // LIFO), clearing the pointer before the memory it points into goes
    // away.
    defer c.Clay_SetCurrentContext(null);
    const clay_arena = c.Clay_CreateArenaWithCapacityAndMemory(arena_size, memory.ptr);

    _ = c.Clay_Initialize(clay_arena, .{ .width = 300, .height = 100 }, .{
        .errorHandlerFunction = onClayError,
        .userData = null,
    });
    c.Clay_SetMeasureTextFunction(measureText, null);

    c.Clay_BeginLayout();

    var parent_decl: c.Clay_ElementDeclaration = std.mem.zeroes(c.Clay_ElementDeclaration);
    parent_decl.layout.sizing.width = .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = 300, .max = 300 } } };
    parent_decl.layout.sizing.height = .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = 100, .max = 100 } } };
    parent_decl.layout.layoutDirection = c.CLAY_LEFT_TO_RIGHT;

    const parent_id = hashId("parent");
    c.Clay__OpenElementWithId(parent_id);
    c.Clay__ConfigureOpenElement(parent_decl);

    var grow_decl: c.Clay_ElementDeclaration = std.mem.zeroes(c.Clay_ElementDeclaration);
    grow_decl.layout.sizing.width = .{ .type = c.CLAY__SIZING_TYPE_GROW, .size = .{ .minMax = .{ .min = 0, .max = std.math.floatMax(f32) } } };
    grow_decl.layout.sizing.height = .{ .type = c.CLAY__SIZING_TYPE_GROW, .size = .{ .minMax = .{ .min = 0, .max = std.math.floatMax(f32) } } };

    const child_a_id = hashId("childA");
    c.Clay__OpenElementWithId(child_a_id);
    c.Clay__ConfigureOpenElement(grow_decl);
    c.Clay__CloseElement();

    const child_b_id = hashId("childB");
    c.Clay__OpenElementWithId(child_b_id);
    c.Clay__ConfigureOpenElement(grow_decl);
    c.Clay__CloseElement();

    c.Clay__CloseElement(); // close parent

    _ = c.Clay_EndLayout(0.0);

    const a_data = c.Clay_GetElementData(child_a_id);
    const b_data = c.Clay_GetElementData(child_b_id);
    if (!a_data.found or !b_data.found) return error.ClayElementNotFound;

    return .{ .child_a = a_data.boundingBox, .child_b = b_data.boundingBox };
}

// L4: every Clay-managed widget's element id is this constant string hashed
// with the widget's own numeric id as Clay__HashStringWithOffset's `offset`
// -- the same mechanism CLAY_SIDI expands to for indexed elements in a
// loop, reused here since widget ids are exactly that: a stable per-widget
// index, no runtime string formatting needed to make each one unique.
const widget_id_label: c.Clay_String = .{ .isStaticallyAllocated = true, .length = "natyv_widget".len, .chars = "natyv_widget" };
fn elementId(widget_id: u32) c.Clay_ElementId {
    return c.Clay__HashStringWithOffset(widget_id_label, widget_id, 0);
}

// Widget ids start at 1 (see WidgetHost.next_id), so 0 is free to use as
// the offset for the single synthetic root element every Clay-managed
// widget with no parent gets attached under. `elementId` calls into real
// (non-comptime-callable) C code, so this stays a function, not a
// top-level const -- computed fresh in `layoutIfNeeded` each real pass.
fn rootElementId() c.Clay_ElementId {
    return elementId(0);
}

arena_memory: []u8,
/// The generation `layoutIfNeeded` last actually ran Clay for -- `null`
/// means "never," so the very first call always computes regardless of
/// what `WidgetHost.layout_generation` happens to be.
last_computed_generation: ?u64 = null,
/// Bumped only on an actual `Clay_EndLayout` call, never on a skipped
/// frame -- this is what proves the dirty-flag caching really avoids the
/// call, not just avoids its visible side effects.
recompute_count: usize = 0,

pub fn init(allocator: std.mem.Allocator, window_w: f32, window_h: f32, default_font: *c.TTF_Font) !Self {
    // Defensive, not just symmetric with `deinit` below: if any previous
    // Clay lifecycle in this process (another ClayLayout instance, or
    // ClayLayout.zig's own L1 proof function) left Clay's global "current
    // context" pointing at memory that's since been freed,
    // Clay_MinMemorySize() below would dereference it and segfault --
    // confirmed by hitting exactly that crash before this line was added
    // (see the comment on `proveTwoGrowChildrenSplitEvenly`'s matching
    // cleanup). Clearing it first means Clay_MinMemorySize() always falls
    // back to its documented defaults instead, regardless of what any
    // other caller did or forgot to clean up.
    c.Clay_SetCurrentContext(null);
    const arena_size = c.Clay_MinMemorySize();
    const memory = try allocator.alloc(u8, arena_size);
    const clay_arena = c.Clay_CreateArenaWithCapacityAndMemory(arena_size, memory.ptr);
    _ = c.Clay_Initialize(clay_arena, .{ .width = window_w, .height = window_h }, .{
        .errorHandlerFunction = onClayError,
        .userData = null,
    });
    c.Clay_SetMeasureTextFunction(measureText, default_font);
    return .{ .arena_memory = memory };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    // See `init`'s comment -- clear the global pointer before freeing the
    // memory it points into, so nothing after this call can dereference it.
    c.Clay_SetCurrentContext(null);
    allocator.free(self.arena_memory);
}

/// Recursively opens every Clay-managed widget in `slots` whose `parent_id`
/// matches `parent_id`, redeclaring each one's stored `ClayStyle` and
/// recursing into its own children before closing it -- rebuilds the exact
/// open/configure/(recurse)/close nesting Clay's macros would produce, but
/// driven from the flat parent_id-linked registry snapshot instead of
/// nested source-level scopes.
fn openChildren(slots: []const WidgetHost.Slot, parent_id: ?u32) void {
    for (slots) |slot| {
        if (!slot.clay_managed or !std.meta.eql(slot.parent_id, parent_id)) continue;

        var decl: c.Clay_ElementDeclaration = std.mem.zeroes(c.Clay_ElementDeclaration);
        decl.layout.sizing = slot.clay_style.sizing;
        decl.layout.padding = slot.clay_style.padding;
        decl.layout.childGap = slot.clay_style.child_gap;
        decl.layout.layoutDirection = slot.clay_style.direction;
        decl.layout.childAlignment = slot.clay_style.child_alignment;

        c.Clay__OpenElementWithId(elementId(slot.id));
        c.Clay__ConfigureOpenElement(decl);
        openChildren(slots, slot.id);
        c.Clay__CloseElement();
    }
}

/// Runs a real Clay layout pass from the current widget registry state, but
/// only if something Clay-managed actually changed since the last one
/// (`WidgetHost.layout_generation` moved) -- otherwise returns immediately
/// and every widget keeps the `rect` it already has cached from the last
/// real computation. This is the entire caching story: Clay itself has no
/// incremental-relayout API (confirmed against the real header), so
/// avoiding the call is natyv's responsibility, not Clay's.
///
/// When a real pass does run: declares one synthetic root element sized to
/// the window, opens every Clay-managed widget under its real parent
/// (walking `parent_id`), ends the layout, then writes each Clay-managed
/// widget's computed `Clay_BoundingBox` back into its registry `rect` via
/// `WidgetHost.setRect` -- the same field `Button`/`TextField`/`Label`
/// `.draw()` and every hit-test already read, so this is invisible to the
/// rest of the render loop.
pub fn layoutIfNeeded(self: *Self, widgets: *WidgetHost, io: Io, window_w: f32, window_h: f32, mouse_x: f32, mouse_y: f32, mouse_down: bool) void {
    const current_generation = widgets.currentGeneration(io);
    if (self.last_computed_generation) |last| {
        if (last == current_generation) return;
    }

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    const n = widgets.snapshot(io, &snap);
    const slots = snap[0..n];

    c.Clay_SetLayoutDimensions(.{ .width = window_w, .height = window_h });
    c.Clay_SetPointerState(.{ .x = mouse_x, .y = mouse_y }, mouse_down);
    c.Clay_BeginLayout();

    var root_decl: c.Clay_ElementDeclaration = std.mem.zeroes(c.Clay_ElementDeclaration);
    root_decl.layout.sizing.width = .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = window_w, .max = window_w } } };
    root_decl.layout.sizing.height = .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = window_h, .max = window_h } } };
    c.Clay__OpenElementWithId(rootElementId());
    c.Clay__ConfigureOpenElement(root_decl);
    openChildren(slots, null);
    c.Clay__CloseElement();

    _ = c.Clay_EndLayout(0.0);
    self.recompute_count += 1;

    for (slots) |slot| {
        if (!slot.clay_managed) continue;
        const data = c.Clay_GetElementData(elementId(slot.id));
        if (data.found) {
            const box = data.boundingBox;
            widgets.setRect(io, slot.id, .{ .x = box.x, .y = box.y, .w = box.width, .h = box.height });
        }
    }

    self.last_computed_generation = current_generation;
}
