// Port of basicer_shader.vert + texture_merge_shader.frag: the final composite to the window.
// Scene + blurred emission x 2.9, plus a boost where the unblurred emission is bright.
// The targets hold gamma-space values (angrybot shades as redfish's GL did); the result is
// clamped as GL's 8-bit window was, then decoded so the sRGB surface shows GL's values.
// Material (pbr layout, made from the render targets): base color = scene, emissive =
// blurred emission, metallic-roughness slot = unblurred emission (redfish's base_texture,
// emission_texture, bright_texture).

@group(GROUP_MATERIAL) @binding(0) var<uniform> material: MaterialUniforms;
@group(GROUP_MATERIAL) @binding(1) var base_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(2) var bright_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(5) var emission_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(6) var base_sampler: sampler;
@group(GROUP_MATERIAL) @binding(7) var bright_sampler: sampler;
@group(GROUP_MATERIAL) @binding(10) var emission_sampler: sampler;

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
    out.clip_position = vec4f(in.position, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let base = textureSample(base_texture, base_sampler, in.texcoord).rgb;
    let emission = textureSample(emission_texture, emission_sampler, in.texcoord).rgb;
    let raw_bright = textureSample(bright_texture, bright_sampler, in.texcoord).rgb;

    var color = vec4f(base + emission * 2.9, 1.0);

    let brightness = calcBrightness(raw_bright);
    if (brightness > 0.05) {
        let mult = 1.5;
        let additive = select(0.4, 1.8, brightness > 0.3);
        color += vec4f(mult * raw_bright + vec3f(2.0 * additive, 0.6 * additive, 0.6 * additive), 1.0);
    }
    return vec4f(srgbToLinear(clamp(color.rgb, vec3f(0.0), vec3f(1.0))), 1.0);
}

fn calcBrightness(color: vec3f) -> f32 {
    return (color.x + color.y + color.z) / 3.0;
}

/// The sRGB transfer function's inverse, as core's colors.srgbToLinear.
fn srgbToLinear(color: vec3f) -> vec3f {
    let low = color / 12.92;
    let high = pow((color + 0.055) / 1.055, vec3f(2.4));
    return select(high, low, color <= vec3f(0.04045));
}
