// Port of instanced_quats.vert + basic_model.frag: one textured cube per instance, rotated
// by the instance quaternion and moved by the instance position. `.texture` material.
// As redfish: the normal is not rotated by the quaternion, and point lights use
// normalize(world_pos).

@group(GROUP_MATERIAL) @binding(0) var diffuse_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(1) var diffuse_sampler: sampler;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_TEXCOORD) texcoord: vec2f,
    @location(LOCATION_NORMAL) normal: vec3f,
    @location(8) rotation: vec4f,
    @location(9) offset: vec3f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) texcoord: vec2f,
    @location(1) normal: vec3f,
}

fn rotateVec(v: vec3f, q: vec4f) -> vec3f {
    let t = 2.0 * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let world_position = rotateVec(in.position, in.rotation) + in.offset;
    var out: VertexOutput;
    out.clip_position = frame.projection_view * vec4f(world_position, 1.0);
    out.texcoord = in.texcoord;
    out.normal = in.normal;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let color = textureSample(diffuse_texture, diffuse_sampler, in.texcoord);

    let lights = frame.lights;
    if (lights.use_light == 0u) {
        return color;
    }
    let normal = normalize(in.normal);
    var lighting = lights.direction_light.color * max(dot(normal, normalize(-lights.direction_light.dir)), 0.0);
    for (var i = 0u; i < min(lights.num_point_lights, MAX_POINT_LIGHTS); i++) {
        let light = lights.point_lights[i];
        lighting += light.color * max(dot(normal, normalize(light.world_pos)), 0.0);
    }
    return vec4f((lights.ambient + lighting) * color.rgb, color.a);
}
