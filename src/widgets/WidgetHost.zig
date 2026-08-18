//! Owns the live set of widgets a guest has created via
//! natyv_create_button/natyv_create_textfield, and the host functions that
//! let a guest create/read/write/destroy them. This is what makes the guest
//! -- not the host -- the author of the app's UI: main.zig's render loop
//! knows nothing about any particular app, it just draws whatever is
//! registered here.
//!
//! Thread safety: entries are written by host-function callbacks (running
//! on the worker thread, nested inside Runtime.call's extism_plugin_call)
//! and read/written every frame by the render loop (main thread, e.g. live
//! text-field editing). Both sides lock `mutex` (an `Io.Mutex`) around any
//! access -- but a host-function callback is a raw `callconv(.c)` function
//! called by the C ABI, which has no way to carry an `Io` parameter. Since
//! only one plugin call is ever in flight at a time, and every host
//! function invoked during that call runs synchronously nested inside it on
//! the same thread, `Runtime.call` stashes the `io` it was given into
//! `current_io` immediately before calling into the guest -- safe because
//! nothing else can read or write that field while a call is in progress.
//!
//! Wire contract (JSON both directions):
//!   natyv_create_button    in: {"x":f,"y":f,"w":f,"h":f,"label":"..."}
//!   natyv_create_textfield in: {"x":f,"y":f,"w":f,"h":f,"placeholder":"..."}
//!     both out: {"widget_id":N} | {"error":"..."}
//!   natyv_set_text  in: {"widget_id":N,"text":"..."}   out: {} | {"error":..}
//!   natyv_get_text  in: {"widget_id":N}                out: {"text":"..."} | {"error":..}
//!   natyv_destroy_widget in: {"widget_id":N}           out: {} | {"error":..}
//!
//! W1: three more widget kinds and the generic non-text-state accessors they
//! need (`natyv_set_text`/`natyv_get_text` are string-specific, not reusable
//! for a bool or a float):
//!   natyv_create_checkbox     in: {"x":f,"y":f,"w":f,"h":f,"label":"...","checked":bool}
//!   natyv_create_radio_button in: {"x":f,"y":f,"w":f,"h":f,"label":"...","group_id":N,"checked":bool}
//!   natyv_create_progressbar  in: {"x":f,"y":f,"w":f,"h":f,"value":f}
//!   natyv_create_slider       in: {"x":f,"y":f,"w":f,"h":f,"value":f}
//!     all out: {"widget_id":N} | {"error":"..."}
//!   natyv_set_checked in: {"widget_id":N,"checked":bool}  out: {} | {"error":..}
//!   natyv_get_checked in: {"widget_id":N}                 out: {"checked":bool} | {"error":..}
//!   natyv_set_value   in: {"widget_id":N,"value":f}       out: {} | {"error":..}
//!   natyv_get_value   in: {"widget_id":N}                 out: {"value":f} | {"error":..}
//!   (checked/value are no-ops, not errors, on a widget kind they don't
//!   apply to -- same "not an error, just doesn't apply" precedent
//!   natyv_set_text already sets for e.g. Container). Setting a radio
//!   button's checked to true deselects every other radio button sharing
//!   its group_id (see WidgetHost.selectRadioExclusive) -- setting it false
//!   just deselects it, no exclusivity to apply.
//!
//! L3: `natyv_clay_*` variants (only registered when conf.natyv.json's
//! `ui.backend == "clay"`) take a `layout` object instead of x/y/w/h --
//! under a Clay-managed parent, position/size become *computed output*
//! (via L4's per-frame layout pass), not guest-supplied input:
//!   natyv_clay_create_container    in: {"layout":{...}}
//!   natyv_clay_create_button       in: {"layout":{...},"label":"..."}
//!   natyv_clay_create_textfield    in: {"layout":{...},"placeholder":"..."}
//!   natyv_clay_create_label        in: {"layout":{...},"text":"..."}
//!   natyv_clay_create_checkbox     in: {"layout":{...},"label":"...","checked":bool}
//!   natyv_clay_create_radio_button in: {"layout":{...},"label":"...","group_id":N,"checked":bool}
//!   natyv_clay_create_progressbar  in: {"layout":{...},"value":f}
//!   natyv_clay_create_slider       in: {"layout":{...},"value":f}
//!     all out: {"widget_id":N} | {"error":"..."}
//!   layout: {"parent_id":N|null,
//!            "sizing":{"width":{"type":"fit"|"grow"|"fixed"|"percent","min":f,"max":f,"percent":f}, "height":{...}},
//!            "padding":{"left":u16,"right":u16,"top":u16,"bottom":u16},
//!            "child_gap":u16,
//!            "direction":"left_to_right"|"top_to_bottom",
//!            "child_alignment":{"x":"left"|"right"|"center","y":"top"|"bottom"|"center"},
//!            "scroll_vertical":bool,"scroll_horizontal":bool,"floating":bool}
//!   (every layout field is optional -- see ClayLayoutRequest defaults below)
//!   W2: scroll_vertical/scroll_horizontal clip a container's children to
//!   its own bounds and let mouse-wheel input scroll them -- only ever
//!   meaningful on a container with a bounded (non-fit-content) size.
//!   W4: floating layers this element (and its own children) on top of
//!   normal content instead of taking part in its parent's normal flex
//!   flow -- e.g. a dropdown's options panel, attached below whatever
//!   widget this one's parent_id names. See ClayLayout.zig's openChildren
//!   and FloatingOrder.zig for how position/draw-order/hit-testing work.
//!   natyv_set_text/natyv_get_text/natyv_set_checked/natyv_get_checked/
//!   natyv_set_value/natyv_get_value/natyv_destroy_widget all work unchanged
//!   on Clay-created widgets too, since they're the same underlying Widget
//!   union -- only how a widget's rect gets computed differs.
//!
//! W3: Slider is natyv's first *host-authoritative* interactive widget --
//! every kind above changes state because the guest called a
//! natyv_set_* function; a slider's value normally changes because of a
//! live mouse drag or arrow-key nudge main.zig owns, and the guest finds
//! out *after the fact* via a new EventQueue "change" event (see
//! EventQueue.zig), not by initiating the change itself. natyv_set_value/
//! natyv_get_value still work on a slider too (e.g. to set a default), same
//! as every other value-bearing kind -- the asymmetry is only in how the
//! *common* case (dragging) gets reported, not in the create/get/set wire
//! contract itself.
//!
//! W4: a dropdown/select needs no new widget kind or host function at all
//! -- it's composed entirely from existing kinds (a Button trigger, a
//! `floating: true` Container holding Button/Label option rows), the same
//! guest-authored-composition pattern RadioButton groups and bookstore's
//! book list already use. The only new surface is the `floating` layout
//! flag above.

const std = @import("std");
const Io = std.Io;
const c = @import("../c.zig").c;
const host_fn_util = @import("../host_fn_util.zig");
const timing = @import("../timing.zig");
const json_util = @import("../json_util.zig");
const Button = @import("Button.zig");
const TextField = @import("TextField.zig");
const TextArea = @import("TextArea.zig");
const Label = @import("Label.zig");
const Container = @import("Container.zig");
const Checkbox = @import("Checkbox.zig");
const Toggle = @import("Toggle.zig");
const RadioButton = @import("RadioButton.zig");
const ProgressBar = @import("ProgressBar.zig");
const Slider = @import("Slider.zig");
const Divider = @import("Divider.zig");
const Badge = @import("Badge.zig");
// The Extism host-function wire layer (natyv_create_*/natyv_clay_create_*
// callbacks and the generic set/get/destroy ones) lives in its own file --
// see WidgetHostFunctions.zig's doc comment for why, and for the mutual
// `@import` this creates (this file needs the callbacks' function pointers
// by name for registerInto/registerClayInto below; that file needs this
// one's registry-internal helpers).
const HostFunctions = @import("WidgetHostFunctions.zig");

const Self = @This();

/// W16: bumped from 64 -- a real calendar grid (Date & time picker) can
/// have ~60 widgets live at once at peak (week rows, day-number buttons,
/// leading blank spacer cells, weekday/month headers, time steppers), and
/// clay-fixture's own natyv_init already creates ~29 on top of that before
/// the picker is even opened. Every other fixed-size array in the codebase
/// keyed to widget count (DrawBatcher.zig, ClayLayout.zig's snapshot
/// buffer, the expiry-cascade buffers below) derives from this one
/// constant, so this is the only line that needs to change. Memory cost is
/// trivial (a few more KB across small fixed-size arrays of small
/// structs) -- a deliberate, explained bump per
/// feedback_natyv_memory_efficiency's own "as new widgets/capabilities
/// land" anticipation, not organic creep.
pub const max_widgets = 128;
// button/textfield/label create, set_text, get_text, destroy_widget (6) +
// checkbox/radio_button/progress_bar create (3) + get_checked/set_checked/
// get_value/set_value (4) -- W1 widget breadth. + slider create (1) -- W3.
// + textarea create (1) -- W10 (natyv_clay_create_textarea is counted
// separately in registerClayInto's own clay_host_function_count).
// + divider create (1) -- W11, same natyv_clay_create_divider split.
// + toggle create (1) -- W12, same natyv_clay_create_toggle split. Reuses
// the existing natyv_set_checked/natyv_get_checked host functions (no new
// ones needed for those), same as radio_button already does.
// + badge create (1) -- W14, same natyv_clay_create_badge split.
pub const host_function_count = 18;

pub const WidgetKind = enum { button, textfield, textarea, label, container, checkbox, toggle, radio_button, progress_bar, slider, divider, badge };
pub const Widget = union(WidgetKind) {
    button: Button,
    textfield: TextField,
    textarea: TextArea,
    label: Label,
    container: Container,
    checkbox: Checkbox,
    toggle: Toggle,
    radio_button: RadioButton,
    progress_bar: ProgressBar,
    slider: Slider,
    divider: Divider,
    badge: Badge,

    /// Every variant has its own `rect: c.SDL_FRect` field -- this gets a
    /// pointer to whichever one is active, regardless of kind. L4 uses this
    /// to write Clay's computed geometry back into the registry each frame
    /// without a kind-specific switch at every call site.
    pub fn rectPtr(self: *Widget) *c.SDL_FRect {
        return switch (self.*) {
            .button => |*b| &b.rect,
            .textfield => |*t| &t.rect,
            .textarea => |*ta| &ta.rect,
            .label => |*l| &l.rect,
            .container => |*co| &co.rect,
            .checkbox => |*cb| &cb.rect,
            .toggle => |*tg| &tg.rect,
            .radio_button => |*r| &r.rect,
            .progress_bar => |*p| &p.rect,
            .slider => |*s| &s.rect,
            .divider => |*d| &d.rect,
            .badge => |*bd| &bd.rect,
        };
    }

    /// L4.5: the solid-color background fill this widget wants drawn this
    /// frame, or `null` if it doesn't have one (Label never does; Container
    /// is layout-only and never draws at all). `main.zig`'s draw loop
    /// buckets these across every widget into a `DrawBatcher` instead of
    /// each widget filling its own rect with its own `SDL_RenderFillRect`
    /// call.
    pub fn fillRect(self: Widget) ?struct { color: c.SDL_Color, rect: c.SDL_FRect } {
        return switch (self) {
            .button => |b| .{ .color = b.fillColor(), .rect = b.rect },
            .textfield => |t| .{ .color = t.fillColor(), .rect = t.rect },
            .textarea => |ta| .{ .color = ta.fillColor(), .rect = ta.rect },
            // Only fills when checked -- an unchecked box has nothing to
            // batch-fill, just the outline `drawDecorations` always draws.
            // Uses `boxRect()`, not the full `rect`, since the label area
            // (if any) is never filled.
            .checkbox => |cb| if (cb.checked) .{ .color = cb.fillColor(), .rect = cb.boxRect() } else null,
            // W5: only fills when `background` is set -- see
            // Container.zig's doc comment.
            .container => |cont| if (cont.fillColor()) |color| .{ .color = color, .rect = cont.rect } else null,
            // RadioButton.zig's doc comment explains why this opts out
            // entirely -- its checked state is an inset dot, not a
            // whole-rect fill.
            // W3: Slider needs its own two-color (track + fill) custom draw
            // in drawDecorations, same "opts out of the single-color batched
            // fill" precedent ProgressBar already established. W12: Toggle
            // joins for the same reason -- its track+thumb are a real
            // two-color draw, not a single conditional fill.
            .label, .radio_button, .progress_bar, .slider, .toggle => null,
            // W11: unlike Container's opt-in background, a divider always
            // fills -- see Divider.zig's doc comment.
            .divider => |d| .{ .color = d.fillColor(), .rect = d.rect },
            // W14: same "always fills" precedent as Divider -- a Badge is
            // a pill, not a checkmark-on-demand.
            .badge => |bd| .{ .color = bd.fillColor(), .rect = bd.rect },
        };
    }

    /// Keyboard-interaction model: only `Button`/`TextField` can receive
    /// focus -- `Label`/`Container` are pure display/layout, never
    /// interactive. Used by `focusableIdsSorted` to decide which widgets
    /// participate in Tab order.
    pub fn isFocusable(self: Widget) bool {
        return switch (self) {
            .button, .textfield, .textarea, .checkbox, .toggle, .radio_button, .slider => true,
            .label, .container, .progress_bar, .divider, .badge => false,
        };
    }

    /// Per-kind dispatch for setting/clearing the `focused: bool` field --
    /// no-op for `Label`/`Container`, which don't have one. Used by
    /// `WidgetHost.setFocused` instead of a hardcoded `.textfield` check, so
    /// `Button` (or any future focusable kind) participates the same way.
    pub fn setFocusedFlag(self: *Widget, focused: bool) void {
        switch (self.*) {
            .button => |*b| b.focused = focused,
            .textfield => |*t| t.focused = focused,
            .textarea => |*ta| ta.focused = focused,
            .checkbox => |*cb| cb.focused = focused,
            .toggle => |*tg| tg.focused = focused,
            .radio_button => |*r| r.focused = focused,
            .slider => |*s| s.focused = focused,
            .label, .container, .progress_bar, .divider, .badge => {},
        }
    }
};

/// The Clay tree relationships/style a widget was created with -- only
/// `natyv_clay_*` host functions (L3) populate these for real; every widget
/// created via the plain `natyv_create_*` functions above keeps the
/// defaults (no parent, zeroed style), since its layout stays
/// guest-supplied absolute pixels. Stored per-slot (not recomputed) so the
/// render loop can redeclare each node to Clay every frame from data it
/// already has, without a second guest round trip.
pub const ClayStyle = struct {
    sizing: c.Clay_Sizing = std.mem.zeroes(c.Clay_Sizing),
    padding: c.Clay_Padding = std.mem.zeroes(c.Clay_Padding),
    child_gap: u16 = 0,
    direction: c.Clay_LayoutDirection = c.CLAY_LEFT_TO_RIGHT,
    child_alignment: c.Clay_ChildAlignment = std.mem.zeroes(c.Clay_ChildAlignment),
    /// W2: clips overflowing children to this element's bounds and lets
    /// mouse-wheel input scroll them. Clay owns the actual scroll offset
    /// internally (keyed by this widget's stable elementId) -- nothing
    /// extra needs to be stored per-slot beyond these two flags.
    scroll_vertical: bool = false,
    scroll_horizontal: bool = false,
    /// W4: layers this element (and everything nested under it) over the
    /// top of normal content instead of taking part in its parent's normal
    /// flex flow -- see ClayLayout.zig's openChildren for how this becomes
    /// a real Clay_FloatingElementConfig, and FloatingOrder.zig/main.zig
    /// for how natyv's own draw order and click hit-testing account for it
    /// (Clay itself has no opinion on either -- it only computes position).
    floating: bool = false,
    /// W5: implies floating-style positioning (the guest sets this alone,
    /// not `floating: true` as well) but centered against the whole window
    /// via `CLAY_ATTACH_TO_ROOT` instead of Dropdown's "attach below my
    /// parent" shape -- see ClayLayout.zig's openChildren. Also the signal
    /// FloatingOrder.zig's modal-specific functions (topmost-of-several,
    /// input-blocking subtree, surface id) key off of; a plain `floating`
    /// widget (like Dropdown's panel) never blocks input or gets a
    /// backdrop, only a `modal` one does.
    ///
    /// A backdrop click never dismisses -- deliberate, per Quinn's
    /// real click-through feedback (2026-08-17): "for a modal, backdrop
    /// clicking shouldn't close ever... only ever block. that's more
    /// idiomatic." An earlier version made this a per-modal opt-in
    /// (`backdrop_dismiss`); Quinn simplified it to always-block instead,
    /// so that flag was removed rather than left as dead/unused wire
    /// surface. Escape and a guest-declared close Button are the only two
    /// ways to close a modal -- see main.zig's backdrop-miss handling
    /// (blocks, never pushes `.dismiss`) and its Escape-key handling
    /// (always pushes `.dismiss`, unconditionally).
    modal: bool = false,
    /// W7: implies floating-style positioning on its own (guest sets this
    /// alone, not `floating`/`modal` too), anchored to a fixed screen
    /// corner (`CLAY_ATTACH_TO_ROOT`, bottom-right) rather than below a
    /// parent (`floating`) or centered (`modal`) -- see ClayLayout.zig's
    /// openChildren. Set once, on a guest's single persistent toast-stack
    /// container; individual toasts are plain (non-floating) children of
    /// it, stacking via ordinary flex layout. Orthogonal to
    /// `ClayContainerRequest.duration_ms` below (the actual expiry timer)
    /// -- a toast's content Container carries `duration_ms`, not `toast`.
    toast: bool = false,
};

pub const Slot = struct {
    id: u32,
    widget: Widget,
    parent_id: ?u32 = null,
    clay_style: ClayStyle = .{},
    /// True only for widgets inserted via the `natyv_clay_*` path (L3) --
    /// distinguishes "has a `parent_id`/`clay_style`" (could just be
    /// defaults) from "actually participates in Clay's tree," since a
    /// top-level Clay-managed container legitimately has `parent_id == null`
    /// too. Used to decide which layout-affecting mutations should bump
    /// `layout_generation` below (a legacy natyv_create_* widget's text
    /// changing has no effect on Clay's tree, so it shouldn't force a
    /// recompute).
    clay_managed: bool = false,
    /// W7: when set, `main.zig`'s per-frame `destroyExpiredWidgets` call
    /// destroys this widget (and every descendant -- see that function's
    /// doc comment for why cascading is required here specifically) once
    /// `timing.nowMs() >= expires_at_ms`. `null` (the default) means "never
    /// expires," same as every widget before this existed. Bookkeeping,
    /// not a layout property -- lives here, not on `ClayStyle`, same
    /// reasoning `clay_managed` already gets.
    expires_at_ms: ?i64 = null,
};

allocator: std.mem.Allocator,
mutex: Io.Mutex = .init,
slots: [max_widgets]?Slot = [_]?Slot{null} ** max_widgets,
next_id: u32 = 1,
/// Bumped by any mutation that could change Clay-managed layout geometry
/// (create/destroy a Clay-managed widget, or change text on one whose size
/// depends on its content) -- L4's render-loop pass compares this against
/// the generation it last actually ran Clay for, and skips
/// BeginLayout/EndLayout entirely on a frame where nothing moved it,
/// reusing each widget's already-cached `rect` instead. See
/// `ClayLayout.layoutIfNeeded`.
layout_generation: u64 = 0,
/// See file doc comment -- set by Runtime.call around every guest call,
/// unset after. Only ever read from inside a host function callback, which
/// by construction only ever runs nested inside that same call.
current_io: ?Io = null,
/// F3: `TTF_DestroyText` (like `TTF_CreateText`) must run on the thread
/// that created the text -- but `natyv_destroy_widget` is a host function,
/// called from inside `natyv_dispatch` on the *worker* thread (see
/// Dispatch.zig's file doc comment for why guest calls live there at all).
/// A guest destroying a widget (e.g. bookstore's refreshBookList) can't
/// destroy its `TTF_Text` right then and there -- `destroyWidgetHostFn`
/// queues the pointer here instead, and `flushPendingTextDestroys` (called
/// once per frame from `main.zig`, main thread) does the real
/// `TTF_DestroyText` call. Sized for the worst case between two frames:
/// every widget destroyed at once, times 2 (a TextField queues both its
/// entered-text and placeholder objects).
pending_text_destroys: [max_widgets * 2]?*c.TTF_Text = [_]?*c.TTF_Text{null} ** (max_widgets * 2),
pending_text_destroy_count: usize = 0,

pub const EnabledKinds = struct {
    button: bool = true,
    textfield: bool = true,
    textarea: bool = true,
    label: bool = true,
    checkbox: bool = true,
    toggle: bool = true,
    radio_button: bool = true,
    progress_bar: bool = true,
    slider: bool = true,
    divider: bool = true,
    badge: bool = true,
};

/// Registers only the create-functions for widget kinds `enabled` declares
/// (an app's conf.natyv.json) -- a guest that was never granted a kind gets
/// a normal "unknown import" failure from Extism if it tries to use it,
/// same class of enforcement as `allowed_hosts` for network access.
/// `natyv_set_text`/`natyv_get_text`/`natyv_destroy_widget` are generic
/// utility ops over whatever widgets already exist, so they're always
/// registered regardless -- there's nothing to gate: a guest can't get a
/// widget_id to call them with unless it already had permission to create
/// that widget in the first place.
pub fn registerInto(self: *Self, funcs_out: []?*const c.ExtismFunction, enabled: EnabledKinds) usize {
    const in_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const out_types = [_]c.ExtismValType{c.ExtismValType_I64};
    var n: usize = 0;
    if (enabled.button) {
        funcs_out[n] = c.extism_function_new("natyv_create_button", &in_types[0], 1, &out_types[0], 1, HostFunctions.createButtonHostFn, self, null);
        n += 1;
    }
    if (enabled.textfield) {
        funcs_out[n] = c.extism_function_new("natyv_create_textfield", &in_types[0], 1, &out_types[0], 1, HostFunctions.createTextFieldHostFn, self, null);
        n += 1;
    }
    if (enabled.textarea) {
        funcs_out[n] = c.extism_function_new("natyv_create_textarea", &in_types[0], 1, &out_types[0], 1, HostFunctions.createTextAreaHostFn, self, null);
        n += 1;
    }
    if (enabled.label) {
        funcs_out[n] = c.extism_function_new("natyv_create_label", &in_types[0], 1, &out_types[0], 1, HostFunctions.createLabelHostFn, self, null);
        n += 1;
    }
    if (enabled.checkbox) {
        funcs_out[n] = c.extism_function_new("natyv_create_checkbox", &in_types[0], 1, &out_types[0], 1, HostFunctions.createCheckboxHostFn, self, null);
        n += 1;
    }
    if (enabled.toggle) {
        funcs_out[n] = c.extism_function_new("natyv_create_toggle", &in_types[0], 1, &out_types[0], 1, HostFunctions.createToggleHostFn, self, null);
        n += 1;
    }
    if (enabled.radio_button) {
        funcs_out[n] = c.extism_function_new("natyv_create_radio_button", &in_types[0], 1, &out_types[0], 1, HostFunctions.createRadioButtonHostFn, self, null);
        n += 1;
    }
    if (enabled.progress_bar) {
        funcs_out[n] = c.extism_function_new("natyv_create_progressbar", &in_types[0], 1, &out_types[0], 1, HostFunctions.createProgressBarHostFn, self, null);
        n += 1;
    }
    if (enabled.slider) {
        funcs_out[n] = c.extism_function_new("natyv_create_slider", &in_types[0], 1, &out_types[0], 1, HostFunctions.createSliderHostFn, self, null);
        n += 1;
    }
    if (enabled.divider) {
        funcs_out[n] = c.extism_function_new("natyv_create_divider", &in_types[0], 1, &out_types[0], 1, HostFunctions.createDividerHostFn, self, null);
        n += 1;
    }
    if (enabled.badge) {
        funcs_out[n] = c.extism_function_new("natyv_create_badge", &in_types[0], 1, &out_types[0], 1, HostFunctions.createBadgeHostFn, self, null);
        n += 1;
    }
    funcs_out[n] = c.extism_function_new("natyv_set_text", &in_types[0], 1, &out_types[0], 1, HostFunctions.setTextHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_get_text", &in_types[0], 1, &out_types[0], 1, HostFunctions.getTextHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_destroy_widget", &in_types[0], 1, &out_types[0], 1, HostFunctions.destroyWidgetHostFn, self, null);
    n += 1;
    // W1: generic non-text state accessors (bool/float) -- same "always
    // registered, nothing to gate" reasoning as set_text/get_text/
    // destroy_widget above (a guest can't get a widget_id to call these
    // with unless it already had permission to create that widget).
    funcs_out[n] = c.extism_function_new("natyv_set_checked", &in_types[0], 1, &out_types[0], 1, HostFunctions.setCheckedHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_get_checked", &in_types[0], 1, &out_types[0], 1, HostFunctions.getCheckedHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_set_value", &in_types[0], 1, &out_types[0], 1, HostFunctions.setValueHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_get_value", &in_types[0], 1, &out_types[0], 1, HostFunctions.getValueHostFn, self, null);
    n += 1;
    return n;
}

pub const clay_host_function_count = 12;

/// Registered only when conf.natyv.json's `ui.backend == "clay"` --
/// Runtime.loadPlugin gates this the same way sqlite/widgets.* already
/// gate their own host functions (see Config.zig's UiConfig). These only
/// touch the widget registry (store parent_id + style on insert); the
/// actual Clay arena/BeginLayout/EndLayout lifecycle lives in
/// ClayLayout.zig and is driven per-frame by L4's render-loop pass, not by
/// these guest-facing create calls.
pub fn registerClayInto(self: *Self, funcs_out: []?*const c.ExtismFunction) usize {
    const in_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const out_types = [_]c.ExtismValType{c.ExtismValType_I64};
    funcs_out[0] = c.extism_function_new("natyv_clay_create_container", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayContainerHostFn, self, null);
    funcs_out[1] = c.extism_function_new("natyv_clay_create_button", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayButtonHostFn, self, null);
    funcs_out[2] = c.extism_function_new("natyv_clay_create_textfield", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayTextFieldHostFn, self, null);
    funcs_out[3] = c.extism_function_new("natyv_clay_create_label", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayLabelHostFn, self, null);
    funcs_out[4] = c.extism_function_new("natyv_clay_create_checkbox", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayCheckboxHostFn, self, null);
    funcs_out[5] = c.extism_function_new("natyv_clay_create_radio_button", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayRadioButtonHostFn, self, null);
    funcs_out[6] = c.extism_function_new("natyv_clay_create_progressbar", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayProgressBarHostFn, self, null);
    funcs_out[7] = c.extism_function_new("natyv_clay_create_slider", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClaySliderHostFn, self, null);
    funcs_out[8] = c.extism_function_new("natyv_clay_create_textarea", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayTextAreaHostFn, self, null);
    funcs_out[9] = c.extism_function_new("natyv_clay_create_divider", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayDividerHostFn, self, null);
    funcs_out[10] = c.extism_function_new("natyv_clay_create_toggle", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayToggleHostFn, self, null);
    funcs_out[11] = c.extism_function_new("natyv_clay_create_badge", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayBadgeHostFn, self, null);
    return clay_host_function_count;
}

/// `pub` so `WidgetHostFunctions.zig`'s callbacks can reach it -- see that
/// file's own doc comment for why it's a separate file at all.
pub fn io(self: *Self) Io {
    return self.current_io orelse unreachable; // see file doc comment: invariant enforced by Runtime.call
}

/// `pub` -- see `io`'s doc comment above.
pub fn insertLocked(self: *Self, widget: Widget) ?u32 {
    return self.insertLockedWithLayout(widget, null, .{});
}

fn insertLockedWithLayout(self: *Self, widget: Widget, parent_id: ?u32, clay_style: ClayStyle) ?u32 {
    for (&self.slots) |*slot| {
        if (slot.* == null) {
            const id = self.next_id;
            self.next_id += 1;
            slot.* = .{ .id = id, .widget = widget, .parent_id = parent_id, .clay_style = clay_style };
            return id;
        }
    }
    return null;
}

/// Locks, inserts a widget with explicit Clay parent/style data, and
/// unlocks -- the counterpart to the plain natyv_create_* host functions
/// above (which always go through the parent_id=null/default-style path).
/// L3's natyv_clay_* host functions call this directly once they exist;
/// for now it's exercised by Runtime.zig's own L2 test, since only a test
/// file's own root gets its `test` blocks reliably discovered under Zig's
/// lazy analysis (same lesson as the ClayLayout import above).
///
/// W16: also marks the inserted widget `clay_managed` (same as
/// `insertLockedWithLayoutValidated` below always does) -- L2's own test
/// never needed a real Clay layout pass over what this inserts, but
/// `openChildren` skips anything not `clay_managed`, so a test that *does*
/// want one (see RuntimeTest.zig's W16 flip-above test, which constructs
/// a scenario directly rather than through a compiled guest) needs this
/// set to get real computed geometry back at all.
pub fn insertWithLayout(self: *Self, call_io: Io, widget: Widget, parent_id: ?u32, clay_style: ClayStyle) ?u32 {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const id = self.insertLockedWithLayout(widget, parent_id, clay_style) orelse return null;
    if (self.findLocked(id)) |slot| slot.clay_managed = true;
    return id;
}

const InsertClayError = error{ NoSuchParent, RegistryFull };

/// Same as `insertLockedWithLayout`, but rejects a `parent_id` that doesn't
/// name an existing widget instead of silently inserting an orphan -- used
/// by the `natyv_clay_*` host functions below, which need to report a
/// meaningful error back to the guest rather than just failing later when
/// L4's layout pass can't find the parent.
/// `pub` -- see `io`'s doc comment above.
pub fn insertLockedWithLayoutValidated(self: *Self, widget: Widget, parent_id: ?u32, clay_style: ClayStyle, expires_at_ms: ?i64) InsertClayError!u32 {
    if (parent_id) |pid| {
        if (self.findLocked(pid) == null) return error.NoSuchParent;
    }
    const id = self.insertLockedWithLayout(widget, parent_id, clay_style) orelse return error.RegistryFull;
    if (self.findLocked(id)) |slot| {
        slot.clay_managed = true;
        // W7: only Container creation ever passes a non-null value here
        // (see insertClayWidget's callers) -- set while still holding the
        // lock this function's caller already took, no second lock cycle.
        slot.expires_at_ms = expires_at_ms;
    }
    self.layout_generation +%= 1;
    return id;
}

/// Locked read of `layout_generation` -- L4's render-loop pass calls this
/// once per frame to decide whether a real Clay recompute is needed at all.
pub fn currentGeneration(self: *Self, call_io: Io) u64 {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    return self.layout_generation;
}

/// Writes Clay's computed geometry back into a widget's `rect` after a real
/// layout pass. Deliberately does *not* bump `layout_generation` itself --
/// this is downstream of a layout computation, not a cause of one, and
/// bumping here would make the generation counter chase its own tail.
pub fn setRect(self: *Self, call_io: Io, id: u32, rect: c.SDL_FRect) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| slot.widget.rectPtr().* = rect;
}

/// `pub` -- see `io`'s doc comment above.
pub fn findLocked(self: *Self, id: u32) ?*Slot {
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            if (s.id == id) return s;
        }
    }
    return null;
}

/// F3: creates/updates every button/textfield/label's cached `TTF_Text`
/// against the *live* registry, once per frame, before that frame's
/// `snapshot` below is taken -- same "mutate the registry, then snapshot
/// sees the fresh result" ordering `ClayLayout.layoutIfNeeded` already
/// established for computed geometry (see main.zig's frame loop). Each
/// widget's own `syncText` decides whether it actually needs to touch
/// SDL_ttf at all this frame (see e.g. `Button.syncText`'s doc comment).
pub fn syncTextObjects(self: *Self, call_io: Io, engine: *c.TTF_TextEngine, font: *c.TTF_Font) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            switch (s.widget) {
                .button => |*b| b.syncText(engine, font),
                .textfield => |*t| t.syncText(engine, font),
                .textarea => |*ta| ta.syncText(engine, font),
                .label => |*l| l.syncText(engine, font),
                .checkbox => |*cb| cb.syncText(engine, font),
                .toggle => |*tg| tg.syncText(engine, font),
                .radio_button => |*r| r.syncText(engine, font),
                .badge => |*bd| bd.syncText(engine, font),
                .container, .progress_bar, .slider, .divider => {},
            }
        }
    }
}

/// SDL_ttf requires every `TTF_Text` be destroyed before its owning
/// `TTF_TextEngine` is -- called once at app shutdown (main.zig), for
/// every widget still in the registry regardless of whether the guest ever
/// explicitly destroyed it, since closing the window is not the same as
/// the guest calling natyv_destroy_widget on everything first.
pub fn destroyAllTextObjects(self: *Self, call_io: Io) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            switch (s.widget) {
                .button => |*b| b.destroyText(),
                .textfield => |*t| t.destroyText(),
                .textarea => |*ta| ta.destroyText(),
                .label => |*l| l.destroyText(),
                .checkbox => |*cb| cb.destroyText(),
                .toggle => |*tg| tg.destroyText(),
                .radio_button => |*r| r.destroyText(),
                .badge => |*bd| bd.destroyText(),
                .container, .progress_bar, .slider, .divider => {},
            }
        }
    }
}

/// W7: called once per frame from `main.zig`, main thread -- destroys
/// `TTF_Text` immediately, no queueing needed (unlike `natyv_destroy_widget`,
/// which runs on the worker thread and can't touch the text engine
/// directly), same reasoning `destroyAllTextObjects` above already
/// established for shutdown.
///
/// Unlike every other destroy path in this project (always guest-initiated,
/// with an explicit-per-child-only contract every prior floating widget
/// relies on -- e.g. `closeDropdown`'s 3-widget destroy loop), this
/// cascades to every descendant of an expired widget. There is no guest
/// callback to clean children up here -- if only the expired root's own
/// slot were nulled, its content would be orphaned (still registered,
/// parented to an id that no longer exists, nothing left to ever destroy
/// it). This is a deliberate, narrowly-scoped exception confined to this
/// one host-driven path; `natyv_destroy_widget`'s own no-cascade contract
/// is completely unchanged.
pub fn destroyExpiredWidgets(self: *Self, call_io: Io, now_ms: i64) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);

    var expired_roots: [max_widgets]u32 = undefined;
    var expired_count: usize = 0;
    for (self.slots) |maybe_slot| {
        if (maybe_slot) |s| {
            if (s.expires_at_ms) |exp| {
                if (now_ms >= exp) {
                    expired_roots[expired_count] = s.id;
                    expired_count += 1;
                }
            }
        }
    }
    for (expired_roots[0..expired_count]) |root_id| self.destroySubtreeLocked(root_id);
}

/// Destroys `root_id` and every descendant reachable via `parent_id`.
/// Two-phase deliberately -- collects the full set to destroy first
/// (against still-fully-intact slot data), then destroys everything in a
/// second pass. Doing it in one pass would risk nulling an ancestor's slot
/// before a not-yet-visited descendant's own parent_id chain-walk reaches
/// it, which would sever that walk early (`findLocked` on an
/// already-nulled ancestor returns nothing) and wrongly leave a real
/// descendant behind.
fn destroySubtreeLocked(self: *Self, root_id: u32) void {
    var to_destroy: [max_widgets]u32 = undefined;
    var count: usize = 0;
    for (self.slots) |maybe_slot| {
        if (maybe_slot) |s| {
            if (s.id != root_id and self.isDescendantLocked(s.id, root_id)) {
                to_destroy[count] = s.id;
                count += 1;
            }
        }
    }
    to_destroy[count] = root_id;
    count += 1;

    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            for (to_destroy[0..count]) |id| {
                if (s.id == id) {
                    switch (s.widget) {
                        .button => |*b| b.destroyText(),
                        .textfield => |*t| t.destroyText(),
                        .textarea => |*ta| ta.destroyText(),
                        .label => |*l| l.destroyText(),
                        .checkbox => |*cb| cb.destroyText(),
                        .toggle => |*tg| tg.destroyText(),
                        .radio_button => |*r| r.destroyText(),
                        .badge => |*bd| bd.destroyText(),
                        .container, .progress_bar, .slider, .divider => {},
                    }
                    if (s.clay_managed) self.layout_generation +%= 1;
                    slot.* = null;
                    break;
                }
            }
        }
    }
}

/// True when `id` is a strict descendant of `root_id` (walks `parent_id`
/// up the chain) -- `id == root_id` itself is checked separately by every
/// caller. Same shape `FloatingOrder.isDescendantOfOrSelf` uses over a
/// snapshot slice; a small local equivalent over the live registry lives
/// here instead of reusing that one, since `FloatingOrder.zig` already
/// imports this file and the reverse import would be circular.
fn isDescendantLocked(self: *Self, id: u32, root_id: u32) bool {
    var current = (self.findLocked(id) orelse return false).parent_id;
    while (current) |pid| {
        if (pid == root_id) return true;
        current = (self.findLocked(pid) orelse break).parent_id;
    }
    return false;
}

/// Appends `obj_ptr`'s pointee to the pending-destroy queue (see the field
/// doc comment) and nulls it out on the widget -- called from
/// `destroyWidgetHostFn` (worker thread) instead of calling `TTF_DestroyText`
/// directly there, since that call is only valid on the thread that created
/// the text. Silently drops the pointer if the queue is already at its
/// (generous, whole-registry-sized) capacity rather than overflow -- a tiny,
/// practically-unreachable leak is preferable to a panic in a guest-facing
/// host function.
fn queuePendingTextDestroy(self: *Self, obj_ptr: *?*c.TTF_Text) void {
    if (obj_ptr.*) |obj| {
        if (self.pending_text_destroy_count < self.pending_text_destroys.len) {
            self.pending_text_destroys[self.pending_text_destroy_count] = obj;
            self.pending_text_destroy_count += 1;
        }
        obj_ptr.* = null;
    }
}

/// Must be called with `mutex` already held -- queues every `TTF_Text`
/// pointer this widget owns for later destruction on the main thread. See
/// `WidgetHostFunctions.zig`'s `destroyWidgetHostFn`, the only caller --
/// `pub` for exactly that, see `io`'s doc comment above.
pub fn queueWidgetTextDestroysLocked(self: *Self, widget: *Widget) void {
    switch (widget.*) {
        .button => |*b| self.queuePendingTextDestroy(&b.text_obj),
        .textfield => |*t| {
            self.queuePendingTextDestroy(&t.text_obj);
            self.queuePendingTextDestroy(&t.placeholder_obj);
        },
        .textarea => |*ta| {
            self.queuePendingTextDestroy(&ta.text_obj);
            self.queuePendingTextDestroy(&ta.placeholder_obj);
        },
        .label => |*l| self.queuePendingTextDestroy(&l.text_obj),
        .checkbox => |*cb| self.queuePendingTextDestroy(&cb.text_obj),
        .toggle => |*tg| self.queuePendingTextDestroy(&tg.text_obj),
        .radio_button => |*r| self.queuePendingTextDestroy(&r.text_obj),
        .badge => |*bd| self.queuePendingTextDestroy(&bd.text_obj),
        .container, .progress_bar, .slider, .divider => {},
    }
}

/// Drains the pending-destroy queue -- called once per frame from
/// `main.zig`, on the main thread (the only thread `TTF_DestroyText` is
/// valid to call on for these objects). See the field's doc comment for why
/// this queue exists at all instead of destroying inline in
/// `destroyWidgetHostFn`.
pub fn flushPendingTextDestroys(self: *Self, call_io: Io) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    for (self.pending_text_destroys[0..self.pending_text_destroy_count]) |maybe_obj| {
        if (maybe_obj) |obj| c.TTF_DestroyText(obj);
    }
    self.pending_text_destroy_count = 0;
}

/// Copies the live widget set into `out` (id + widget snapshot) for the
/// render loop to draw/hit-test without holding the lock across SDL calls --
/// same pattern as the original prototype's `snapshotBooks`.
pub fn snapshot(self: *Self, call_io: Io, out: []Slot) usize {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    var n: usize = 0;
    for (self.slots) |slot| {
        if (n >= out.len) break;
        if (slot) |s| {
            out[n] = s;
            n += 1;
        }
    }
    return n;
}

/// W6: returns the number of bytes copied into `out` (`out.len >=
/// TextField.max_len` required) -- the widget's real post-mutation text --
/// or `null` if `id` isn't a textfield/textarea. `null`, not `0`, for the
/// not-a-text-widget case specifically because `0` is itself a real,
/// meaningful result (backspacing the last character leaves an empty
/// string, which still needs a `.text_changed` event) -- same "?T, not a T
/// with an overloaded sentinel" shape `setSliderValue` (W3) established.
/// Copying the text out here (rather than handing back a slice into the
/// live, mutex-protected, guest-mutable-via-a-concurrent-`natyv_set_text`
/// buffer) is deliberate, same reasoning `setSliderValue` documents for
/// returning a value instead of a pointer. `main.zig` uses the copy to
/// build a `.text_changed` event.
///
/// W10: `.textarea` joins `.textfield` here -- same append-at-the-end
/// model, just a bigger buffer (`out` must be sized for whichever of the
/// two is larger; `main.zig` sizes it off `TextArea.max_len`, since that's
/// always the bigger one). This is also the path Enter uses to insert a
/// literal newline into a focused textarea (`appendTextTo(io, id, "\n",
/// ...)`), not a separate mechanism -- a newline is just another string to
/// append, from this function's point of view.
pub fn appendTextTo(self: *Self, call_io: Io, id: u32, s: []const u8, out: []u8) ?usize {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| {
        if (slot.widget == .textfield) {
            slot.widget.textfield.appendText(s);
            // FIT-sized Clay nodes size themselves from content -- a text
            // change can change a Clay-managed widget's geometry, so it
            // needs to force a recompute. A legacy (non-Clay) textfield's
            // text has no effect on any Clay tree, so it shouldn't.
            if (slot.clay_managed) self.layout_generation +%= 1;
            const text = slot.widget.textfield.text();
            @memcpy(out[0..text.len], text);
            return text.len;
        } else if (slot.widget == .textarea) {
            slot.widget.textarea.appendText(s);
            if (slot.clay_managed) self.layout_generation +%= 1;
            const text = slot.widget.textarea.text();
            @memcpy(out[0..text.len], text);
            return text.len;
        }
    }
    return null;
}

/// W6: see `appendTextTo`'s doc comment -- same shape. W10: `.textarea`
/// joins `.textfield` here too, same reasoning.
pub fn backspaceOn(self: *Self, call_io: Io, id: u32, out: []u8) ?usize {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| {
        if (slot.widget == .textfield) {
            slot.widget.textfield.backspace();
            if (slot.clay_managed) self.layout_generation +%= 1;
            const text = slot.widget.textfield.text();
            @memcpy(out[0..text.len], text);
            return text.len;
        } else if (slot.widget == .textarea) {
            slot.widget.textarea.backspace();
            if (slot.clay_managed) self.layout_generation +%= 1;
            const text = slot.widget.textarea.text();
            @memcpy(out[0..text.len], text);
            return text.len;
        }
    }
    return null;
}

/// Sets `id` as the sole focused widget (clearing focus on every other
/// slot), or clears focus entirely when `id` is `null`. Returns `true` when
/// the newly focused widget wants IME/text input active -- `.textfield` or
/// `.textarea` (W10 widened this from "is specifically a `.textfield`",
/// renaming the local accordingly, since the old name became inaccurate).
/// `main.zig` uses this to decide whether to start/stop `SDL_StartTextInput`
/// without a second registry lookup (focusing a `Button` shouldn't turn on
/// IME/text composition).
pub fn setFocused(self: *Self, call_io: Io, id: ?u32) bool {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    var focused_wants_text_input = false;
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            const this_one = id != null and s.id == id.?;
            s.widget.setFocusedFlag(this_one);
            if (this_one and (s.widget == .textfield or s.widget == .textarea)) focused_wants_text_input = true;
        }
    }
    return focused_wants_text_input;
}

/// Keyboard interaction model: every focusable widget's id (see
/// `Widget.isFocusable`), sorted ascending. Ids are assigned by a monotonic
/// counter that's never reused, so ascending id order *is* creation order --
/// but `snapshot()`'s array-index order is not a safe substitute for this
/// once a widget has been destroyed and a new one created afterward (the
/// new widget can land in a freed lower-index slot while carrying a higher
/// id). `main.zig`'s Tab handling calls this fresh on every Tab press
/// rather than caching it, so it never goes stale.
pub fn focusableIdsSorted(self: *Self, call_io: Io, out: []u32) usize {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    var n: usize = 0;
    for (self.slots) |slot| {
        if (n >= out.len) break;
        if (slot) |s| {
            if (s.widget.isFocusable()) {
                out[n] = s.id;
                n += 1;
            }
        }
    }
    std.mem.sort(u32, out[0..n], {}, std.sort.asc(u32));
    return n;
}

/// Pure Tab-navigation logic, deliberately kept free of `Io`/locking so it's
/// unit-testable in isolation -- given `ids` (already sorted ascending, see
/// `focusableIdsSorted`) and the currently focused id (`null` if nothing is
/// focused), returns the next (`forward`) or previous (`!forward`) id,
/// wrapping around either end. Returns `null` only when `ids` is empty.
/// `current` not being present in `ids` (e.g. the focused widget was just
/// destroyed) is treated the same as `current == null` -- starts from the
/// beginning (forward) or end (backward) of the list.
pub fn nextFocusable(ids: []const u32, current: ?u32, forward: bool) ?u32 {
    if (ids.len == 0) return null;
    const current_index: ?usize = if (current) |cur| std.mem.indexOfScalar(u32, ids, cur) else null;
    if (current_index) |i| {
        if (forward) {
            return ids[(i + 1) % ids.len];
        } else {
            return ids[(i + ids.len - 1) % ids.len];
        }
    }
    return if (forward) ids[0] else ids[ids.len - 1];
}

pub fn flashButton(self: *Self, call_io: Io, id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| {
        if (slot.widget == .button) slot.widget.button.flash();
    }
}

/// W1: the click/Enter/Space activation counterpart to `flashButton`, for
/// a checkbox -- flips its `checked` state. `main.zig`'s widened activation
/// handling calls this instead of `flashButton` when the activated widget
/// is a `.checkbox`.
pub fn toggleCheckbox(self: *Self, call_io: Io, id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| {
        if (slot.widget == .checkbox) slot.widget.checkbox.toggle();
    }
}

/// W12: the `.toggle`-kind counterpart to `toggleCheckbox` above -- kept as
/// its own function (not a generalization of `toggleCheckbox` to any
/// bool-state kind) since `Checkbox` and `Toggle` are otherwise-unrelated
/// widget kinds sharing this file only by convention, and generalizing here
/// would mean touching `toggleCheckbox`'s already-shipped, tested body for
/// no functional gain.
pub fn toggleToggle(self: *Self, call_io: Io, id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| {
        if (slot.widget == .toggle) slot.widget.toggle.toggle();
    }
}

/// W1: selects radio button `id` and deselects every other `.radio_button`
/// sharing its `group_id` -- the actual mutual-exclusivity logic
/// `RadioButton.zig`'s own doc comment defers to this file for, since it
/// needs to reach across the whole registry, not just one widget. Called
/// both from a real click/Enter/Space activation (`main.zig`) and from
/// `natyv_set_checked` when a guest programmatically selects a radio, so
/// both paths behave identically. A no-op if `id` doesn't name a radio
/// button.
pub fn selectRadioExclusive(self: *Self, call_io: Io, id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const group_id = blk: {
        const slot = self.findLocked(id) orelse return;
        break :blk switch (slot.widget) {
            .radio_button => |r| r.group_id,
            else => return,
        };
    };
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            if (s.widget == .radio_button and s.widget.radio_button.group_id == group_id) {
                if (s.id == id) {
                    s.widget.radio_button.select();
                } else {
                    s.widget.radio_button.deselect();
                }
            }
        }
    }
}

/// W3: the host-authoritative counterpart to `toggleCheckbox`/
/// `selectRadioExclusive` -- called directly by `main.zig`'s drag-update
/// block and arrow-key nudge handling (not via a host function; there's no
/// guest call involved in a mouse drag). Returns the *actual clamped*
/// value if it changed, or `null` if `id` doesn't name a slider or the
/// clamped value is unchanged (e.g. a drag pinned against 0/1 while the
/// mouse keeps moving) -- returning the clamped value, not just a bool,
/// means `main.zig`'s `notifySliderValue` can report exactly what got
/// stored without a second lookup, never an out-of-range value a caller
/// (e.g. an arrow-key nudge past 0/1) happened to pass in.
pub fn setSliderValue(self: *Self, call_io: Io, id: u32, value: f32) ?f32 {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const slot = self.findLocked(id) orelse return null;
    if (slot.widget != .slider) return null;
    const old = slot.widget.slider.value;
    slot.widget.slider.setValue(value);
    const new = slot.widget.slider.value;
    return if (new != old) new else null;
}
