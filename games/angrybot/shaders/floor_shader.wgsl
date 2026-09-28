// Port of basic_texture_shader.vert + floor_shader.frag: the floor with a 3x3 PCF shadow and
// a fixed specular light. Material (pbr layout): base color = Floor D, metallic-roughness
// slot = Floor M (specular), normal slot = Floor N. Shadow map at group 3.
//
// The floor's light is its own, not the frame's: run_app.zig's floor_light_dir /
// floor_light_color / floor_ambient_color, which redfish set as floor_shader uniforms.
// As redfish: the tangent-space normal map is used as a world-space normal, and the PCF
// sum is divided by 7 and scaled by 0.7. Not ported: the point light branch, which
// redfish always turned off for the floor.

const SHADOW_BIAS: f32 = 0.001;
const SPEC_SHININESS: f32 = 0.7;

// normalize(10, 0, -10)
const FLOOR_LIGHT_DIR = vec3f(0.70710677, 0.0, -0.70710677);
// (1, 1, 1) x FLOOR_LIGHT_FACTOR (0.35)
const FLOOR_LIGHT_COLOR = vec3f(0.35, 0.35, 0.35);
// (FLOOR_NON_BLUE x 0.7, FLOOR_NON_BLUE x 0.7, 0.7) x FLOOR_LIGHT_FACTOR x 0.5
const FLOOR_AMBIENT = vec3f(0.08575, 0.08575, 0.1225);
// normalize(-3, 0, -1)
const SPEC_LIGHT_DIR = vec3f(-0.9486833, 0.0, -0.31622777);

@group(GROUP_MATERIAL) @binding(0) var<uniform> material: MaterialUniforms;
@group(GROUP_MATERIAL) @binding(1) var diffuse_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(2) var specular_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(3) var normal_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(6) var diffuse_sampler: sampler;
@group(GROUP_MATERIAL) @binding(7) var specular_sampler: sampler;
@group(GROUP_MATERIAL) @binding(8) var normal_sampler: sampler;

@group(GROUP_PASS) @binding(0) var shadow_map: texture_depth_2d;
@group(GROUP_PASS) @binding(1) var shadow_sampler: sampler_comparison;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_TEXCOORD) texcoord: vec2f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) world_position: vec3f,
    @location(1) texcoord: vec2f,
    @location(2) light_clip: vec4f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let world_position = draw.model * vec4f(in.position, 1.0);
    var out: VertexOutput;
    out.clip_position = frame.projection_view * world_position;
    out.world_position = world_position.xyz;
    out.texcoord = in.texcoord;
    out.light_clip = frame.light_space * world_position;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let diffuse = textureSample(diffuse_texture, diffuse_sampler, in.texcoord);
    let specular = textureSample(specular_texture, specular_sampler, in.texcoord);
    let normal_sample = textureSample(normal_texture, normal_sampler, in.texcoord).xyz;

    let light_dir = normalize(-FLOOR_LIGHT_DIR);
    let normal = normalize(normal_sample * 2.0 - 1.0);
    let diff = max(dot(normal, light_dir), 0.0);
    let ambient = FLOOR_AMBIENT * diffuse.rgb;

    let texel_size = 1.0 / vec2f(textureDimensions(shadow_map));
    var shadow = 0.0;
    for (var x = -1; x <= 1; x++) {
        for (var y = -1; y <= 1; y++) {
            shadow += shadowAmount(in.light_clip, vec2f(f32(x), f32(y)) * texel_size);
        }
    }
    shadow /= 7.0;
    shadow *= 0.7;

    let light_color = vec4f(FLOOR_LIGHT_COLOR, 1.0);
    var color = 0.7 * (1.0 - shadow) * light_color * diffuse * diff + vec4f(ambient, 1.0);

    // Fixed specular light
    let reflect_dir = reflect(SPEC_LIGHT_DIR, vec3f(0.0, 1.0, 0.0));
    let view_dir = normalize(frame.view_position - in.world_position);
    let spec = pow(max(dot(view_dir, reflect_dir), 0.0), SPEC_SHININESS);
    color += spec * specular * light_color;

    return color;
}

/// 1 in shadow, 0 lit, for one PCF tap. Off the map is lit, as redfish's white border.
fn shadowAmount(light_clip: vec4f, offset: vec2f) -> f32 {
    let coords = shadowCoords(light_clip);
    let uv = coords.xy + offset;
    if (any(uv < vec2f(0.0)) || any(uv > vec2f(1.0))) {
        return 0.0;
    }
    return 1.0 - textureSampleCompareLevel(shadow_map, shadow_sampler, uv, coords.z - SHADOW_BIAS);
}
