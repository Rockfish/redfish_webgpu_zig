// Shapes with a per-draw color (or vertex color) and one fixed directional light; with
// UNLIT, the color as is (explosion fireballs). `frame` and `draw` come from common.wgsl.

override UNLIT: bool = false;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_TEXCOORD) texcoord: vec2f,
    @location(LOCATION_NORMAL) normal: vec3f,
    @location(LOCATION_COLOR) color: vec4f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) world_normal: vec3f,
    @location(1) color: vec4f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let world_position = draw.model * vec4f(in.position, 1.0);
    let use_vertex_color = (draw.flags & DRAW_FLAG_VERTEX_COLOR) != 0u;

    var out: VertexOutput;
    out.clip_position = frame.projection_view * world_position;
    // w = 0: normals are directions, so translation must not apply
    out.world_normal = (draw.normal_matrix * vec4f(in.normal, 0.0)).xyz;
    out.color = select(draw.color, in.color, use_vertex_color);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    if (UNLIT) {
        return in.color;
    }
    let light_direction = normalize(vec3f(0.4, 1.0, 0.6));
    let diffuse = max(dot(normalize(in.world_normal), light_direction), 0.0);
    let lighting = 0.25 + 0.75 * diffuse;
    return vec4f(in.color.rgb * lighting, in.color.a);
}
