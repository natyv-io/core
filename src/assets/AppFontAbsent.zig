//! Default stub swapped in via `-Dapp-font=false` (the default) --
//! mirrors `WindowStyleAbsent.zig`/`TextureAssetsAbsent.zig`'s own
//! file-swap pattern. An app that ships no font of its own, and sets no
//! custom point size, pays nothing: `natyv build` only swaps in the real
//! `AppFontGenerated.zig` (written by `natyv prepare`'s staging pass)
//! when one was actually configured.
//!
//! Null means "nothing was configured", which is what lets
//! `capabilities/Font.zig` fall back to its own bundled Inter at 16.0.
pub const data: ?[]const u8 = null;
pub const point_size: ?f32 = null;
