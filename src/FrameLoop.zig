//! Multi-window Stage 3: the extracted, parameterized per-frame body --
//! everything main.zig's single-window frame loop used to do inline
//! (event handling, slider drag, hover/tooltip, drawing) now lives here as
//! functions taking a `*WindowManager.WindowContext` for the per-window
//! pieces (its own `interaction`, `draw_batcher`, `SDL_Window`/
//! `SDL_Renderer`/`TTF_TextEngine`) plus that window's own already-filtered
//! widget subset (see `FloatingOrder.windowSubset`) for everything that used
//! to read the single global `widget_snapshot`. Behavior for the original
//! startup window (`root_widget_id == null`) is unchanged from before this
//! extraction -- its own subset is exactly "every widget with no
//! window-root ancestor," which is every widget that existed before this
//! feature at all.
//!
//! `main.zig` owns the outer `while (running)` loop, SDL event polling +
//! windowID-based routing to the right `WindowContext`, and app-wide
//! registry maintenance that must happen exactly once per frame regardless
//! of how many windows are open (`flushPendingTextDestroys`,
//! `destroyExpiredWidgets`) -- this file owns everything that's genuinely
//! per-window.

const std = @import("std");
const c = @import("c.zig").c;
const WidgetHost = @import("widgets/WidgetHost.zig");
const Slider = @import("widgets/Slider.zig");
const RangeSlider = @import("widgets/RangeSlider.zig");
const TextField = @import("widgets/TextField.zig");
const TextArea = @import("widgets/TextArea.zig");
const json_util = @import("json_util.zig");
const timing = @import("timing.zig");
const ClayLayout = @import("capabilities/ClayLayout.zig");
const EventQueue = @import("EventQueue.zig");
const DrawBatcher = @import("DrawBatcher.zig");
const ScrollClip = @import("ScrollClip.zig");
const ScrollBar = @import("ScrollBar.zig");
const FloatingOrder = @import("FloatingOrder.zig");
const WindowManager = @import("WindowManager.zig");
const ShapeCache = @import("capabilities/ShapeCache.zig");
const ImageCache = @import("capabilities/ImageCache.zig");
const TextureAssets = @import("TextureAssets");

const max_widgets_on_screen = WidgetHost.max_widgets;

/// W10: shared sizing for every stack buffer that has to hold "whichever
/// text widget's post-mutation content is currently biggest" -- see
/// main.zig's original doc comment on this same constant.
const max_text_widget_len = @max(TextField.max_len, TextArea.max_len);

/// W15: see main.zig's original doc comment on this same constant.
pub const tooltip_hover_threshold_ms: i64 = 100;

/// How long after a window's own creation `drawWindow`'s redraw gate
/// forces every real draw regardless of `layout_generation` -- see
/// `WindowContext.created_at_ms`'s own doc comment for the real,
/// live-confirmed reason this exists (a freshly-created window's first
/// present isn't reliably guaranteed to actually display by the OS
/// compositor). 500ms is comfortably longer than any realistic compositor/
/// window-manager warmup delay while still being a one-time, per-window
/// cost too small to matter for the idle-CPU fix this gate is otherwise
/// part of.
pub const window_redraw_warmup_ms: i64 = 500;

/// Pixels of scroll per SDL wheel "notch" -- see main.zig's original doc
/// comment on this same constant.
const wheel_pixels_per_notch: f32 = 4.0;

/// True when `id` is present in `ids` -- shared by this file's own
/// window-subset filtering and `ClayLayout.zig`'s identically-shaped
/// private helper (kept separate rather than exported, since sharing it
/// would mean threading an import between two files that otherwise have no
/// reason to know about each other).
pub fn containsId(ids: []const u32, id: u32) bool {
    for (ids) |x| if (x == id) return true;
    return false;
}

/// Syncs every open window's own text-bearing widgets' real `TTF_Text`
/// render objects (the thing SDL_ttf actually draws glyphs from) against
/// the live registry's *current* text content -- `main.zig` calls this
/// once early in the frame (unchanged, original position/timing) and a
/// second time right after this same frame's own events have been
/// processed, mirroring `rebuildFrameSnapshot`'s own two-call shape and
/// fixing the same underlying class of bug for the *other* real
/// mechanism a stale pre-event call leaves behind: `WidgetHost.
/// syncTextObjects` reads the live registry directly (not a snapshot), so
/// calling it only once, before events, meant a just-typed character's
/// `TTF_Text` object was updated one frame late -- invisible under the
/// old unthrottled loop, a real visible one-keystroke lag once
/// `SDL_WaitEventTimeout` bounds this loop to real event/wake cadence
/// (the exact same root cause as `rebuildFrameSnapshot`'s own doc
/// comment, just a second, independent place it manifests).
pub fn syncAllWindowText(widgets: *WidgetHost, io: std.Io, windows: []const WindowManager.WindowContext, font: *c.TTF_Font) void {
    var struct_snap: [max_widgets_on_screen]WidgetHost.Slot = undefined;
    const struct_n = widgets.snapshot(io, &struct_snap);
    for (windows) |wctx| {
        var ids: [max_widgets_on_screen]u32 = undefined;
        const idn = FloatingOrder.windowSubset(struct_snap[0..struct_n], wctx.root_widget_id, &ids);
        widgets.syncTextObjects(io, wctx.text_engine, font, ids[0..idn]);
    }
}

/// Rebuilds this frame's registry-wide snapshot and each open window's own
/// widget/is_floating/topmost_modal subset from the *current* live
/// registry state -- `main.zig` calls this once early in the frame (for
/// layout/scroll-push purposes, before this same frame's own input events
/// are processed) and a second time right before the draw pass, so
/// drawing reflects this same frame's own just-processed events instead
/// of showing them one frame late.
///
/// Real, live-confirmed bug this second call fixes: `main.zig`'s original
/// design took exactly one snapshot per frame, before the event loop, and
/// reused it for both event dispatch and drawing -- invisible under the
/// old unthrottled loop (the *next* iteration, microseconds later, would
/// already show the correction), but a real, visible one-keystroke input
/// lag once `SDL_WaitEventTimeout` bounds the loop to real event/wake
/// cadence (a typed character updated the registry immediately via
/// `WidgetHost.appendTextTo`, called synchronously from this same frame's
/// event-draining loop, but wasn't visible on screen until the *next*
/// keystroke's own draw call, since that draw call used the stale
/// snapshot captured before the current keystroke was ever processed).
///
/// Returns the registry-wide widget count (mirrors `WidgetHost.snapshot`'s
/// own return value, since callers need it to slice `widget_snapshot`).
pub fn rebuildFrameSnapshot(
    widgets: *WidgetHost,
    io: std.Io,
    windows: []const WindowManager.WindowContext,
    widget_snapshot: []WidgetHost.Slot,
    per_window_slots: [][max_widgets_on_screen]WidgetHost.Slot,
    per_window_slot_count: []usize,
    per_window_is_floating: [][max_widgets_on_screen]bool,
    per_window_topmost_modal: []?u32,
) usize {
    const widget_count = widgets.snapshot(io, widget_snapshot);
    for (windows, 0..) |wctx, i| {
        var ids: [max_widgets_on_screen]u32 = undefined;
        const idn = FloatingOrder.windowSubset(widget_snapshot[0..widget_count], wctx.root_widget_id, &ids);
        var n: usize = 0;
        for (widget_snapshot[0..widget_count]) |s| {
            if (containsId(ids[0..idn], s.id)) {
                per_window_slots[i][n] = s;
                n += 1;
            }
        }
        per_window_slot_count[i] = n;
        FloatingOrder.computeIsFloating(per_window_slots[i][0..n], per_window_is_floating[i][0..n]);
        per_window_topmost_modal[i] = FloatingOrder.topmostModalRoot(per_window_slots[i][0..n]);
    }
    return widget_count;
}

/// Multi-window Stage 3: the `SDL_WindowID` a given SDL event targets, or
/// `null` for an event type with no window affinity at all (e.g. `QUIT`).
/// Every input event SDL delivers carries this field somewhere in its own
/// union member -- confirmed against SDL3's real headers, not assumed.
pub fn windowIDOf(event: c.SDL_Event) ?c.SDL_WindowID {
    return switch (event.type) {
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => event.window.windowID,
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => event.button.windowID,
        c.SDL_EVENT_TEXT_INPUT => event.text.windowID,
        c.SDL_EVENT_MOUSE_WHEEL => event.wheel.windowID,
        c.SDL_EVENT_KEY_DOWN => event.key.windowID,
        else => null,
    };
}

/// Keyboard interaction model: the one place focus actually changes -- see
/// main.zig's original doc comment on this same function for the full
/// story (W6/W9 blur payload). Takes a `*WindowManager.WindowContext`
/// instead of a bare `*c.SDL_Window` now -- IME start/stop is scoped to
/// whichever window's own focus actually changed, not a single shared one.
fn updateFocus(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, wctx: *WindowManager.WindowContext, slots: []const WidgetHost.Slot, index: WidgetHost.SnapshotIndex, new_id: ?u32) void {
    if (wctx.interaction.focused_widget_id) |old_id| {
        if (new_id == null or old_id != new_id.?) {
            var buf: [32]u8 = undefined;
            const payload = std.fmt.bufPrint(&buf, "{{\"new_focus_id\":{d}}}", .{new_id orelse 0}) catch "{}";
            queue.push(io, old_id, .blur, payload, FloatingOrder.surfaceIdFor(slots, index, old_id));
        }
    }
    const wants_text_input = widgets.setFocused(io, new_id);
    wctx.interaction.focused_widget_id = new_id;
    if (wants_text_input) {
        _ = c.SDL_StartTextInput(wctx.window);
    } else {
        _ = c.SDL_StopTextInput(wctx.window);
    }
}

fn toClipRect(r: c.SDL_FRect) c.SDL_Rect {
    return .{
        .x = @intFromFloat(@floor(r.x)),
        .y = @intFromFloat(@floor(r.y)),
        .w = @intFromFloat(@ceil(r.w)),
        .h = @intFromFloat(@ceil(r.h)),
    };
}

/// W1: the shared "activate this widget" body -- see main.zig's original
/// doc comment on this same function.
fn activateWidget(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, kind: WidgetHost.WidgetKind, surface_id: u32) void {
    switch (kind) {
        .button => widgets.flashButton(io, id),
        .checkbox => widgets.toggleCheckbox(io, id),
        .toggle => widgets.toggleToggle(io, id),
        .radio_button => widgets.selectRadioExclusive(io, id),
        // 2026-09-02: a Container's own new click support (tryHitWidget)
        // needs no state-mutating side effect the way a checkbox/toggle's
        // own visible state-flip does -- just the plain `.click` event
        // below, so a guest can make a whole card/row clickable.
        .container => {},
        .textfield, .textarea, .label, .progress_bar, .slider, .range_slider, .divider, .badge, .numeric_stepper, .segmented_control, .tabs, .spinner => return,
    }
    queue.push(io, id, .click, "", surface_id);
}

fn notifySliderValue(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, value: f32, surface_id: u32) void {
    const clamped = widgets.setSliderValue(io, id, value) orelse return;
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"value\":{d}}}", .{clamped}) catch "{}";
    queue.push(io, id, .change, json, surface_id);
}

fn notifyRangeSliderValue(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, handle: RangeSlider.Handle, value: f32, surface_id: u32) void {
    const result = widgets.setRangeSliderValue(io, id, handle, value) orelse return;
    var buf: [48]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"min\":{d},\"max\":{d}}}", .{ result.min, result.max }) catch "{}";
    queue.push(io, id, .change, json, surface_id);
}

fn notifyStepperValue(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, value: i32, surface_id: u32) void {
    const resolved = widgets.setStepperValue(io, id, value) orelse return;
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"value\":{d}}}", .{resolved}) catch "{}";
    queue.push(io, id, .change, json, surface_id);
}

fn notifySegmentedValue(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, index: usize, surface_id: u32) void {
    const resolved = widgets.setSegmentedIndex(io, id, index) orelse return;
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"value\":{d}}}", .{resolved}) catch "{}";
    queue.push(io, id, .change, json, surface_id);
}

fn notifyTabsValue(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, index: usize, surface_id: u32) void {
    const resolved = widgets.setActiveTab(io, id, index) orelse return;
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"value\":{d}}}", .{resolved}) catch "{}";
    queue.push(io, id, .change, json, surface_id);
}

fn notifyTextChanged(queue: *EventQueue, io: std.Io, id: u32, new_text: []const u8, slots: []const WidgetHost.Slot, index: WidgetHost.SnapshotIndex) void {
    var buf: [max_text_widget_len + 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "{\"text\":") catch return;
    json_util.writeString(&out, a, new_text) catch return;
    out.append(a, '}') catch return;
    queue.push(io, id, .text_changed, out.items, FloatingOrder.surfaceIdFor(slots, index, id));
}

/// W23: see main.zig's original doc comment on this same struct.
const FileDialogCallbackContext = struct {
    io: std.Io,
    queue: *EventQueue,
    widget_id: u32,
    surface_id: u32,
};

const max_file_dialog_payload_len = 4096;

fn fileDialogCallback(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, filter: c_int) callconv(.c) void {
    _ = filter;
    const ctx: *FileDialogCallbackContext = @ptrCast(@alignCast(userdata.?));

    var buf: [max_file_dialog_payload_len]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "{\"paths\":[") catch return;
    if (filelist) |list| {
        var i: usize = 0;
        while (list[i]) |path_ptr| : (i += 1) {
            if (i != 0) out.append(a, ',') catch return;
            json_util.writeString(&out, a, std.mem.span(path_ptr)) catch return;
        }
    }
    out.appendSlice(a, "]}") catch return;
    ctx.queue.push(ctx.io, ctx.widget_id, .file_selected, out.items, ctx.surface_id);
}

/// Reused across every dialog request, address stable for main()'s whole
/// lifetime -- see main.zig's original `FileDialogCallbackContext` doc
/// comment for why. Owned by this file now (not main.zig) since it's only
/// ever touched from `drainGlobalPending` below.
var file_dialog_ctx: FileDialogCallbackContext = undefined;

/// Registry-wide, not per-window: scroll-into-view and the file-dialog
/// request queue are both single-pending-slot hand-offs (see their own doc
/// comments on `WidgetHost`) tied to whichever window is conceptually "the
/// app's own" -- v1 scope keeps both anchored to the original startup
/// window's own `SDL_Window*` (the natural parent for a native file-picker
/// sheet), same as before this feature existed. `full_snapshot` must be
/// this frame's fresh, post-text-sync snapshot -- both surface_id lookups
/// need up-to-date parent_id/clay_style data.
pub fn drainGlobalPending(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, primary_window: *c.SDL_Window, full_snapshot: []const WidgetHost.Slot) void {
    if (widgets.takePendingScrollIntoView(io)) |scroll_target_id| {
        ClayLayout.applyScrollIntoView(full_snapshot, widgets, scroll_target_id);
    }
    if (widgets.takePendingFileDialogRequest(io)) |req| {
        file_dialog_ctx = .{
            .io = io,
            .queue = queue,
            .widget_id = req.widget_id,
            .surface_id = FloatingOrder.surfaceIdFor(full_snapshot, WidgetHost.SnapshotIndex.build(full_snapshot), req.widget_id),
        };
        switch (req.kind) {
            .open => c.SDL_ShowOpenFileDialog(fileDialogCallback, &file_dialog_ctx, primary_window, null, 0, null, req.allow_many),
            .save => c.SDL_ShowSaveFileDialog(fileDialogCallback, &file_dialog_ctx, primary_window, null, 0, null),
        }
    }
}

/// Runs this window's own Clay layout pass (if the Clay backend is enabled)
/// and stashes the mouse position this frame resolved for it onto its own
/// `interaction` -- called once per open, non-closing window, before any
/// registry-wide maintenance (`flushPendingTextDestroys`/
/// `destroyExpiredWidgets`) so a real recompute's freshly written-back rects
/// are what the rest of the frame sees, same ordering main.zig's original
/// single-window body already established.
///
/// Multi-window Stage 3: mouse position/button state is no longer read via
/// `SDL_GetMouseState` (which reports coordinates relative to whichever
/// window currently has *mouse focus* -- not necessarily the window being
/// processed, the instant a second one can exist) -- `global_mouse_x`/`y`/
/// `global_buttons` come from one shared `SDL_GetGlobalMouseState` call
/// main.zig makes once per frame, and this function converts to
/// window-relative coordinates via `SDL_GetWindowPosition`.
pub fn layoutWindow(widgets: *WidgetHost, io: std.Io, wctx: *WindowManager.WindowContext, global_mouse_x: f32, global_mouse_y: f32, global_buttons: c.SDL_MouseButtonFlags) void {
    var win_x: c_int = undefined;
    var win_y: c_int = undefined;
    _ = c.SDL_GetWindowPosition(wctx.window, &win_x, &win_y);
    wctx.interaction.mouse_x = global_mouse_x - @as(f32, @floatFromInt(win_x));
    wctx.interaction.mouse_y = global_mouse_y - @as(f32, @floatFromInt(win_y));

    wctx.scrolled_count = 0;
    wctx.did_recompute = false;
    if (wctx.clay_layout) |*clay_layout| {
        var win_w: c_int = undefined;
        var win_h: c_int = undefined;
        _ = c.SDL_GetWindowSize(wctx.window, &win_w, &win_h);
        const mouse_down = (global_buttons & c.SDL_BUTTON_LMASK) != 0;
        if (clay_layout.layoutIfNeeded(widgets, io, @floatFromInt(win_w), @floatFromInt(win_h), wctx.interaction.mouse_x, wctx.interaction.mouse_y, mouse_down, wctx.interaction.pending_scroll_dx, wctx.interaction.pending_scroll_dy, &wctx.scrolled_ids, wctx.root_widget_id)) |count| {
            wctx.scrolled_count = count;
            wctx.did_recompute = true;
        }
    }
    wctx.interaction.pending_scroll_dx = 0;
    wctx.interaction.pending_scroll_dy = 0;
}

/// Pushes a `.scroll` event for every scroll container `layoutWindow`
/// reported as having actually moved this frame -- see main.zig's original
/// Tree view doc comment on this same block. `full_snapshot` is this frame's
/// fresh, post-text-sync snapshot (needed for a correct surface_id lookup).
pub fn pushScrollEvents(queue: *EventQueue, io: std.Io, wctx: *WindowManager.WindowContext, full_snapshot: []const WidgetHost.Slot) void {
    if (wctx.scrolled_count == 0) return;
    const index = WidgetHost.SnapshotIndex.build(full_snapshot);
    for (wctx.scrolled_ids[0..wctx.scrolled_count]) |scrolled_id| {
        const slot = index.find(full_snapshot, scrolled_id) orelse continue;
        const sd = slot.scroll_data orelse continue;
        var buf: [64]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"scroll_offset_x\":{d},\"scroll_offset_y\":{d}}}", .{ sd.scroll_offset_x, sd.scroll_offset_y }) catch "{}";
        queue.push(io, scrolled_id, .scroll, json, FloatingOrder.surfaceIdFor(full_snapshot, index, scrolled_id));
    }
}

fn widgetContainsPoint(widget: WidgetHost.Widget, mx: f32, my: f32) bool {
    return switch (widget) {
        .button => |b| b.containsPoint(mx, my),
        .checkbox => |cb| cb.containsPoint(mx, my),
        .toggle => |tg| tg.containsPoint(mx, my),
        .radio_button => |r| r.containsPoint(mx, my),
        .textfield => |t| t.containsPoint(mx, my),
        .textarea => |ta| ta.containsPoint(mx, my),
        .slider => |s| s.containsPoint(mx, my),
        .range_slider => |rs| rs.containsPoint(mx, my),
        .numeric_stepper => |ns| ns.containsPoint(mx, my),
        .segmented_control => |sc| sc.containsPoint(mx, my),
        .tabs => |tb| tb.containsPoint(mx, my),
        .label, .container, .progress_bar, .divider, .badge, .spinner => false,
    };
}

fn tryHitWidget(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, slots: []const WidgetHost.Slot, index: WidgetHost.SnapshotIndex, slot: WidgetHost.Slot, mx: f32, my: f32, dragging_slider_id: *?u32, dragging_range_handle: *?RangeSlider.Handle) ?u32 {
    if (!WidgetHost.isEffectivelyVisible(slots, index, slot)) return null;
    switch (slot.widget) {
        // A disabled Button (ClayStyle.enabled's own doc comment) is
        // treated as a real miss here -- no click event, no flash, and it
        // doesn't consume the point (`hit_focusable`), so a real "< N >"
        // pager can disable either end without it swallowing clicks meant
        // for whatever's underneath/behind it.
        .button => |b| if (slot.clay_style.enabled and b.containsPoint(mx, my)) {
            activateWidget(widgets, io, queue, slot.id, .button, FloatingOrder.surfaceIdFor(slots, index, slot.id));
            return slot.id;
        },
        .checkbox => |cb| if (cb.containsPoint(mx, my)) {
            activateWidget(widgets, io, queue, slot.id, .checkbox, FloatingOrder.surfaceIdFor(slots, index, slot.id));
            return slot.id;
        },
        .toggle => |tg| if (tg.containsPoint(mx, my)) {
            activateWidget(widgets, io, queue, slot.id, .toggle, FloatingOrder.surfaceIdFor(slots, index, slot.id));
            return slot.id;
        },
        .radio_button => |r| if (r.containsPoint(mx, my)) {
            activateWidget(widgets, io, queue, slot.id, .radio_button, FloatingOrder.surfaceIdFor(slots, index, slot.id));
            return slot.id;
        },
        .textfield => |t| if (t.containsPoint(mx, my)) {
            return slot.id;
        },
        .textarea => |ta| if (ta.containsPoint(mx, my)) {
            return slot.id;
        },
        .slider => |s| if (s.containsPoint(mx, my)) {
            dragging_slider_id.* = slot.id;
            return slot.id;
        },
        .range_slider => |rs| if (rs.containsPoint(mx, my)) {
            const handle = rs.closestHandle(mx);
            widgets.setRangeSliderActiveHandle(io, slot.id, handle);
            dragging_range_handle.* = handle;
            dragging_slider_id.* = slot.id;
            return slot.id;
        },
        .numeric_stepper => |ns| {
            const surface_id = FloatingOrder.surfaceIdFor(slots, index, slot.id);
            switch (ns.regionAt(mx, my)) {
                .minus => {
                    notifyStepperValue(widgets, io, queue, slot.id, ns.value - ns.step, surface_id);
                    return slot.id;
                },
                .plus => {
                    notifyStepperValue(widgets, io, queue, slot.id, ns.value + ns.step, surface_id);
                    return slot.id;
                },
                .none => if (ns.containsPoint(mx, my)) return slot.id,
            }
        },
        .segmented_control => |sc| if (sc.segmentAt(mx, my)) |idx| {
            notifySegmentedValue(widgets, io, queue, slot.id, idx, FloatingOrder.surfaceIdFor(slots, index, slot.id));
            return slot.id;
        } else if (sc.containsPoint(mx, my)) return slot.id,
        .tabs => |tb| if (tb.tabAt(mx, my)) |idx| {
            notifyTabsValue(widgets, io, queue, slot.id, idx, FloatingOrder.surfaceIdFor(slots, index, slot.id));
            return slot.id;
        } else if (tb.containsPoint(mx, my)) return slot.id,
        // 2026-09-02: a Container can now be clicked directly (a real,
        // guest-requested "make this whole row/card clickable" need) --
        // but only when no more-specific *interactive* descendant (a
        // Button/Checkbox/Toggle/RadioButton nested inside it, e.g. a
        // per-row Checkbox in an otherwise-clickable row) also contains
        // this exact point, so clicking that descendant doesn't *also*
        // fire the wrapping Container's own click. Every other widget
        // kind here (Label, ProgressBar, Divider, Badge, Spinner) truly
        // has nothing to do on a click, unlike Container.
        .container => |cont| if (cont.containsPoint(mx, my) and !containerClickBlockedByDescendant(slots, index, slot.id, mx, my)) {
            activateWidget(widgets, io, queue, slot.id, .container, FloatingOrder.surfaceIdFor(slots, index, slot.id));
            return slot.id;
        },
        .label, .progress_bar, .divider, .badge, .spinner => {},
    }
    return null;
}

/// Whether some more-specific interactive descendant of `container_id`
/// also contains this exact click point -- see the `.container` arm
/// above for why this must suppress a wrapping Container's own click
/// rather than let both fire for the same real mouse click. Only checks
/// kinds with their own real `activateWidget`-driven click (Button/
/// Checkbox/Toggle/RadioButton) -- TextField/TextArea's own hit is a
/// focus grab, not really "a click" in this same sense, so they don't
/// suppress a wrapping Container's click.
fn containerClickBlockedByDescendant(slots: []const WidgetHost.Slot, index: WidgetHost.SnapshotIndex, container_id: u32, mx: f32, my: f32) bool {
    for (slots) |other| {
        if (other.id == container_id) continue;
        const is_clickable_kind = switch (other.widget) {
            .button, .checkbox, .toggle, .radio_button => true,
            else => false,
        };
        if (!is_clickable_kind) continue;
        if (!widgetContainsPoint(other.widget, mx, my)) continue;
        if (FloatingOrder.isDescendantOfOrSelf(slots, index, other.id, container_id)) return true;
    }
    return false;
}

// Styling system Stage 2: `padding` is the owning slot's real
// `clay_style.padding`, resolved through `WidgetHost.effectiveTextPadding`
// once here rather than per text-bearing arm below -- only the four
// text-drawing kinds actually read it.
/// Styling system Stage 2: converts a resolved-style `background_color`
/// override (0..1 floats, matching the stylesheet resolver's own `Color`
/// and the SDF shader's eventual uniform convention) into the plain 0-255
/// `SDL_Color` the existing fill-rect draw path already uses -- `null`
/// means "no override was ever set on this widget," not "the color is
/// black," so callers must fall back to the widget's own `fillColor()`
/// result, not to a default color here.
fn fcolorToColor(fc: c.SDL_FColor) c.SDL_Color {
    return .{
        .r = @intFromFloat(@round(std.math.clamp(fc.r, 0, 1) * 255)),
        .g = @intFromFloat(@round(std.math.clamp(fc.g, 0, 1) * 255)),
        .b = @intFromFloat(@round(std.math.clamp(fc.b, 0, 1) * 255)),
        .a = @intFromFloat(@round(std.math.clamp(fc.a, 0, 1) * 255)),
    };
}

fn styleOverrideColor(fcolor: ?c.SDL_FColor) ?c.SDL_Color {
    const fc = fcolor orelse return null;
    return fcolorToColor(fc);
}

/// Fully transparent -- the fallback "default_color" passed to
/// `drawStyledFill`/the plain-fill path when a widget has no natural fill
/// of its own (`fillRect()` returned null) but real NTSS style properties
/// are set anyway. Never actually shown as-is: `drawStyledFill`'s own
/// `styleOverrideColor(...) orelse default_color` only reaches this when
/// `background_color` itself is unset (a border/corner-radius-only style
/// with no fill), the one case where "draw nothing behind the border" is
/// correct.
const transparent: c.SDL_Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

/// A disabled Button's fixed fill color -- see `ClayStyle.enabled`'s own
/// doc comment for why this always wins over any guest-set NTSS
/// `backgroundColor`, and why text itself can't also be dimmed to match.
///
/// Deliberately darker/duller than any real button color role (2026-09-02,
/// fixing a real bug: the original (0.3, 0.31, 0.32) was *brighter* than
/// e.g. mail-natyv's own secondaryBtn (#2A2E37 = 0.165, 0.18, 0.216),
/// making disabled buttons visually more prominent than active ones --
/// backwards from how "disabled" should read. Sits close to the app's own
/// dark root background rather than any fixed absolute gray, so it stays
/// duller than a normal button's color across any real color scheme.
const disabled_color: c.SDL_FColor = .{ .r = 0.14, .g = 0.15, .b = 0.17, .a = 1.0 };

/// Real, once-unnoticed gap between two unrelated opt-ins (2026-09-02):
/// `Widget.fillRect()` returning null (a plain Container's own W5
/// `background` flag defaulting false, e.g. every `.ntx`-authored
/// Container) used to silently suppress `drawStyledFill` entirely, even
/// when the widget's own `clay_style` carries a real, guest-set NTSS
/// style (`styles={...}` naming a token with `backgroundColor`/
/// `cornerRadius`/etc.) -- that flag was only ever meant to give a
/// floating panel (Dropdown, Modal) a default backdrop box, not gate the
/// separate, later, fully guest-controllable styling system. Both real
/// draw call sites below now check this to decide whether to still draw
/// via the widget's own rect (`rectPtr()`) even without a natural fill.
fn hasVisualStyle(clay_style: WidgetHost.ClayStyle) bool {
    return clay_style.background_color != null or clay_style.corner_radius != null or clay_style.border != null or clay_style.gradient != null or clay_style.texture != null;
}

/// Styling system Stage 5a: shared by both `fillRect()` draw call sites
/// below (the batched path can't use this -- it opts a styled widget out of
/// batching entirely, same "opt out for a shape that isn't a plain solid
/// rect" precedent RadioButton's own dot already established). Widgets with
/// neither `corner_radius` nor `border` set keep the exact plain
/// `SDL_RenderFillRect` path, unchanged -- this only branches into
/// `ShapeCache` for a widget that actually opted into styling.
fn drawStyledFill(renderer: ?*c.SDL_Renderer, shape_cache: *ShapeCache.Cache, image_cache: *ImageCache.Cache, clay_style: WidgetHost.ClayStyle, rect: c.SDL_FRect, default_color: c.SDL_Color) void {
    const color = styleOverrideColor(clay_style.background_color) orelse default_color;
    if (clay_style.corner_radius == null and clay_style.border == null and clay_style.gradient == null and clay_style.texture == null) {
        _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
        _ = c.SDL_RenderFillRect(renderer, &rect);
        return;
    }
    const radii = clay_style.corner_radius orelse .{ 0, 0, 0, 0 };
    // Texture-fill styling system: takes precedence over gradient/flat
    // fill when set, same "most specific fill wins" precedent gradient
    // already established over background_color. `id >= TextureAssets
    // .data.len`/a genuine decode failure both fall through to the
    // gradient/flat path below rather than drawing nothing -- an app
    // should never hit either in practice (Prepare.zig's asset-staging
    // pass guarantees every resolved texture id is valid), but degrading
    // gracefully here is strictly better than a guest-triggerable crash.
    const texture_tex: ?*c.SDL_Texture = if (clay_style.texture) |id|
        (if (id < TextureAssets.data.len) ImageCache.getOrLoad(image_cache, renderer, id, TextureAssets.data[id]) else null)
    else
        null;
    if (texture_tex) |tex| {
        ShapeCache.drawRoundedRectTexture(shape_cache, renderer, rect, radii, tex);
    } else if (clay_style.gradient) |g| {
        ShapeCache.drawRoundedRectGradient(shape_cache, renderer, rect, radii, g.start_uv, g.start_color, g.end_uv, g.end_color);
    } else {
        ShapeCache.drawRoundedRect(shape_cache, renderer, rect, radii, color);
    }
    if (clay_style.border) |b| {
        ShapeCache.drawRoundedRectBorder(shape_cache, renderer, rect, radii, b.width, fcolorToColor(b.color));
    }
}

/// Real intersection of two int clip rects (never a negative width/height
/// -- an empty intersection collapses to a zero-size rect at the overlap
/// point, which SDL's own clipping already treats as "draw nothing," the
/// correct behavior when a widget's own bounds fall entirely outside an
/// already-active outer clip, e.g. a scroll region).
fn intersectClipRects(a: c.SDL_Rect, b: c.SDL_Rect) c.SDL_Rect {
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const x2 = @min(a.x + a.w, b.x + b.w);
    const y2 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x1, .y = y1, .w = @max(0, x2 - x1), .h = @max(0, y2 - y1) };
}

/// Real, general containment fix (2026-09-02): text has no font-driven
/// measurement against its own widget's box (a real, disclosed natyv
/// limitation -- see `fitSizing`'s own doc comment in shared's
/// `Codegen.zig` for the layout-side half of this same gap), so a string
/// longer than its widget's own configured width previously just drew
/// straight past that widget's own edge onto whatever sits next to it
/// (confirmed live: a long guest-set Button label visibly overran its
/// own background). Clipping to the widget's own rect here doesn't
/// recover the missing characters -- there's still no way to *see* them
/// -- but it does guarantee the one thing actually being asked for: a
/// widget's own rendered content never visually spills outside its own
/// box, with zero required opt-in from `.ntx`/NTSS. Intersects with
/// whatever clip a caller already had active (e.g. a scroll region)
/// rather than replacing it, and always restores the prior clip
/// afterward -- both call sites below already scope their own outer
/// clip the same way.
fn drawWidgetDecorations(widget: WidgetHost.Widget, renderer: ?*c.SDL_Renderer, raw_padding: c.Clay_Padding, shape_cache: *ShapeCache.Cache) void {
    const padding = WidgetHost.effectiveTextPadding(raw_padding);

    const had_prior_clip = c.SDL_RenderClipEnabled(renderer);
    var prior_clip: c.SDL_Rect = undefined;
    if (had_prior_clip) _ = c.SDL_GetRenderClipRect(renderer, &prior_clip);
    var w = widget;
    const own_clip = toClipRect(w.rectPtr().*);
    const effective_clip = if (had_prior_clip) intersectClipRects(prior_clip, own_clip) else own_clip;
    _ = c.SDL_SetRenderClipRect(renderer, &effective_clip);
    defer {
        if (had_prior_clip) {
            _ = c.SDL_SetRenderClipRect(renderer, &prior_clip);
        } else {
            _ = c.SDL_SetRenderClipRect(renderer, null);
        }
    }

    switch (widget) {
        .button => |b| b.drawDecorations(renderer, padding),
        .textfield => |t| t.drawDecorations(renderer, padding),
        .textarea => |ta| ta.drawDecorations(renderer, padding),
        .label => |l| l.drawDecorations(renderer, padding),
        .checkbox => |cb| cb.drawDecorations(renderer),
        .toggle => |tg| tg.drawDecorations(renderer),
        .radio_button => |r| r.drawDecorations(renderer, shape_cache),
        .progress_bar => |p| p.drawDecorations(renderer),
        .slider => |s| s.drawDecorations(renderer),
        .range_slider => |rs| rs.drawDecorations(renderer),
        .container => |cont| cont.drawDecorations(renderer),
        .divider => |d| d.drawDecorations(renderer),
        .badge => |bd| bd.drawDecorations(renderer),
        .numeric_stepper => |ns| ns.drawDecorations(renderer),
        .segmented_control => |sc| sc.drawDecorations(renderer),
        .tabs => |tb| tb.drawDecorations(renderer),
        .spinner => |sp| sp.drawDecorations(renderer),
    }
}

fn drawFloatingWidget(slot: WidgetHost.Slot, clip: ?c.SDL_FRect, renderer: ?*c.SDL_Renderer, shape_cache: *ShapeCache.Cache, image_cache: *ImageCache.Cache) void {
    const sdl_clip: c.SDL_Rect = if (clip) |cr| toClipRect(cr) else undefined;
    if (clip != null) _ = c.SDL_SetRenderClipRect(renderer, &sdl_clip);
    if (slot.widget.fillRect()) |fr| {
        drawStyledFill(renderer, shape_cache, image_cache, slot.clay_style, fr.rect, fr.color);
    } else if (hasVisualStyle(slot.clay_style)) {
        // See the identical branch in drawWindow's own batched loop below
        // for why this exists: fillRect() returning null (e.g. a plain
        // Container, whose own W5 `background` opt-in flag is false) must
        // not also suppress a real, guest-set NTSS style -- that flag and
        // this one are unrelated opt-ins that predate each other.
        var w = slot.widget;
        drawStyledFill(renderer, shape_cache, image_cache, slot.clay_style, w.rectPtr().*, transparent);
    }
    drawWidgetDecorations(slot.widget, renderer, slot.clay_style.padding, shape_cache);
    if (clip != null) _ = c.SDL_SetRenderClipRect(renderer, null);
}

/// One scrollbar thumb (vertical and/or horizontal), for a single
/// scroll-enabled Container slot -- factored out of `drawWindow`'s own
/// scrollbar pass (2026-09-02 fix) so that pass can run three times, once
/// per layering phase (ordinary content / floating-non-modal / modal),
/// instead of the single unconditional end-of-frame pass that let a
/// scrollbar draw on top of a modal it should have been covered by. A
/// no-op for a slot that isn't a scroll-enabled Container, or whose
/// content doesn't currently overflow (`ScrollBar.verticalThumb`/
/// `horizontalThumb` return `null` in that case -- see their own doc
/// comments).
fn drawScrollbarFor(slot: WidgetHost.Slot, clay_layout: ClayLayout, renderer: ?*c.SDL_Renderer) void {
    if (!slot.clay_managed or slot.widget != .container) return;
    if (!(slot.clay_style.scroll_vertical or slot.clay_style.scroll_horizontal)) return;
    const data = clay_layout.scrollContainerData(slot.id) orelse return;
    const container_rect = slot.widget.container.rect;

    _ = c.SDL_SetRenderDrawColor(renderer, 150, 150, 160, 190);
    if (slot.clay_style.scroll_vertical) {
        if (ScrollBar.verticalThumb(container_rect, data)) |thumb| {
            _ = c.SDL_RenderFillRect(renderer, &thumb);
        }
    }
    if (slot.clay_style.scroll_horizontal) {
        if (ScrollBar.horizontalThumb(container_rect, data)) |thumb| {
            _ = c.SDL_RenderFillRect(renderer, &thumb);
        }
    }
}

/// Handles one SDL input event already resolved (by main.zig, via
/// `windowIDOf`) as targeting `wctx`'s own window -- the exact per-event
/// body main.zig's original single-window body ran inline, now scoped to
/// `slots`/`is_floating`/`topmost_modal` (this window's own subset,
/// computed once per frame by the caller, same ordering the original
/// single-window body already established: before any event in this
/// window is processed).
///
pub fn handleEvent(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, wctx: *WindowManager.WindowContext, slots: []const WidgetHost.Slot, is_floating: []const bool, topmost_modal: ?u32, event: c.SDL_Event) void {
    // Built once per event, shared by every `FloatingOrder`/
    // `isEffectivelyVisible` lookup below instead of each one re-scanning
    // `slots` linearly on its own -- see `WidgetHost.SnapshotIndex`'s own
    // doc comment.
    const index = WidgetHost.SnapshotIndex.build(slots);
    switch (event.type) {
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            if (event.button.button == c.SDL_BUTTON_LEFT) {
                const mx = event.button.x;
                const my = event.button.y;
                var hit_focusable: ?u32 = null;

                if (topmost_modal) |modal_id| {
                    for (slots) |slot| {
                        if (!FloatingOrder.isDescendantOfOrSelf(slots, index, slot.id, modal_id)) continue;
                        if (tryHitWidget(widgets, io, queue, slots, index, slot, mx, my, &wctx.interaction.dragging_slider_id, &wctx.interaction.dragging_range_handle)) |id| hit_focusable = id;
                    }
                } else {
                    var topmost_floating_root: ?u32 = null;
                    for (slots, is_floating) |slot, floating| {
                        if (!floating) continue;
                        if (!widgetContainsPoint(slot.widget, mx, my)) continue;
                        const root = FloatingOrder.nearestFloatingRoot(slots, index, slot.id) orelse continue;
                        if (topmost_floating_root == null or root > topmost_floating_root.?) topmost_floating_root = root;
                    }
                    for (slots, is_floating) |slot, floating| {
                        if (!floating) continue;
                        if (topmost_floating_root) |root| {
                            if (FloatingOrder.nearestFloatingRoot(slots, index, slot.id) != root) continue;
                        }
                        if (tryHitWidget(widgets, io, queue, slots, index, slot, mx, my, &wctx.interaction.dragging_slider_id, &wctx.interaction.dragging_range_handle)) |id| hit_focusable = id;
                    }
                    if (hit_focusable == null) {
                        for (slots, is_floating) |slot, floating| {
                            if (floating) continue;
                            if (tryHitWidget(widgets, io, queue, slots, index, slot, mx, my, &wctx.interaction.dragging_slider_id, &wctx.interaction.dragging_range_handle)) |id| hit_focusable = id;
                        }
                    }
                }
                updateFocus(widgets, io, queue, wctx, slots, index, hit_focusable);
            }
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (event.button.button == c.SDL_BUTTON_LEFT) {
                wctx.interaction.dragging_slider_id = null;
                wctx.interaction.dragging_range_handle = null;
            }
        },
        c.SDL_EVENT_TEXT_INPUT => {
            if (wctx.interaction.focused_widget_id) |id| {
                var text_buf: [max_text_widget_len]u8 = undefined;
                if (widgets.appendTextTo(io, id, std.mem.span(event.text.text), &text_buf)) |n| {
                    notifyTextChanged(queue, io, id, text_buf[0..n], slots, index);
                }
            }
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            wctx.interaction.pending_scroll_dx += event.wheel.x * wheel_pixels_per_notch;
            wctx.interaction.pending_scroll_dy += event.wheel.y * wheel_pixels_per_notch;
        },
        c.SDL_EVENT_KEY_DOWN => switch (event.key.key) {
            c.SDLK_BACKSPACE => if (wctx.interaction.focused_widget_id) |id| {
                var text_buf: [max_text_widget_len]u8 = undefined;
                if (widgets.backspaceOn(io, id, &text_buf)) |n| {
                    notifyTextChanged(queue, io, id, text_buf[0..n], slots, index);
                }
            },
            c.SDLK_TAB => {
                var registry_focusable_ids: [max_widgets_on_screen]u32 = undefined;
                const registry_focusable_count = widgets.focusableIdsSorted(io, &registry_focusable_ids);
                // Scoped to this window's own subset -- Tab shouldn't jump
                // focus into a different open window.
                var focusable_ids: [max_widgets_on_screen]u32 = undefined;
                var focusable_count: usize = 0;
                for (registry_focusable_ids[0..registry_focusable_count]) |fid| {
                    if (containsIdInSlots(slots, fid)) {
                        focusable_ids[focusable_count] = fid;
                        focusable_count += 1;
                    }
                }
                const forward = (event.key.mod & c.SDL_KMOD_SHIFT) == 0;
                const next = WidgetHost.nextFocusable(focusable_ids[0..focusable_count], wctx.interaction.focused_widget_id, forward);
                updateFocus(widgets, io, queue, wctx, slots, index, next);
            },
            c.SDLK_RETURN, c.SDLK_KP_ENTER, c.SDLK_SPACE => {
                if (wctx.interaction.focused_widget_id) |id| {
                    for (slots) |slot| {
                        if (slot.id == id) {
                            activateWidget(widgets, io, queue, id, std.meta.activeTag(slot.widget), FloatingOrder.surfaceIdFor(slots, index, id));
                            if (slot.widget == .textfield and event.key.key != c.SDLK_SPACE) {
                                queue.push(io, id, .key_nav, "{\"key\":\"enter\"}", FloatingOrder.surfaceIdFor(slots, index, id));
                            }
                            if (slot.widget == .textarea and event.key.key != c.SDLK_SPACE) {
                                var text_buf: [max_text_widget_len]u8 = undefined;
                                if (widgets.appendTextTo(io, id, "\n", &text_buf)) |n| {
                                    notifyTextChanged(queue, io, id, text_buf[0..n], slots, index);
                                }
                            }
                        }
                    }
                }
            },
            c.SDLK_ESCAPE => if (topmost_modal) |modal_id| {
                queue.push(io, modal_id, .dismiss, "", FloatingOrder.surfaceIdFor(slots, index, modal_id));
            } else {
                updateFocus(widgets, io, queue, wctx, slots, index, null);
            },
            c.SDLK_LEFT => if (wctx.interaction.focused_widget_id) |id| {
                for (slots) |slot| {
                    const surface_id = FloatingOrder.surfaceIdFor(slots, index, id);
                    if (slot.id != id) continue;
                    switch (slot.widget) {
                        .slider => |s| notifySliderValue(widgets, io, queue, id, s.value - Slider.nudge_step, surface_id),
                        .range_slider => |rs| notifyRangeSliderValue(widgets, io, queue, id, rs.active_handle, rs.activeValue() - rs.nudgeAmount(), surface_id),
                        .numeric_stepper => |ns| notifyStepperValue(widgets, io, queue, id, ns.value - ns.step, surface_id),
                        .segmented_control => |sc| notifySegmentedValue(widgets, io, queue, id, if (sc.selected_index > 0) sc.selected_index - 1 else 0, surface_id),
                        .tabs => |tb| notifyTabsValue(widgets, io, queue, id, if (tb.selected_index > 0) tb.selected_index - 1 else 0, surface_id),
                        .button => queue.push(io, id, .key_nav, "{\"key\":\"left\"}", surface_id),
                        else => {},
                    }
                }
            },
            c.SDLK_RIGHT => if (wctx.interaction.focused_widget_id) |id| {
                for (slots) |slot| {
                    const surface_id = FloatingOrder.surfaceIdFor(slots, index, id);
                    if (slot.id != id) continue;
                    switch (slot.widget) {
                        .slider => |s| notifySliderValue(widgets, io, queue, id, s.value + Slider.nudge_step, surface_id),
                        .range_slider => |rs| notifyRangeSliderValue(widgets, io, queue, id, rs.active_handle, rs.activeValue() + rs.nudgeAmount(), surface_id),
                        .numeric_stepper => |ns| notifyStepperValue(widgets, io, queue, id, ns.value + ns.step, surface_id),
                        .segmented_control => |sc| notifySegmentedValue(widgets, io, queue, id, sc.selected_index + 1, surface_id),
                        .tabs => |tb| notifyTabsValue(widgets, io, queue, id, tb.selected_index + 1, surface_id),
                        .button => queue.push(io, id, .key_nav, "{\"key\":\"right\"}", surface_id),
                        else => {},
                    }
                }
            },
            c.SDLK_DOWN => if (wctx.interaction.focused_widget_id) |id| {
                for (slots) |slot| {
                    if (slot.id == id and slot.widget == .slider) {
                        notifySliderValue(widgets, io, queue, id, slot.widget.slider.value - Slider.nudge_step, FloatingOrder.surfaceIdFor(slots, index, id));
                    } else if (slot.id == id and slot.widget == .range_slider) {
                        const rs = slot.widget.range_slider;
                        notifyRangeSliderValue(widgets, io, queue, id, rs.active_handle, rs.activeValue() - rs.nudgeAmount(), FloatingOrder.surfaceIdFor(slots, index, id));
                    } else if (slot.id == id and (slot.widget == .textfield or slot.widget == .button)) {
                        queue.push(io, id, .key_nav, "{\"key\":\"down\"}", FloatingOrder.surfaceIdFor(slots, index, id));
                    }
                }
            },
            c.SDLK_UP => if (wctx.interaction.focused_widget_id) |id| {
                for (slots) |slot| {
                    if (slot.id == id and slot.widget == .slider) {
                        notifySliderValue(widgets, io, queue, id, slot.widget.slider.value + Slider.nudge_step, FloatingOrder.surfaceIdFor(slots, index, id));
                    } else if (slot.id == id and slot.widget == .range_slider) {
                        const rs = slot.widget.range_slider;
                        notifyRangeSliderValue(widgets, io, queue, id, rs.active_handle, rs.activeValue() + rs.nudgeAmount(), FloatingOrder.surfaceIdFor(slots, index, id));
                    } else if (slot.id == id and (slot.widget == .textfield or slot.widget == .button)) {
                        queue.push(io, id, .key_nav, "{\"key\":\"up\"}", FloatingOrder.surfaceIdFor(slots, index, id));
                    }
                }
            },
            else => {},
        },
        else => {},
    }
}

fn containsIdInSlots(slots: []const WidgetHost.Slot, id: u32) bool {
    for (slots) |s| if (s.id == id) return true;
    return false;
}

/// Per-frame drag-update, hover/tooltip, and every draw pass for one window
/// -- runs after every event this frame has been dispatched (mirrors
/// main.zig's original ordering: drag-update reads `dragging_slider_id` set
/// earlier this same frame). `slots`/`is_floating`/`topmost_modal` are the
/// same window-scoped values `handleEvent` above was called with.
///
/// Multi-window Stage 3: `SDL_SetCursor` sets a single OS-wide cursor
/// image, not a per-window one (confirmed against SDL3's own docs) -- with
/// only one window this was a non-issue, but two windows both deciding
/// "the pointer cursor should be active" from their own (independently
/// hover-tested) `hovering_any` would fight over the same global cursor.
/// Gated on `SDL_WINDOW_MOUSE_FOCUS` so only whichever window the OS
/// cursor is actually over ever calls `SDL_SetCursor` -- for the original
/// single-window case this is exactly today's behavior (the one window
/// always has mouse focus whenever the cursor is over it at all).
pub fn drawWindow(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, wctx: *WindowManager.WindowContext, slots: []WidgetHost.Slot, is_floating: []const bool, topmost_modal: ?u32, arrow_cursor: ?*c.SDL_Cursor, pointer_cursor: ?*c.SDL_Cursor) void {
    const widget_count = slots.len;
    // Built once per draw pass, shared by every `FloatingOrder`/
    // `isEffectivelyVisible` lookup below -- see
    // `WidgetHost.SnapshotIndex`'s own doc comment.
    const index = WidgetHost.SnapshotIndex.build(slots);

    if (wctx.interaction.dragging_slider_id) |id| {
        for (slots) |slot| {
            if (slot.id == id and slot.widget == .slider) {
                notifySliderValue(widgets, io, queue, id, slot.widget.slider.valueFromX(wctx.interaction.mouse_x), FloatingOrder.surfaceIdFor(slots, index, id));
            } else if (slot.id == id and slot.widget == .range_slider) {
                const handle = wctx.interaction.dragging_range_handle orelse slot.widget.range_slider.active_handle;
                notifyRangeSliderValue(widgets, io, queue, id, handle, slot.widget.range_slider.valueFromX(wctx.interaction.mouse_x), FloatingOrder.surfaceIdFor(slots, index, id));
            }
        }
    }

    // Real, deliberate exception to the generation-based redraw gate below:
    // Spinner always animates from wall-clock time with no registry-side
    // state at all (see Spinner.zig's own doc comment), and Button's
    // post-click flash color is likewise computed from `now_ms <
    // flash_until_ms` inside the draw pass, not from anything that bumps
    // `layout_generation` -- a generation-only gate would freeze both
    // solid, exactly the idle case this fix targets. Folded into this same
    // per-slot loop (already iterating every effectively-visible,
    // not-behind-a-modal slot for hover hit-testing) rather than a second
    // pass over the same data.
    var needs_continuous_redraw = false;
    const now_ms = timing.nowMs();
    var hovering_any = false;
    var hovered_widget_id_this_frame: ?u32 = null;
    for (slots) |slot| {
        if (topmost_modal) |modal_id| {
            if (!FloatingOrder.isDescendantOfOrSelf(slots, index, slot.id, modal_id)) continue;
        }
        if (!WidgetHost.isEffectivelyVisible(slots, index, slot)) continue;
        switch (slot.widget) {
            // A disabled Button shows neither the pointer cursor nor a
            // tooltip hover -- it isn't actually clickable right now, so
            // neither affordance should suggest otherwise. The flash check
            // is independent of both `enabled` and hover state -- a click
            // flash still needs to fade even if the button became disabled
            // or the mouse moved away immediately afterward.
            .button => |b| {
                if (slot.clay_style.enabled and b.containsPoint(wctx.interaction.mouse_x, wctx.interaction.mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                }
                if (now_ms < b.flash_until_ms) needs_continuous_redraw = true;
            },
            .textfield => |t| if (t.containsPoint(wctx.interaction.mouse_x, wctx.interaction.mouse_y)) {
                hovering_any = true;
                hovered_widget_id_this_frame = slot.id;
            },
            .textarea => |ta| if (ta.containsPoint(wctx.interaction.mouse_x, wctx.interaction.mouse_y)) {
                hovering_any = true;
                hovered_widget_id_this_frame = slot.id;
            },
            .checkbox => |cb| if (cb.containsPoint(wctx.interaction.mouse_x, wctx.interaction.mouse_y)) {
                hovering_any = true;
                hovered_widget_id_this_frame = slot.id;
            },
            .toggle => |tg| if (tg.containsPoint(wctx.interaction.mouse_x, wctx.interaction.mouse_y)) {
                hovering_any = true;
                hovered_widget_id_this_frame = slot.id;
            },
            .radio_button => |r| if (r.containsPoint(wctx.interaction.mouse_x, wctx.interaction.mouse_y)) {
                hovering_any = true;
                hovered_widget_id_this_frame = slot.id;
            },
            .slider => |s| if (s.containsPoint(wctx.interaction.mouse_x, wctx.interaction.mouse_y)) {
                hovering_any = true;
                hovered_widget_id_this_frame = slot.id;
            },
            .range_slider => |rs| if (rs.containsPoint(wctx.interaction.mouse_x, wctx.interaction.mouse_y)) {
                hovering_any = true;
                hovered_widget_id_this_frame = slot.id;
            },
            .numeric_stepper => |ns| if (ns.containsPoint(wctx.interaction.mouse_x, wctx.interaction.mouse_y)) {
                hovering_any = true;
                hovered_widget_id_this_frame = slot.id;
            },
            .segmented_control => |sc| if (sc.containsPoint(wctx.interaction.mouse_x, wctx.interaction.mouse_y)) {
                hovering_any = true;
                hovered_widget_id_this_frame = slot.id;
            },
            .tabs => |tb| if (tb.containsPoint(wctx.interaction.mouse_x, wctx.interaction.mouse_y)) {
                hovering_any = true;
                hovered_widget_id_this_frame = slot.id;
            },
            .spinner => needs_continuous_redraw = true,
            .label, .container, .progress_bar, .divider, .badge => {},
        }
    }
    if (hovering_any != wctx.interaction.cursor_is_pointer) {
        wctx.interaction.cursor_is_pointer = hovering_any;
        if ((c.SDL_GetWindowFlags(wctx.window) & c.SDL_WINDOW_MOUSE_FOCUS) != 0) {
            _ = c.SDL_SetCursor(if (hovering_any) pointer_cursor else arrow_cursor);
        }
    }

    if (hovered_widget_id_this_frame != wctx.interaction.hovered_widget_id) {
        if (wctx.interaction.tooltip_active_for) |active_id| {
            if (wctx.interaction.hovered_widget_id) |prev_id| {
                if (active_id == prev_id) {
                    queue.push(io, prev_id, .hover, "{\"hovering\":false}", FloatingOrder.surfaceIdFor(slots, index, prev_id));
                }
            }
            wctx.interaction.tooltip_active_for = null;
        }
        wctx.interaction.hovered_widget_id = hovered_widget_id_this_frame;
        wctx.interaction.hover_start_ms = if (hovered_widget_id_this_frame != null) timing.nowMs() else null;
    } else if (hovered_widget_id_this_frame) |id| {
        if (wctx.interaction.hover_start_ms) |start| {
            const already_active = if (wctx.interaction.tooltip_active_for) |active_id| active_id == id else false;
            if (timing.nowMs() - start >= tooltip_hover_threshold_ms and !already_active) {
                queue.push(io, id, .hover, "{\"hovering\":true}", FloatingOrder.surfaceIdFor(slots, index, id));
                wctx.interaction.tooltip_active_for = id;
            }
        }
    }

    // Skips the actual GPU work (clear/fill/decorate/present) when nothing
    // for this window changed since its own last real draw -- this is the
    // draw-level half of the idle-CPU fix (main.zig's SDL_WaitEventTimeout
    // is the other half, bounding how *often* this function even gets
    // called). `needs_continuous_redraw` (computed above, in the same pass
    // as hover hit-testing) covers Spinner/Button-flash, the two real cases
    // that don't bump `layout_generation` at all -- see this block's own
    // reasoning just above. An active slider/range-slider drag is a third
    // real exception: `notifySliderValue`/`notifyRangeSliderValue` above
    // push the new value to the guest, but nothing guarantees a same-frame
    // `layout_generation` bump back before *this* draw needs to reflect the
    // thumb's new position, so a drag in progress always redraws too. The
    // hover/tooltip logic above still runs every call regardless -- it's
    // cheap and already self-gates via its own hovered-widget-changed
    // checks, only the renderer work below is worth skipping.
    const current_generation = widgets.currentGeneration(io);
    const dragging = wctx.interaction.dragging_slider_id != null;
    const warming_up = now_ms - wctx.created_at_ms < window_redraw_warmup_ms;
    // A real Clay recompute this same iteration (scroll or resize, not just
    // content) writes fresh `rect`/`scroll_data` via `WidgetHost.setRect`/
    // `setScrollData` -- neither bumps `layout_generation` (see
    // `ClayLayout.layoutIfNeeded`'s own doc comment), so without this a
    // scroll or a resize would freeze on screen exactly like the focus ring
    // did before it got its own generation bump -- confirmed live: scroll
    // was already silently frozen before this line was added, most likely
    // ever since the very first draw-level dirty check landed (nothing here
    // ever exercised scrolling until now). `wctx.did_recompute` is set by
    // `layoutWindow`, called unconditionally right before this same call.
    const needs_redraw = wctx.last_drawn_generation == null or wctx.last_drawn_generation.? != current_generation or dragging or needs_continuous_redraw or warming_up or wctx.did_recompute;
    if (!needs_redraw) return;
    wctx.last_drawn_generation = current_generation;
    wctx.draw_count += 1;

    var clip_rects: [max_widgets_on_screen]?c.SDL_FRect = undefined;
    ScrollClip.computeClipRects(slots, clip_rects[0..widget_count]);

    _ = c.SDL_SetRenderDrawColor(wctx.renderer, 24, 24, 28, 255);
    _ = c.SDL_RenderClear(wctx.renderer);

    for (slots, clip_rects[0..widget_count], is_floating) |slot, clip, floating| {
        if (floating) continue;
        if (!WidgetHost.isEffectivelyVisible(slots, index, slot)) continue;

        var rect: c.SDL_FRect = undefined;
        var default_color: c.SDL_Color = undefined;
        if (slot.widget.fillRect()) |fr| {
            rect = fr.rect;
            default_color = fr.color;
        } else if (hasVisualStyle(slot.clay_style)) {
            // See hasVisualStyle's own doc comment -- a widget with no
            // natural fill (fillRect() null) still needs its real,
            // guest-set NTSS style drawn; its rect exists regardless of
            // that unrelated opt-in, via the same generic accessor L4's
            // own layout writeback already uses.
            var w = slot.widget;
            rect = w.rectPtr().*;
            default_color = transparent;
        } else {
            continue;
        }

        // A disabled Button (ClayStyle.enabled's own doc comment) always
        // draws this fixed muted gray, regardless of any guest-set NTSS
        // backgroundColor -- overriding a *local copy* of clay_style
        // (passed by value below either way) rather than adding a
        // separate parameter everywhere color gets resolved.
        var effective_style = slot.clay_style;
        if (slot.widget == .button and !slot.clay_style.enabled) {
            effective_style.background_color = disabled_color;
        }

        if (effective_style.corner_radius != null or effective_style.border != null or effective_style.gradient != null or effective_style.texture != null) {
            // Flush whatever's pending first -- a styled shape draws
            // immediately (it can't join the plain-rect batch), so
            // without this, a batched sibling queued earlier in this
            // same loop would render *after* this one instead of
            // before it, silently reordering overlapping widgets.
            wctx.draw_batcher.flush(wctx.renderer);
            if (clip) |cr| {
                const sdl_clip = toClipRect(cr);
                _ = c.SDL_SetRenderClipRect(wctx.renderer, &sdl_clip);
                drawStyledFill(wctx.renderer, &wctx.shape_cache, &wctx.image_cache, effective_style, rect, default_color);
                _ = c.SDL_SetRenderClipRect(wctx.renderer, null);
            } else {
                drawStyledFill(wctx.renderer, &wctx.shape_cache, &wctx.image_cache, effective_style, rect, default_color);
            }
            continue;
        }
        const color = styleOverrideColor(effective_style.background_color) orelse default_color;
        if (clip) |cr| {
            const sdl_clip = toClipRect(cr);
            _ = c.SDL_SetRenderClipRect(wctx.renderer, &sdl_clip);
            _ = c.SDL_SetRenderDrawColor(wctx.renderer, color.r, color.g, color.b, color.a);
            _ = c.SDL_RenderFillRect(wctx.renderer, &rect);
            _ = c.SDL_SetRenderClipRect(wctx.renderer, null);
        } else {
            wctx.draw_batcher.add(color, rect);
        }
    }
    wctx.draw_batcher.flush(wctx.renderer);

    for (slots, clip_rects[0..widget_count], is_floating) |slot, clip, floating| {
        if (floating) continue;
        if (!WidgetHost.isEffectivelyVisible(slots, index, slot)) continue;
        const sdl_clip: c.SDL_Rect = if (clip) |cr| toClipRect(cr) else undefined;
        if (clip != null) _ = c.SDL_SetRenderClipRect(wctx.renderer, &sdl_clip);
        drawWidgetDecorations(slot.widget, wctx.renderer, slot.clay_style.padding, &wctx.shape_cache);
        if (clip != null) _ = c.SDL_SetRenderClipRect(wctx.renderer, null);
    }

    // Scrollbar thumbs, drawn in the same three layering phases as the
    // widgets they belong to (2026-09-02 fix) -- previously a single
    // unconditional pass ran after *everything* else, including the modal
    // backdrop and its own content, so an ordinary scrollable Container's
    // thumb visibly drew on top of any open modal (found via a real
    // click-through: mail-natyv's own message-list scrollbar cut straight
    // through a Dialog). Ordinary (non-floating) content's own scrollbars
    // belong in this same phase, beneath floating/modal content.
    if (wctx.clay_layout) |clay_layout| {
        for (slots, is_floating) |slot, floating| {
            if (floating) continue;
            drawScrollbarFor(slot, clay_layout, wctx.renderer);
        }
    }

    for (slots, clip_rects[0..widget_count], is_floating) |slot, clip, floating| {
        if (!floating) continue;
        if (!WidgetHost.isEffectivelyVisible(slots, index, slot)) continue;
        if (topmost_modal) |modal_id| {
            if (FloatingOrder.isDescendantOfOrSelf(slots, index, slot.id, modal_id)) continue;
        }
        drawFloatingWidget(slot, clip, wctx.renderer, &wctx.shape_cache, &wctx.image_cache);
    }
    // A floating (but non-modal) scrollable widget's own scrollbar -- e.g.
    // a scrollable Dropdown/Menu panel -- belongs here: above ordinary
    // content, still beneath any modal.
    if (wctx.clay_layout) |clay_layout| {
        for (slots, is_floating) |slot, floating| {
            if (!floating) continue;
            if (topmost_modal) |modal_id| {
                if (FloatingOrder.isDescendantOfOrSelf(slots, index, slot.id, modal_id)) continue;
            }
            drawScrollbarFor(slot, clay_layout, wctx.renderer);
        }
    }
    if (topmost_modal) |modal_id| {
        var win_w: c_int = undefined;
        var win_h: c_int = undefined;
        _ = c.SDL_GetWindowSize(wctx.window, &win_w, &win_h);
        _ = c.SDL_SetRenderDrawBlendMode(wctx.renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(wctx.renderer, 0, 0, 0, 140);
        const backdrop: c.SDL_FRect = .{ .x = 0, .y = 0, .w = @floatFromInt(win_w), .h = @floatFromInt(win_h) };
        _ = c.SDL_RenderFillRect(wctx.renderer, &backdrop);
        _ = c.SDL_SetRenderDrawBlendMode(wctx.renderer, c.SDL_BLENDMODE_NONE);

        for (slots, clip_rects[0..widget_count], is_floating) |slot, clip, floating| {
            if (!floating) continue;
            if (!WidgetHost.isEffectivelyVisible(slots, index, slot)) continue;
            if (!FloatingOrder.isDescendantOfOrSelf(slots, index, slot.id, modal_id)) continue;
            drawFloatingWidget(slot, clip, wctx.renderer, &wctx.shape_cache, &wctx.image_cache);
        }
        // A scrollable widget inside the modal itself (e.g. a long
        // message list in a Dialog) -- correctly on top of everything,
        // matching the modal content it belongs to.
        if (wctx.clay_layout) |clay_layout| {
            for (slots, is_floating) |slot, floating| {
                if (!floating) continue;
                if (!FloatingOrder.isDescendantOfOrSelf(slots, index, slot.id, modal_id)) continue;
                drawScrollbarFor(slot, clay_layout, wctx.renderer);
            }
        }
    }

    _ = c.SDL_RenderPresent(wctx.renderer);
}
