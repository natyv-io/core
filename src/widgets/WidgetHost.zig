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
//!
//! W19: Tabs is natyv's first host-owned widget that both draws its own
//! decoration (a clickable header row, like SegmentedControl) AND is the
//! real Clay parent of further Clay-managed children (its panels, like
//! Container) -- and the first to need hiding a subtree without destroying
//! it, since exactly one panel is shown at a time:
//!   natyv_clay_create_tabs      in: {"layout":{...},"labels":["..."],"selected_index":N}
//!   natyv_clay_create_tab_panel in: {"layout":{"parent_id":N,...}}  -- parent_id MUST name a Tabs widget
//!     both out: {"widget_id":N} | {"error":"..."}
//!   Selecting a different tab (click or arrow-key) calls `setActiveTab`,
//!   which flips a new `ClayStyle.visible` flag on every panel so only the
//!   newly-selected one participates in layout/draw/hit-test -- see that
//!   flag's own doc comment for the mechanism, and `Tabs.zig`'s file doc
//!   comment for why this widget owns both header and panel-visibility
//!   together instead of guest-composing a SegmentedControl header with
//!   manually-toggled panels.

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
const RangeSlider = @import("RangeSlider.zig");
const Spinner = @import("Spinner.zig");
const Divider = @import("Divider.zig");
const Badge = @import("Badge.zig");
const NumericStepper = @import("NumericStepper.zig");
const SegmentedControl = @import("SegmentedControl.zig");
const Tabs = @import("Tabs.zig");
const ScrollBar = @import("../ScrollBar.zig");
// The Extism host-function wire layer (natyv_create_*/natyv_clay_create_*
// callbacks and the generic set/get/destroy ones) lives in its own file --
// see WidgetHostFunctions.zig's doc comment for why, and for the mutual
// `@import` this creates (this file needs the callbacks' function pointers
// by name for registerInto/registerClayInto below; that file needs this
// one's registry-internal helpers).
const HostFunctions = @import("WidgetHostFunctions.zig");

const Self = @This();

/// W16: bumped from 64 to 128 -- a real calendar grid (Date & time picker)
/// can have ~60 widgets live at once at peak (week rows, day-number
/// buttons, leading blank spacer cells, weekday/month headers, time
/// steppers), and clay-fixture's own natyv_init already created ~29 on top
/// of that before the picker was even opened.
///
/// W22: bumped from 128 to 192 -- Table's own demo (3 columns x a 6-row
/// permanent pool, each pool row a Button + 3 child Label cells, plus its
/// header row/buttons/spacers/viewport/wrapper -- ~32 widgets, see
/// table.go's own doc comment for why the pool is permanent rather than
/// created on demand) pushed clay-fixture's own natyv_init baseline to 94,
/// which the W16 calendar-grid peak above (94 + ~60) then genuinely
/// exceeded the old 128 cap with -- confirmed via a real `widget registry
/// full` test failure, not assumed. Every other fixed-size array in the
/// codebase keyed to widget count (DrawBatcher.zig, ClayLayout.zig's
/// snapshot buffer, the expiry-cascade buffers below) derives from this one
/// constant, so this is the only line that needs to change. Memory cost is
/// trivial (a few more KB across small fixed-size arrays of small
/// structs) -- a deliberate, explained bump per
/// feedback_natyv_memory_efficiency's own "as new widgets/capabilities
/// land" anticipation, not organic creep.
pub const max_widgets = 192;
// button/textfield/label create, set_text, get_text, destroy_widget (6) +
// checkbox/radio_button/progress_bar create (3) + get_checked/set_checked/
// get_value/set_value (4) -- W1 widget breadth. + slider create (1) -- W3.
// + natyv_set_range/natyv_get_range (2) -- W27 RangeSlider's own two-field
// accessor pair, always registered like set_value/get_value above.
// + textarea create (1) -- W10 (natyv_clay_create_textarea is counted
// separately in registerClayInto's own clay_host_function_count).
// + divider create (1) -- W11, same natyv_clay_create_divider split.
// + toggle create (1) -- W12, same natyv_clay_create_toggle split. Reuses
// the existing natyv_set_checked/natyv_get_checked host functions (no new
// ones needed for those), same as radio_button already does.
// + badge create (1) -- W14, same natyv_clay_create_badge split.
// + numeric_stepper/segmented_control create (2) -- W17, same
// natyv_clay_create_* split.
// Tabs (W19) adds no plain natyv_create_* function at all -- like
// Container, it's inherently a Clay parent/child + visibility construct,
// so it's Clay-only (see registerClayInto/clay_host_function_count below) --
// it never had a plain natyv_create_* function in registerInto's own count
// to begin with.
// + natyv_set_visible (1) -- Accordion, generic per-slot toggle, guest-
// composed rather than a new WidgetKind, so no Clay-side registration.
// + natyv_set_size (1) -- Tree view, generic per-slot Fixed-height resize,
// same "guest-composed, no new WidgetKind" reasoning as natyv_set_visible.
// + natyv_show_open_file_dialog/natyv_show_save_file_dialog (2) -- File
// picker, generic (unrelated to any WidgetKind at all -- these trigger a
// native OS dialog, not a Clay widget), same "always registered" reasoning
// as the block above.
// + natyv_set_style (1) -- Styling system Stage 2, generic per-slot
// resolved-style application, same "guest-composed, no new WidgetKind"
// reasoning as natyv_set_visible/natyv_set_size.
pub const host_function_count = 28;

pub const WidgetKind = enum { button, textfield, textarea, label, container, checkbox, toggle, radio_button, progress_bar, slider, range_slider, divider, badge, numeric_stepper, segmented_control, tabs, spinner };
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
    range_slider: RangeSlider,
    divider: Divider,
    badge: Badge,
    numeric_stepper: NumericStepper,
    segmented_control: SegmentedControl,
    tabs: Tabs,
    spinner: Spinner,

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
            .range_slider => |*rs| &rs.rect,
            .divider => |*d| &d.rect,
            .badge => |*bd| &bd.rect,
            .numeric_stepper => |*ns| &ns.rect,
            .segmented_control => |*sc| &sc.rect,
            .tabs => |*tb| &tb.rect,
            .spinner => |*sp| &sp.rect,
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
            // two-color draw, not a single conditional fill. W27: RangeSlider
            // joins for the same reason as Slider -- track + span-fill +
            // two thumbs, an even more custom draw than Slider's own.
            .label, .radio_button, .progress_bar, .slider, .range_slider, .toggle => null,
            // W11: unlike Container's opt-in background, a divider always
            // fills -- see Divider.zig's doc comment.
            .divider => |d| .{ .color = d.fillColor(), .rect = d.rect },
            // W14: same "always fills" precedent as Divider -- a Badge is
            // a pill, not a checkmark-on-demand.
            .badge => |bd| .{ .color = bd.fillColor(), .rect = bd.rect },
            // W17: both are multi-region custom draws (minus/plus zones,
            // or N segments) -- same "opts out of the single-color batched
            // fill" precedent Slider/Toggle already established.
            // W19: Tabs is the same kind of multi-region custom draw for its
            // own header strip; its panel content draws via the normal
            // per-child pass instead (real Clay children, each with their
            // own fillRect).
            // W29: Spinner joins the same "owns its whole draw" set --
            // multiple independently-scaled dots isn't a single solid-color
            // rect.
            .numeric_stepper, .segmented_control, .tabs, .spinner => null,
        };
    }

    /// Keyboard-interaction model: only `Button`/`TextField` can receive
    /// focus -- `Label`/`Container` are pure display/layout, never
    /// interactive. Used by `focusableIdsSorted` to decide which widgets
    /// participate in Tab order.
    pub fn isFocusable(self: Widget) bool {
        return switch (self) {
            .button, .textfield, .textarea, .checkbox, .toggle, .radio_button, .slider, .range_slider, .numeric_stepper, .segmented_control, .tabs => true,
            .label, .container, .progress_bar, .divider, .badge, .spinner => false,
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
            .range_slider => |*rs| rs.focused = focused,
            .numeric_stepper => |*ns| ns.focused = focused,
            .segmented_control => |*sc| sc.focused = focused,
            .tabs => |*tb| tb.focused = focused,
            .label, .container, .progress_bar, .divider, .badge, .spinner => {},
        }
    }

    /// Read-side counterpart to `setFocusedFlag`, used by `WidgetHost.setFocused`
    /// to detect whether a slot's `focused` flag is actually about to flip
    /// (so it only bumps `layout_generation` when something will actually
    /// look different on screen, same "no-op call, no pointless recompute"
    /// shape as `setVisible`/`setHeight`).
    pub fn isFocused(self: Widget) bool {
        return switch (self) {
            .button => |b| b.focused,
            .textfield => |t| t.focused,
            .textarea => |ta| ta.focused,
            .checkbox => |cb| cb.focused,
            .toggle => |tg| tg.focused,
            .radio_button => |r| r.focused,
            .slider => |s| s.focused,
            .range_slider => |rs| rs.focused,
            .numeric_stepper => |ns| ns.focused,
            .segmented_control => |sc| sc.focused,
            .tabs => |tb| tb.focused,
            .label, .container, .progress_bar, .divider, .badge, .spinner => false,
        };
    }
};

/// The Clay tree relationships/style a widget was created with -- only
/// `natyv_clay_*` host functions (L3) populate these for real; every widget
/// created via the plain `natyv_create_*` functions above keeps the
/// defaults (no parent, zeroed style), since its layout stays
/// guest-supplied absolute pixels. Stored per-slot (not recomputed) so the
/// render loop can redeclare each node to Clay every frame from data it
/// already has, without a second guest round trip.
/// Styling system Stage 5a. Named (not an inline anonymous struct) so the
/// same type identity can be shared between `ClayStyle.border`, `setStyle`,
/// and the host-function request shape -- two separately-written anonymous
/// `struct { ... }` literals are distinct types in Zig even when
/// structurally identical.
pub const Border = struct { width: f32, color: c.SDL_FColor };

/// Styling system Stage 5b. `start_uv`/`end_uv` are plain 0..1 shape-space
/// positions, already resolved from the stylesheet's named anchor
/// vocabulary (`topLeft`, etc.) at `natyv prepare` time -- see
/// ShapeCache.drawRoundedRectGradient's own doc comment for why this host
/// type stays anchor-agnostic.
pub const Gradient = struct { start_uv: [2]f32, start_color: c.SDL_FColor, end_uv: [2]f32, end_color: c.SDL_FColor };

pub const ClayStyle = struct {
    sizing: c.Clay_Sizing = std.mem.zeroes(c.Clay_Sizing),
    padding: c.Clay_Padding = std.mem.zeroes(c.Clay_Padding),
    /// Styling system Stage 2: `null` means "use this widget kind's own
    /// hardcoded default fill" (e.g. Container's `background: bool`
    /// still picks its fixed panel color) -- set only via `setStyle`
    /// below, real end-to-end proof that a resolved stylesheet token can
    /// actually change a widget's rendering. Consulted at the two
    /// `fillRect()` draw call sites in FrameLoop.zig, not inside each
    /// widget's own `fillColor()` -- keeps this override generic across
    /// every widget kind that already participates in the plain-fill draw
    /// path, with zero changes to their individual `fillColor()` methods.
    background_color: ?c.SDL_FColor = null,
    /// Styling system Stage 5a: same "`null` means use this widget's own
    /// default (square corners)" precedent as `background_color`. Order is
    /// TL/TR/BR/BL, matching the stylesheet's real CSS-clockwise
    /// convention (see `Resolver.zig`). Consulted at the same two
    /// `fillRect()` call sites -- when set, those sites draw through
    /// `ShapeCache.drawRoundedRect` instead of a plain `SDL_RenderFillRect`.
    corner_radius: ?[4]f32 = null,
    /// Styling system Stage 5a: `null` means no border drawn at all (not
    /// "zero-width border", which would be a wasted draw). Drawn via
    /// `ShapeCache.drawRoundedRectBorder` using the same `corner_radius`
    /// above, so a bordered widget's border always matches its own
    /// corners -- there's no separate border-radius concept.
    border: ?Border = null,
    /// Styling system Stage 5b: `null` means flat `background_color` fill
    /// (or the widget's own default, per that field's doc comment) --
    /// when set, takes precedence over `background_color` for the fill
    /// itself. Drawn via `ShapeCache.drawRoundedRectGradient` using the
    /// same `corner_radius` above; `border` (if also set) still draws its
    /// own flat color on top, borders don't have a gradient concept in
    /// this vocabulary.
    gradient: ?Gradient = null,
    /// Texture-fill styling system: `null` means no texture fill (flat
    /// `background_color`/`gradient` apply as normal, per those fields' own
    /// doc comments). Non-null is a real asset id -- an index into the
    /// per-app generated `TextureAssets.data` embedded-bytes array (see
    /// `build.zig`'s `-Dhas-textures` module swap), never a raw path or
    /// guest-supplied bytes; `natyv prepare`'s styling codegen is what
    /// resolves a stylesheet's `texture: "logo.png"` string into this id.
    /// Takes precedence over both `background_color` and `gradient` for the
    /// fill itself when set, same "most specific fill wins" precedent
    /// `gradient` already established over `background_color`.
    texture: ?u32 = null,
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
    /// W19: when false, `ClayLayout.openChildren` skips declaring this slot
    /// (and, since it never recurses into an undeclared slot, its entire
    /// subtree) in Clay's tree at all this frame -- it doesn't contribute to
    /// a `fit`-sized parent's sizing, isn't returned by `Clay_GetElementData`,
    /// and isn't drawn or hit-tested. This is the generic mechanism Tabs
    /// uses to show exactly one panel at a time while keeping every panel's
    /// widgets alive in the registry (no destroy/recreate churn) -- see
    /// `WidgetHost.setActiveTab`. Toggling this flips what `openChildren`
    /// declares, so any code path that changes it must also bump
    /// `layout_generation` or the next frame's cached-layout short-circuit
    /// in `layoutIfNeeded` will skip re-running Clay and the change won't
    /// appear. Defaults `true` so every existing widget kind (which never
    /// sets this) keeps behaving exactly as before.
    visible: bool = true,
    /// 2026-09-02: when false, a Button ignores clicks entirely (`tryHitWidget`
    /// treats it as a miss, no flash, no `.click` event) and renders dimmed
    /// (`Button.fillColor`/`drawDecorations`' border both override to a fixed
    /// muted gray regardless of any guest-set NTSS background color -- text
    /// itself can't be dimmed too, natyv's own label text color is hardcoded
    /// with no per-widget override, a real, separate, already-disclosed
    /// limitation). Generic on every slot, same "no coordination the host
    /// needs to own" reasoning `visible`/`natyv_set_visible` already
    /// established, though only `Button` actually reads it today -- built for
    /// a real "< N >" pager, disabled at either end instead of the buttons
    /// disappearing. Defaults `true` so every existing widget keeps behaving
    /// exactly as before.
    enabled: bool = true,
    /// Multi-window Stage 3: marks this slot as the root of a real second OS
    /// window (a plain `.container` underneath, same shape as any other
    /// Clay-managed root -- see `WindowManager.WindowContext` for the real
    /// `SDL_Window`/`SDL_Renderer`/`ClayLayout`/`TTF_TextEngine` this widget
    /// is paired with, owned outside the registry since those are main-
    /// thread-only OS resources). Always `parent_id == null` -- a real OS
    /// window can't be a Clay child of anything. Distinct from `floating`/
    /// `modal`/`toast`: those all layer content *within one window's own
    /// Clay context and draw pass*; this instead marks the boundary between
    /// two *separate* Clay contexts/renderers entirely, so it deliberately
    /// does NOT participate in `isFloatingOrDescendant`/`nearestFloatingRoot`
    /// (see those functions' own doc comments) -- there's no cross-window
    /// z-order question for them to answer. `FloatingOrder.windowSubset` is
    /// the corresponding per-window scoping helper: given a window's own
    /// root id (or `null` for the original startup window), it returns which
    /// widgets belong to that window's own subtree, for main.zig's per-
    /// window layout/hit-test/draw/text-sync passes to filter against.
    window_root: bool = false,
};

/// Styling system Stage 2: the fallback natyv applies to a text-bearing
/// widget's own draw position/wrap-width calculation when its configured
/// `clay_style.padding` is entirely zero on all four sides. `padding`
/// itself already flows real guest-requested values end-to-end (see
/// `WidgetHostFunctions.toClayStyle`) -- this only covers the common case
/// of a guest never having set it at all, which parses to the same all-
/// zero `ClayPaddingRequest{}` default as an explicit `padding: 0` request
/// (the wire format has no "unset" distinct from "zero," a real, accepted
/// imprecision rather than reworking every padding field into an Optional
/// for this). Text-bearing widgets (Label/Button/TextArea/TextField) call
/// `effectiveTextPadding` instead of reading `clay_style.padding` raw, so
/// text stops sitting flush against a widget's edge by default while still
/// respecting any real non-zero padding a guest actually configured.
pub const default_text_padding: u16 = 4;

pub fn effectiveTextPadding(p: c.Clay_Padding) c.Clay_Padding {
    if (p.left == 0 and p.right == 0 and p.top == 0 and p.bottom == 0) {
        return .{ .left = default_text_padding, .right = default_text_padding, .top = default_text_padding, .bottom = default_text_padding };
    }
    return p;
}

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
    /// Live scroll offset/dimensions, refreshed every real Clay layout pass
    /// (`ClayLayout.layoutIfNeeded`'s writeback loop, right alongside
    /// `.rect`) for any slot with `clay_style.scroll_vertical` or
    /// `.scroll_horizontal` -- `null` for every other slot. This is the
    /// cross-thread-safe copy `natyv_get_scroll_position` reads (see
    /// `pending_scroll_into_view`'s doc comment for why the host function
    /// can't just call Clay directly) -- always at most one real Clay pass
    /// stale, same staleness `.rect` itself already has between passes.
    scroll_data: ?ScrollBar.Data = null,
};

/// W19 follow-up: whether `slot` should actually be drawn/hit-tested this
/// frame -- true only if `slot.clay_style.visible` AND every ancestor's
/// (walked via `parent_id`) is also `true`. `ClayLayout.openChildren`'s own
/// skip (`if (!slot.clay_style.visible) continue`) is correct as-is because
/// it's recursive -- skipping a slot there means its own children are never
/// even visited, so *they* never get redeclared to Clay regardless of their
/// own `visible` flag. But `visible` is never propagated down to children's
/// own `clay_style` -- a hidden Tabs panel's child Label keeps its own
/// default `visible == true` -- so any *flat* per-slot check (main.zig's
/// draw loops, `tryHitWidget`) that only reads `slot.clay_style.visible`
/// directly will happily draw/hit-test that Label using its last real
/// (now-stale, since Clay stopped recomputing it) rect. Caught via Quinn's
/// real click-through (2026-08-18): switching Tabs left every previous
/// tab's content visually stacked on screen instead of disappearing, even
/// though only the newly-selected panel was still being laid out -- same
/// "fix applied to the parent, not propagated to descendants" class of bug
/// as the W15 tooltip-overflow fix's round 2. `slots` is a snapshot slice
/// (same shape `FloatingOrder.zig`'s own ancestor-walk helpers take), not
/// the live locked registry -- callers already have one from `snapshot()`.
pub fn isEffectivelyVisible(slots: []const Slot, index: SnapshotIndex, slot: Slot) bool {
    if (!slot.clay_style.visible) return false;
    var current = slot.parent_id;
    while (current) |pid| {
        const p = index.find(slots, pid) orelse return true; // orphaned parent id -- shouldn't normally happen, no ancestor constraint to apply
        if (!p.clay_style.visible) return false;
        current = p.parent_id;
    }
    return true;
}

/// Fixed-capacity, allocation-free id -> `Slot` lookup over a snapshot slice
/// (`[]const Slot`) -- distinct from `id_to_index` above, which only ever
/// indexes the *live* registry's own `self.slots`, never a copied-out
/// snapshot handed around by value. `isEffectivelyVisible` above and
/// `FloatingOrder.zig`/`ScrollClip.zig`/`ClayLayout.zig`'s own ancestor-walk
/// helpers all used to re-scan the whole snapshot slice linearly on every
/// single step of every walk; building one of these once per real "process
/// this snapshot" call and reusing it for every walk that call makes turns
/// each step into a real O(1) average lookup.
///
/// Open-addressing (linear probing) over a fixed-size array, not
/// `std.AutoHashMapUnmanaged` (unlike `id_to_index` above) -- these are all
/// pure, allocator-free functions today, some called directly from tests
/// with no allocator anywhere in scope, and introducing one here would be a
/// real, unwanted architecture change just to look up a handful of ids per
/// frame (see feedback_natyv_memory_efficiency's own "bounded by design"
/// convention). `capacity` is a power of two (so probing can use a bitmask,
/// not `%`) comfortably above `max_widgets` -- load factor stays <= ~0.4
/// even when every slot is live at once, keeping the average probe chain
/// short.
pub const SnapshotIndex = struct {
    // Coupled to `max_widgets` (192) the same way DrawBatcher/ClayLayout's
    // own snapshot buffers already are -- comfortably above it (~0.375 load
    // factor at the hard cap) so probe chains stay short. If `max_widgets`
    // is ever bumped again (it's been bumped twice already), revisit this
    // alongside it.
    const capacity = 512;
    const empty: u32 = std.math.maxInt(u32);

    slot_of: [capacity]u32 = [_]u32{empty} ** capacity,

    pub fn build(slots: []const Slot) SnapshotIndex {
        var self: SnapshotIndex = .{};
        for (slots, 0..) |slot, i| {
            var probe = slot.id & (capacity - 1);
            while (self.slot_of[probe] != empty) : (probe = (probe + 1) & (capacity - 1)) {}
            self.slot_of[probe] = @intCast(i);
        }
        return self;
    }

    /// `slots` must be the exact same slice `build` was called with --
    /// this only ever stores indices into it, never copies of its data.
    pub fn find(self: SnapshotIndex, slots: []const Slot, id: u32) ?Slot {
        var probe = id & (capacity - 1);
        var probes: usize = 0;
        while (probes < capacity) : (probes += 1) {
            const si = self.slot_of[probe];
            if (si == empty) return null;
            if (slots[si].id == id) return slots[si];
            probe = (probe + 1) & (capacity - 1);
        }
        return null;
    }
};

allocator: std.mem.Allocator,
mutex: Io.Mutex = .init,
slots: [max_widgets]?Slot = [_]?Slot{null} ** max_widgets,
next_id: u32 = 1,
/// id -> index into `slots`, kept in sync at every real site a slot ever
/// gets assigned or freed (`insertLockedWithLayout`; `destroySubtreeLocked`,
/// the cascading-destroy path; and `WidgetHostFunctions.destroyWidgetHostFn`,
/// `natyv_destroy_widget`'s own single-widget, no-cascade path, which nulls
/// a slot inline rather than going through `destroySubtreeLocked`) -- turns
/// `findLocked` from an O(max_widgets) linear scan into an O(1) lookup.
/// `destroyWidgetHostFn` was missed on the first pass (grepped only this
/// file for null-assignment sites, not the whole tree) and shipped a real,
/// reproducible crash: `natyv_destroy_widget` nulled the slot without
/// removing the map entry, so any later `findLocked` on that id found a
/// stale index pointing at a `null` slot and panicked on `self.slots[idx].?`
/// -- caught by Quinn's own real click-through on `clay-fixture`, not by
/// any unit test (every test exercised `destroySubtreeLocked`'s cascading
/// path, never the everyday single-widget destroy the fixture's own
/// hover/click demo widgets actually use). Stores an index, not a `*Slot`
/// pointer, so it stays valid even if `self` itself is ever moved/copied
/// (a raw self-pointer wouldn't be). `.empty` (not `.init(allocator)`)
/// matches this codebase's own established `ArrayList`-unmanaged
/// convention -- no separate `WidgetHost.init`/`.deinit` lifecycle
/// exists today (every real construction site is a plain struct
/// literal), so this needs to work with that same zero-init shape.
id_to_index: std.AutoHashMapUnmanaged(u32, usize) = .empty,
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
/// Scroll-into-view: same cross-thread hand-off shape as
/// `pending_text_destroys` above, for the same reason -- Clay's live scroll
/// offset lives behind a single global, non-thread-safe C context
/// (`Clay__currentContext`), and `natyv_scroll_into_view` (called from
/// `natyv_dispatch` on the worker thread) can't touch it directly without
/// racing the main thread's own `Clay_UpdateScrollContainers`/layout pass.
/// `queueScrollIntoView` (worker thread) just stashes the target widget id
/// here; `ClayLayout.applyScrollIntoView` (called once per frame from
/// `main.zig`, main thread, via `takePendingScrollIntoView`) does the real
/// Clay work. `null` means nothing pending. A second request before the
/// first is drained simply overwrites -- no ordering guarantee needed for
/// this (see `queueScrollIntoView`'s own doc comment).
pending_scroll_into_view: ?u32 = null,

/// Same cross-thread hand-off shape as `pending_scroll_into_view` above,
/// for the same class of reason: `SDL_ShowOpenFileDialog`/
/// `SDL_ShowSaveFileDialog` must be called from the main thread (per SDL's
/// own documented `\threadsafety`), but the host function that queues this
/// (`natyv_show_open_file_dialog`/`natyv_show_save_file_dialog`) runs on
/// the worker thread, same as every `natyv_dispatch`-invoked host call.
/// `main.zig`'s frame loop drains this once per frame and makes the real
/// SDL call there -- see its own doc comment for how the eventual result
/// gets back to the guest (a new `.file_selected` EventQueue event, not
/// this same hand-off in reverse -- SDL's callback can land on any thread,
/// not necessarily the main thread that made the call). `null` means
/// nothing pending; a second request before the first drains simply
/// overwrites -- same "no ordering guarantee needed" reasoning
/// `queueScrollIntoView` already documents, and realistic use only ever has
/// one dialog open at a time regardless. Uses the named
/// `PendingFileDialogRequest` type (declared below, after every field --
/// same Zig field-then-decl ordering requirement `PendingSetScrollPosition`
/// already ran into this session).
pending_file_dialog_request: ?PendingFileDialogRequest = null,

/// Multi-window Stage 4: same cross-thread hand-off shape as
/// `pending_file_dialog_request` above (real SDL/Clay/TTF window creation
/// must happen on the main thread, but `natyv_clay_create_window` runs on
/// the worker thread), but a real bounded *array*, not a single slot -- the
/// file-dialog precedent's single-pending-slot shape doesn't transfer here.
/// File dialogs are gated by a real one-at-a-time OS-modal interaction;
/// window creation isn't -- a guest could call `natyv_clay_create_window`
/// several times in one `natyv_dispatch` handler before the main thread ever
/// drains anything, and a single slot would silently lose all but the last
/// request. `main.zig`'s frame loop drains this in full every frame (not one
/// per frame -- each materialization is cheap, no reason to throttle),
/// calling `WindowManager.createWindowContext` for each. The widget's own
/// `window_root` `Slot` already exists in the registry by the time this is
/// queued (`createClayWindowHostFn` inserts it synchronously, same as every
/// other `natyv_clay_create_*`, so the guest can parent children under it
/// immediately) -- this queue only carries what's needed to materialize the
/// *real* OS window a frame or so later. Named types (`PendingWindowRequest`,
/// `max_pending_window_requests`) declared below, after every field -- same
/// Zig field-then-decl ordering requirement `PendingFileDialogRequest` right
/// below already runs into.
pending_window_requests: [max_pending_window_requests]?PendingWindowRequest = [_]?PendingWindowRequest{null} ** max_pending_window_requests,
pending_window_request_count: usize = 0,

/// Multi-window Stage 4: the teardown counterpart to
/// `pending_window_requests` above -- widget ids of `window_root` slots
/// whose real OS resources (`WindowManager.WindowContext`) `main.zig` should
/// tear down next frame. `natyv_destroy_window` (worker thread) has already
/// destroyed the widget subtree itself (via `destroyWindowSubtree`, safe to
/// call from any thread -- it queues each widget's `TTF_Text` for the main
/// thread to actually destroy via `pending_text_destroys`, the same
/// `destroyWidgetHostFn` already relies on, rather than calling
/// `TTF_DestroyText` directly; see `destroySubtreeLocked`'s own doc comment
/// for a real cross-thread crash this exact queuing was added to fix) by the
/// time this is queued -- this only carries the still-pending *real*
/// SDL/Clay/TTF teardown, which is main-thread-only.
/// Same bounded-array-not-single-slot reasoning as the request queue above
/// (a guest could call `natyv_destroy_window` on more than one window in a
/// single dispatch handler).
pending_window_teardowns: [max_pending_window_requests]?u32 = [_]?u32{null} ** max_pending_window_requests,
pending_window_teardown_count: usize = 0,

/// `allow_many` is ignored for `.save` -- `SDL_ShowSaveFileDialog` has no
/// such parameter, only `SDL_ShowOpenFileDialog` does.
pub const PendingFileDialogRequest = struct {
    kind: enum { open, save },
    widget_id: u32,
    allow_many: bool,
};

/// Multi-window Stage 4: small fixed cap on in-flight window creation/
/// teardown requests per frame -- same "bump later if a real need shows up"
/// precedent `max_widgets`/`WindowManager.max_open_windows` already set. A
/// guest realistically never queues anywhere near this many window
/// operations in the time between two frames.
pub const max_pending_window_requests = 8;

/// A guest's requested window title, copied into this owned fixed buffer at
/// request time -- guest memory isn't guaranteed to outlive the host call,
/// same precedent `Button.label_buf` already established for exactly this
/// reason. `title_len` bytes of `title_buf` are the real title; the rest is
/// unspecified.
pub const PendingWindowRequest = struct {
    widget_id: u32,
    title_buf: [64]u8,
    title_len: usize,
    width: f32,
    height: f32,
};

/// Worker-thread side of the window-creation hand-off -- returns `false`
/// (queues nothing) if the queue is already full this frame, so the caller
/// can undo its own registry insert instead of leaving an orphaned
/// `window_root` widget with no real window ever materializing for it.
pub fn queueWindowRequest(self: *Self, call_io: Io, req: PendingWindowRequest) bool {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.pending_window_request_count >= self.pending_window_requests.len) return false;
    self.pending_window_requests[self.pending_window_request_count] = req;
    self.pending_window_request_count += 1;
    return true;
}

/// Main-thread side -- drains every pending request into `out` (bounded by
/// `out.len`, though it's always sized `max_pending_window_requests` by
/// every real caller), returns how many were written.
pub fn takePendingWindowRequests(self: *Self, call_io: Io, out: []PendingWindowRequest) usize {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const n = @min(self.pending_window_request_count, out.len);
    for (0..n) |i| out[i] = self.pending_window_requests[i].?;
    self.pending_window_request_count = 0;
    return n;
}

/// Worker-thread side of the window-teardown hand-off -- silently drops the
/// request if the queue is already full this frame (same "tiny, practically
/// unreachable leak preferable to a panic in a guest-facing host function"
/// precedent `queuePendingTextDestroy` already establishes); the widget
/// subtree itself is already gone from the registry by the time this would
/// be called regardless (see this field's own doc comment), so a dropped
/// entry here only delays real OS resource cleanup, not a correctness gap.
pub fn queueWindowTeardown(self: *Self, call_io: Io, widget_id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.pending_window_teardown_count >= self.pending_window_teardowns.len) return;
    self.pending_window_teardowns[self.pending_window_teardown_count] = widget_id;
    self.pending_window_teardown_count += 1;
}

/// Main-thread side -- same drain-in-full shape as `takePendingWindowRequests`.
pub fn takePendingWindowTeardowns(self: *Self, call_io: Io, out: []u32) usize {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const n = @min(self.pending_window_teardown_count, out.len);
    for (0..n) |i| out[i] = self.pending_window_teardowns[i].?;
    self.pending_window_teardown_count = 0;
    return n;
}

/// Registers every widget kind's create-function unconditionally -- widgets
/// are declarative purely through use of their tag in `.ntx` markup, with no
/// separate per-app opt-in step (confirmed decision, 2026-08-29: matches how
/// `Container` already worked, see the "not gated" comment above; the
/// previous per-kind `conf.natyv.json` `widgets.*` gate never actually added
/// real enforcement value once every kind defaulted through the same guest
/// SDK path, so it was a pure config-surface cost with no offsetting
/// benefit -- unlike `sqlite`/`network`, which remain real, enforced gates).
pub fn registerInto(self: *Self, funcs_out: []?*const c.ExtismFunction) usize {
    const in_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const out_types = [_]c.ExtismValType{c.ExtismValType_I64};
    var n: usize = 0;
    funcs_out[n] = c.extism_function_new("natyv_create_button", &in_types[0], 1, &out_types[0], 1, HostFunctions.createButtonHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_textfield", &in_types[0], 1, &out_types[0], 1, HostFunctions.createTextFieldHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_textarea", &in_types[0], 1, &out_types[0], 1, HostFunctions.createTextAreaHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_label", &in_types[0], 1, &out_types[0], 1, HostFunctions.createLabelHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_checkbox", &in_types[0], 1, &out_types[0], 1, HostFunctions.createCheckboxHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_toggle", &in_types[0], 1, &out_types[0], 1, HostFunctions.createToggleHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_radio_button", &in_types[0], 1, &out_types[0], 1, HostFunctions.createRadioButtonHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_progressbar", &in_types[0], 1, &out_types[0], 1, HostFunctions.createProgressBarHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_slider", &in_types[0], 1, &out_types[0], 1, HostFunctions.createSliderHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_divider", &in_types[0], 1, &out_types[0], 1, HostFunctions.createDividerHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_badge", &in_types[0], 1, &out_types[0], 1, HostFunctions.createBadgeHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_numeric_stepper", &in_types[0], 1, &out_types[0], 1, HostFunctions.createNumericStepperHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_create_segmented_control", &in_types[0], 1, &out_types[0], 1, HostFunctions.createSegmentedControlHostFn, self, null);
    n += 1;
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
    // Accordion: generic per-slot visibility toggle, guest-composed (see
    // Accordion's own doc comment on `HostFunctions.setVisibleHostFn`) --
    // same "always registered" reasoning as the block above.
    funcs_out[n] = c.extism_function_new("natyv_set_visible", &in_types[0], 1, &out_types[0], 1, HostFunctions.setVisibleHostFn, self, null);
    n += 1;
    // A real "< N >" pager: generic per-slot disabled toggle, guest-composed
    // (see `ClayStyle.enabled`'s own doc comment) -- same "always
    // registered" reasoning as the block above.
    funcs_out[n] = c.extism_function_new("natyv_set_enabled", &in_types[0], 1, &out_types[0], 1, HostFunctions.setEnabledHostFn, self, null);
    n += 1;
    // Tree view: generic per-slot Fixed-height resize, guest-composed (see
    // `HostFunctions.setSizeHostFn`'s own doc comment) -- same "always
    // registered" reasoning as the block above.
    funcs_out[n] = c.extism_function_new("natyv_set_size", &in_types[0], 1, &out_types[0], 1, HostFunctions.setSizeHostFn, self, null);
    n += 1;
    // Styling system Stage 2: applies already-resolved style values
    // (background color, padding) to an existing widget -- generic,
    // guest-composed, same "always registered" reasoning as the rest of
    // this block. See `HostFunctions.setStyleHostFn`'s own doc comment for
    // why this takes resolved values, never style-token names.
    funcs_out[n] = c.extism_function_new("natyv_set_style", &in_types[0], 1, &out_types[0], 1, HostFunctions.setStyleHostFn, self, null);
    n += 1;
    // File picker: generic, unrelated to any WidgetKind (a native OS
    // dialog, not a Clay widget) -- same "always registered" reasoning as
    // the block above.
    funcs_out[n] = c.extism_function_new("natyv_show_open_file_dialog", &in_types[0], 1, &out_types[0], 1, HostFunctions.showOpenFileDialogHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_show_save_file_dialog", &in_types[0], 1, &out_types[0], 1, HostFunctions.showSaveFileDialogHostFn, self, null);
    n += 1;
    // W27: RangeSlider's own two-field (min/max) counterpart to
    // natyv_set_value/natyv_get_value above -- a plain {"value":f} shape
    // doesn't fit a span, so this is its own pair rather than overloading
    // the single-value one. Same "always registered" reasoning as every
    // other generic accessor in this block: a guest can't get a widget_id
    // to call this with unless it already had permission to create that
    // widget in the first place.
    funcs_out[n] = c.extism_function_new("natyv_set_range", &in_types[0], 1, &out_types[0], 1, HostFunctions.setRangeHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_get_range", &in_types[0], 1, &out_types[0], 1, HostFunctions.getRangeHostFn, self, null);
    n += 1;
    return n;
}

// W19: +2 for natyv_clay_create_tabs/natyv_clay_create_tab_panel.
// + natyv_get_scroll_position/natyv_scroll_into_view (2) -- scroll-into-view
// for Accordion, plus the general scroll-position getter already flagged
// for Table/data grid's future virtualization.
// W27: +1 for natyv_clay_create_range_slider.
// W29: +1 for natyv_clay_create_spinner.
// Multi-window Stage 4: +2 for natyv_clay_create_window/natyv_destroy_window
// -- the latter deliberately isn't `_clay_`-prefixed (semantically closer to
// the generic `natyv_destroy_widget` family, just cascading), but it's a
// real second OS window that categorically doesn't exist outside the Clay
// backend, so it's registered here alongside its create counterpart, not in
// registerInto's always-on block.
pub const clay_host_function_count = 22;

/// Registered only when conf.natyv.json's `ui.backend == "clay"` --
/// Runtime.loadPlugin gates this the same way `sqlite`/`network` gate their
/// own host functions (see Config.zig's UiConfig; unlike those two real
/// capability gates, plain widget-kind registration in `registerInto` above
/// is always-on and ungated). These only
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
    funcs_out[12] = c.extism_function_new("natyv_clay_create_numeric_stepper", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayNumericStepperHostFn, self, null);
    funcs_out[13] = c.extism_function_new("natyv_clay_create_segmented_control", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClaySegmentedControlHostFn, self, null);
    funcs_out[14] = c.extism_function_new("natyv_clay_create_tabs", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayTabsHostFn, self, null);
    funcs_out[15] = c.extism_function_new("natyv_clay_create_tab_panel", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayTabPanelHostFn, self, null);
    // Scroll-into-view: Clay-only (scroll containers don't exist outside
    // the Clay backend), so registered here rather than registerInto -- see
    // pending_scroll_into_view's own doc comment for the cross-thread
    // design this pair exists for.
    funcs_out[16] = c.extism_function_new("natyv_get_scroll_position", &in_types[0], 1, &out_types[0], 1, HostFunctions.getScrollPositionHostFn, self, null);
    funcs_out[17] = c.extism_function_new("natyv_scroll_into_view", &in_types[0], 1, &out_types[0], 1, HostFunctions.scrollIntoViewHostFn, self, null);
    funcs_out[18] = c.extism_function_new("natyv_clay_create_range_slider", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayRangeSliderHostFn, self, null);
    funcs_out[19] = c.extism_function_new("natyv_clay_create_spinner", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClaySpinnerHostFn, self, null);
    funcs_out[20] = c.extism_function_new("natyv_clay_create_window", &in_types[0], 1, &out_types[0], 1, HostFunctions.createClayWindowHostFn, self, null);
    funcs_out[21] = c.extism_function_new("natyv_destroy_window", &in_types[0], 1, &out_types[0], 1, HostFunctions.destroyWindowHostFn, self, null);
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
    for (&self.slots, 0..) |*slot, idx| {
        if (slot.* == null) {
            const id = self.next_id;
            self.next_id += 1;
            // Inserted into the map *before* the slot itself, so a failed
            // put (OOM) leaves this a clean no-op -- the slot stays null,
            // and the skipped id is simply never reused (harmless: ids
            // were never required to be contiguous).
            self.id_to_index.put(self.allocator, id, idx) catch return null;
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

/// Same shape/caller as `setRect` above (called from `ClayLayout`'s own
/// writeback loop, right alongside it) -- writes a fresh cross-thread-safe
/// copy of a scroll container's live Clay data into its `Slot`. See
/// `Slot.scroll_data`'s own doc comment.
pub fn setScrollData(self: *Self, call_io: Io, id: u32, data: ScrollBar.Data) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| slot.scroll_data = data;
}

/// `pub` -- see `io`'s doc comment above. O(1) via `id_to_index` --
/// previously an O(max_widgets) linear scan; the id->index invariant is
/// maintained by `insertLockedWithLayout`/`destroySubtreeLocked`, the
/// only two places a slot is ever assigned or freed.
pub fn findLocked(self: *Self, id: u32) ?*Slot {
    const idx = self.id_to_index.get(id) orelse return null;
    return &(self.slots[idx].?);
}

/// Frees `id_to_index`'s own backing memory -- the fixed-size `slots`
/// array needs no equivalent, but a hash map does. Not called anywhere
/// yet (no `Runtime.deinit`-style teardown reaches `WidgetHost` today),
/// wired in alongside this change so the leak-checked GPA in debug
/// builds doesn't start reporting one the moment this map exists.
pub fn deinit(self: *Self) void {
    self.id_to_index.deinit(self.allocator);
}

/// F3: creates/updates every button/textfield/label's cached `TTF_Text`
/// against the *live* registry, once per frame, before that frame's
/// `snapshot` below is taken -- same "mutate the registry, then snapshot
/// sees the fresh result" ordering `ClayLayout.layoutIfNeeded` already
/// established for computed geometry (see main.zig's frame loop). Each
/// widget's own `syncText` decides whether it actually needs to touch
/// SDL_ttf at all this frame (see e.g. `Button.syncText`'s doc comment).
///
/// Multi-window Stage 3: `allowed_ids` scopes this call to one window's own
/// widget subset -- required, not optional, once a second `TTF_TextEngine`
/// can exist: a `TTF_Text` is renderer-specific (created against whichever
/// engine `syncText` is handed), so syncing a widget that belongs to window
/// B against window A's engine would produce a `TTF_Text` window A's own
/// renderer can't draw. Callers compute this once per frame per window via
/// `FloatingOrder.windowSubset` over a structural snapshot (parent_id/
/// window_root don't change from text syncing itself, so a snapshot taken
/// just before this loop, not necessarily this exact frame's final one, is
/// fine -- see main.zig's own per-frame ordering). This file can't import
/// `FloatingOrder.zig` directly (that file already imports this one), so the
/// filtering happens caller-side; this just takes the resolved id list.
pub fn syncTextObjects(self: *Self, call_io: Io, engine: *c.TTF_TextEngine, font: *c.TTF_Font, allowed_ids: []const u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            if (std.mem.indexOfScalar(u32, allowed_ids, s.id) == null) continue;
            switch (s.widget) {
                .button => |*b| {
                    // Real button auto-width (2026-09-02): a `width: fit`
                    // button's own real size depends on `b.measured_width`,
                    // which only changes right here, on a real resync
                    // (`sync_count` bump) -- but text syncing has always
                    // been orthogonal to `layout_generation` (Clay has no
                    // idea text exists at all, see ClayLayout.zig's own
                    // header comment), so without this, a *second* real
                    // relayout picking up the corrected width would simply
                    // never happen: the first-ever layout pass for a new
                    // Fit-width button runs *before* its first text sync
                    // (see main.zig's own frame ordering), so it always
                    // measures 0 and nothing would ever ask Clay to try
                    // again. Scoped to Fit-width buttons specifically --
                    // a Fixed/Grow button's own width never depends on
                    // measured_width, so its own text changes have nothing
                    // new to relayout for.
                    const before = b.sync_count;
                    b.syncText(engine, font);
                    if (b.sync_count != before and s.clay_style.sizing.width.type == c.CLAY__SIZING_TYPE_FIT) {
                        self.layout_generation +%= 1;
                    }
                },
                .textfield => |*t| t.syncText(engine, font),
                .textarea => |*ta| ta.syncText(engine, font, effectiveTextPadding(s.clay_style.padding)),
                .label => |*l| l.syncText(engine, font, effectiveTextPadding(s.clay_style.padding)),
                .checkbox => |*cb| cb.syncText(engine, font),
                .toggle => |*tg| tg.syncText(engine, font),
                .radio_button => |*r| r.syncText(engine, font),
                .badge => |*bd| bd.syncText(engine, font),
                .numeric_stepper => |*ns| ns.syncText(engine, font),
                .segmented_control => |*sc| sc.syncText(engine, font),
                .tabs => |*tb| tb.syncText(engine, font),
                .container, .progress_bar, .slider, .range_slider, .divider, .spinner => {},
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
                .numeric_stepper => |*ns| ns.destroyText(),
                .segmented_control => |*sc| sc.destroyText(),
                .tabs => |*tb| tb.destroyText(),
                .container, .progress_bar, .slider, .range_slider, .divider, .spinner => {},
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

/// `true` when any slot has a real `expires_at_ms` set, regardless of
/// whether it's actually due yet -- `main.zig`'s idle-CPU wait-mode
/// decision needs this: `destroyExpiredWidgets` above only ever runs when
/// the main loop wakes for some other reason, so a toast-style expiring
/// widget with nothing else happening on screen would never get cleaned up
/// under an indefinite `SDL_WaitEvent` wait. Forces the short-timeout wait
/// to stay active for as long as *anything* has a pending expiry, so the
/// loop keeps checking every `frame_wait_timeout_ms` until it's actually
/// due -- correct but not maximally efficient (it doesn't compute the
/// exact nearest deadline), a deliberate simplicity/safety tradeoff over a
/// precise dynamic timeout.
pub fn hasPendingExpiry(self: *Self, call_io: Io) bool {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    for (self.slots) |maybe_slot| {
        if (maybe_slot) |s| {
            if (s.expires_at_ms != null) return true;
        }
    }
    return false;
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
                    // Multi-window Stage 5 fix: queues each widget's
                    // TTF_Text for the main thread to actually destroy next
                    // frame (see queueWidgetTextDestroysLocked's own doc
                    // comment), rather than calling TTF_DestroyText
                    // directly here. This function's only caller used to be
                    // destroyExpiredWidgets, always main-thread (called from
                    // main.zig's own frame loop) -- direct destruction was
                    // only ever safe by virtue of that, not because this
                    // function is inherently thread-safe. destroyWindowSubtree
                    // (Stage 4) calls this too, from the *worker* thread
                    // (natyv_destroy_window's host function) -- a real,
                    // confirmed cross-thread SDL_ttf corruption bug, caught
                    // via a real crash ("member access within misaligned
                    // address... TTF_TextData") clicking a window's own
                    // Close button live, not by inspection. The doc comment
                    // on destroyWindowSubtree that claimed this was already
                    // safe "the same way every other destroy path in this
                    // file already is" was wrong -- it asserted an unverified
                    // claim about a function whose only real caller had
                    // never actually exercised the worker-thread path.
                    self.queueWidgetTextDestroysLocked(&s.widget);
                    if (s.clay_managed) self.layout_generation +%= 1;
                    _ = self.id_to_index.remove(s.id);
                    slot.* = null;
                    break;
                }
            }
        }
    }
}

/// Destroys a window's own root (a `window_root` slot) and every
/// descendant -- the cascading counterpart `natyv_destroy_widget`
/// deliberately doesn't provide (see that function's own no-cascade
/// contract, and `destroyExpiredWidgets`'s doc comment for why a
/// whole-window teardown needs the cascade the same way an expired toast's
/// does). Reuses the same two-phase `destroySubtreeLocked` every other
/// cascading destroy path in this file already goes through -- safe to call
/// from any thread, including the worker thread `natyv_destroy_window`
/// (Stage 4) calls this from, since `destroySubtreeLocked` only ever queues
/// each widget's `TTF_Text` for later main-thread destruction, never calls
/// `TTF_DestroyText` itself.
pub fn destroyWindowSubtree(self: *Self, call_io: Io, root_id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    self.destroySubtreeLocked(root_id);
}

/// `natyv_destroy_widget`'s own real implementation, as of the mail-natyv
/// demo app's own real UI work -- cascading is now the default, not the
/// single-widget-only contract this function's own doc comment used to
/// describe. Real motivation: an app dynamically rebuilding a view (an
/// inbox list, a compose form) previously had to track and individually
/// `Destroy()` every single widget it ever created, since destroying just
/// the view's own outer container left every child orphaned in the
/// registry (a still-live slot with a now-null `parent_id` target) --
/// exactly the kind of foot-gun `destroySubtreeLocked` already exists to
/// avoid for `destroyExpiredWidgets`/`destroyWindowSubtree`, just never
/// generalized to the plain guest-facing destroy call until now. Returns
/// `false` if `root_id` doesn't correspond to any real widget -- the
/// caller's job to report as a clear error, matching the original
/// single-widget destroy's own "no such widget" contract;
/// `destroySubtreeLocked` itself silently no-ops on an unknown id, since
/// its own other two real callers never needed to distinguish that case.
pub fn destroyWidgetSubtree(self: *Self, call_io: Io, root_id: u32) bool {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(root_id) == null) return false;
    self.destroySubtreeLocked(root_id);
    return true;
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
        .numeric_stepper => |*ns| self.queuePendingTextDestroy(&ns.text_obj),
        // W17: up to `SegmentedControl.max_segments` (6) text objects per
        // widget -- still well within `pending_text_destroys`' documented
        // "practically unreachable" slack (256 slots) for any realistic
        // number of segmented controls destroyed in a single frame.
        .segmented_control => |*sc| for (0..sc.count) |i| self.queuePendingTextDestroy(&sc.text_objs[i]),
        // W19: same "up to max_tabs text objects" shape as SegmentedControl.
        .tabs => |*tb| for (0..tb.count) |i| self.queuePendingTextDestroy(&tb.text_objs[i]),
        .container, .progress_bar, .slider, .range_slider, .divider, .spinner => {},
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

/// Worker-thread side of the scroll-into-view hand-off -- see
/// `pending_scroll_into_view`'s own doc comment for why this can't just call
/// into Clay directly.
pub fn queueScrollIntoView(self: *Self, call_io: Io, widget_id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    self.pending_scroll_into_view = widget_id;
}

/// Main-thread side -- called once per frame from `main.zig`, returns and
/// clears whatever's pending (`null` if nothing is).
pub fn takePendingScrollIntoView(self: *Self, call_io: Io) ?u32 {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const id = self.pending_scroll_into_view;
    self.pending_scroll_into_view = null;
    return id;
}

/// Worker-thread side of the file-dialog request hand-off -- see
/// `pending_file_dialog_request`'s own doc comment.
pub fn queueFileDialogRequest(self: *Self, call_io: Io, req: PendingFileDialogRequest) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    self.pending_file_dialog_request = req;
}

/// Main-thread side -- called once per frame from `main.zig`, returns and
/// clears whatever's pending (`null` if nothing is).
pub fn takePendingFileDialogRequest(self: *Self, call_io: Io) ?PendingFileDialogRequest {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const req = self.pending_file_dialog_request;
    self.pending_file_dialog_request = null;
    return req;
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
/// IME/text composition). Bumps `layout_generation` when any slot's
/// `focused` flag actually flips -- the focus ring is drawn purely off that
/// flag with no `needsContinuousRedraw` exception (unlike Spinner/Button's
/// flash), so without this bump `FrameLoop.drawWindow`'s draw-level dirty
/// check (added by the idle-CPU render-loop fix) would skip redrawing it
/// entirely until some unrelated generation-bumping event happened to also
/// occur -- caught live: focus visibly moved with no ring shown until the
/// user started typing, which bumps generation via the text edit itself.
pub fn setFocused(self: *Self, call_io: Io, id: ?u32) bool {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    var focused_wants_text_input = false;
    var changed = false;
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            const this_one = id != null and s.id == id.?;
            if (s.widget.isFocused() != this_one) changed = true;
            s.widget.setFocusedFlag(this_one);
            if (this_one and (s.widget == .textfield or s.widget == .textarea)) focused_wants_text_input = true;
        }
    }
    if (changed) self.layout_generation +%= 1;
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
/// Bumps `layout_generation` on every real toggle -- the checked mark is a
/// purely visual difference (Clay never sees `checked`), but
/// `FrameLoop.drawWindow`'s draw-level dirty check (idle-CPU render-loop
/// fix) means "purely visual" no longer implies "always redrawn anyway";
/// see `WidgetHost.setFocused`'s doc comment for the full reasoning.
pub fn toggleCheckbox(self: *Self, call_io: Io, id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| {
        if (slot.widget == .checkbox) {
            slot.widget.checkbox.toggle();
            self.layout_generation +%= 1;
        }
    }
}

/// W12: the `.toggle`-kind counterpart to `toggleCheckbox` above -- kept as
/// its own function (not a generalization of `toggleCheckbox` to any
/// bool-state kind) since `Checkbox` and `Toggle` are otherwise-unrelated
/// widget kinds sharing this file only by convention, and generalizing here
/// would mean touching `toggleCheckbox`'s already-shipped, tested body for
/// no functional gain.
/// Bumps `layout_generation` on every real toggle -- same reasoning as
/// `toggleCheckbox` just above.
pub fn toggleToggle(self: *Self, call_io: Io, id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| {
        if (slot.widget == .toggle) {
            slot.widget.toggle.toggle();
            self.layout_generation +%= 1;
        }
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
/// Bumps `layout_generation` when the selection actually moved -- same
/// draw-level-dirty-check reasoning as `toggleCheckbox`/`setFocused`.
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
    var changed = false;
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            if (s.widget == .radio_button and s.widget.radio_button.group_id == group_id) {
                const should_select = s.id == id;
                if (s.widget.radio_button.checked != should_select) changed = true;
                if (should_select) {
                    s.widget.radio_button.select();
                } else {
                    s.widget.radio_button.deselect();
                }
            }
        }
    }
    if (changed) self.layout_generation +%= 1;
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
/// Bumps `layout_generation` when the clamped value actually moved -- a
/// drag in progress is already covered separately (`FrameLoop.drawWindow`'s
/// own `dragging` exception), but a non-drag change (arrow-key nudge, a
/// guest's `natyv_set_slider_value`) has no such exception and needs this
/// bump to ever actually redraw, same reasoning as `setFocused`.
pub fn setSliderValue(self: *Self, call_io: Io, id: u32, value: f32) ?f32 {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const slot = self.findLocked(id) orelse return null;
    if (slot.widget != .slider) return null;
    const old = slot.widget.slider.value;
    slot.widget.slider.setValue(value);
    const new = slot.widget.slider.value;
    if (new == old) return null;
    self.layout_generation +%= 1;
    return new;
}

/// W27: the `RangeSlider` counterpart to `setSliderValue` -- called directly
/// by `main.zig`'s drag-update block and arrow-key nudge handling, same as
/// Slider's. `handle` picks which of the two clamped-against-each-other
/// values `value` targets (see `RangeSlider.setHandleValue`'s own doc
/// comment); also updates `active_handle` to `handle`, so a drag-start and a
/// keyboard nudge both leave the widget pointed at whichever handle was just
/// touched, same "last-touched handle" model `main.zig`'s own mouse-down
/// hit-test already establishes via `setRangeSliderActiveHandle`. Returns
/// the actual clamped `{min, max}` pair if either changed, or `null` if `id`
/// doesn't name a range slider or nothing actually moved (e.g. nudging a
/// handle already pinned against its sibling).
/// Bumps `layout_generation` when either value actually moved -- same
/// "drag already covered, non-drag paths aren't" reasoning as
/// `setSliderValue`.
pub fn setRangeSliderValue(self: *Self, call_io: Io, id: u32, handle: RangeSlider.Handle, value: f32) ?struct { min: f32, max: f32 } {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const slot = self.findLocked(id) orelse return null;
    if (slot.widget != .range_slider) return null;
    const old_min = slot.widget.range_slider.min;
    const old_max = slot.widget.range_slider.max;
    slot.widget.range_slider.setHandleValue(handle, value);
    slot.widget.range_slider.active_handle = handle;
    const new_min = slot.widget.range_slider.min;
    const new_max = slot.widget.range_slider.max;
    if (new_min == old_min and new_max == old_max) return null;
    self.layout_generation +%= 1;
    return .{ .min = new_min, .max = new_max };
}

/// W27: sets which handle a click targeted, without changing either value --
/// called from `main.zig`'s mouse-down hit-test (`RangeSlider.closestHandle`
/// already resolved *which* handle, this just records it) before the
/// per-frame drag-update block starts moving it via `setRangeSliderValue`
/// above. A no-op if `id` doesn't name a range slider.
pub fn setRangeSliderActiveHandle(self: *Self, call_io: Io, id: u32, handle: RangeSlider.Handle) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const slot = self.findLocked(id) orelse return;
    if (slot.widget != .range_slider) return;
    slot.widget.range_slider.active_handle = handle;
}

/// W17: the `NumericStepper` counterpart to `setSliderValue` -- same shape,
/// same "return the actual resolved value, or null if unchanged/wrong
/// kind" contract, integer-valued and going through `NumericStepper.resolve`
/// (clamp or wrap, see that function's doc comment) instead of a plain
/// [0,1] clamp.
/// Bumps `layout_generation` when the resolved value actually changed --
/// same reasoning as `setSliderValue` (no drag exception applies here at
/// all, so this is the only thing that ever forces a redraw).
pub fn setStepperValue(self: *Self, call_io: Io, id: u32, value: i32) ?i32 {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const slot = self.findLocked(id) orelse return null;
    if (slot.widget != .numeric_stepper) return null;
    const old = slot.widget.numeric_stepper.value;
    slot.widget.numeric_stepper.setValue(value);
    const new = slot.widget.numeric_stepper.value;
    if (new == old) return null;
    self.layout_generation +%= 1;
    return new;
}

/// W17: the `SegmentedControl` counterpart to `setSliderValue` -- same
/// shape, clamping via `SegmentedControl.select` instead of a value range.
/// Bumps `layout_generation` when the selection actually changed -- same
/// reasoning as `setStepperValue`.
pub fn setSegmentedIndex(self: *Self, call_io: Io, id: u32, index: usize) ?usize {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const slot = self.findLocked(id) orelse return null;
    if (slot.widget != .segmented_control) return null;
    const old = slot.widget.segmented_control.selected_index;
    slot.widget.segmented_control.select(index);
    const new = slot.widget.segmented_control.selected_index;
    if (new == old) return null;
    self.layout_generation +%= 1;
    return new;
}

/// W19: the `Tabs` counterpart to `setSegmentedIndex` -- same clamp-and-
/// report-if-changed shape, plus the real reason Tabs is its own host-owned
/// widget kind rather than a guest-composed pairing: flips the `visible`
/// flag on every tracked panel so exactly the newly-selected one participates
/// in the next Clay layout pass, and bumps `layout_generation` so that pass
/// actually runs (see `ClayStyle.visible`'s doc comment for why this bump is
/// required here but not on `setSegmentedIndex`/`setStepperValue`, which
/// never change what's declared in the tree).
pub fn setActiveTab(self: *Self, call_io: Io, id: u32, index: usize) ?usize {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    const slot = self.findLocked(id) orelse return null;
    if (slot.widget != .tabs) return null;
    const old = slot.widget.tabs.selected_index;
    slot.widget.tabs.select(index);
    const new = slot.widget.tabs.selected_index;
    if (new == old) return null;
    for (0..slot.widget.tabs.panel_count) |i| {
        if (self.findLocked(slot.widget.tabs.panel_ids[i])) |panel_slot| {
            panel_slot.clay_style.visible = (i == new);
        }
    }
    self.layout_generation +%= 1;
    return new;
}

/// Generic per-slot visibility toggle, guest-composed for Accordion (a
/// plain `Button` header + `Container` content wired together in guest code
/// -- see `sdk/go/widgets/accordion.go`) rather than a new host-owned
/// `WidgetKind` -- unlike `setActiveTab`, this never switches on
/// `slot.widget`, since `clay_style.visible` exists on every `Slot`
/// regardless of kind. Returns `false` only when `id` doesn't name any
/// widget (the host function surfaces that as a "no such widget" error to
/// the guest); a no-op call (already at the requested value) still returns
/// `true`. Bumps `layout_generation` -- same reason `setActiveTab` does and
/// `setSegmentedIndex`/`setStepperValue` don't, see `ClayStyle.visible`'s
/// doc comment -- but only when the value actually changes, so a repeated
/// identical call doesn't force a pointless recompute.
pub fn setVisible(self: *Self, call_io: Io, id: u32, visible: bool) bool {
    self.mutex.lockUncancelable(call_io);
    const slot = self.findLocked(id) orelse {
        self.mutex.unlock(call_io);
        return false;
    };
    const changed = slot.clay_style.visible != visible;
    slot.clay_style.visible = visible;
    self.mutex.unlock(call_io);

    if (changed) self.layout_generation +%= 1;
    return true;
}

/// Generic per-slot disabled toggle -- see `ClayStyle.enabled`'s own doc
/// comment. Doesn't change what Clay declares or how anything is sized
/// (unlike `setVisible`), only how a Button draws and responds to clicks --
/// but "draws" still needs a `layout_generation` bump now that
/// `FrameLoop.drawWindow`'s draw-level dirty check (added by the idle-CPU
/// render-loop fix) skips the actual redraw unless that generation moved (or
/// one of a short, explicit list of continuous-redraw exceptions applies,
/// which a disabled-state flip isn't). The old "read fresh every frame"
/// reasoning predates that gate and stopped being true the day it landed --
/// same class of bug as `setFocused`'s doc comment describes, only found via
/// code audit here rather than live click-through. Only bumps when the
/// value actually changes, same as `setVisible`/`setHeight`.
pub fn setEnabled(self: *Self, call_io: Io, id: u32, enabled: bool) bool {
    self.mutex.lockUncancelable(call_io);
    const slot = self.findLocked(id) orelse {
        self.mutex.unlock(call_io);
        return false;
    };
    const changed = slot.clay_style.enabled != enabled;
    slot.clay_style.enabled = enabled;
    self.mutex.unlock(call_io);

    if (changed) self.layout_generation +%= 1;
    return true;
}

/// Generic per-slot Fixed-height resize (min=max=height, regardless of
/// whichever sizing type the slot was created with) -- built for Tree
/// view's virtualized top/bottom spacer Containers (see
/// sdk/go/widgets/tree.go), which used to destroy+recreate on every window
/// shift purely to get a new height. That destroy/create pair on both
/// spacers, every single scroll tick, was a real source of visible flash
/// (see tree.go's own render/onScroll doc comments) -- this collapses it
/// to a single in-place mutation, no widget identity change at all.
/// Guest-composed rather than a new `WidgetKind`, same "no coordination the
/// host needs to own" reasoning `natyv_set_visible` already established --
/// `ClayStyle.sizing` exists on every `Slot` regardless of kind, so this
/// never switches on `slot.widget` either. Width is left exactly as it was
/// at creation time -- no current caller needs to resize both axes
/// independently. Returns `false` only when `id` doesn't name any widget; a
/// no-op call (already at the requested height) still returns `true`.
/// Bumps `layout_generation` only when the value actually changes, same
/// reasoning as `setVisible`.
pub fn setHeight(self: *Self, call_io: Io, id: u32, height: f32) bool {
    self.mutex.lockUncancelable(call_io);
    const slot = self.findLocked(id) orelse {
        self.mutex.unlock(call_io);
        return false;
    };
    const axis = &slot.clay_style.sizing.height;
    const changed = axis.type != c.CLAY__SIZING_TYPE_FIXED or axis.size.minMax.min != height or axis.size.minMax.max != height;
    axis.type = c.CLAY__SIZING_TYPE_FIXED;
    axis.size.minMax = .{ .min = height, .max = height };
    self.mutex.unlock(call_io);

    if (changed) self.layout_generation +%= 1;
    return true;
}

/// Styling system Stage 2 (Stage 5a added `corner_radius`/`border`):
/// applies already-resolved style values to an existing widget -- every
/// param is `null` when the guest's call didn't include that property
/// (leaves it unchanged), not "set it to zero/none." Deliberately takes
/// resolved values, not style-token names -- see `natyv_jsx_markup_layer`
/// memory's "Corrected 2026-08-21" note: the host stays completely
/// ignorant of tokens, same as every other host wire contract in this
/// project (it already only ever receives fully-resolved property values,
/// e.g. `ClayContainerRequest`'s `padding` today). Name-to-value
/// resolution/merging lives in the Go SDK's `ApplyStyle` helper, one layer
/// up. `corner_radius`/`border`/`gradient`/`texture` are purely visual
/// (Clay never sees them) and never affect sizing, but they still bump
/// `layout_generation` below when changed -- same "used to be provably fine
/// without it, until `FrameLoop.drawWindow`'s draw-level dirty check
/// (idle-CPU render-loop fix) started skipping the redraw entirely unless
/// generation moved" reasoning as `setFocused`/`setEnabled`. A
/// `slot.clay_managed` style-only change still forces the redraw gate open
/// (worth the occasional unnecessary Clay recompute -- these calls aren't
/// hot-path) rather than silently never rendering until something unrelated
/// happens to redraw.
pub fn setStyle(self: *Self, call_io: Io, id: u32, background_color: ?c.SDL_FColor, padding: ?c.Clay_Padding, corner_radius: ?[4]f32, border: ?Border, gradient: ?Gradient, texture: ?u32) bool {
    self.mutex.lockUncancelable(call_io);
    const slot = self.findLocked(id) orelse {
        self.mutex.unlock(call_io);
        return false;
    };
    var changed = false;
    if (background_color) |bg| {
        changed = changed or slot.clay_style.background_color == null or !std.meta.eql(slot.clay_style.background_color.?, bg);
        slot.clay_style.background_color = bg;
    }
    if (padding) |p| {
        changed = changed or !std.meta.eql(slot.clay_style.padding, p);
        slot.clay_style.padding = p;
    }
    if (corner_radius) |cr| {
        changed = changed or slot.clay_style.corner_radius == null or !std.meta.eql(slot.clay_style.corner_radius.?, cr);
        slot.clay_style.corner_radius = cr;
    }
    if (border) |b| {
        changed = changed or slot.clay_style.border == null or !std.meta.eql(slot.clay_style.border.?, b);
        slot.clay_style.border = b;
    }
    if (gradient) |g| {
        changed = changed or slot.clay_style.gradient == null or !std.meta.eql(slot.clay_style.gradient.?, g);
        slot.clay_style.gradient = g;
    }
    if (texture) |t| {
        changed = changed or slot.clay_style.texture == null or slot.clay_style.texture.? != t;
        slot.clay_style.texture = t;
    }
    self.mutex.unlock(call_io);

    if (changed and slot.clay_managed) self.layout_generation +%= 1;
    return true;
}
