// Port of basic_texture_shader.vert / .frag as the burn marks use it: the texture color
// (redfish's useLight was never set for this shader, so its lighting branch never ran).
// `.texture` material.

@group(GROUP_MATERIAL) @binding(0) var diffuse_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(1) var diffuse_sampler: sampler;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_TEXCOORD) texcoord: vec2f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) texcoord: vec2f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clip_position = frame.projection_view * draw.model * vec4f(in.position, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return textureSample(diffuse_texture, diffuse_sampler, in.texcoord);
}
