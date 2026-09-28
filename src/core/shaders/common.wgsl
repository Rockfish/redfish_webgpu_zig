// Shared by every shader. Prepended after the generated constants header, which defines
// GROUP_*, LOCATION_*, MAX_JOINTS, and DRAW_FLAG_*.
// Structs mirror src/core/bindings.zig; field names match exactly.

struct DirectionLight {
    dir: vec3f,
    color: vec3f,
}

struct PointLight {
    world_pos: vec3f,
    constant: f32,
    color: vec3f,
    linear: f32,
    quadratic: f32,
    enabled: u32,
}

// The frame's SceneLights (src/core/lights.zig).
struct Lights {
    ambient: vec3f,
    use_light: u32,
    direction_light: DirectionLight,
    point_lights: array<PointLight, MAX_POINT_LIGHTS>,
    num_point_lights: u32,
    fade_grazing_specular: u32,
}

struct FrameUniforms {
    projection: mat4x4f,
    view: mat4x4f,
    projection_view: mat4x4f,
    view_position: vec3f,
    time: f32,
    lights: Lights,
    // Projection x view of the shadow-casting light (redfish's lightSpaceMatrix).
    light_space: mat4x4f,
}

struct DrawUniforms {
    model: mat4x4f,
    normal_matrix: mat4x4f,
    color: vec4f,
    flags: u32,
    joint_offset: u32,
    // Shader-specific per-draw values, documented by the shader that reads them.
    params: vec4f,
}

// Group 1 uniforms of `pbr` materials.
struct MaterialUniforms {
    base_color_factor: vec4f,
    emissive_factor: vec3f,
    metallic_factor: f32,
    roughness_factor: f32,
    alpha_cutoff: f32,
    flags: u32,
}

@group(GROUP_FRAME) @binding(0) var<uniform> frame: FrameUniforms;
@group(GROUP_OBJECT) @binding(0) var<uniform> draw: DrawUniforms;
// Joint matrices for skinned draws, from `draw.joint_offset`. One identity matrix otherwise.
@group(GROUP_OBJECT) @binding(1) var<storage, read> joints: array<mat4x4f>;

/// Blend of this vertex's joint matrices, or identity when the draw isn't skinned.
fn skinMatrix(joint_ids: vec4u, weights: vec4f) -> mat4x4f {
    if ((draw.flags & DRAW_FLAG_SKINNED) == 0u) {
        return mat4x4f(vec4f(1.0, 0.0, 0.0, 0.0), vec4f(0.0, 1.0, 0.0, 0.0), vec4f(0.0, 0.0, 1.0, 0.0), vec4f(0.0, 0.0, 0.0, 1.0));
    }
    return jointMatrix(joint_ids.x) * weights.x
        + jointMatrix(joint_ids.y) * weights.y
        + jointMatrix(joint_ids.z) * weights.z
        + jointMatrix(joint_ids.w) * weights.w;
}

/// Out-of-range reads are implementation-defined in WGSL; clamp to the last matrix.
fn jointMatrix(joint: u32) -> mat4x4f {
    let index = min(draw.joint_offset + joint, arrayLength(&joints) - 1u);
    return joints[index];
}

/// Shadow map coordinates of a position in the light's clip space: uv with WebGPU's
/// top-left texture origin (y flipped from NDC) and depth as is (0..1 already). The
/// result's xy outside 0..1 is off the map.
fn shadowCoords(light_clip: vec4f) -> vec3f {
    let ndc = light_clip.xyz / light_clip.w;
    return vec3f(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5, ndc.z);
}
