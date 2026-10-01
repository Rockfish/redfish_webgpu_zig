// Tracer rounds: one stretched cube per instance, rotated by the instance quaternion and
// moved to the instance position. Unlit, in the draw color, so tracers stay bright.
// `frame` and `draw` come from common.wgsl.

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(8) rotation: vec4f,
    @location(9) offset: vec3f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let world_position = rotateVec(in.position, in.rotation) + in.offset;
    var out: VertexOutput;
    out.clip_position = frame.projection_view * vec4f(world_position, 1.0);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return draw.color;
}

// Rotates `v` by the unit quaternion `q` (xyz vector part, w scalar part).
fn rotateVec(v: vec3f, q: vec4f) -> vec3f {
    let t = 2.0 * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}
