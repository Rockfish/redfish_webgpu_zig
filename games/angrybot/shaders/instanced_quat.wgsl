// Port of instanced_quat.vert + basic_texture_shader.frag (useLight off): the bullets, one
// textured quad pair per instance, rotated by the instance quaternion (x, y, z, w) and
// moved by the instance position. `.texture` material.

@group(GROUP_MATERIAL) @binding(0) var diffuse_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(1) var diffuse_sampler: sampler;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_TEXCOORD) texcoord: vec2f,
    @location(8) rotation: vec4f,
    @location(9) offset: vec3f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) texcoord: vec2f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let world_position = rotateVec(in.position, in.rotation) + in.offset;
    var out: VertexOutput;
    out.clip_position = frame.projection_view * vec4f(world_position, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return textureSample(diffuse_texture, diffuse_sampler, in.texcoord);
}

/// v' = v + 2 cross(q.xyz, cross(q.xyz, v) + q.w v), as the Zig Quat.rotateVec.
fn rotateVec(v: vec3f, q: vec4f) -> vec3f {
    let t = 2.0 * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}
