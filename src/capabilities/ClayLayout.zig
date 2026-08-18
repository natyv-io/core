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
const timing = @import("../timing.zig");
const ScrollBar = @import("../ScrollBar.zig");

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

/// Reads Clay's live scroll offset/dimensions for a given widget id, or
/// `null` if that widget isn't a currently-tracked scroll container (never
/// declared with scroll_vertical/scroll_horizontal, or not yet opened by a
/// real layout pass). Safe to call any time after `init` -- reads Clay's
/// persistent per-context state directly, not tied to being inside a
/// BeginLayout/EndLayout pass. Returns `ScrollBar.Data` directly (rather
/// than a second identical struct here) since that's its only consumer.
pub fn scrollContainerData(widget_id: u32) ?ScrollBar.Data {
    const data = c.Clay_GetScrollContainerData(elementId(widget_id));
    if (!data.found) return null;
    const pos = data.scrollPosition orelse return null;
    return .{
        .scroll_offset_x = pos.*.x,
        .scroll_offset_y = pos.*.y,
        .container_w = data.scrollContainerDimensions.width,
        .container_h = data.scrollContainerDimensions.height,
        .content_w = data.contentDimensions.width,
        .content_h = data.contentDimensions.height,
    };
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
/// W2: milliseconds at the last real recompute (not "last frame" -- see
/// layoutIfNeeded's deltaTime comment). `null` before the first recompute.
last_recompute_ms: ?i64 = null,

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
/// W16: names plain-`floating` widgets (never `modal`/`toast`, see the
/// `floating` branch below) that should flip along one axis this pass --
/// `v_ids` opens *above* the parent instead of below, `h_ids` opens
/// *right-aligned* to the parent instead of left-aligned. Both empty on
/// `layoutIfNeeded`'s first, optimistic pass; populated only for a rare
/// second pass, when the first pass's results showed one or more
/// overflowing the window on that axis. A widget can appear in both sets
/// at once (e.g. a panel that overflows both the bottom and the right
/// edge). See `layoutIfNeeded`'s own doc comment for the full
/// measure-then-decide story -- a floating element's real resolved
/// position isn't known until *after* a real `Clay_EndLayout()`, so this
/// can never be decided during a single declare pass.
const FlipSet = struct {
    v_ids: []const u32 = &.{},
    h_ids: []const u32 = &.{},
};

fn containsId(ids: []const u32, id: u32) bool {
    for (ids) |x| if (x == id) return true;
    return false;
}

fn openChildren(slots: []const WidgetHost.Slot, parent_id: ?u32, flips: FlipSet) void {
    for (slots) |slot| {
        if (!slot.clay_managed or !std.meta.eql(slot.parent_id, parent_id)) continue;

        var decl: c.Clay_ElementDeclaration = std.mem.zeroes(c.Clay_ElementDeclaration);
        decl.layout.sizing = slot.clay_style.sizing;
        decl.layout.padding = slot.clay_style.padding;
        decl.layout.childGap = slot.clay_style.child_gap;
        decl.layout.layoutDirection = slot.clay_style.direction;
        decl.layout.childAlignment = slot.clay_style.child_alignment;

        c.Clay__OpenElementWithId(elementId(slot.id));
        // W2: Clay_GetScrollOffset() only returns the right value for
        // whichever element is currently open -- must be read strictly
        // between OpenElementWithId and ConfigureOpenElement, matching the
        // exact sequencing Clay's own CLAY() macro expands to via C's comma
        // operator (confirmed against the real macro, vendor/clay/clay.h).
        if (slot.clay_style.scroll_vertical or slot.clay_style.scroll_horizontal) {
            decl.clip = .{
                .horizontal = slot.clay_style.scroll_horizontal,
                .vertical = slot.clay_style.scroll_vertical,
                .childOffset = c.Clay_GetScrollOffset(),
            };
        }
        // W4: unlike .clip above, floating doesn't read any Clay state
        // that's only valid while this element is open -- Clay resolves a
        // floating element's real position in a later pass, against its
        // parent's already-computed bounding box (confirmed against the
        // real source, vendor/clay/clay.h). CLAY_ATTACH_TO_PARENT is used
        // deliberately instead of CLAY_ATTACH_TO_ELEMENT_WITH_ID -- natyv's
        // own parent_id already names exactly the element Clay would need
        // a second id field to point at, so no extra wire-contract field is
        // needed. Positions the floating element's top-left just below its
        // parent's bottom-left corner (e.g. a dropdown's options panel
        // appearing directly under its trigger).
        // W5: modal implies floating-style positioning -- the guest sets
        // `modal` alone, not `floating` as well -- but centers against the
        // whole window (CLAY_ATTACH_TO_ROOT + CENTER_CENTER/CENTER_CENTER)
        // instead of Dropdown's "attach below my parent" shape, since a
        // modal isn't conceptually anchored to whatever triggered it the
        // way a dropdown panel is anchored to its trigger button.
        // zIndex 2 (vs. plain floating's 1) keeps a modal visually above
        // any ordinary open floating content if both happen to be open at
        // once -- see FloatingOrder.zig/main.zig for how natyv's own draw
        // order, hit-testing, and input-blocking account for the
        // modal/floating distinction (Clay itself has no opinion on any of
        // that, only position).
        if (slot.clay_style.modal) {
            decl.floating = .{
                .attachTo = c.CLAY_ATTACH_TO_ROOT,
                .attachPoints = .{ .parent = c.CLAY_ATTACH_POINT_CENTER_CENTER, .element = c.CLAY_ATTACH_POINT_CENTER_CENTER },
                .zIndex = 2,
            };
        } else if (slot.clay_style.toast) {
            // W7: same CLAY_ATTACH_TO_ROOT shape modal uses, anchored to a
            // fixed screen corner (bottom-right) instead of centered --
            // set once on a guest's persistent toast-stack container;
            // individual toasts are plain, non-floating children of it, so
            // they stack via the stack's own ordinary flex layout rather
            // than each needing their own floating config. zIndex 1, same
            // tier as plain `floating` -- a toast doesn't need modal's
            // "always above everything" guarantee.
            decl.floating = .{
                .attachTo = c.CLAY_ATTACH_TO_ROOT,
                .attachPoints = .{ .parent = c.CLAY_ATTACH_POINT_RIGHT_BOTTOM, .element = c.CLAY_ATTACH_POINT_RIGHT_BOTTOM },
                .zIndex = 1,
            };
        } else if (slot.clay_style.floating) {
            // W16: flips vertically (element's own bottom touches the
            // parent's top instead of the reverse) and/or horizontally
            // (element's own right edge touches the parent's right edge
            // instead of left-to-left) when this pass's `flips` says this
            // widget's normal "open below-left" position would overflow
            // the window on that axis -- see layoutIfNeeded's two-pass
            // doc comment. The two axes are independent -- a widget can
            // flip both at once (bottom-right corner case).
            const flip_v = containsId(flips.v_ids, slot.id);
            const flip_h = containsId(flips.h_ids, slot.id);
            const parent_point = if (flip_v and flip_h)
                c.CLAY_ATTACH_POINT_RIGHT_TOP
            else if (flip_v)
                c.CLAY_ATTACH_POINT_LEFT_TOP
            else if (flip_h)
                c.CLAY_ATTACH_POINT_RIGHT_BOTTOM
            else
                c.CLAY_ATTACH_POINT_LEFT_BOTTOM;
            const element_point = if (flip_v and flip_h)
                c.CLAY_ATTACH_POINT_RIGHT_BOTTOM
            else if (flip_v)
                c.CLAY_ATTACH_POINT_LEFT_BOTTOM
            else if (flip_h)
                c.CLAY_ATTACH_POINT_RIGHT_TOP
            else
                c.CLAY_ATTACH_POINT_LEFT_TOP;
            decl.floating = .{
                .attachTo = c.CLAY_ATTACH_TO_PARENT,
                .attachPoints = .{ .parent = @intCast(parent_point), .element = @intCast(element_point) },
                .zIndex = 1,
            };
        }
        c.Clay__ConfigureOpenElement(decl);
        openChildren(slots, slot.id, flips);
        c.Clay__CloseElement();
    }
}

/// Runs a real Clay layout pass from the current widget registry state, but
/// only if something Clay-managed actually changed since the last one
/// (`WidgetHost.layout_generation` moved) *or* this frame carries a nonzero
/// scroll delta -- otherwise returns immediately and every widget keeps the
/// `rect` it already has cached from the last real computation. This is the
/// entire caching story: Clay itself has no incremental-relayout API
/// (confirmed against the real header), so avoiding the call is natyv's
/// responsibility, not Clay's.
///
/// W2: `Clay_UpdateScrollContainers` must be called exactly once per real
/// `Clay_BeginLayout`/`Clay_EndLayout` cycle, never independently on a
/// skipped frame -- confirmed against Clay's real implementation
/// (vendor/clay/clay.h): each tracked scroll container's internal
/// `openThisFrame` flag is unconditionally flipped false on every call to
/// `Clay_UpdateScrollContainers`, and only flipped back true when
/// `openChildren` actually redeclares that element during a real layout
/// pass. Calling it on a skip frame would mean the *next* such call evicts
/// the scroll container's tracked position entirely (`RemoveSwapback`),
/// silently snapping scroll position back to the top a couple frames after
/// the user stops scrolling. This is why a nonzero scroll delta forces a
/// real recompute below rather than being applied "for free" on a skip
/// frame, and why `Clay_SetPointerState`/`Clay_UpdateScrollContainers` only
/// ever run paired with `Clay_BeginLayout`, immediately before it.
///
/// When a real pass does run: declares one synthetic root element sized to
/// the window, opens every Clay-managed widget under its real parent
/// (walking `parent_id`), ends the layout, then writes each Clay-managed
/// widget's computed `Clay_BoundingBox` back into its registry `rect` via
/// `WidgetHost.setRect` -- the same field `Button`/`TextField`/`Label`
/// `.draw()` and every hit-test already read, so this is invisible to the
/// rest of the render loop. A scroll container's children shift position via
/// this same writeback, since `openChildren` feeds their clip's
/// `childOffset` from Clay's own internally-tracked scroll position.
pub fn layoutIfNeeded(self: *Self, widgets: *WidgetHost, io: Io, window_w: f32, window_h: f32, mouse_x: f32, mouse_y: f32, mouse_down: bool, scroll_dx: f32, scroll_dy: f32) void {
    const current_generation = widgets.currentGeneration(io);
    const content_changed = self.last_computed_generation == null or self.last_computed_generation.? != current_generation;
    const scrolled = scroll_dx != 0 or scroll_dy != 0;
    if (!content_changed and !scrolled) return;

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    const n = widgets.snapshot(io, &snap);
    const slots = snap[0..n];

    // deltaTime is seconds since the *last real recompute* (not literal
    // frame time) -- Clay_UpdateScrollContainers is only ever called
    // alongside a real recompute (see doc comment above), so "time since
    // last frame" for its purposes really means "time since this function
    // last actually ran Clay." Not currently load-bearing for wheel-only
    // scrolling (enableDragScrolling below is false, so Clay's momentum
    // decay never activates), but wired correctly now via timing.zig's
    // already-available nowMs() rather than hardcoded, since it's cheap and
    // keeps this forward-compatible if drag-scrolling is ever added.
    const now_ms = timing.nowMs();
    const delta_time_s: f32 = if (self.last_recompute_ms) |last| @as(f32, @floatFromInt(now_ms - last)) / 1000.0 else 0.0;
    self.last_recompute_ms = now_ms;

    c.Clay_SetLayoutDimensions(.{ .width = window_w, .height = window_h });
    c.Clay_SetPointerState(.{ .x = mouse_x, .y = mouse_y }, mouse_down);
    // enableDragScrolling=false -- v1 is wheel/trackpad-notch input only, no
    // touch/mouse-drag scrolling.
    c.Clay_UpdateScrollContainers(false, .{ .x = scroll_dx, .y = scroll_dy }, delta_time_s);
    c.Clay_BeginLayout();

    var root_decl: c.Clay_ElementDeclaration = std.mem.zeroes(c.Clay_ElementDeclaration);
    root_decl.layout.sizing.width = .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = window_w, .max = window_w } } };
    root_decl.layout.sizing.height = .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = window_h, .max = window_h } } };
    c.Clay__OpenElementWithId(rootElementId());
    c.Clay__ConfigureOpenElement(root_decl);
    openChildren(slots, null, .{});
    c.Clay__CloseElement();

    _ = c.Clay_EndLayout(0.0);
    self.recompute_count += 1;

    // W16: a plain-floating widget (never modal/toast -- see their own
    // fixed anchors above) whose "open below-left" position from this
    // first pass would extend past the bottom and/or right edge of the
    // window gets a second real pass with its attach point flipped on
    // whichever axis(es) overflowed. A floating element's real resolved
    // position is only known *after* a real Clay_EndLayout() (confirmed
    // against vendor/clay/clay.h -- floating positions are resolved in a
    // pass after normal box measurement), so this can never be decided
    // during the single declare pass above -- there's no way to "ask
    // first." Re-running the whole pass (not just patching the one
    // widget's position after the fact) also correctly re-resolves any
    // *nested* floating content anchored to it (e.g. a submenu anchored
    // to a just-flipped menu panel), since Clay computes each floating
    // element's position against its own parent's already-computed box.
    //
    // Clay_UpdateScrollContainers is still only called once above, not
    // again here -- confirmed against the real implementation
    // (vendor/clay/clay.h) that it's tied to this function's own "real
    // recompute" event, not to each individual Begin/EndLayout pair; the
    // scroll position it already applied this recompute carries over
    // unchanged into this second pass's own openChildren declarations.
    var v_flip_ids: [WidgetHost.max_widgets]u32 = undefined;
    var v_flip_count: usize = 0;
    var h_flip_ids: [WidgetHost.max_widgets]u32 = undefined;
    var h_flip_count: usize = 0;
    for (slots) |slot| {
        if (!slot.clay_managed or !slot.clay_style.floating or slot.clay_style.modal or slot.clay_style.toast) continue;
        const data = c.Clay_GetElementData(elementId(slot.id));
        if (!data.found) continue;
        if (data.boundingBox.y + data.boundingBox.height > window_h) {
            v_flip_ids[v_flip_count] = slot.id;
            v_flip_count += 1;
        }
        if (data.boundingBox.x + data.boundingBox.width > window_w) {
            h_flip_ids[h_flip_count] = slot.id;
            h_flip_count += 1;
        }
    }
    if (v_flip_count > 0 or h_flip_count > 0) {
        c.Clay_BeginLayout();
        c.Clay__OpenElementWithId(rootElementId());
        c.Clay__ConfigureOpenElement(root_decl);
        openChildren(slots, null, .{ .v_ids = v_flip_ids[0..v_flip_count], .h_ids = h_flip_ids[0..h_flip_count] });
        c.Clay__CloseElement();
        _ = c.Clay_EndLayout(0.0);
        self.recompute_count += 1;
    }

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
