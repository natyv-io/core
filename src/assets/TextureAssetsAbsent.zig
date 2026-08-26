//! Default stub swapped in via `-Dhas-textures=false` (the default) --
//! mirrors `BindingsAbsent.zig`/`EmbeddedWasmAbsent.zig`'s own file-swap
//! pattern exactly. An app that never references `texture` in its
//! stylesheet never needs any real staged assets, and this costs nothing:
//! `natyv build` only swaps in the real `TextureAssetsGenerated.zig`
//! (written by `natyv prepare`'s asset-staging pass, src/cli/Prepare.zig)
//! when it actually staged at least one texture.
pub const data: []const []const u8 = &.{};
