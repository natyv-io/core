//! Default stub swapped in via `-Dwindow-style=false` (the default) --
//! mirrors `TextureAssetsAbsent.zig`/`BindingsAbsent.zig`'s own file-swap
//! pattern exactly. An app whose `.ntss` has no reserved `window` block
//! (or that has no `.ntss` at all) pays nothing: `natyv build` only swaps
//! in the real `WindowStyleGenerated.zig` (written by `natyv prepare`'s
//! staging pass, src/cli/Prepare.zig) when a window block was actually
//! declared and staged.
//!
//! `null` means "the stylesheet said nothing," which is what lets
//! `main.zig` fall through to conf.natyv.json's `ui.background_color` and
//! then to natyv's own built-in ground.
pub const background: ?[4]u8 = null;

/// Startup-window size in pixels. Null means "the stylesheet said
/// nothing", same fall-through as `background`. Only ever applies to the
/// startup window -- a window the guest opens via
/// `natyv_clay_create_window` passes its own explicit size and is never
/// overridden.
pub const width: ?u16 = null;
pub const height: ?u16 = null;
