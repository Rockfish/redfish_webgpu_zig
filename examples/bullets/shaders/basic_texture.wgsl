// Port of basic_texture.vert / .frag: textured or flat-colored shapes lit by the frame's
// SceneLights. Material (pbr layout): base color = diffuse map, normal slot = normal map,
// metallic-roughness slot = specular map. Without a diffuse map the color is draw.color;
// the output alpha is draw.color.a (redfish's `colorAlpha`).
// As redfish: the normal map is used as a world-space normal, without a TBN.
// Ambient is ambient x base color; redfish multiplied by the diffuse map even without one
// (GL read whatever was in texture unit 0), which here would add flat white.

@group(GROUP_MATERIAL) @binding(0) var<uniform> material: MaterialUniforms;
@group(GROUP_MATERIAL) @binding(1) var diffuse_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(2) var spec_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(3) var normal_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(6) var diffuse_sampler: sampler;
@group(GROUP_MATERIAL) @binding(7) var spec_sampler: sampler;
@group(GROUP_MATERIAL) @binding(8) var normal_sampler: sampler;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_TEXCOORD) texcoord: vec2f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) world_position: vec3f,
    @location(1) texcoord: vec2f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let world_position = draw.model * vec4f(in.position, 1.0);
    var out: VertexOutput;
    out.clip_position = frame.projection_view * world_position;
    out.world_position = world_position.xyz;
    out.texcoord = in.texcoord;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let diffuse_sample = textureSample(diffuse_texture, diffuse_sampler, in.texcoord);
    let normal_sample = textureSample(normal_texture, normal_sampler, in.texcoord).xyz;
    let spec_sample = textureSample(spec_texture, spec_sampler, in.texcoord).r;

    let has_texture = (material.flags & MATERIAL_FLAG_BASE_COLOR_TEXTURE) != 0u;
    var color = select(draw.color.rgb, diffuse_sample.rgb, has_texture);

    let lights = frame.lights;
    if (lights.use_light != 0u) {
        let normal = normalize(normal_sample * 2.0 - 1.0);

        let light_dir = normalize(-lights.direction_light.dir);
        var lighting = lights.direction_light.color * max(dot(normal, light_dir), 0.0);

        for (var i = 0u; i < min(lights.num_point_lights, MAX_POINT_LIGHTS); i++) {
            let light = lights.point_lights[i];
            let distance = length(light.world_pos - in.world_position);
            let attenuation = 1.0 / (light.constant + light.linear * distance + light.quadratic * distance * distance);
            let point_dir = normalize(light.world_pos - in.world_position);
            lighting += light.color * max(dot(normal, point_dir), 0.0) * attenuation;
        }

        lighting += lighting * spec_sample * 0.3;
        color = lighting * color + lights.ambient * color;
    }

    return vec4f(color, draw.color.a);
}
