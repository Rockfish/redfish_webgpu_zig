//! glTF metallic-roughness materials at group 1. One bind group per mesh primitive:
//! `MaterialUniforms` plus five textures and their samplers. Missing textures bind the
//! shared 1×1 `DefaultTextures`, so the shader always has something to sample.

const std = @import("std");
const math = @import("math");
const wgpu = @import("wgpu");
const bindings = @import("bindings.zig");
const gltf_types = @import("gltf/gltf.zig");
const gpu_context = @import("gpu_context.zig");
const texture_ = @import("texture.zig");
const RenderState = @import("pipeline.zig").RenderState;

const c = wgpu.c;
const stringView = wgpu.stringView;
const BindGroup = bindings.BindGroup;
const MaterialFlags = bindings.MaterialFlags;
const MaterialUniforms = bindings.MaterialUniforms;
const GpuContext = gpu_context.GpuContext;
const Frame = gpu_context.Frame;
const Texture = texture_.Texture;

const log = std.log.scoped(.material);

/// Texture slots in binding order (1-5); samplers follow at 6-10.
pub const TextureSlot = enum(u32) {
    base_color,
    metallic_roughness,
    normal,
    occlusion,
    emissive,

    pub fn isSrgb(self: TextureSlot) bool {
        return self == .base_color or self == .emissive;
    }
};

/// What a primitive's vertex data provides, folded into the material flags.
pub const PrimitiveAttributes = struct {
    has_normals: bool,
    has_vertex_colors: bool,
    has_skin: bool,
};

pub const PbrMaterial = struct {
    uniform_buffer: c.WGPUBuffer,
    bind_group: c.WGPUBindGroup,
    render_state: RenderState,

    const Self = @This();

    /// `textures` holds the asset's loaded texture per slot, or null for the default.
    pub fn init(
        gpu: *GpuContext,
        material: gltf_types.Material,
        textures: [bindings.PBR_TEXTURE_COUNT]?*const Texture,
        attributes: PrimitiveAttributes,
    ) !Self {
        const uniforms = materialUniforms(material, textures, attributes);
        const uniform_buffer = c.wgpuDeviceCreateBuffer(gpu.device, &.{
            .label = stringView("material uniforms"),
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(MaterialUniforms),
        });
        c.wgpuQueueWriteBuffer(gpu.queue, uniform_buffer, 0, &uniforms, @sizeOf(MaterialUniforms));

        return .{
            .uniform_buffer = uniform_buffer,
            .bind_group = try createBindGroup(gpu, uniform_buffer, textures),
            .render_state = .{
                .transparent = material.alpha_mode == .blend,
                .no_depth_write = material.alpha_mode == .blend,
                .double_sided = material.double_sided,
            },
        };
    }

    /// Material from textures alone, for shapes (e.g. a floor's diffuse / normal / specular
    /// maps in the base color / normal / metallic-roughness slots). White, non-metallic,
    /// fully rough, opaque.
    pub fn initWithTextures(gpu: *GpuContext, textures: [bindings.PBR_TEXTURE_COUNT]?*const Texture) !Self {
        var material = defaultMaterial();
        material.pbr_metallic_roughness.?.roughness_factor = 1.0;
        return init(gpu, material, textures, .{ .has_normals = true, .has_vertex_colors = false, .has_skin = false });
    }

    /// The material shape draws with a `.pbr` shader use from here on, this frame.
    pub fn bind(self: *const Self, frame: *const Frame) void {
        frame.gpu.bound_material = .{ .bind_group = self.bind_group, .kind = .pbr };
    }

    /// Group 1 for one mesh primitive draw. Doesn't change the frame's bound material.
    pub fn setBindGroup(self: *const Self, frame: *const Frame) void {
        c.wgpuRenderPassEncoderSetBindGroup(frame.pass, BindGroup.material, self.bind_group, 0, null);
    }

    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuBufferRelease(self.uniform_buffer);
    }
};

/// Default material for primitives without one: white, non-metallic, rough (as redfish).
pub fn defaultMaterial() gltf_types.Material {
    return .{
        .name = null,
        .pbr_metallic_roughness = .{
            .base_color_factor = math.vec4(1.0, 1.0, 1.0, 1.0),
            .metallic_factor = 0.0,
            .roughness_factor = 0.9,
            .base_color_texture = null,
            .metallic_roughness_texture = null,
        },
        .normal_texture = null,
        .occlusion_texture = null,
        .emissive_texture = null,
    };
}

/// glTF texture index used by a material slot, if any.
pub fn textureIndex(material: gltf_types.Material, slot: TextureSlot) ?u32 {
    const pbr = material.pbr_metallic_roughness;
    const info: ?gltf_types.TextureInfo = switch (slot) {
        .base_color => if (pbr) |p| p.base_color_texture else null,
        .metallic_roughness => if (pbr) |p| p.metallic_roughness_texture else null,
        .normal => material.normal_texture,
        .occlusion => material.occlusion_texture,
        .emissive => material.emissive_texture,
    };
    return if (info) |i| i.index else null;
}

/// 1×1 textures bound in place of missing material textures.
pub const DefaultTextures = struct {
    /// (1, 1, 1, 1): neutral for base color, metallic-roughness, occlusion, and emissive
    /// (glTF multiplies each by its factor).
    white: *Texture,
    /// (0.5, 0.5, 1): tangent-space "straight up".
    flat_normal: *Texture,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, gpu: *GpuContext) !Self {
        const sampler = try gpu.samplers.get(gpu.device, texture_.SamplerKey.fromConfig(.{ .wrap = .Repeat }));
        return .{
            .white = try createPixelTexture(allocator, gpu, .{ 255, 255, 255, 255 }, sampler, "default white"),
            .flat_normal = try createPixelTexture(allocator, gpu, .{ 128, 128, 255, 255 }, sampler, "default normal"),
        };
    }

    pub fn forSlot(self: *const Self, slot: TextureSlot) *const Texture {
        return if (slot == .normal) self.flat_normal else self.white;
    }

    pub fn releaseGpuObjects(self: *Self) void {
        self.white.releaseGpuObjects();
        self.flat_normal.releaseGpuObjects();
    }
};

fn materialUniforms(
    material: gltf_types.Material,
    textures: [bindings.PBR_TEXTURE_COUNT]?*const Texture,
    attributes: PrimitiveAttributes,
) MaterialUniforms {
    const pbr = material.pbr_metallic_roughness orelse defaultMaterial().pbr_metallic_roughness.?;

    var flags: u32 = 0;
    const texture_flags = [_]u32{
        MaterialFlags.base_color_texture,
        MaterialFlags.metallic_roughness_texture,
        MaterialFlags.normal_texture,
        MaterialFlags.occlusion_texture,
        MaterialFlags.emissive_texture,
    };
    for (textures, texture_flags) |texture, flag| {
        if (texture != null) flags |= flag;
    }
    if (attributes.has_normals) flags |= MaterialFlags.has_normals;
    if (attributes.has_vertex_colors) flags |= MaterialFlags.vertex_colors;
    if (attributes.has_skin) flags |= MaterialFlags.skin;
    if (material.alpha_mode == .mask) flags |= MaterialFlags.alpha_mask;

    return .{
        .base_color_factor = pbr.base_color_factor,
        .emissive_factor = material.emissive_factor,
        .metallic_factor = pbr.metallic_factor,
        .roughness_factor = pbr.roughness_factor,
        .alpha_cutoff = material.alpha_cutoff,
        .flags = flags,
    };
}

fn createBindGroup(
    gpu: *GpuContext,
    uniform_buffer: c.WGPUBuffer,
    textures: [bindings.PBR_TEXTURE_COUNT]?*const Texture,
) !c.WGPUBindGroup {
    const count = bindings.PBR_TEXTURE_COUNT;
    var entries: [1 + 2 * count]c.WGPUBindGroupEntry = undefined;
    entries[0] = .{ .binding = 0, .buffer = uniform_buffer, .size = @sizeOf(MaterialUniforms) };

    for (textures, 0..) |maybe_texture, i| {
        const slot: TextureSlot = @enumFromInt(i);
        const texture = maybe_texture orelse gpu.default_textures.forSlot(slot);
        entries[1 + i] = .{ .binding = @intCast(1 + i), .textureView = texture.view };
        entries[1 + count + i] = .{ .binding = @intCast(1 + count + i), .sampler = texture.sampler };
    }

    return c.wgpuDeviceCreateBindGroup(gpu.device, &.{
        .label = stringView("pbr material"),
        .layout = gpu.bindings.pbr_layout,
        .entryCount = entries.len,
        .entries = &entries,
    });
}

fn createPixelTexture(
    allocator: std.mem.Allocator,
    gpu: *GpuContext,
    rgba: [4]u8,
    sampler: c.WGPUSampler,
    label: []const u8,
) !*Texture {
    var pixel = rgba;
    const image: texture_.RawImage = .{ .data = &pixel, .width = 1, .height = 1 };
    return texture_.initFromPixels(allocator, gpu, image, false, sampler, label);
}
