// Port of level_01's basic_model.vert / .frag: unlit. The texture color, or the vertex
// color with DRAW_FLAG_VERTEX_COLOR (redfish's hasTexture == 0 path, used by the barrel),
// plus `draw.color`: zero normally, red for the node under the mouse (redfish's hitColor).
// redfish computed ambient and diffuse terms but never used them.

@group(GROUP_MATERIAL) @binding(0) var texture_diffuse: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(1) var texture_sampler: sampler;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_TEXCOORD) texcoord: vec2f,
    @location(LOCATION_COLOR) color: vec4f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) texcoord: vec2f,
    @location(1) color: vec4f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clip_position = frame.projection_view * draw.model * vec4f(in.position, 1.0);
    out.texcoord = in.texcoord;
    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let use_vertex_color = (draw.flags & DRAW_FLAG_VERTEX_COLOR) != 0u;
    let texture_color = textureSample(texture_diffuse, texture_sampler, in.texcoord);
    let color = select(texture_color, in.color, use_vertex_color);

    if (color.a < 0.1) {
        discard;
    }
    return color + draw.color;
}
