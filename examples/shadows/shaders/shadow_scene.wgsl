// Shapes lit by the frame's directional light, receiving shadows from the shadow map at
// group 3. The same file is the shadow pass's caster: with DEPTH_MODE the position comes
// from the light (`frame.light_space`) and the pipeline has no fragment stage.
//
// Per-draw values: `draw.color` is the surface color; `draw.params.x` is the depth bias
// subtracted before the shadow comparison (the panel's "shader bias"); `draw.params.y` is
// the PCF radius, 0 for a single comparison.

override DEPTH_MODE: bool = false;

@group(GROUP_PASS) @binding(0) var shadow_map: texture_depth_2d;
@group(GROUP_PASS) @binding(1) var shadow_sampler: sampler_comparison;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_NORMAL) normal: vec3f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) world_normal: vec3f,
    @location(1) light_clip: vec4f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let world_position = draw.model * vec4f(in.position, 1.0);

    var out: VertexOutput;
    out.light_clip = frame.light_space * world_position;
    out.clip_position = select(frame.projection_view * world_position, out.light_clip, DEPTH_MODE);
    // w = 0: normals are directions, so translation must not apply
    out.world_normal = (draw.normal_matrix * vec4f(in.normal, 0.0)).xyz;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let lights = frame.lights;
    let normal = normalize(in.world_normal);
    let to_light = normalize(-lights.direction_light.dir);
    let diffuse = max(dot(normal, to_light), 0.0);

    let lit = litAmount(in.light_clip, draw.params.x, i32(draw.params.y));
    let color = draw.color.rgb * (lights.ambient + lights.direction_light.color * diffuse * lit);
    return vec4f(color, draw.color.a);
}

/// 1 where lit, 0 in shadow, in between at a softened edge. Percentage-closer filtering:
/// the average of (2 x radius + 1)² comparisons one texel apart, so the edge fades over
/// that many texels. Off the map counts as lit.
fn litAmount(light_clip: vec4f, bias: f32, radius: i32) -> f32 {
    let coords = shadowCoords(light_clip);
    if (any(coords.xy < vec2f(0.0)) || any(coords.xy > vec2f(1.0)) || coords.z > 1.0) {
        return 1.0;
    }

    let texel = 1.0 / vec2f(textureDimensions(shadow_map));
    var lit = 0.0;
    for (var y = -radius; y <= radius; y++) {
        for (var x = -radius; x <= radius; x++) {
            let uv = coords.xy + vec2f(f32(x), f32(y)) * texel;
            lit += textureSampleCompareLevel(shadow_map, shadow_sampler, uv, coords.z - bias);
        }
    }
    let taps = f32((2 * radius + 1) * (2 * radius + 1));
    return lit / taps;
}
