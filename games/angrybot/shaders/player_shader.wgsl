// Port of player_shader.vert / .frag, also the enemies' shader (wiggly_shader.vert with
// player_shader.frag) and the player's emission shader (texture_emissive_shader.frag).
// redfish switched between these with uniforms; here each is an `override` constant set
// per pipeline in run_app:
//   DEPTH_MODE       shadow pass: position from the light; the pipeline has no fragment stage
//   EMISSIVE_ONLY    emission pass: the emissive texture only
//   WIGGLE           enemies: wiggly_shader's sideways wave
//   USE_EMISSIVE     add the emissive texture (redfish's useEmissive)
//   USE_POINT_LIGHT  the muzzle flash light, frame.lights.point_lights[0] while
//                    num_point_lights > 0 (redfish's usePointLight)
//
// Custom textures arrive in the PBR slots: base color = texture_diffuse, metallic-roughness
// = texture_specular, emissive = texture_emissive. The frame's direction light and ambient
// are redfish's directionLight / ambient. The shadow map is at group 3.
//
// Differences from redfish: normals use draw.normal_matrix with the skin (redfish used
// aimRot x the last joint); shadow coordinates flip y for WebGPU's texture origin
// (shadowCoords); the view position is the active camera's (redfish: the game camera's).

override DEPTH_MODE: bool = false;
override EMISSIVE_ONLY: bool = false;
override WIGGLE: bool = false;
override USE_EMISSIVE: bool = false;
override USE_POINT_LIGHT: bool = false;

const SHADOW_BIAS: f32 = 0.001;
const SHININESS: f32 = 24.0;

// wiggly_shader.vert
const WIGGLE_MAGNITUDE: f32 = 3.0;
const WIGGLE_DIST_MODIFIER: f32 = 0.12;
const WIGGLE_TIME_MODIFIER: f32 = 9.4;
// enemy.zig's nosePos: (1.0, MONSTER_Y, -2.0), MONSTER_Y = 0.0044 * 110.0
const NOSE_POSITION = vec3f(1.0, 0.484, -2.0);

@group(GROUP_MATERIAL) @binding(0) var<uniform> material: MaterialUniforms;
@group(GROUP_MATERIAL) @binding(1) var diffuse_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(2) var specular_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(5) var emissive_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(6) var diffuse_sampler: sampler;
@group(GROUP_MATERIAL) @binding(7) var specular_sampler: sampler;
@group(GROUP_MATERIAL) @binding(10) var emissive_sampler: sampler;

@group(GROUP_PASS) @binding(0) var shadow_map: texture_depth_2d;
@group(GROUP_PASS) @binding(1) var shadow_sampler: sampler_comparison;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_TEXCOORD) texcoord: vec2f,
    @location(LOCATION_NORMAL) normal: vec3f,
    @location(LOCATION_JOINTS) joints: vec4u,
    @location(LOCATION_WEIGHTS) weights: vec4f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) world_position: vec3f,
    @location(1) texcoord: vec2f,
    @location(2) normal: vec3f,
    @location(3) light_clip: vec4f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var position = in.position;
    if (WIGGLE) {
        let phase = WIGGLE_TIME_MODIFIER * frame.time + WIGGLE_DIST_MODIFIER * distance(NOSE_POSITION, in.position);
        position.x += sin(phase) * WIGGLE_MAGNITUDE;
    }

    let skin = skinMatrix(in.joints, in.weights);
    let skin3 = mat3x3f(skin[0].xyz, skin[1].xyz, skin[2].xyz);
    let world_position = draw.model * skin * vec4f(position, 1.0);

    var out: VertexOutput;
    out.light_clip = frame.light_space * world_position;
    out.clip_position = select(frame.projection_view * world_position, out.light_clip, DEPTH_MODE);
    out.world_position = world_position.xyz;
    out.texcoord = in.texcoord;
    out.normal = (draw.normal_matrix * vec4f(skin3 * in.normal, 0.0)).xyz;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let diffuse = textureSample(diffuse_texture, diffuse_sampler, in.texcoord);
    let specular = textureSample(specular_texture, specular_sampler, in.texcoord);
    let emission = textureSample(emissive_texture, emissive_sampler, in.texcoord);

    if (EMISSIVE_ONLY) {
        return emission;
    }

    let lights = frame.lights;
    let light_color = vec4f(lights.direction_light.color, 1.0);
    let normal = normalize(in.normal);

    // Direction light
    let light_dir = normalize(-lights.direction_light.dir);
    let diff = max(dot(normal, light_dir), 0.0);
    let ambient = lights.ambient * diffuse.rgb;
    let shadow = shadowAmount(in.light_clip);
    var color = (1.0 - shadow) * light_color * diffuse * diff + vec4f(ambient, 1.0);

    if (USE_POINT_LIGHT && lights.num_point_lights > 0u) {
        let point_light = lights.point_lights[0];
        let point_dir = normalize(point_light.world_pos - in.world_position);
        let point_diff = max(dot(normal, point_dir), 0.0);
        color += vec4f(0.7 * point_light.color * point_diff * diffuse.rgb, 1.0);
    }

    // Specular, outside shadows
    if (shadow < 0.1) {
        let reflect_dir = reflect(-lights.direction_light.dir, normal);
        let view_dir = normalize(frame.view_position - in.world_position);
        let spec = pow(max(dot(view_dir, reflect_dir), 0.0), SHININESS);
        color += spec * specular * light_color;
        color += spec * 0.1 * vec4f(1.0, 1.0, 1.0, 1.0);
    }

    if (USE_EMISSIVE) {
        color += emission;
    }
    return color;
}

/// 1 in shadow, 0 lit. Off the map is lit, as redfish's white border color.
fn shadowAmount(light_clip: vec4f) -> f32 {
    let coords = shadowCoords(light_clip);
    if (any(coords.xy < vec2f(0.0)) || any(coords.xy > vec2f(1.0))) {
        return 0.0;
    }
    return 1.0 - textureSampleCompareLevel(shadow_map, shadow_sampler, coords.xy, coords.z - SHADOW_BIAS);
}
