// Shared by every shader. Prepended after the generated constants header, which defines
// GROUP_*, LOCATION_*, MAX_JOINTS, and DRAW_FLAG_*.
// Structs mirror src/core/bindings.zig; field names match exactly.

struct FrameUniforms {
    projection: mat4x4f,
    view: mat4x4f,
    projection_view: mat4x4f,
    view_position: vec3f,
    time: f32,
    light_position: vec3f,
    light_intensity: f32,
    light_color: vec3f,
}

struct DrawUniforms {
    model: mat4x4f,
    normal_matrix: mat4x4f,
    color: vec4f,
    flags: u32,
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

