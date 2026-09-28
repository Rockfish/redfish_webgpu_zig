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
pub const MAX_POINT_LIGHTS = 4;

/// What a shader binds at group 1. Picks the pipeline layout's material slot.
pub const MaterialKind = enum {
    /// Nothing; draws bind the empty group.
    none,
    /// One color texture and its sampler: `@binding(0)` texture_2d<f32>, `@binding(1)` sampler.
    texture,
    /// glTF metallic-roughness: `MaterialUniforms` at 0, five textures at 1-5 (base color,
    /// metallic-roughness, normal, occlusion, emissive), their samplers at 6-10.
    pbr,
    /// A cube map and its sampler (skybox): `@binding(0)` texture_cube<f32>, `@binding(1)` sampler.
    cube_texture,
};

/// What a shader binds at group 3, pass-specific resources.
pub const PassKind = enum {
    none,
    /// A shadow map: `@binding(0)` texture_depth_2d, `@binding(1)` sampler_comparison.
    shadow,
};

pub const PBR_TEXTURE_COUNT = 5;

/// `DrawUniforms.flags` bits.
pub const DrawFlags = struct {
    /// Use the vertex color attribute instead of `DrawUniforms.color`.
    pub const vertex_color: u32 = 1 << 0;
    /// Skin with `joints[joint_offset + joint_index]`. Set only when joints are bound.
    pub const skinned: u32 = 1 << 1;
};

/// Mirrors `DirectionLight` in shaders/common.wgsl.
pub const DirectionLightUniforms = extern struct {
    dir: Vec3,
    _pad0: f32 = 0.0,
    color: Vec3,
    _pad1: f32 = 0.0,
};

/// Mirrors `PointLight` in shaders/common.wgsl.
pub const PointLightUniforms = extern struct {
    world_pos: Vec3,
    constant: f32,
    color: Vec3,
    linear: f32,
    quadratic: f32,
    enabled: u32,
    _pad: [2]u32 = .{ 0, 0 },
};

/// Mirrors `Lights` in shaders/common.wgsl. Filled by `SceneLights.uniforms()`; all zero
/// (no light at all) until an app sets it.
pub const LightsUniforms = extern struct {
    ambient: Vec3 = Vec3.init(0.0, 0.0, 0.0),
    use_light: u32 = 0,
    direction_light: DirectionLightUniforms = .{ .dir = Vec3.init(0.0, -1.0, 0.0), .color = Vec3.init(0.0, 0.0, 0.0) },
    point_lights: [MAX_POINT_LIGHTS]PointLightUniforms = @splat(.{
        .world_pos = Vec3.init(0.0, 0.0, 0.0),
        .constant = 1.0,
        .color = Vec3.init(0.0, 0.0, 0.0),
        .linear = 0.0,
        .quadratic = 0.0,
        .enabled = 0,
    }),
    num_point_lights: u32 = 0,
    /// Nonzero: fade specular at grazing views (see `SceneLights.fade_grazing_specular`).
    fade_grazing_specular: u32 = 0,
    _pad: [2]u32 = .{ 0, 0 },
};

/// Mirrors `FrameUniforms` in shaders/common.wgsl (group 0, binding 0).
pub const FrameUniforms = extern struct {
    projection: Mat4,
    view: Mat4,
    projection_view: Mat4,
    view_position: Vec3,
    time: f32, // fills vec3's 16-byte slot
    lights: LightsUniforms = .{},
    /// Projection x view of the shadow-casting light (redfish's `lightSpaceMatrix`), for
    /// shadow passes and shadow lookups. Identity when unused.
    light_space: Mat4 = Mat4.Identity,
};

/// Mirrors `DrawUniforms` in shaders/common.wgsl (group 2, binding 0). One per draw,
/// allocated from the uniform ring.
pub const DrawUniforms = extern struct {
    model: Mat4,
    /// Inverse transpose of `model`; a mat4 because a WGSL mat3x3 pads its columns.
    normal_matrix: Mat4,
    color: Vec4,
    flags: u32,
    /// First joint matrix of this draw in group 2's `joints` array (skinned meshes).
    joint_offset: u32 = 0,
    _pad: [2]u32 = .{ 0, 0 },
    /// Shader-specific per-draw values (e.g. a sprite sheet's columns and age); zero
    /// unless the shader documents them.
    params: Vec4 = Vec4.init(0.0, 0.0, 0.0, 0.0),

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
    std.debug.assert(@sizeOf(DirectionLightUniforms) == 32);
    std.debug.assert(@sizeOf(PointLightUniforms) == 48);
    std.debug.assert(@sizeOf(LightsUniforms) == 256);
    std.debug.assert(@sizeOf(FrameUniforms) == 528);
    std.debug.assert(@offsetOf(FrameUniforms, "light_space") == 464);
    std.debug.assert(@sizeOf(DrawUniforms) == 176);
    std.debug.assert(@offsetOf(DrawUniforms, "params") == 160);
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
    \\const MAX_POINT_LIGHTS: u32 = {d}u;
    \\const DRAW_FLAG_VERTEX_COLOR: u32 = {d}u;
    \\const DRAW_FLAG_SKINNED: u32 = {d}u;
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
    MAX_POINT_LIGHTS,
    DrawFlags.vertex_color,
    DrawFlags.skinned,
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
    cube_texture_layout: c.WGPUBindGroupLayout,
    object_layout: c.WGPUBindGroupLayout,
    shadow_layout: c.WGPUBindGroupLayout,

    frame_buffer: c.WGPUBuffer,
    frame_bind_group: c.WGPUBindGroup,
    empty_bind_group: c.WGPUBindGroup,
    /// One identity matrix: group 2's `joints` for draws without skinning.
    no_joints_buffer: c.WGPUBuffer,
    /// Binds the uniform ring with a dynamic offset per draw, and `no_joints_buffer`.
    /// Skinned instances make their own with `createObjectBindGroup`.
    object_bind_group: c.WGPUBindGroup,

    const Self = @This();

    pub fn init(device: c.WGPUDevice, queue: c.WGPUQueue, uniform_ring_buffer: c.WGPUBuffer) Self {
        const frame_layout = createUniformLayout(device, "frame layout", @sizeOf(FrameUniforms), false);
        const empty_layout = c.wgpuDeviceCreateBindGroupLayout(device, &.{ .label = stringView("empty layout") });
        const object_layout = createObjectLayout(device);
        const texture_layout = createTextureLayout(device, c.WGPUTextureViewDimension_2D, "texture material layout");
        const pbr_layout = createPbrLayout(device);
        const cube_texture_layout = createTextureLayout(device, c.WGPUTextureViewDimension_Cube, "cube texture layout");

        const no_joints_buffer = c.wgpuDeviceCreateBuffer(device, &.{
            .label = stringView("no joints"),
            .usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(Mat4),
        });
        c.wgpuQueueWriteBuffer(queue, no_joints_buffer, 0, &Mat4.Identity, @sizeOf(Mat4));

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
            .cube_texture_layout = cube_texture_layout,
            .object_layout = object_layout,
            .shadow_layout = createShadowLayout(device),
            .frame_buffer = frame_buffer,
            .frame_bind_group = createUniformBindGroup(device, "frame", frame_layout, frame_buffer, @sizeOf(FrameUniforms)),
            .empty_bind_group = c.wgpuDeviceCreateBindGroup(device, &.{
                .label = stringView("empty"),
                .layout = empty_layout,
            }),
            .no_joints_buffer = no_joints_buffer,
            .object_bind_group = createObjectBindGroup(device, object_layout, uniform_ring_buffer, no_joints_buffer, @sizeOf(Mat4)),
        };
    }

    pub fn materialLayout(self: *const Self, kind: MaterialKind) c.WGPUBindGroupLayout {
        return switch (kind) {
            .none => self.empty_layout,
            .texture => self.texture_layout,
            .pbr => self.pbr_layout,
            .cube_texture => self.cube_texture_layout,
        };
    }

    /// Group 3 layout for `kind`; null for `.none` (the pipeline layout stops at group 2).
    pub fn passLayout(self: *const Self, kind: PassKind) c.WGPUBindGroupLayout {
        return switch (kind) {
            .none => null,
            .shadow => self.shadow_layout,
        };
    }

    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuBindGroupLayoutRelease(self.shadow_layout);
        c.wgpuBindGroupRelease(self.object_bind_group);
        c.wgpuBufferRelease(self.no_joints_buffer);
        c.wgpuBindGroupRelease(self.empty_bind_group);
        c.wgpuBindGroupRelease(self.frame_bind_group);
        c.wgpuBufferRelease(self.frame_buffer);
        c.wgpuBindGroupLayoutRelease(self.object_layout);
        c.wgpuBindGroupLayoutRelease(self.cube_texture_layout);
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

/// Group 2: per-draw uniforms from the ring (dynamic offset) at 0, joint matrices at 1.
fn createObjectLayout(device: c.WGPUDevice) c.WGPUBindGroupLayout {
    const entries = [_]c.WGPUBindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment,
            .buffer = .{
                .type = c.WGPUBufferBindingType_Uniform,
                .hasDynamicOffset = 1,
                .minBindingSize = @sizeOf(DrawUniforms),
            },
        },
        .{
            .binding = 1,
            .visibility = c.WGPUShaderStage_Vertex,
            .buffer = .{ .type = c.WGPUBufferBindingType_ReadOnlyStorage, .minBindingSize = @sizeOf(Mat4) },
        },
    };
    return c.wgpuDeviceCreateBindGroupLayout(device, &.{
        .label = stringView("object layout"),
        .entryCount = entries.len,
        .entries = &entries,
    });
}

/// A group 2 bind group: the uniform ring plus a joint matrix buffer.
pub fn createObjectBindGroup(
    device: c.WGPUDevice,
    object_layout: c.WGPUBindGroupLayout,
    uniform_ring_buffer: c.WGPUBuffer,
    joints_buffer: c.WGPUBuffer,
    joints_size: u64,
) c.WGPUBindGroup {
    const entries = [_]c.WGPUBindGroupEntry{
        .{ .binding = 0, .buffer = uniform_ring_buffer, .size = @sizeOf(DrawUniforms) },
        .{ .binding = 1, .buffer = joints_buffer, .size = joints_size },
    };
    return c.wgpuDeviceCreateBindGroup(device, &.{
        .label = stringView("object"),
        .layout = object_layout,
        .entryCount = entries.len,
        .entries = &entries,
    });
}

/// `MaterialKind.texture` (2D) and `.cube_texture` (cube): filterable texture at binding 0,
/// filtering sampler at 1.
fn createTextureLayout(device: c.WGPUDevice, view_dimension: c.WGPUTextureViewDimension, label: []const u8) c.WGPUBindGroupLayout {
    const entries = [_]c.WGPUBindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = c.WGPUShaderStage_Fragment,
            .texture = .{ .sampleType = c.WGPUTextureSampleType_Float, .viewDimension = view_dimension },
        },
        .{
            .binding = 1,
            .visibility = c.WGPUShaderStage_Fragment,
            .sampler = .{ .type = c.WGPUSamplerBindingType_Filtering },
        },
    };
    return c.wgpuDeviceCreateBindGroupLayout(device, &.{
        .label = stringView(label),
        .entryCount = entries.len,
        .entries = &entries,
    });
}

/// `PassKind.shadow`: depth texture at binding 0, comparison sampler at 1.
fn createShadowLayout(device: c.WGPUDevice) c.WGPUBindGroupLayout {
    const entries = [_]c.WGPUBindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = c.WGPUShaderStage_Fragment,
            .texture = .{ .sampleType = c.WGPUTextureSampleType_Depth, .viewDimension = c.WGPUTextureViewDimension_2D },
        },
        .{
            .binding = 1,
            .visibility = c.WGPUShaderStage_Fragment,
            .sampler = .{ .type = c.WGPUSamplerBindingType_Comparison },
        },
    };
    return c.wgpuDeviceCreateBindGroupLayout(device, &.{
        .label = stringView("shadow layout"),
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
