//! Everything Zig and WGSL must agree on: bind group numbers, vertex attribute locations,
//! shared constants, and the uniform structs. `wgsl_header` is generated from these and
//! prepended to every shader, so WGSL never hard-codes them.
//!
//! Also owns the bind group layouts and bind groups shared by all pipelines.

const std = @import("std");
const math = @import("math");
const wgpu = @import("wgpu");

const c = wgpu.c;
const stringView = wgpu.stringView;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const Mat4 = math.Mat4;

/// Bind group numbers, fixed project-wide.
pub const BindGroup = struct {
    pub const frame = 0; // camera, lights, time
    pub const material = 1; // textures, samplers, material factors
    pub const object = 2; // per-draw uniforms, joint matrices
    pub const pass = 3; // shadow map, etc.
};

/// Vertex attribute locations. Same numbers as redfish's `constants.VertexAttr`.
pub const VertexAttr = struct {
    pub const position = 0;
    pub const texcoord = 1;
    pub const normal = 2;
    pub const tangent = 3;
    pub const color = 4;
    pub const joints = 5;
    pub const weights = 6;
};

pub const MAX_JOINTS = 100;

/// What a shader binds at group 1. Picks the pipeline layout's material slot.
pub const MaterialKind = enum {
    /// Nothing; draws bind the empty group.
    none,
    /// One color texture and its sampler: `@binding(0)` texture_2d<f32>, `@binding(1)` sampler.
    texture,
    /// glTF metallic-roughness: `MaterialUniforms` at 0, five textures at 1-5 (base color,
    /// metallic-roughness, normal, occlusion, emissive), their samplers at 6-10.
    pbr,
};

pub const PBR_TEXTURE_COUNT = 5;

/// `DrawUniforms.flags` bits.
pub const DrawFlags = struct {
    /// Use the vertex color attribute instead of `DrawUniforms.color`.
    pub const vertex_color: u32 = 1 << 0;
};

/// Mirrors `FrameUniforms` in shaders/common.wgsl (group 0, binding 0).
pub const FrameUniforms = extern struct {
    projection: Mat4,
    view: Mat4,
    projection_view: Mat4,
    view_position: Vec3,
    time: f32, // fills vec3's 16-byte slot
    /// One point light until `SceneLights` (port Step 6). Zero intensity means unlit.
    light_position: Vec3 = Vec3.init(0.0, 0.0, 0.0),
    light_intensity: f32 = 0.0,
    light_color: Vec3 = Vec3.init(1.0, 1.0, 1.0),
    _pad: f32 = 0.0,
};

/// Mirrors `DrawUniforms` in shaders/common.wgsl (group 2, binding 0). One per draw,
/// allocated from the uniform ring.
pub const DrawUniforms = extern struct {
    model: Mat4,
    /// Inverse transpose of `model`; a mat4 because a WGSL mat3x3 pads its columns.
    normal_matrix: Mat4,
    color: Vec4,
    flags: u32,
    _pad: [3]u32 = .{ 0, 0, 0 },

    pub fn init(model: Mat4, color: Vec4) DrawUniforms {
        return .{
            .model = model,
            .normal_matrix = model.getInverse().getTranspose(),
            .color = color,
            .flags = 0,
        };
    }
};

/// `MaterialUniforms.flags` bits.
pub const MaterialFlags = struct {
    pub const base_color_texture: u32 = 1 << 0;
    pub const metallic_roughness_texture: u32 = 1 << 1;
    pub const normal_texture: u32 = 1 << 2;
    pub const occlusion_texture: u32 = 1 << 3;
    pub const emissive_texture: u32 = 1 << 4;
    pub const has_normals: u32 = 1 << 5;
    pub const vertex_colors: u32 = 1 << 6;
    pub const skin: u32 = 1 << 7;
    /// glTF alpha mode MASK: discard below `alpha_cutoff`.
    pub const alpha_mask: u32 = 1 << 8;
};

/// Mirrors `MaterialUniforms` in shaders/common.wgsl (group 1, binding 0, `pbr` materials).
pub const MaterialUniforms = extern struct {
    base_color_factor: Vec4,
    emissive_factor: Vec3,
    metallic_factor: f32,
    roughness_factor: f32,
    alpha_cutoff: f32,
    flags: u32,
    _pad: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(MaterialUniforms) == 48);
    std.debug.assert(@sizeOf(FrameUniforms) == 240);
    std.debug.assert(@sizeOf(DrawUniforms) == 160);
}

/// WGSL constants generated from the declarations above.
pub const wgsl_header = std.fmt.comptimePrint(
    \\// Generated from src/core/bindings.zig. Do not edit.
    \\const GROUP_FRAME: u32 = {d}u;
    \\const GROUP_MATERIAL: u32 = {d}u;
    \\const GROUP_OBJECT: u32 = {d}u;
    \\const GROUP_PASS: u32 = {d}u;
    \\const LOCATION_POSITION: u32 = {d}u;
    \\const LOCATION_TEXCOORD: u32 = {d}u;
    \\const LOCATION_NORMAL: u32 = {d}u;
    \\const LOCATION_TANGENT: u32 = {d}u;
    \\const LOCATION_COLOR: u32 = {d}u;
    \\const LOCATION_JOINTS: u32 = {d}u;
    \\const LOCATION_WEIGHTS: u32 = {d}u;
    \\const MAX_JOINTS: u32 = {d}u;
    \\const DRAW_FLAG_VERTEX_COLOR: u32 = {d}u;
    \\const MATERIAL_FLAG_BASE_COLOR_TEXTURE: u32 = {d}u;
    \\const MATERIAL_FLAG_METALLIC_ROUGHNESS_TEXTURE: u32 = {d}u;
    \\const MATERIAL_FLAG_NORMAL_TEXTURE: u32 = {d}u;
    \\const MATERIAL_FLAG_OCCLUSION_TEXTURE: u32 = {d}u;
    \\const MATERIAL_FLAG_EMISSIVE_TEXTURE: u32 = {d}u;
    \\const MATERIAL_FLAG_HAS_NORMALS: u32 = {d}u;
    \\const MATERIAL_FLAG_VERTEX_COLORS: u32 = {d}u;
    \\const MATERIAL_FLAG_SKIN: u32 = {d}u;
    \\const MATERIAL_FLAG_ALPHA_MASK: u32 = {d}u;
    \\
    \\
, .{
    BindGroup.frame,
    BindGroup.material,
    BindGroup.object,
    BindGroup.pass,
    VertexAttr.position,
    VertexAttr.texcoord,
    VertexAttr.normal,
    VertexAttr.tangent,
    VertexAttr.color,
    VertexAttr.joints,
    VertexAttr.weights,
    MAX_JOINTS,
    DrawFlags.vertex_color,
    MaterialFlags.base_color_texture,
    MaterialFlags.metallic_roughness_texture,
    MaterialFlags.normal_texture,
    MaterialFlags.occlusion_texture,
    MaterialFlags.emissive_texture,
    MaterialFlags.has_normals,
    MaterialFlags.vertex_colors,
    MaterialFlags.skin,
    MaterialFlags.alpha_mask,
});

/// Shared bind group layouts and bind groups. Created once by `GpuContext`.
pub const Bindings = struct {
    frame_layout: c.WGPUBindGroupLayout,
    empty_layout: c.WGPUBindGroupLayout,
    texture_layout: c.WGPUBindGroupLayout,
    pbr_layout: c.WGPUBindGroupLayout,
    object_layout: c.WGPUBindGroupLayout,

    frame_buffer: c.WGPUBuffer,
    frame_bind_group: c.WGPUBindGroup,
    empty_bind_group: c.WGPUBindGroup,
    /// Binds the uniform ring with a dynamic offset per draw.
    object_bind_group: c.WGPUBindGroup,

    const Self = @This();

    pub fn init(device: c.WGPUDevice, uniform_ring_buffer: c.WGPUBuffer) Self {
        const frame_layout = createUniformLayout(device, "frame layout", @sizeOf(FrameUniforms), false);
        const empty_layout = c.wgpuDeviceCreateBindGroupLayout(device, &.{ .label = stringView("empty layout") });
        const object_layout = createUniformLayout(device, "object layout", @sizeOf(DrawUniforms), true);
        const texture_layout = createTextureLayout(device);
        const pbr_layout = createPbrLayout(device);

        const frame_buffer = c.wgpuDeviceCreateBuffer(device, &.{
            .label = stringView("frame uniforms"),
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(FrameUniforms),
        });

        return .{
            .frame_layout = frame_layout,
            .empty_layout = empty_layout,
            .texture_layout = texture_layout,
            .pbr_layout = pbr_layout,
            .object_layout = object_layout,
            .frame_buffer = frame_buffer,
            .frame_bind_group = createUniformBindGroup(device, "frame", frame_layout, frame_buffer, @sizeOf(FrameUniforms)),
            .empty_bind_group = c.wgpuDeviceCreateBindGroup(device, &.{
                .label = stringView("empty"),
                .layout = empty_layout,
            }),
            .object_bind_group = createUniformBindGroup(device, "object", object_layout, uniform_ring_buffer, @sizeOf(DrawUniforms)),
        };
    }

    pub fn materialLayout(self: *const Self, kind: MaterialKind) c.WGPUBindGroupLayout {
        return switch (kind) {
            .none => self.empty_layout,
            .texture => self.texture_layout,
            .pbr => self.pbr_layout,
        };
    }

    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuBindGroupRelease(self.object_bind_group);
        c.wgpuBindGroupRelease(self.empty_bind_group);
        c.wgpuBindGroupRelease(self.frame_bind_group);
        c.wgpuBufferRelease(self.frame_buffer);
        c.wgpuBindGroupLayoutRelease(self.object_layout);
        c.wgpuBindGroupLayoutRelease(self.pbr_layout);
        c.wgpuBindGroupLayoutRelease(self.texture_layout);
        c.wgpuBindGroupLayoutRelease(self.empty_layout);
        c.wgpuBindGroupLayoutRelease(self.frame_layout);
    }
};

/// Layout with one uniform buffer at binding 0, visible to vertex and fragment stages.
fn createUniformLayout(device: c.WGPUDevice, label: []const u8, size: u64, dynamic_offset: bool) c.WGPUBindGroupLayout {
    const entry: c.WGPUBindGroupLayoutEntry = .{
        .binding = 0,
        .visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment,
        .buffer = .{
            .type = c.WGPUBufferBindingType_Uniform,
            .hasDynamicOffset = @intFromBool(dynamic_offset),
            .minBindingSize = size,
        },
    };
    return c.wgpuDeviceCreateBindGroupLayout(device, &.{
        .label = stringView(label),
        .entryCount = 1,
        .entries = &entry,
    });
}

/// `MaterialKind.texture`: filterable 2D texture at binding 0, filtering sampler at 1.
fn createTextureLayout(device: c.WGPUDevice) c.WGPUBindGroupLayout {
    const entries = [_]c.WGPUBindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = c.WGPUShaderStage_Fragment,
            .texture = .{ .sampleType = c.WGPUTextureSampleType_Float, .viewDimension = c.WGPUTextureViewDimension_2D },
        },
        .{
            .binding = 1,
            .visibility = c.WGPUShaderStage_Fragment,
            .sampler = .{ .type = c.WGPUSamplerBindingType_Filtering },
        },
    };
    return c.wgpuDeviceCreateBindGroupLayout(device, &.{
        .label = stringView("texture material layout"),
        .entryCount = entries.len,
        .entries = &entries,
    });
}

/// `MaterialKind.pbr`: uniforms at 0, textures at 1-5, samplers at 6-10.
fn createPbrLayout(device: c.WGPUDevice) c.WGPUBindGroupLayout {
    var entries: [1 + 2 * PBR_TEXTURE_COUNT]c.WGPUBindGroupLayoutEntry = undefined;
    entries[0] = .{
        .binding = 0,
        .visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment,
        .buffer = .{ .type = c.WGPUBufferBindingType_Uniform, .minBindingSize = @sizeOf(MaterialUniforms) },
    };
    for (0..PBR_TEXTURE_COUNT) |i| {
        entries[1 + i] = .{
            .binding = @intCast(1 + i),
            .visibility = c.WGPUShaderStage_Fragment,
            .texture = .{ .sampleType = c.WGPUTextureSampleType_Float, .viewDimension = c.WGPUTextureViewDimension_2D },
        };
        entries[1 + PBR_TEXTURE_COUNT + i] = .{
            .binding = @intCast(1 + PBR_TEXTURE_COUNT + i),
            .visibility = c.WGPUShaderStage_Fragment,
            .sampler = .{ .type = c.WGPUSamplerBindingType_Filtering },
        };
    }
    return c.wgpuDeviceCreateBindGroupLayout(device, &.{
        .label = stringView("pbr material layout"),
        .entryCount = entries.len,
        .entries = &entries,
    });
}

fn createUniformBindGroup(
    device: c.WGPUDevice,
    label: []const u8,
    layout: c.WGPUBindGroupLayout,
    buffer: c.WGPUBuffer,
    size: u64,
) c.WGPUBindGroup {
    const entry: c.WGPUBindGroupEntry = .{ .binding = 0, .buffer = buffer, .size = size };
    return c.wgpuDeviceCreateBindGroup(device, &.{
        .label = stringView(label),
        .layout = layout,
        .entryCount = 1,
        .entries = &entry,
    });
}
