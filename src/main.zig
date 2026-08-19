const std = @import("std");
const c = @import("c.zig").c;
const Config = @import("Config.zig");
const Manifest = @import("Manifest.zig");
const Runtime = @import("Runtime.zig");
const WidgetHost = @import("widgets/WidgetHost.zig");
const Slider = @import("widgets/Slider.zig");
const RangeSlider = @import("widgets/RangeSlider.zig");
const TextField = @import("widgets/TextField.zig");
const TextArea = @import("widgets/TextArea.zig");
const json_util = @import("json_util.zig");
const timing = @import("timing.zig");
const ClayLayout = @import("capabilities/ClayLayout.zig");
const Font = @import("capabilities/Font.zig");
const EventQueue = @import("EventQueue.zig");
const Dispatch = @import("Dispatch.zig");
const DrawBatcher = @import("DrawBatcher.zig");
const ScrollClip = @import("ScrollClip.zig");
const ScrollBar = @import("ScrollBar.zig");
const FloatingOrder = @import("FloatingOrder.zig");

const max_widgets_on_screen = WidgetHost.max_widgets;

/// W10: shared sizing for every stack buffer that has to hold "whichever
/// text widget's post-mutation content is currently biggest" --
/// TextArea.max_len is always the larger of the two, but computed via
/// @max rather than hardcoded so this stays correct if that ever changes.
const max_text_widget_len = @max(TextField.max_len, TextArea.max_len);

/// W15: how long the mouse has to sit continuously over the same widget
/// before a `.hover` `{"hovering":true}` event fires for it. Fixed, not
/// guest-configurable in v1 -- same treatment Slider's `nudge_step` got.
/// 100ms (not a more typical OS tooltip delay like 500ms) per Quinn's real
/// click-through feedback: at 500ms the tooltip felt laggy rather than
/// responsive; 100ms reads as near-instant while still being long enough
/// to not fire on a mouse merely passing over the widget in transit.
const tooltip_hover_threshold_ms: i64 = 100;

/// Keyboard interaction model: the one place focus actually changes (mouse
/// click, Tab/Shift+Tab, Escape all route through this) -- updates the
/// registry, the caller's local tracking var, and starts/stops
/// `SDL_StartTextInput` based on whether the newly focused widget is a
/// `TextField` (focusing a `Button` shouldn't turn on IME/text
/// composition). Kept as a free function taking everything explicitly
/// rather than a closure, since Zig's nested functions can't capture outer
/// locals.
///
/// W6: also fires `.blur` to whatever was previously focused, when focus
/// actually changes away from it (re-clicking the same already-focused
/// widget, or `new_id` genuinely equal to the old one, isn't a blur).
/// Fired for any widget kind, not just textfields -- simpler than
/// special-casing, and harmless for a guest that never registered a
/// handler for it, same "host fires generically, guest decides relevance"
/// precedent every other event type here already follows.
///
/// W9 follow-up (Quinn's real click-through feedback): the payload now
/// carries `new_focus_id` (0 = none) -- a real gap found via Menu's
/// submenu, not just a nice-to-have. Clicking "More" to open a submenu
/// moves focus onto "More" itself, which (since it differs from the
/// previously-focused top-level trigger) fires a genuine `.blur` on the
/// trigger in the very same frame, right after the "More" click's own
/// `.click` already opened the submenu -- without knowing *what* focus
/// moved to, a guest's blur handler can't tell "focus moved to something
/// that's still part of my own menu" (should NOT close) apart from "focus
/// moved somewhere unrelated" (a real click-away, should close), and
/// blindly closing on every blur was destroying the submenu the same
/// frame it opened.
fn updateFocus(widgets: *WidgetHost, io: std.Io, window: *c.SDL_Window, queue: *EventQueue, slots: []const WidgetHost.Slot, focused_widget_id: *?u32, new_id: ?u32) void {
    if (focused_widget_id.*) |old_id| {
        if (new_id == null or old_id != new_id.?) {
            var buf: [32]u8 = undefined;
            const payload = std.fmt.bufPrint(&buf, "{{\"new_focus_id\":{d}}}", .{new_id orelse 0}) catch "{}";
            queue.push(io, old_id, .blur, payload, FloatingOrder.surfaceIdFor(slots, old_id));
        }
    }
    // W10: renamed from is_textfield -- WidgetHost.setFocused's returned
    // bool now also covers .textarea, not just .textfield.
    const wants_text_input = widgets.setFocused(io, new_id);
    focused_widget_id.* = new_id;
    if (wants_text_input) {
        _ = c.SDL_StartTextInput(window);
    } else {
        _ = c.SDL_StopTextInput(window);
    }
}

/// W2: `SDL_SetRenderClipRect` takes an integer `SDL_Rect`, not the
/// `SDL_FRect` every widget rect and DrawBatcher entry uses -- floor the
/// origin and ceil the extent (rather than a bare truncating cast) so a
/// partially-visible edge pixel is kept rather than clipped away early.
fn toClipRect(r: c.SDL_FRect) c.SDL_Rect {
    return .{
        .x = @intFromFloat(@floor(r.x)),
        .y = @intFromFloat(@floor(r.y)),
        .w = @intFromFloat(@ceil(r.w)),
        .h = @intFromFloat(@ceil(r.h)),
    };
}

/// W1: the shared "activate this widget" body for both a mouse click and a
/// keyboard Enter/Space -- one place so the two input paths can't drift
/// apart on what "activating" a given kind actually does. Not every kind is
/// activatable (TextField, Label, Container, ProgressBar aren't); those
/// just fall through without pushing an event at all, same as clicking
/// empty space today. W3: Slider joins that non-activatable set too --
/// Enter/Space isn't slider semantics, it's driven by drag/arrow-keys
/// instead (see `notifySliderValue` and the drag-update block below). W10:
/// TextArea joins it too, same reasoning as TextField -- Enter means
/// "insert a newline" for it (see the SDLK_RETURN handling below), not
/// "activate."
fn activateWidget(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, kind: WidgetHost.WidgetKind, surface_id: u32) void {
    switch (kind) {
        .button => widgets.flashButton(io, id),
        .checkbox => widgets.toggleCheckbox(io, id),
        .toggle => widgets.toggleToggle(io, id),
        .radio_button => widgets.selectRadioExclusive(io, id),
        // W17: same non-activatable set Slider joins -- driven by
        // click-zone/arrow-key input instead (see `notifyStepperValue`/
        // `notifySegmentedValue` and the keyboard handling below). W19:
        // Tabs joins for the same reason -- driven by `tabAt`/arrow-key
        // input via `notifyTabsValue`, not Enter/Space.
        // W27: RangeSlider joins the same non-activatable set as Slider --
        // driven by drag/arrow-keys, not Enter/Space.
        .textfield, .textarea, .label, .container, .progress_bar, .slider, .range_slider, .divider, .badge, .numeric_stepper, .segmented_control, .tabs, .spinner => return,
    }
    queue.push(io, id, .click, "", surface_id);
}

/// W3: the slider counterpart to `activateWidget` -- called both from a
/// click-to-jump/drag update and an arrow-key nudge. Mutates the host-side
/// value immediately via `WidgetHost.setSliderValue` (so the thumb responds
/// the same frame, not waiting on a guest round trip) and, only if the
/// clamped value actually changed, pushes a "change" event carrying that
/// *clamped* value so the guest finds out too. `EventQueue.push`'s
/// `.change` coalescing means calling this every frame during a drag never
/// floods the queue -- only the latest value per widget is ever pending
/// delivery.
fn notifySliderValue(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, value: f32, surface_id: u32) void {
    const clamped = widgets.setSliderValue(io, id, value) orelse return;
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"value\":{d}}}", .{clamped}) catch "{}";
    queue.push(io, id, .change, json, surface_id);
}

/// W27: the `RangeSlider` counterpart to `notifySliderValue` -- called from
/// both a drag update and an arrow-key nudge, always for whichever handle
/// `WidgetHost.setRangeSliderValue`'s own `handle` param names (the widget's
/// current `active_handle`, resolved separately at drag-start/focus time).
/// Payload is `{"min":m,"max":x}`, not Slider's bare `{"value":f}` -- a
/// different shape under the same `.change` event type, decoded by the
/// guest SDK's own `RegisterRangeChange` instead of `RegisterChange` (see
/// that file's own doc comment for why they're two separate handler tables
/// rather than one, despite sharing an event type).
fn notifyRangeSliderValue(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, handle: RangeSlider.Handle, value: f32, surface_id: u32) void {
    const result = widgets.setRangeSliderValue(io, id, handle, value) orelse return;
    var buf: [48]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"min\":{d},\"max\":{d}}}", .{ result.min, result.max }) catch "{}";
    queue.push(io, id, .change, json, surface_id);
}

/// W17: the `NumericStepper` counterpart to `notifySliderValue` -- called
/// from both a minus/plus zone click and an arrow-key press with an
/// already-delta'd raw value (`current.value +/- current.step`); the
/// clamp/wrap resolution itself happens host-side in `setStepperValue`.
fn notifyStepperValue(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, value: i32, surface_id: u32) void {
    const resolved = widgets.setStepperValue(io, id, value) orelse return;
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"value\":{d}}}", .{resolved}) catch "{}";
    queue.push(io, id, .change, json, surface_id);
}

/// W17: the `SegmentedControl` counterpart to `notifySliderValue` -- called
/// from a segment click (the tapped index directly) or an arrow-key press
/// (`current.selected_index +/- 1`). Payload key is `"value"`, not
/// `"selected_index"` -- deliberately matching every other `.change`
/// emitter's wire shape (Slider/Toggle/Checkbox/NumericStepper) so guest
/// SDKs can decode all of them through one shared `{"value": N}` payload
/// type instead of a one-off shape just for this kind.
fn notifySegmentedValue(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, index: usize, surface_id: u32) void {
    const resolved = widgets.setSegmentedIndex(io, id, index) orelse return;
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"value\":{d}}}", .{resolved}) catch "{}";
    queue.push(io, id, .change, json, surface_id);
}

/// W19: the `Tabs` counterpart to `notifySegmentedValue` -- same shape,
/// same shared `{"value":N}` payload convention, except `setActiveTab`
/// (unlike `setSegmentedIndex`) also flips every panel's `visible` flag and
/// bumps `layout_generation` as a side effect -- see that function's doc
/// comment.
fn notifyTabsValue(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, index: usize, surface_id: u32) void {
    const resolved = widgets.setActiveTab(io, id, index) orelse return;
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"value\":{d}}}", .{resolved}) catch "{}";
    queue.push(io, id, .change, json, surface_id);
}

/// W6: the TextField counterpart to `notifySliderValue` -- called after
/// `appendTextTo`/`backspaceOn` already mutated the widget and copied its
/// real post-mutation text into `new_text`. Unlike the slider's payload
/// (a bare float, safe to `bufPrint` directly), arbitrary typed text needs
/// real JSON string escaping -- reuses `json_util.writeString`, the same
/// escaping `Dispatch.zig`'s own payload-wrapping already relies on, over a
/// stack-based `FixedBufferAllocator` so this stays allocation-free like
/// every other per-frame push site here.
fn notifyTextChanged(queue: *EventQueue, io: std.Io, id: u32, new_text: []const u8, slots: []const WidgetHost.Slot) void {
    var buf: [max_text_widget_len + 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "{\"text\":") catch return;
    json_util.writeString(&out, a, new_text) catch return;
    out.append(a, '}') catch return;
    queue.push(io, id, .text_changed, out.items, FloatingOrder.surfaceIdFor(slots, id));
}

/// W23: what `fileDialogCallback` below needs to push a real `.file_selected`
/// event once SDL's own callback actually fires -- populated by the drain
/// loop right before the real `SDL_ShowOpenFileDialog`/`SDL_ShowSaveFileDialog`
/// call, read back via the callback's own `userdata` pointer. Kept as a
/// single reused main()-local variable (not heap-allocated per request) --
/// its address must stay stable for as long as the dialog might be open
/// (unbounded; the user could leave it open indefinitely), which a
/// stack-local in the one frame that drains the request wouldn't survive,
/// but `WidgetHost.pending_file_dialog_request`'s own "single pending slot,
/// a second request before the first drains just overwrites" simplification
/// already accepts that only one dialog is ever realistically in flight, so
/// one reused context is consistent with that, not a separate risk.
const FileDialogCallbackContext = struct {
    io: std.Io,
    queue: *EventQueue,
    widget_id: u32,
    surface_id: u32,
};

/// Max total bytes for the JSON-encoded `{"paths":[...]}` payload this
/// builds on the stack before handing it to `queue.push` (which then owns
/// its own heap copy, same as every other per-frame push site here) --
/// generous enough for several real filesystem paths in a multi-select
/// dialog. If the real result is bigger than this, the event is silently
/// dropped, same `catch return` precedent `notifyTextChanged` above already
/// establishes for an oversized payload.
const max_file_dialog_payload_len = 4096;

/// The real `SDL_DialogFileCallback` -- `userdata` is the
/// `FileDialogCallbackContext` the drain loop populated before the SDL
/// call. Per SDL's own documented `\threadsafety`, this may fire on any
/// thread, not necessarily main -- doesn't touch SDL/the widget registry
/// directly, only pushes onto `EventQueue` (the same cross-thread-safe
/// mutex/condvar primitives the worker thread's own `queue.pop` already
/// relies on, so this is safe from any thread the same way). `filelist` is
/// a null-terminated array of null-terminated UTF-8 paths (NULL itself for
/// a real SDL-level error, a pointer to NULL for "user cancelled") -- both
/// collapse to the same empty `{"paths":[]}` result, since a guest can't
/// meaningfully act differently on the two (see EventQueue.EventType's own
/// doc comment on `.file_selected`).
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

/// Pure per-kind geometry check, factored out of `tryHitWidget`'s switch
/// below -- W9 follow-up: needed by the floating-content pre-scan (see the
/// mouse-down handler below) to find which currently-open floating subtree
/// actually contains a click point *before* any side effect (activateWidget's
/// `.click` push, starting a slider drag) fires for anything, so overlapping
/// floating panels (e.g. Menu's submenu, stacked on top of its own
/// still-open parent panel) can be ranked without double-firing.
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

/// W4: the per-kind mouse-hit body every `SDL_EVENT_MOUSE_BUTTON_DOWN`
/// arm already used inline before this existed -- extracted so it can run
/// in two priority passes (floating content first, then normal content)
/// instead of one, see the event handler below. Behavior for any single
/// widget is completely unchanged from before this extraction; returns the
/// hit widget's id (to focus) or null if `slot` wasn't hit/isn't
/// interactive. `dragging_slider_id` is an out-param the same way it was
/// an inline assignment before -- a slider hit starts a drag as a side
/// effect, same as before. W27: also covers a RangeSlider hit (its own drag
/// is host-authoritative the same way, just on whichever handle
/// `RangeSlider.closestHandle` resolves) -- not renamed to something more
/// generic like `dragging_widget_id`, since only one of the two kinds can
/// ever be mid-drag at once anyway (a single global mouse gesture), same
/// reasoning `WidgetHost.setRangeSliderValue`'s own doc comment gives for
/// reusing `.change` as RangeSlider's event type instead of inventing a new
/// one. `dragging_range_handle` is a second, RangeSlider-only out-param --
/// a real bug (Quinn's own click-through: "I can only use the slider on
/// the left") caught that `widgets.setRangeSliderActiveHandle` below
/// mutates the *live* registry, but the per-frame drag-update block reads
/// `widget_snapshot`, captured once at the top of this same frame, *before*
/// any of this frame's events ran -- so a fresh handle choice made here
/// was invisible to that block for the rest of the frame it was chosen in,
/// silently moving whichever handle was active *last* frame instead. This
/// plain local (threaded the same way `dragging_slider_id` already is, not
/// read back through the stale snapshot) is what the drag-update block
/// actually reads now.
fn tryHitWidget(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, slots: []const WidgetHost.Slot, slot: WidgetHost.Slot, mx: f32, my: f32, dragging_slider_id: *?u32, dragging_range_handle: *?RangeSlider.Handle) ?u32 {
    // W19: an invisible slot (a Tabs panel that isn't the active tab, e.g.)
    // isn't declared to Clay this frame, so its cached `rect` can go stale
    // rather than zeroed -- don't rely on that; skip explicitly rather than
    // risk hit-testing/clicking a hidden widget for one frame. Checked once
    // here rather than at every one of this function's several call sites.
    // Ancestor-aware (`WidgetHost.isEffectivelyVisible`, not the raw
    // `slot.clay_style.visible` field) -- a hidden panel's own children
    // (e.g. a Label) keep their own default `visible == true`, since that
    // flag is never propagated down; see that function's own doc comment.
    if (!WidgetHost.isEffectivelyVisible(slots, slot)) return null;
    switch (slot.widget) {
        .button => |b| if (b.containsPoint(mx, my)) {
            activateWidget(widgets, io, queue, slot.id, .button, FloatingOrder.surfaceIdFor(slots, slot.id));
            return slot.id;
        },
        .checkbox => |cb| if (cb.containsPoint(mx, my)) {
            activateWidget(widgets, io, queue, slot.id, .checkbox, FloatingOrder.surfaceIdFor(slots, slot.id));
            return slot.id;
        },
        .toggle => |tg| if (tg.containsPoint(mx, my)) {
            activateWidget(widgets, io, queue, slot.id, .toggle, FloatingOrder.surfaceIdFor(slots, slot.id));
            return slot.id;
        },
        .radio_button => |r| if (r.containsPoint(mx, my)) {
            activateWidget(widgets, io, queue, slot.id, .radio_button, FloatingOrder.surfaceIdFor(slots, slot.id));
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
        // W27: resolves which handle this click targets (whichever thumb
        // is closer) and records it as active *before* starting the drag --
        // main.zig's own per-frame drag-update block (below) and any
        // arrow-key nudge afterward both just move whatever `active_handle`
        // currently is, so this is the one place that decision gets made.
        .range_slider => |rs| if (rs.containsPoint(mx, my)) {
            const handle = rs.closestHandle(mx);
            widgets.setRangeSliderActiveHandle(io, slot.id, handle);
            dragging_range_handle.* = handle;
            dragging_slider_id.* = slot.id;
            return slot.id;
        },
        // W17: the first widget with more than one clickable zone in a
        // single rect -- `regionAt`/`segmentAt` (not a plain
        // `containsPoint`) decide which one was hit. A click in the
        // middle "value" zone (stepper) or anywhere in the rect (control)
        // that isn't a real zone/segment still returns the id for focus,
        // same "click to focus, no value change" feel `Slider`'s
        // click-to-drag establishes for its own track.
        .numeric_stepper => |ns| {
            const surface_id = FloatingOrder.surfaceIdFor(slots, slot.id);
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
            notifySegmentedValue(widgets, io, queue, slot.id, idx, FloatingOrder.surfaceIdFor(slots, slot.id));
            return slot.id;
        } else if (sc.containsPoint(mx, my)) return slot.id,
        // W19: same "internal zone, not the whole rect" shape as
        // SegmentedControl -- `tabAt` only resolves inside the header strip
        // (see `Tabs.headerRect`), so a click on real panel content below it
        // correctly falls through to `null` here (that content is a
        // separate slot with its own hit-test arm, tried elsewhere in the
        // caller's own loop over every slot).
        .tabs => |tb| if (tb.tabAt(mx, my)) |idx| {
            notifyTabsValue(widgets, io, queue, slot.id, idx, FloatingOrder.surfaceIdFor(slots, slot.id));
            return slot.id;
        } else if (tb.containsPoint(mx, my)) return slot.id,
        .label, .container, .progress_bar, .divider, .badge, .spinner => {},
    }
    return null;
}

/// The border/text/checkmark/etc a widget draws on top of its own fill --
/// shared by the normal decoration pass and the W4 floating-content pass
/// below, so a new widget kind only needs one switch arm added here, not
/// duplicated across both passes.
fn drawWidgetDecorations(widget: WidgetHost.Widget, renderer: ?*c.SDL_Renderer) void {
    switch (widget) {
        .button => |b| b.drawDecorations(renderer),
        .textfield => |t| t.drawDecorations(renderer),
        .textarea => |ta| ta.drawDecorations(renderer),
        .label => |l| l.drawDecorations(renderer),
        .checkbox => |cb| cb.drawDecorations(renderer),
        .toggle => |tg| tg.drawDecorations(renderer),
        .radio_button => |r| r.drawDecorations(renderer),
        .progress_bar => |p| p.drawDecorations(renderer),
        .slider => |s| s.drawDecorations(renderer),
        .range_slider => |rs| rs.drawDecorations(renderer),
        // W5: draws a border only when `background` is set -- see
        // Container.zig's doc comment.
        .container => |cont| cont.drawDecorations(renderer),
        .divider => |d| d.drawDecorations(renderer),
        .badge => |bd| bd.drawDecorations(renderer),
        .numeric_stepper => |ns| ns.drawDecorations(renderer),
        .segmented_control => |sc| sc.drawDecorations(renderer),
        // W19: header strip only -- panel content is real Clay children,
        // drawn through the normal per-child pass instead.
        .tabs => |tb| tb.drawDecorations(renderer),
        // W29: reads wall-clock time itself, every frame -- see
        // Spinner.zig's own doc comment for why this needs no per-widget
        // animation state or new host mechanism, just a real call here
        // like every other kind gets.
        .spinner => |sp| sp.drawDecorations(renderer),
    }
}

/// W4/W5: shared fill-then-decorate body for a single floating widget --
/// used by both halves of the floating draw pass below, which W5 splits in
/// two around a modal's backdrop instead of running as one loop.
fn drawFloatingWidget(slot: WidgetHost.Slot, clip: ?c.SDL_FRect, renderer: ?*c.SDL_Renderer) void {
    const sdl_clip: c.SDL_Rect = if (clip) |cr| toClipRect(cr) else undefined;
    if (clip != null) _ = c.SDL_SetRenderClipRect(renderer, &sdl_clip);
    if (slot.widget.fillRect()) |fr| {
        _ = c.SDL_SetRenderDrawColor(renderer, fr.color.r, fr.color.g, fr.color.b, fr.color.a);
        _ = c.SDL_RenderFillRect(renderer, &fr.rect);
    }
    drawWidgetDecorations(slot.widget, renderer);
    if (clip != null) _ = c.SDL_SetRenderClipRect(renderer, null);
}

// M7: app identity, wasm location, and every capability an app needs
// (SQLite, network + allowed hosts, which widget kinds) now come from
// conf.natyv.json instead of CLI arguments -- a real install shouldn't
// require remembering flags to run someone else's app correctly. The one
// remaining CLI argument is the config file's own path, defaulting to
// `conf.natyv.json` in the current directory, purely for dev convenience
// (pointing at a different example without `cd`ing into it first).
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const argv = init.minimal.args.vector;
    const config_path: []const u8 = if (argv.len > 1) std.mem.span(argv[1]) else "conf.natyv.json";

    const config = Config.load(allocator, io, config_path) catch |err| {
        std.debug.print("[main] failed to load {s}: {}\n", .{ config_path, err });
        return err;
    };
    defer config.deinit();

    const config_dir = std.fs.path.dirname(config_path) orelse ".";
    const app_wasm_path = try std.fs.path.join(allocator, &.{ config_dir, config.value.app_wasm });
    defer allocator.free(app_wasm_path);

    const app_name_z = try allocator.dupeZ(u8, config.value.name);
    defer allocator.free(app_name_z);

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    // F2: the bundled default font (Inter) -- unconditional, not gated by
    // conf.natyv.json, since every app gets it regardless (see the
    // font-rendering plan). Not consumed yet -- that's F3, which swaps
    // every SDL_RenderDebugText call site over to real glyph rendering.
    var default_font = try Font.init();
    defer default_font.deinit();

    var db_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var db_path: ?[:0]const u8 = null;
    if (config.value.sqlite.enabled) {
        const pref_path_c = c.SDL_GetPrefPath("natyv", app_name_z.ptr) orelse {
            std.debug.print("SDL_GetPrefPath failed: {s}\n", .{c.SDL_GetError()});
            return error.PrefPathFailed;
        };
        defer c.SDL_free(pref_path_c);
        const pref_path = std.mem.span(pref_path_c);
        db_path = std.fmt.bufPrintZ(&db_path_buf, "{s}{s}", .{ pref_path, config.value.sqlite.filename }) catch {
            std.debug.print("[main] db path too long\n", .{});
            return error.PathTooLong;
        };
    }

    std.debug.print("[main] app: {s} ({s})\n[main] database: {s}\n", .{ config.value.name, app_wasm_path, db_path orelse "(sqlite disabled)" });

    const wasm = std.Io.Dir.cwd().readFileAlloc(io, app_wasm_path, allocator, .unlimited) catch |err| {
        std.debug.print("[main] failed to read {s}: {}\n", .{ app_wasm_path, err });
        return err;
    };
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, db_path);
    defer runtime.deinit();

    const manifest: Manifest = .{ .allowed_hosts = if (config.value.network.enabled) config.value.network.allowed_hosts else &.{} };
    const widget_kinds: WidgetHost.EnabledKinds = .{
        .button = config.value.widgets.button,
        .textfield = config.value.widgets.textfield,
        .textarea = config.value.widgets.textarea,
        .label = config.value.widgets.label,
        .checkbox = config.value.widgets.checkbox,
        .toggle = config.value.widgets.toggle,
        .radio_button = config.value.widgets.radio_button,
        .progress_bar = config.value.widgets.progress_bar,
        .slider = config.value.widgets.slider,
        .divider = config.value.widgets.divider,
        .badge = config.value.widgets.badge,
        .numeric_stepper = config.value.widgets.numeric_stepper,
        .segmented_control = config.value.widgets.segmented_control,
    };
    const clay_enabled = if (config.value.ui.backend) |backend| std.mem.eql(u8, backend, "clay") else false;
    try runtime.loadPlugin(wasm, manifest, widget_kinds, clay_enabled);
    runtime.initGuest(io);

    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    const worker = try std.Thread.spawn(.{}, Dispatch.run, .{ &runtime, io, &queue });

    // W23: see FileDialogCallbackContext's own doc comment -- reused across
    // every dialog request, address stable for main()'s whole lifetime.
    var file_dialog_ctx: FileDialogCallbackContext = undefined;

    const window = c.SDL_CreateWindow(app_name_z.ptr, 900, 700, 0) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindowFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlRendererFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    // F3: one renderer-backed text engine for the app's lifetime -- every
    // widget's cached TTF_Text is created against this. SDL_ttf requires
    // every TTF_Text be destroyed before the engine that made it, so
    // `destroyAllTextObjects`'s defer is declared *after* this one --
    // Zig's LIFO defer order means it runs first at shutdown, same
    // ordering fix Clay's global-context clearing needed in L4.
    const text_engine = c.TTF_CreateRendererTextEngine(renderer) orelse {
        std.debug.print("TTF_CreateRendererTextEngine failed: {s}\n", .{c.SDL_GetError()});
        return error.TextEngineFailed;
    };
    defer c.TTF_DestroyRendererTextEngine(text_engine);
    defer runtime.widgets.destroyAllTextObjects(io);

    // L4: `null` when ui.backend isn't "clay" -- no arena allocated, no
    // per-frame Clay calls at all, same "capability you didn't declare
    // costs you nothing" story as sqlite/network above.
    var maybe_clay_layout: ?ClayLayout = if (clay_enabled) try ClayLayout.init(allocator, 900, 700, default_font.font) else null;
    defer if (maybe_clay_layout) |*cl| cl.deinit(allocator);

    const arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
    defer if (arrow_cursor) |cur| c.SDL_DestroyCursor(cur);
    const pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
    defer if (pointer_cursor) |cur| c.SDL_DestroyCursor(cur);
    var cursor_is_pointer = false;

    var focused_widget_id: ?u32 = null;
    // W3: which slider (if any) is currently being dragged -- set on
    // MOUSE_BUTTON_DOWN when the click lands on a slider, cleared
    // unconditionally on MOUSE_BUTTON_UP regardless of where the mouse
    // currently is (standard drag semantics: releasing outside the widget's
    // bounds still ends the drag). Not stored on the widget itself, same
    // "main.zig owns interaction state, WidgetHost owns widget state"
    // split `focused_widget_id` already establishes.
    var dragging_slider_id: ?u32 = null;
    // W27: which handle `dragging_slider_id` (above) is currently moving,
    // when it names a RangeSlider -- see tryHitWidget's own doc comment for
    // why this can't just be read back from the widget itself via
    // `widget_snapshot` in the same frame it was chosen.
    var dragging_range_handle: ?RangeSlider.Handle = null;

    // W15: which widget (if any) the mouse is currently continuously over,
    // when that hover started, and which widget (if any) we've already
    // fired `.hover true` for -- `tooltip_active_for` is tracked
    // separately from `hovered_widget_id` so hover-out only ever fires
    // `.hover false` for a widget that actually crossed the threshold and
    // got a `true` sent, never for one the mouse merely brushed past.
    var hovered_widget_id: ?u32 = null;
    var hover_start_ms: ?i64 = null;
    var tooltip_active_for: ?u32 = null;

    std.debug.print("[main] window open -- close it to quit.\n", .{});

    var running = true;
    var widget_snapshot: [max_widgets_on_screen]WidgetHost.Slot = undefined;
    var clip_rects: [max_widgets_on_screen]?c.SDL_FRect = undefined;
    // W4: whether each widget is itself floating or nested under a
    // floating ancestor (e.g. a dropdown's options panel and its rows) --
    // computed once per frame, used both to give floating content priority
    // in mouse hit-testing and to draw it in its own pass on top of
    // everything else. See FloatingOrder.zig.
    var is_floating: [max_widgets_on_screen]bool = undefined;
    var draw_batcher: DrawBatcher = .{};
    // W5: the topmost currently-open modal's widget id (see
    // FloatingOrder.topmostModalRoot), recomputed once per frame alongside
    // is_floating. Gates the hit-test/keyboard input-blocking restructure
    // and the backdrop draw pass below -- null means "no modal open,
    // behave exactly as before W5."
    var topmost_modal: ?u32 = null;

    // W2: accumulated per-frame wheel delta, in pixels (already scaled from
    // SDL's raw wheel "notch" units), consumed by layoutIfNeeded at the top
    // of the *next* frame then reset -- the poll loop that discovers wheel
    // events runs after layoutIfNeeded's call site (see the ordering note
    // below), so this is a deliberate one-frame lag, same idea as
    // EventQueue's own "drain once per frame" discrete-event handling
    // elsewhere in this codebase.
    var pending_scroll_dx: f32 = 0;
    var pending_scroll_dy: f32 = 0;
    // Pixels of scroll per SDL wheel "notch" (event.wheel.x/y), before
    // Clay's own internal *10 multiplier on top of that (see
    // Clay_UpdateScrollContainers) -- tuned so one notch moves roughly one
    // bookstore row (~38px), not a token amount.
    const wheel_pixels_per_notch: f32 = 4.0;

    while (running) {
        var mouse_x: f32 = undefined;
        var mouse_y: f32 = undefined;
        const mouse_buttons = c.SDL_GetMouseState(&mouse_x, &mouse_y);

        // Must run before this frame's snapshot below, not after -- so
        // that if a real Clay recompute happens this frame, the freshly
        // written-back `rect`s are what the rest of the frame (hit-testing,
        // hover, drawing) actually sees, not last frame's stale ones.
        // Tree view: `scrolled_ids` collects which scroll containers (if
        // any) actually moved this pass -- pushed as `.scroll` events below,
        // once `widget_snapshot` (needed for each one's real surface_id) is
        // available.
        var scrolled_ids: [WidgetHost.max_widgets]u32 = undefined;
        var scrolled_count: usize = 0;
        if (maybe_clay_layout) |*clay_layout| {
            var win_w: c_int = undefined;
            var win_h: c_int = undefined;
            _ = c.SDL_GetWindowSize(window, &win_w, &win_h);
            scrolled_count = clay_layout.layoutIfNeeded(&runtime.widgets, io, @floatFromInt(win_w), @floatFromInt(win_h), mouse_x, mouse_y, (mouse_buttons & c.SDL_BUTTON_LMASK) != 0, pending_scroll_dx, pending_scroll_dy, &scrolled_ids);
        }
        pending_scroll_dx = 0;
        pending_scroll_dy = 0;

        // F3: a guest destroying a widget (natyv_destroy_widget, called on
        // the worker thread inside natyv_dispatch) can't destroy its
        // TTF_Text right then -- that's only valid on the thread that
        // created it. It queues the pointer instead; this is the main
        // thread actually freeing it, once per frame. Must run before
        // syncTextObjects below in case a widget was destroyed and a new
        // one with the same generation-counter state gets created in its
        // place within the same guest call.
        runtime.widgets.flushPendingTextDestroys(io);

        // W7: destroys any widget (and cascades to its descendants -- see
        // destroyExpiredWidgets's doc comment) whose expiry has passed --
        // e.g. a toast that's been showing long enough. Same "must run
        // before syncTextObjects/snapshot" ordering as the flush above,
        // for the same reason.
        runtime.widgets.destroyExpiredWidgets(io, timing.nowMs());

        // F3: same "mutate the live registry, then snapshot sees the fresh
        // result" ordering as layoutIfNeeded above -- must run before
        // snapshot so a widget created or re-labeled this frame already has
        // a real (or updated) TTF_Text by the time drawDecorations reads it.
        runtime.widgets.syncTextObjects(io, text_engine, default_font.font);

        const widget_count = runtime.widgets.snapshot(io, &widget_snapshot);

        // Scroll-into-view: the one safe place to touch Clay's live scroll
        // offset for a guest-requested natyv_scroll_into_view -- main
        // thread, after this frame's layoutIfNeeded/snapshot have already
        // resolved fresh rects, see WidgetHost.pending_scroll_into_view's
        // doc comment for why this can't happen inside the host function
        // itself (worker thread). Only ever non-null when the Clay backend
        // is enabled (natyv_scroll_into_view is Clay-only, see
        // registerClayInto), so no extra `maybe_clay_layout` guard needed
        // here.
        if (runtime.widgets.takePendingScrollIntoView(io)) |scroll_target_id| {
            ClayLayout.applyScrollIntoView(widget_snapshot[0..widget_count], &runtime.widgets, scroll_target_id);
        }

        // File picker: the one safe place to call SDL_ShowOpenFileDialog/
        // SDL_ShowSaveFileDialog for a guest-requested
        // natyv_show_open_file_dialog/natyv_show_save_file_dialog -- main
        // thread, per SDL's own documented \threadsafety. See
        // WidgetHost.pending_file_dialog_request's own doc comment for why
        // this can't happen inside the host function itself (worker
        // thread), and FileDialogCallbackContext's for how the eventual
        // result gets back to the guest.
        if (runtime.widgets.takePendingFileDialogRequest(io)) |req| {
            file_dialog_ctx = .{
                .io = io,
                .queue = &queue,
                .widget_id = req.widget_id,
                .surface_id = FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], req.widget_id),
            };
            switch (req.kind) {
                .open => c.SDL_ShowOpenFileDialog(fileDialogCallback, &file_dialog_ctx, window, null, 0, null, req.allow_many),
                .save => c.SDL_ShowSaveFileDialog(fileDialogCallback, &file_dialog_ctx, window, null, 0, null),
            }
        }

        // Tree view: a real `.scroll` push for each scroll container
        // `layoutIfNeeded` reported above -- same `surface_id` lookup and
        // JSON-building shape every other `notifyXValue` helper already
        // uses, just inlined here since it needs `scrolled_ids` from
        // outside `widget_snapshot`'s own scope, not a widget-kind-specific
        // value.
        for (scrolled_ids[0..scrolled_count]) |scrolled_id| {
            for (widget_snapshot[0..widget_count]) |slot| {
                if (slot.id != scrolled_id) continue;
                const sd = slot.scroll_data orelse break;
                var buf: [64]u8 = undefined;
                const json = std.fmt.bufPrint(&buf, "{{\"scroll_offset_x\":{d},\"scroll_offset_y\":{d}}}", .{ sd.scroll_offset_x, sd.scroll_offset_y }) catch "{}";
                queue.push(io, scrolled_id, .scroll, json, FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], scrolled_id));
                break;
            }
        }

        // W4: computed here, before the event loop below, since
        // MOUSE_BUTTON_DOWN's hit-testing needs it this same frame.
        FloatingOrder.computeIsFloating(widget_snapshot[0..widget_count], is_floating[0..widget_count]);
        topmost_modal = FloatingOrder.topmostModalRoot(widget_snapshot[0..widget_count]);

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        const mx = event.button.x;
                        const my = event.button.y;
                        // Keyboard interaction model: a click now focuses
                        // whatever it hits (button or textfield, not just
                        // textfield as before) so Tab-navigation picks up
                        // naturally from wherever the mouse last landed.
                        // Buttons still fire immediately on click, same as
                        // before -- focusing them is additional, not a
                        // replacement for that.
                        var hit_focusable: ?u32 = null;

                        if (topmost_modal) |modal_id| {
                            // W5: a modal blocks input to everything outside
                            // its own subtree -- unlike Dropdown's "miss
                            // falls through to normal content" behavior, a
                            // miss here is fully consumed (no fallback to
                            // any other floating or normal-content pass at
                            // all).
                            //
                            // W5 follow-up (Quinn's real click-through
                            // feedback, 2026-08-17): a backdrop-click miss
                            // never fires `.dismiss` -- it only blocks, full
                            // stop. Quinn: "for a modal, backdrop clicking
                            // shouldn't close ever... only ever block, i
                            // think that's more idiomatic of modals." Escape
                            // (below) and a guest-declared close Button
                            // inside the modal are the only two ways to
                            // close one.
                            for (widget_snapshot[0..widget_count]) |slot| {
                                if (!FloatingOrder.isDescendantOfOrSelf(widget_snapshot[0..widget_count], slot.id, modal_id)) continue;
                                if (tryHitWidget(&runtime.widgets, io, &queue, widget_snapshot[0..widget_count], slot, mx, my, &dragging_slider_id, &dragging_range_handle)) |id| hit_focusable = id;
                            }
                        } else {
                            // W4: floating content (e.g. an open dropdown's
                            // options panel) draws on top of everything else
                            // (see the floating draw pass below), so it must
                            // also claim clicks first -- checked in its own
                            // pass, and if anything floating was hit, the
                            // normal pass is skipped entirely so a click on a
                            // floating option can't also fire whatever's
                            // visually underneath it.
                            //
                            // W9 follow-up (Quinn's real click-through
                            // feedback): a real gap, not just Menu-specific --
                            // several floating subtrees can be open at once
                            // (e.g. Menu's submenu, stacked on top of its own
                            // still-open parent panel) and, since
                            // `WidgetHost.slots` is a fixed-size array reused
                            // first-fit on destroy, a widget's position in
                            // this snapshot has *no* relationship to creation
                            // order -- so simply running every floating
                            // widget's `tryHitWidget` in snapshot order could
                            // fire a real, side-effecting `.click` for *both*
                            // an overlapping submenu item and whatever
                            // top-level item sits underneath it at the same
                            // point, not just whichever happened to match
                            // last. Fixed with a pure pre-scan (no side
                            // effects -- see `widgetContainsPoint`) that finds
                            // the highest `nearestFloatingRoot` among floating
                            // widgets the click point actually lands on
                            // (`FloatingOrder.nearestFloatingRoot`'s doc
                            // comment: higher id = opened more recently = the
                            // topmost overlapping subtree), then only that
                            // subtree's widgets go through the real,
                            // side-effecting `tryHitWidget` pass below -- a
                            // widget belonging to a lower (older) floating
                            // root that happens to geometrically overlap the
                            // click point is skipped entirely, not just
                            // outrun by a later match.
                            var topmost_floating_root: ?u32 = null;
                            for (widget_snapshot[0..widget_count], is_floating[0..widget_count]) |slot, floating| {
                                if (!floating) continue;
                                if (!widgetContainsPoint(slot.widget, mx, my)) continue;
                                const root = FloatingOrder.nearestFloatingRoot(widget_snapshot[0..widget_count], slot.id) orelse continue;
                                if (topmost_floating_root == null or root > topmost_floating_root.?) topmost_floating_root = root;
                            }
                            for (widget_snapshot[0..widget_count], is_floating[0..widget_count]) |slot, floating| {
                                if (!floating) continue;
                                if (topmost_floating_root) |root| {
                                    if (FloatingOrder.nearestFloatingRoot(widget_snapshot[0..widget_count], slot.id) != root) continue;
                                }
                                if (tryHitWidget(&runtime.widgets, io, &queue, widget_snapshot[0..widget_count], slot, mx, my, &dragging_slider_id, &dragging_range_handle)) |id| hit_focusable = id;
                            }
                            if (hit_focusable == null) {
                                for (widget_snapshot[0..widget_count], is_floating[0..widget_count]) |slot, floating| {
                                    if (floating) continue;
                                    if (tryHitWidget(&runtime.widgets, io, &queue, widget_snapshot[0..widget_count], slot, mx, my, &dragging_slider_id, &dragging_range_handle)) |id| hit_focusable = id;
                                }
                            }
                        }
                        updateFocus(&runtime.widgets, io, window, &queue, widget_snapshot[0..widget_count], &focused_widget_id, hit_focusable);
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    // W3: ends the drag unconditionally, regardless of
                    // where the mouse currently is -- standard drag
                    // semantics (releasing outside the widget's bounds
                    // still stops it).
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        dragging_slider_id = null;
                        dragging_range_handle = null;
                    }
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    if (focused_widget_id) |id| {
                        var text_buf: [max_text_widget_len]u8 = undefined;
                        if (runtime.widgets.appendTextTo(io, id, std.mem.span(event.text.text), &text_buf)) |n| {
                            notifyTextChanged(&queue, io, id, text_buf[0..n], widget_snapshot[0..widget_count]);
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    // Not negated: confirmed against real hardware (Quinn's
                    // click-through) that Clay's scrollPosition should move
                    // directly with SDL's raw wheel.x/y sign, not inverted.
                    // The original negation was based on a scroll-convention
                    // assumption that turned out backwards in practice.
                    pending_scroll_dx += event.wheel.x * wheel_pixels_per_notch;
                    pending_scroll_dy += event.wheel.y * wheel_pixels_per_notch;
                },
                c.SDL_EVENT_KEY_DOWN => switch (event.key.key) {
                    c.SDLK_BACKSPACE => if (focused_widget_id) |id| {
                        var text_buf: [max_text_widget_len]u8 = undefined;
                        if (runtime.widgets.backspaceOn(io, id, &text_buf)) |n| {
                            notifyTextChanged(&queue, io, id, text_buf[0..n], widget_snapshot[0..widget_count]);
                        }
                    },
                    c.SDLK_TAB => {
                        var focusable_ids: [max_widgets_on_screen]u32 = undefined;
                        const focusable_count = runtime.widgets.focusableIdsSorted(io, &focusable_ids);
                        const forward = (event.key.mod & c.SDL_KMOD_SHIFT) == 0;
                        const next = WidgetHost.nextFocusable(focusable_ids[0..focusable_count], focused_widget_id, forward);
                        updateFocus(&runtime.widgets, io, window, &queue, widget_snapshot[0..widget_count], &focused_widget_id, next);
                    },
                    c.SDLK_RETURN, c.SDLK_KP_ENTER, c.SDLK_SPACE => {
                        // Activates a focused Button/Checkbox/RadioButton --
                        // a focused TextField never reaches here for Space,
                        // since that's delivered as literal text via
                        // SDL_EVENT_TEXT_INPUT instead, not this key-down
                        // path. `activateWidget` itself no-ops for any kind
                        // that isn't activatable.
                        if (focused_widget_id) |id| {
                            for (widget_snapshot[0..widget_count]) |slot| {
                                if (slot.id == id) {
                                    activateWidget(&runtime.widgets, io, &queue, id, std.meta.activeTag(slot.widget), FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id));
                                    // W6: Enter (not Space -- that must keep
                                    // inserting a literal space) additionally
                                    // signals "select the highlighted
                                    // combobox option" when the focused
                                    // widget is a textfield -- activateWidget
                                    // itself no-ops for .textfield, this is
                                    // genuinely additional, not a replacement.
                                    if (slot.widget == .textfield and event.key.key != c.SDLK_SPACE) {
                                        queue.push(io, id, .key_nav, "{\"key\":\"enter\"}", FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id));
                                    }
                                    // W10: Enter on a focused TextArea
                                    // inserts a literal newline instead --
                                    // completely independent of the
                                    // TextField-only key_nav "enter" case
                                    // above (a TextArea never fires
                                    // key_nav at all). Space is excluded
                                    // the same way TextField's is: a
                                    // focused TextArea already receives a
                                    // literal space via SDL_EVENT_TEXT_INPUT,
                                    // this path would double it.
                                    if (slot.widget == .textarea and event.key.key != c.SDLK_SPACE) {
                                        var text_buf: [max_text_widget_len]u8 = undefined;
                                        if (runtime.widgets.appendTextTo(io, id, "\n", &text_buf)) |n| {
                                            notifyTextChanged(&queue, io, id, text_buf[0..n], widget_snapshot[0..widget_count]);
                                        }
                                    }
                                }
                            }
                        }
                    },
                    // W5: Escape dismisses the topmost open modal instead of
                    // clearing focus -- same `.dismiss`-and-let-the-guest-
                    // decide treatment as a backdrop click above. Focus is
                    // deliberately left alone (a dismiss isn't a guaranteed
                    // close). When no modal is open, unchanged.
                    c.SDLK_ESCAPE => if (topmost_modal) |modal_id| {
                        queue.push(io, modal_id, .dismiss, "", FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], modal_id));
                    } else {
                        updateFocus(&runtime.widgets, io, window, &queue, widget_snapshot[0..widget_count], &focused_widget_id, null);
                    },
                    // W3: nudges the *focused* widget's value if it's a
                    // slider -- confirmed unbound by anything else in this
                    // switch today, so safe to add unconditionally; a no-op
                    // when nothing focused or the focused widget isn't a
                    // slider (`notifySliderValue`/`setSliderValue` both
                    // handle that, see their doc comments). Left/Right were
                    // split off from Down/Up (W6, previously grouped
                    // together as "decrement"/"increment") so Down/Up alone
                    // could *also* mean "move the highlight" for a focused
                    // textfield (Combobox, W6) or Button (Menu, W9),
                    // without Left/Right picking up that meaning too.
                    //
                    // W17: extended to also adjust a focused NumericStepper/
                    // SegmentedControl (same "arrow keys move the value"
                    // shape as Slider, just integer-valued/index-valued),
                    // and -- separately -- to push `.key_nav` for a focused
                    // plain Button, exactly mirroring how SDLK_DOWN/SDLK_UP
                    // below were widened to cover focused Buttons in W9.
                    // This is what lets the Date & time picker's month
                    // prev/next buttons respond to Left/Right without any
                    // new host concept: the guest just handles `key_nav`
                    // "left"/"right" for the two button ids it cares about
                    // and ignores it for every other focused Button.
                    c.SDLK_LEFT => if (focused_widget_id) |id| {
                        for (widget_snapshot[0..widget_count]) |slot| {
                            const surface_id = FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id);
                            if (slot.id != id) continue;
                            switch (slot.widget) {
                                .slider => |s| notifySliderValue(&runtime.widgets, io, &queue, id, s.value - Slider.nudge_step, surface_id),
                                // W27: nudges whichever handle is currently
                                // active (see RangeSlider.active_handle's
                                // own doc comment) -- notifyRangeSliderValue
                                // itself updates active_handle too, but it's
                                // already this same handle, a no-op change.
                                .range_slider => |rs| notifyRangeSliderValue(&runtime.widgets, io, &queue, id, rs.active_handle, rs.activeValue() - rs.nudgeAmount(), surface_id),
                                .numeric_stepper => |ns| notifyStepperValue(&runtime.widgets, io, &queue, id, ns.value - ns.step, surface_id),
                                .segmented_control => |sc| notifySegmentedValue(&runtime.widgets, io, &queue, id, if (sc.selected_index > 0) sc.selected_index - 1 else 0, surface_id),
                                // W19: same clamped (non-wrapping) ±1 shape
                                // as SegmentedControl.
                                .tabs => |tb| notifyTabsValue(&runtime.widgets, io, &queue, id, if (tb.selected_index > 0) tb.selected_index - 1 else 0, surface_id),
                                .button => queue.push(io, id, .key_nav, "{\"key\":\"left\"}", surface_id),
                                else => {},
                            }
                        }
                    },
                    c.SDLK_RIGHT => if (focused_widget_id) |id| {
                        for (widget_snapshot[0..widget_count]) |slot| {
                            const surface_id = FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id);
                            if (slot.id != id) continue;
                            switch (slot.widget) {
                                .slider => |s| notifySliderValue(&runtime.widgets, io, &queue, id, s.value + Slider.nudge_step, surface_id),
                                .range_slider => |rs| notifyRangeSliderValue(&runtime.widgets, io, &queue, id, rs.active_handle, rs.activeValue() + rs.nudgeAmount(), surface_id),
                                .numeric_stepper => |ns| notifyStepperValue(&runtime.widgets, io, &queue, id, ns.value + ns.step, surface_id),
                                .segmented_control => |sc| notifySegmentedValue(&runtime.widgets, io, &queue, id, sc.selected_index + 1, surface_id),
                                .tabs => |tb| notifyTabsValue(&runtime.widgets, io, &queue, id, tb.selected_index + 1, surface_id),
                                .button => queue.push(io, id, .key_nav, "{\"key\":\"right\"}", surface_id),
                                else => {},
                            }
                        }
                    },
                    c.SDLK_DOWN => if (focused_widget_id) |id| {
                        for (widget_snapshot[0..widget_count]) |slot| {
                            if (slot.id == id and slot.widget == .slider) {
                                notifySliderValue(&runtime.widgets, io, &queue, id, slot.widget.slider.value - Slider.nudge_step, FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id));
                            } else if (slot.id == id and slot.widget == .range_slider) {
                                const rs = slot.widget.range_slider;
                                notifyRangeSliderValue(&runtime.widgets, io, &queue, id, rs.active_handle, rs.activeValue() - rs.nudgeAmount(), FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id));
                            } else if (slot.id == id and (slot.widget == .textfield or slot.widget == .button)) {
                                // W9: widened from textfield-only (W6, for
                                // Combobox) to also cover a focused Button
                                // -- a Menu trigger or submenu-triggering
                                // item uses this exact same mechanism to
                                // move its own highlight, no new host
                                // concept needed.
                                queue.push(io, id, .key_nav, "{\"key\":\"down\"}", FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id));
                            }
                        }
                    },
                    c.SDLK_UP => if (focused_widget_id) |id| {
                        for (widget_snapshot[0..widget_count]) |slot| {
                            if (slot.id == id and slot.widget == .slider) {
                                notifySliderValue(&runtime.widgets, io, &queue, id, slot.widget.slider.value + Slider.nudge_step, FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id));
                            } else if (slot.id == id and slot.widget == .range_slider) {
                                const rs = slot.widget.range_slider;
                                notifyRangeSliderValue(&runtime.widgets, io, &queue, id, rs.active_handle, rs.activeValue() + rs.nudgeAmount(), FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id));
                            } else if (slot.id == id and (slot.widget == .textfield or slot.widget == .button)) {
                                queue.push(io, id, .key_nav, "{\"key\":\"up\"}", FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id));
                            }
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }

        // W3: per-frame slider drag update -- runs after the event-poll
        // loop above (so `dragging_slider_id` set earlier this same frame,
        // on the initial click, is already visible here), using the
        // already-polled `mouse_x`/`mouse_y` from the top of the loop
        // rather than a dedicated MOUSE_MOTION handler. This one block
        // covers both "jump to click position" and "continue following the
        // drag" -- no separate code path needed for the click-to-jump case.
        if (dragging_slider_id) |id| {
            for (widget_snapshot[0..widget_count]) |slot| {
                if (slot.id == id and slot.widget == .slider) {
                    notifySliderValue(&runtime.widgets, io, &queue, id, slot.widget.slider.valueFromX(mouse_x), FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id));
                } else if (slot.id == id and slot.widget == .range_slider) {
                    // W27: moves whichever handle tryHitWidget's mouse-down
                    // resolved as active (RangeSlider.closestHandle) --
                    // valueFromX itself is handle-agnostic (see its own doc
                    // comment), setRangeSliderValue does the real clamping.
                    // Reads `dragging_range_handle`, NOT
                    // `slot.widget.range_slider.active_handle` -- see
                    // tryHitWidget's own doc comment for the same-frame
                    // staleness bug that distinction fixes (a real one,
                    // Quinn's own click-through caught it).
                    const handle = dragging_range_handle orelse slot.widget.range_slider.active_handle;
                    notifyRangeSliderValue(&runtime.widgets, io, &queue, id, handle, slot.widget.range_slider.valueFromX(mouse_x), FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id));
                }
            }
        }

        var hovering_any = false;
        // W15: which widget (if any) the mouse is over this frame, for the
        // hover-hold timer below -- only the kinds that already have a
        // `containsPoint` (the same set `hovering_any` already covers) can
        // be a tooltip anchor; other kinds (Label/Container/ProgressBar/
        // Divider/Badge) don't have one yet, a deliberate v1 scope limit.
        var hovered_widget_id_this_frame: ?u32 = null;
        for (widget_snapshot[0..widget_count]) |slot| {
            // W5 follow-up (Quinn's real click-through feedback,
            // 2026-08-17): when a modal is open, a widget outside its
            // subtree can't actually be clicked (see the input-blocking
            // hit-test above) -- showing the pointer cursor over it anyway
            // would be misleading, implying it's clickable when it isn't.
            // Same scoping the click-blocking hit-test uses.
            if (topmost_modal) |modal_id| {
                if (!FloatingOrder.isDescendantOfOrSelf(widget_snapshot[0..widget_count], slot.id, modal_id)) continue;
            }
            // W19: a hidden Tabs panel (or its content) shouldn't register
            // hover/pointer-cursor -- same reasoning as tryHitWidget's own
            // `visible` skip, ancestor-aware for the same reason.
            if (!WidgetHost.isEffectivelyVisible(widget_snapshot[0..widget_count], slot)) continue;
            switch (slot.widget) {
                .button => |b| if (b.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                },
                .textfield => |t| if (t.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                },
                .textarea => |ta| if (ta.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                },
                .checkbox => |cb| if (cb.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                },
                .toggle => |tg| if (tg.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                },
                .radio_button => |r| if (r.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                },
                .slider => |s| if (s.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                },
                .range_slider => |rs| if (rs.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                },
                .numeric_stepper => |ns| if (ns.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                },
                .segmented_control => |sc| if (sc.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                },
                .tabs => |tb| if (tb.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                    hovered_widget_id_this_frame = slot.id;
                },
                .label => {},
                .container => {},
                .progress_bar => {},
                .divider => {},
                .badge => {},
                .spinner => {},
            }
        }
        if (hovering_any != cursor_is_pointer) {
            cursor_is_pointer = hovering_any;
            _ = c.SDL_SetCursor(if (hovering_any) pointer_cursor else arrow_cursor);
        }

        // W15: hover-hold timer -- reports a `.hover` state transition to
        // the guest, not a continuous stream. If the hovered widget
        // changed (including becoming/leaving null), close out any
        // tooltip we'd actually opened for the *previous* one and reset
        // the timer for the new one. Otherwise, once the same widget has
        // been hovered continuously past the threshold, fire `.hover true`
        // exactly once (guarded by `tooltip_active_for` so it doesn't
        // refire every subsequent frame).
        if (hovered_widget_id_this_frame != hovered_widget_id) {
            if (tooltip_active_for) |active_id| {
                if (hovered_widget_id) |prev_id| {
                    if (active_id == prev_id) {
                        queue.push(io, prev_id, .hover, "{\"hovering\":false}", FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], prev_id));
                    }
                }
                tooltip_active_for = null;
            }
            hovered_widget_id = hovered_widget_id_this_frame;
            hover_start_ms = if (hovered_widget_id_this_frame != null) timing.nowMs() else null;
        } else if (hovered_widget_id_this_frame) |id| {
            if (hover_start_ms) |start| {
                const already_active = if (tooltip_active_for) |active_id| active_id == id else false;
                if (timing.nowMs() - start >= tooltip_hover_threshold_ms and !already_active) {
                    queue.push(io, id, .hover, "{\"hovering\":true}", FloatingOrder.surfaceIdFor(widget_snapshot[0..widget_count], id));
                    tooltip_active_for = id;
                }
            }
        }

        // W2: computed once per frame -- for each widget, the rect it must
        // be visually clipped to (the intersection of every scroll-clipping
        // ancestor's rect up its parent chain), or null if none applies.
        // Clay already computed correct *positions* for a scroll
        // container's children via childOffset; this is the separate,
        // natyv-owned step of actually cropping their rendering, since Clay
        // has no opinion on how (or whether) natyv draws anything.
        ScrollClip.computeClipRects(widget_snapshot[0..widget_count], clip_rects[0..widget_count]);

        _ = c.SDL_SetRenderDrawColor(renderer, 24, 24, 28, 255);
        _ = c.SDL_RenderClear(renderer);

        // L4.5/W2: one SDL_RenderFillRects call per distinct fill color
        // across every *unclipped* widget -- see DrawBatcher.zig.
        // `draw_batcher` is declared outside the frame loop and reused
        // every frame purely to avoid re-zeroing its scratch arrays each
        // time; `flush` below resets it for the next frame regardless. A
        // widget with a non-null clip rect bypasses the batcher entirely
        // and is filled individually inside its own
        // SDL_SetRenderClipRect/null bracket -- DrawBatcher only ever
        // issues one draw color per call, so it can't represent "these N
        // rects share a color but need M different active clip rects."
        // Deliberately not extending the batcher for this: scroll-clipped
        // widgets are a minority of on-screen widgets in any real app (see
        // DrawBatcher.zig's own "tens, not thousands" framing), so a
        // less-batched path for just those is a reasonable trade over a
        // more complex (color, clip_rect) bucket key.
        for (widget_snapshot[0..widget_count], clip_rects[0..widget_count], is_floating[0..widget_count]) |slot, clip, floating| {
            // W4: floating content is drawn in its own pass below, after
            // draw_batcher.flush() -- it can't be interleaved into this
            // pass's immediate/batched fills, since anything the batcher
            // adds here only actually renders at flush() below, which
            // would then paint over an already-drawn floating widget.
            if (floating) continue;
            // W19: see tryHitWidget's own `visible` skip -- an invisible
            // slot's cached rect can go stale rather than zeroed, so don't
            // rely on it alone to keep a hidden Tabs panel from drawing.
            if (!WidgetHost.isEffectivelyVisible(widget_snapshot[0..widget_count], slot)) continue;
            if (slot.widget.fillRect()) |fr| {
                if (clip) |cr| {
                    const sdl_clip = toClipRect(cr);
                    _ = c.SDL_SetRenderClipRect(renderer, &sdl_clip);
                    _ = c.SDL_SetRenderDrawColor(renderer, fr.color.r, fr.color.g, fr.color.b, fr.color.a);
                    _ = c.SDL_RenderFillRect(renderer, &fr.rect);
                    _ = c.SDL_SetRenderClipRect(renderer, null);
                } else {
                    draw_batcher.add(fr.color, fr.rect);
                }
            }
        }
        draw_batcher.flush(renderer);

        for (widget_snapshot[0..widget_count], clip_rects[0..widget_count], is_floating[0..widget_count]) |slot, clip, floating| {
            if (floating) continue;
            if (!WidgetHost.isEffectivelyVisible(widget_snapshot[0..widget_count], slot)) continue;
            const sdl_clip: c.SDL_Rect = if (clip) |cr| toClipRect(cr) else undefined;
            if (clip != null) _ = c.SDL_SetRenderClipRect(renderer, &sdl_clip);
            drawWidgetDecorations(slot.widget, renderer);
            if (clip != null) _ = c.SDL_SetRenderClipRect(renderer, null);
        }

        // W4/W5: floating content (e.g. a dropdown's options panel and its
        // rows) drawn last among "real" widgets, after draw_batcher.flush()
        // above -- guarantees it renders on top of every normal widget
        // regardless of registry order, same "drawn last" precedent
        // ScrollBar's thumbs already established for W2. Unbatched and
        // fill-then-decorate per widget (not split into two sub-passes
        // like the normal content above) -- floating subtrees don't
        // overlap each other in practice, and are small (see
        // DrawBatcher.zig's own "tens, not thousands" framing), so there's
        // no real cost to the simpler per-widget draw here.
        //
        // W5: when a modal is open, this splits around a translucent
        // backdrop instead of running as one pass. Everything floating that
        // ISN'T inside the topmost modal draws first, so it (and, in a
        // nested-modal scenario, any earlier modal that isn't an ancestor
        // of the topmost one) gets correctly dimmed by the backdrop -- then
        // the topmost modal's own subtree draws on top of the backdrop,
        // undimmed.
        for (widget_snapshot[0..widget_count], clip_rects[0..widget_count], is_floating[0..widget_count]) |slot, clip, floating| {
            if (!floating) continue;
            if (!WidgetHost.isEffectivelyVisible(widget_snapshot[0..widget_count], slot)) continue;
            if (topmost_modal) |modal_id| {
                if (FloatingOrder.isDescendantOfOrSelf(widget_snapshot[0..widget_count], slot.id, modal_id)) continue;
            }
            drawFloatingWidget(slot, clip, renderer);
        }
        if (topmost_modal) |modal_id| {
            var win_w: c_int = undefined;
            var win_h: c_int = undefined;
            _ = c.SDL_GetWindowSize(window, &win_w, &win_h);
            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 140);
            const backdrop: c.SDL_FRect = .{ .x = 0, .y = 0, .w = @floatFromInt(win_w), .h = @floatFromInt(win_h) };
            _ = c.SDL_RenderFillRect(renderer, &backdrop);
            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);

            for (widget_snapshot[0..widget_count], clip_rects[0..widget_count], is_floating[0..widget_count]) |slot, clip, floating| {
                if (!floating) continue;
                if (!WidgetHost.isEffectivelyVisible(widget_snapshot[0..widget_count], slot)) continue;
                if (!FloatingOrder.isDescendantOfOrSelf(widget_snapshot[0..widget_count], slot.id, modal_id)) continue;
                drawFloatingWidget(slot, clip, renderer);
            }
        }

        // W2: scrollbar thumbs -- display-only position indicators (not
        // draggable, see ScrollBar.zig's doc comment) drawn last, on top of
        // everything else, one per scroll axis a Clay-managed container
        // declared. Drawn unclipped -- ScrollBar.zig insets the thumb inside
        // its own container's rect already, so it never needs cropping
        // against an ancestor's clip rect the way scrolled *content* does.
        if (maybe_clay_layout != null) {
            for (widget_snapshot[0..widget_count]) |slot| {
                if (!slot.clay_managed or slot.widget != .container) continue;
                if (!(slot.clay_style.scroll_vertical or slot.clay_style.scroll_horizontal)) continue;
                const data = ClayLayout.scrollContainerData(slot.id) orelse continue;
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
        }

        _ = c.SDL_RenderPresent(renderer);
    }

    std.debug.print("[main] window closed -- shutting down\n", .{});
    queue.requestShutdown(io);
    worker.join();
    std.debug.print("[main] clean shutdown\n", .{});
}
