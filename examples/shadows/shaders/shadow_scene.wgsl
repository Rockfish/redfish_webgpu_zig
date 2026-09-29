// Shapes lit by two shadow-casting lights, each with a layer in the ShadowMapArray at
// group 3: the frame's directional light (layer 0) and a spotlight (layer 1), which is the
// frame's point light 0 while `num_point_lights` > 0. The spotlight's cone is its shadow
// projection: light falls where the light's view does, fading out toward the map's edge
// circle. The casters are drawn by shadow_caster.wgsl.
//
// Per-draw values: `draw.color` is the surface color; `draw.params.x` is the depth bias
// subtracted before each shadow comparison (the panel's "shader bias"); `draw.params.y` is
// the PCF radius, 0 for a single comparison.

const DIRECTIONAL_LAYER: i32 = 0;
const SPOT_LAYER: i32 = 1;
/// Fraction of the cone's radius where the spotlight starts fading to its edge.
const SPOT_EDGE_START: f32 = 0.8;

@group(GROUP_PASS) @binding(0) var shadow_maps: texture_depth_2d_array;
@group(GROUP_PASS) @binding(1) var shadow_sampler: sampler_comparison;
@group(GROUP_PASS) @binding(2) var<uniform> shadow_layers: array<ShadowLayer, MAX_SHADOW_LAYERS>;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_NORMAL) normal: vec3f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) world_position: vec3f,
    @location(1) world_normal: vec3f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let world_position = draw.model * vec4f(in.position, 1.0);

    var out: VertexOutput;
    out.clip_position = frame.projection_view * world_position;
    out.world_position = world_position.xyz;
    // w = 0: normals are directions, so translation must not apply
    out.world_normal = (draw.normal_matrix * vec4f(in.normal, 0.0)).xyz;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let lights = frame.lights;
    let normal = normalize(in.world_normal);
    let bias = draw.params.x;
    let pcf_radius = i32(draw.params.y);

    // Directional light
    let to_sun = normalize(-lights.direction_light.dir);
    let sun_diffuse = max(dot(normal, to_sun), 0.0);
    let sun_lit = litAmount(DIRECTIONAL_LAYER, in.world_position, bias, pcf_radius);
    var light = lights.direction_light.color * sun_diffuse * sun_lit;

    // Spotlight
    if (lights.num_point_lights > 0u) {
        let spot = lights.point_lights[0];
        let to_spot = spot.world_pos - in.world_position;
        let distance = length(to_spot);
        let spot_diffuse = max(dot(normal, to_spot / distance), 0.0);
        let attenuation = 1.0 / (spot.constant + spot.linear * distance + spot.quadratic * distance * distance);
        let cone = spotCone(in.world_position);
        let spot_lit = litAmount(SPOT_LAYER, in.world_position, bias, pcf_radius);
        light += spot.color * spot_diffuse * attenuation * cone * spot_lit;
    }

    let color = draw.color.rgb * (lights.ambient + light);
    return vec4f(color, draw.color.a);
}

/// Layer `layer`'s light-space position of a world position.
fn lightClip(layer: i32, world_position: vec3f) -> vec4f {
    return shadow_layers[layer].light_space * vec4f(world_position, 1.0);
}

/// 1 inside the spotlight's cone, fading to 0 at the circle inscribed in its shadow map;
/// 0 behind the light.
fn spotCone(world_position: vec3f) -> f32 {
    let light_clip = lightClip(SPOT_LAYER, world_position);
    if (light_clip.w <= 0.0) {
        return 0.0;
    }
    let coords = shadowCoords(light_clip);
    let radius = length(coords.xy - vec2f(0.5)) * 2.0;
    return 1.0 - smoothstep(SPOT_EDGE_START, 1.0, radius);
}

/// 1 where lit by layer `layer`'s light, 0 in its shadow, in between at a softened edge.
/// Percentage-closer filtering: the average of (2 x radius + 1)² comparisons one texel
/// apart. Off the map, or past the light's far plane, counts as lit.
fn litAmount(layer: i32, world_position: vec3f, bias: f32, radius: i32) -> f32 {
    let light_clip = lightClip(layer, world_position);
    let coords = shadowCoords(light_clip);
    if (light_clip.w <= 0.0 || any(coords.xy < vec2f(0.0)) || any(coords.xy > vec2f(1.0)) || coords.z > 1.0) {
        return 1.0;
    }

    let texel = 1.0 / vec2f(textureDimensions(shadow_maps));
    var lit = 0.0;
    for (var y = -radius; y <= radius; y++) {
        for (var x = -radius; x <= radius; x++) {
            let uv = coords.xy + vec2f(f32(x), f32(y)) * texel;
            lit += textureSampleCompareLevel(shadow_maps, shadow_sampler, uv, layer, coords.z - bias);
        }
    }
    let taps = f32((2 * radius + 1) * (2 * radius + 1));
    return lit / taps;
}
