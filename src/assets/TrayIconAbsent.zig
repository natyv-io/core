//! Default stub swapped in via `-Dtray-icon=false` (the default) -- mirrors
//! `AppFontAbsent.zig`/`WindowStyleAbsent.zig`'s own file-swap pattern. An
//! app that configured no `icon` in `conf.natyv.json` pays nothing: `natyv
//! build` only swaps in the real `TrayIconGenerated.zig` (written by `natyv
//! prepare`'s staging pass) when one was actually configured.
//!
//! Null means "no icon was configured", which `TrayDrain.zig` passes
//! straight through to `SDL_CreateTray` -- whose `icon` parameter is
//! documented as "May be NULL". The tray still works; it just has nothing
//! to draw in the menu bar, which is why `natyv prepare` warns rather than
//! staying silent when an app creates a tray with no icon available.
pub const data: ?[]const u8 = null;
