// Shared by every shader. Prepended after the generated constants header, which defines
// GROUP_*, LOCATION_*, MAX_JOINTS, and DRAW_FLAG_*.
// Structs mirror src/core/bindings.zig; field names match exactly.

struct FrameUniforms {
    projection: mat4x4f,
    view: mat4x4f,
    projection_view: mat4x4f,
    view_position: vec3f,
    time: f32,
}

struct DrawUniforms {
    model: mat4x4f,
    normal_matrix: mat4x4f,
    color: vec4f,
    flags: u32,
}

@group(GROUP_FRAME) @binding(0) var<uniform> frame: FrameUniforms;
@group(GROUP_OBJECT) @binding(0) var<uniform> draw: DrawUniforms;

