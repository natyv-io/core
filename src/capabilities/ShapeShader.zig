//! Styling system Stage 1: SDF-based shape rendering plumbing (amber-woven-
//! lantern.md). Owns the one v1 shape shader (per-corner radii, flat/
//! gradient/texture fill, border -- see shaders/shape.frag.metal) and the
//! GPU device/render-state objects it needs. No widget's draw path calls
//! into this yet -- that's Stage 3. This stage only proves the plumbing
//! exists and doesn't regress anything already rendering via the plain
//! SDL_Renderer API.
//!
//! Two lifetimes, matching `SDL_GPURenderState`'s own real scoping rules
//! (confirmed against SDL_gpu.h/SDL_render.h, not assumed):
//! - `GpuState` is device-scoped and created exactly once for the whole
//!   process (`SDL_CreateGPUDevice`+`SDL_CreateGPUShader` are genuinely
//!   shareable across every window) -- owned by `main.zig`, outliving every
//!   `WindowContext`.
//! - `WindowRenderState` is renderer-scoped and created once per open
//!   window (`SDL_CreateGPURenderState` takes a renderer, not a device) --
//!   owned by that window's own `WindowManager.WindowContext`.
//!
//! Real, deliberate refinement over the original scratchpad prototype: the
//! prototype called `SDL_CreateRenderer(window, SDL_GPU_RENDERER)`, which
//! implicitly creates a *new* `SDL_GPUDevice` per call (confirmed via
//! SDL_render.h's own doc comment on `SDL_CreateGPURenderer`: "device ...
//! or NULL to create a device") -- fine for a single-window demo, but wrong
//! for natyv's real multi-window architecture, where the whole point is one
//! shared shader object reused by every window's own render state. This
//! module instead creates the device explicitly once
//! (`SDL_CreateGPUDevice`) and every window calls `SDL_CreateGPURenderer`
//! against that same shared device.

const std = @import("std");
const c = @import("../c.zig").c;

const shader_source = @embedFile("../shaders/shape.frag.metal");

/// Matches `shaders/shape.frag.metal`'s `type_Constants` field-for-field,
/// including field order -- see that file's own doc comment for why order
/// is load-bearing (Metal's real struct-layout ABI 16/8-byte-aligns
/// float4/float2 members, which a plain Zig `[4]f32` array does not do on
/// its own; grouping same-sized fields together avoids needing manual
/// padding in the middle, and `_tail_pad` accounts for Metal rounding the
/// whole struct's size up to its own 16-byte alignment, 92 raw bytes -> 96).
/// The same field order also produces an identical byte layout under
/// HLSL's cbuffer packing rules (verified by hand against
/// shape.frag.hlsl), so this one struct is correct for both once SPIR-V/
/// DXIL bytecode exists.
pub const ShapeUniforms = extern struct {
    fill_color_a: [4]f32,
    fill_color_b: [4]f32,
    border_color: [4]f32,
    corner_radius: [4]f32,
    half_size: [2]f32,
    gradient_dir: [2]f32,
    feather: f32,
    fill_mode: u32,
    border_width: f32,
    _tail_pad: f32 = 0,
};

pub const fill_mode_flat: u32 = 0;
pub const fill_mode_gradient: u32 = 1;
pub const fill_mode_texture: u32 = 2;

/// Device-scoped, process-wide, created once by `main.zig` before any
/// window exists and destroyed only after every window is gone.
pub const GpuState = struct {
    device: *c.SDL_GPUDevice,
    shader: *c.SDL_GPUShader,
};

/// `null` return (not an error) means "no GPU-capable device available on
/// this machine" -- a real, expected outcome (software renderer, or a
/// device that supports none of the shader formats this build ships), not
/// a bug. Callers fall back to Tier 1 (feathered tessellation, not yet
/// built) rather than treating this as fatal.
pub fn initShared() ?GpuState {
    const device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL, false, null) orelse {
        std.debug.print("[ShapeShader] SDL_CreateGPUDevice failed: {s}\n", .{c.SDL_GetError()});
        return null;
    };

    const formats = c.SDL_GetGPUShaderFormats(device);
    if (formats & c.SDL_GPU_SHADERFORMAT_MSL == 0) {
        // SPIR-V/DXIL bytecode isn't checked in yet (blocked on
        // `shadercross`, see shape.frag.hlsl's own doc comment) -- MSL
        // source is the only format this build can actually hand SDL today.
        std.debug.print("[ShapeShader] device doesn't accept MSL source (formats=0x{x}); SPIR-V/DXIL bytecode not yet checked in -- falling back to Tier 1\n", .{formats});
        c.SDL_DestroyGPUDevice(device);
        return null;
    }

    var shader_info: c.SDL_GPUShaderCreateInfo = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
    shader_info.code = shader_source.ptr;
    shader_info.code_size = shader_source.len;
    shader_info.entrypoint = "main0"; // matches shape.frag.metal's real entry point name
    shader_info.format = c.SDL_GPU_SHADERFORMAT_MSL;
    shader_info.stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT;
    shader_info.num_uniform_buffers = 1;
    shader_info.num_samplers = 1;
    const shader = c.SDL_CreateGPUShader(device, &shader_info) orelse {
        std.debug.print("[ShapeShader] SDL_CreateGPUShader failed: {s}\n", .{c.SDL_GetError()});
        c.SDL_DestroyGPUDevice(device);
        return null;
    };

    return .{ .device = device, .shader = shader };
}

pub fn deinitShared(self: *GpuState) void {
    c.SDL_ReleaseGPUShader(self.device, self.shader);
    c.SDL_DestroyGPUDevice(self.device);
}

/// Renderer-scoped: one per open window, built against the shared
/// `GpuState.shader` but its own `SDL_GPURenderState` (renderer-scoped,
/// confirmed against SDL_render.h) and its own dummy white texture
/// (textures are renderer-scoped too -- one bound per window, never
/// actually sampled outside fill_mode == texture, same "route the draw
/// through the textured path" reasoning the original prototype found for
/// `SDL_GPURenderState` silently no-oping on untextured geometry).
pub const WindowRenderState = struct {
    render_state: *c.SDL_GPURenderState,
    white_texture: *c.SDL_Texture,
};

pub fn createForWindow(gpu: *const GpuState, renderer: *c.SDL_Renderer) ?WindowRenderState {
    var state_info: c.SDL_GPURenderStateCreateInfo = std.mem.zeroes(c.SDL_GPURenderStateCreateInfo);
    state_info.fragment_shader = gpu.shader;
    const render_state = c.SDL_CreateGPURenderState(renderer, &state_info) orelse {
        std.debug.print("[ShapeShader] SDL_CreateGPURenderState failed: {s}\n", .{c.SDL_GetError()});
        return null;
    };

    const white_texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_STATIC, 1, 1) orelse {
        std.debug.print("[ShapeShader] dummy white texture creation failed: {s}\n", .{c.SDL_GetError()});
        c.SDL_DestroyGPURenderState(render_state);
        return null;
    };
    var white_pixel: [4]u8 = .{ 255, 255, 255, 255 };
    _ = c.SDL_UpdateTexture(white_texture, null, &white_pixel, 4);

    return .{ .render_state = render_state, .white_texture = white_texture };
}

pub fn destroyForWindow(self: *WindowRenderState) void {
    c.SDL_DestroyTexture(self.white_texture);
    c.SDL_DestroyGPURenderState(self.render_state);
}

/// One quad (2 triangles) covering the shape's bounding box, `tex_coord`
/// repurposed as local shape-space UV in [-1,1] -- all real rounding/fill/
/// border math happens in the fragment shader; this is deliberately dumb
/// geometry. Vertex color is unused by the fragment shader today (see
/// shape.frag.metal's doc comment on `main0_in`) but SDL's own vertex
/// shader ABI still expects a value, so opaque white is passed uniformly.
/// Not called by any widget yet -- Stage 3 wires a real widget's draw path
/// through this.
pub fn drawSdfQuad(renderer: *c.SDL_Renderer, white_texture: *c.SDL_Texture, rect: c.SDL_FRect) bool {
    const x0 = rect.x;
    const y0 = rect.y;
    const x1 = rect.x + rect.w;
    const y1 = rect.y + rect.h;
    const white: c.SDL_FColor = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    var verts = [4]c.SDL_Vertex{
        .{ .position = .{ .x = x0, .y = y0 }, .color = white, .tex_coord = .{ .x = -1, .y = -1 } },
        .{ .position = .{ .x = x1, .y = y0 }, .color = white, .tex_coord = .{ .x = 1, .y = -1 } },
        .{ .position = .{ .x = x1, .y = y1 }, .color = white, .tex_coord = .{ .x = 1, .y = 1 } },
        .{ .position = .{ .x = x0, .y = y1 }, .color = white, .tex_coord = .{ .x = -1, .y = 1 } },
    };
    var idx = [6]c_int{ 0, 1, 2, 0, 2, 3 };
    return c.SDL_RenderGeometry(renderer, white_texture, &verts, 4, &idx, 6);
}
