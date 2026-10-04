// Projectiles, drawn instanced: each part (`draw.model` places it in the projectile's own
// space) is rotated by the instance quaternion and moved to the instance position.
// Unlit in the draw color, so tracers stay bright; with LIT, shaded by one fixed
// directional light like basic_shape.wgsl (rockets). `frame` and `draw` come from
// common.wgsl.

override LIT: bool = false;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_NORMAL) normal: vec3f,
    @location(8) rotation: vec4f,
    @location(9) offset: vec3f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) world_normal: vec3f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let part_position = (draw.model * vec4f(in.position, 1.0)).xyz;
    let part_normal = (draw.normal_matrix * vec4f(in.normal, 0.0)).xyz;
    let world_position = rotateVec(part_position, in.rotation) + in.offset;

    var out: VertexOutput;
    out.clip_position = frame.projection_view * vec4f(world_position, 1.0);
    out.world_normal = rotateVec(part_normal, in.rotation);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    if (!LIT) {
        return draw.color;
    }
    let light_direction = normalize(vec3f(0.4, 1.0, 0.6));
    let diffuse = max(dot(normalize(in.world_normal), light_direction), 0.0);
    let lighting = 0.25 + 0.75 * diffuse;
    return vec4f(draw.color.rgb * lighting, draw.color.a);
}

// Rotates `v` by the unit quaternion `q` (xyz vector part, w scalar part).
fn rotateVec(v: vec3f, q: vec4f) -> vec3f {
    let t = 2.0 * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}
