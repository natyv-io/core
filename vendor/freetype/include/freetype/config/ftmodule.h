/*
 * natyv: hand-pruned per FreeType's own documented non-GNU-make
 * customization method (docs/CUSTOMIZE section II) -- only the modules
 * actually compiled into vendor/freetype/src are registered here.
 * Registering a module class whose .c file isn't compiled in is a link
 * error; compiling a module in without registering it here means
 * FT_Init_FreeType() never activates it. Kept in sync with the file list
 * `linkNatyvDeps` in build.zig feeds to addCSourceFiles.
 *
 * Scope: TrueType (glyf) + OpenType (CFF) outline parsing and smooth
 * (anti-aliased) rasterization, with real hinting (autofit + pshinter).
 * Deliberately excludes: Type1/CID/PFR/Type42/Windows-FNT/PCF/BDF driver
 * modules (legacy/bitmap formats natyv doesn't need), the SVG and SDF
 * renderers, and the 1-bit `raster` renderer (smooth replaces it).
 */

FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
FT_USE_MODULE( FT_Module_Class, psaux_module_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )

/* EOF */
