//! Multi-window Stage 1: bundles the per-frame interaction state that used
//! to live as bare locals declared directly in main()'s `while (running)`
//! loop -- `focused_widget_id`, drag/hover/tooltip tracking, the pending
//! wheel-scroll accumulator, the pointer-vs-arrow cursor flag, and the
//! current mouse position. Pure extraction, no behavioral change: every
//! field here is exactly the same variable that existed before, just reached
//! through one struct instead of a dozen separate `var`s.
//!
//! The reason this exists at all: a future WindowContext (one per open OS
//! window, not yet built -- see project memory's multi-window plan) needs
//! each open window to own its own independent copy of all of this (focus,
//! drag state, hover, mouse position are all meaningless shared across two
//! separate windows). Bundling it now, while there's still only ever one
//! instance, means the later stage that actually multiplies it only has to
//! change *where* each instance lives and *where* mouse_x/mouse_y get
//! populated from (per-window SDL events instead of one global
//! SDL_GetMouseState call) -- not this struct's shape.

const RangeSlider = @import("widgets/RangeSlider.zig");

const Self = @This();

/// Keyboard interaction model: which widget (if any) currently has focus.
focused_widget_id: ?u32 = null,
/// W3: which slider (if any) is currently being dragged -- set on
/// MOUSE_BUTTON_DOWN when the click lands on a slider, cleared
/// unconditionally on MOUSE_BUTTON_UP regardless of where the mouse
/// currently is (standard drag semantics: releasing outside the widget's
/// bounds still ends the drag).
dragging_slider_id: ?u32 = null,
/// W27: which handle `dragging_slider_id` (above) is currently moving, when
/// it names a RangeSlider -- see `tryHitWidget`'s doc comment in main.zig
/// for why this can't just be read back from the widget itself via
/// `widget_snapshot` in the same frame it was chosen.
dragging_range_handle: ?RangeSlider.Handle = null,
/// Which TextField/TextArea (if any) is currently having its selection
/// extended by a mouse drag -- set on a MOUSE_BUTTON_DOWN hit against a
/// text widget, cleared unconditionally on MOUSE_BUTTON_UP, mirroring
/// `dragging_slider_id`'s exact lifecycle. The selection itself persists
/// after release; only this drag-in-progress flag clears.
text_selecting_id: ?u32 = null,
/// W15: which widget (if any) the mouse is currently continuously over, when
/// that hover started, and which widget (if any) we've already fired
/// `.hover true` for -- `tooltip_active_for` is tracked separately from
/// `hovered_widget_id` so hover-out only ever fires `.hover false` for a
/// widget that actually crossed the threshold and got a `true` sent, never
/// for one the mouse merely brushed past.
hovered_widget_id: ?u32 = null,
hover_start_ms: ?i64 = null,
tooltip_active_for: ?u32 = null,
/// Whether the pointer-shaped cursor (vs. the default arrow) is currently
/// active -- flipped only when `hovering_any` actually changes, to avoid an
/// SDL_SetCursor call every single frame.
cursor_is_pointer: bool = false,
/// W2: accumulated per-frame wheel delta, in pixels (already scaled from
/// SDL's raw wheel "notch" units), consumed by layoutIfNeeded at the top of
/// the *next* frame then reset.
pending_scroll_dx: f32 = 0,
pending_scroll_dy: f32 = 0,
/// Current mouse position. Fetched fresh every frame (see main.zig's
/// SDL_GetMouseState call) -- not meaningfully "persistent" across frames,
/// just homed here rather than as a bare loop-local so a future per-window
/// instance can populate it from that window's own routed SDL events
/// instead, with no change to how the rest of the frame body reads it.
mouse_x: f32 = 0,
mouse_y: f32 = 0,
