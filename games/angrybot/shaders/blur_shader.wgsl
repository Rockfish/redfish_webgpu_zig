// Port of basicer_shader.vert + blur_shader.frag: one direction of a 28-tap Gaussian blur
// over a full-screen quad. `.texture` material (the image to blur). draw.params.x is 1 for
// the horizontal pass, 0 for the vertical (redfish's `horizontal` uniform).

const BLUR_DIST: i32 = 28;
const WEIGHTS = array<f32, 28>(
    0.049835, 0.049448, 0.048304, 0.046456, 0.043987, 0.041004, 0.037631, 0.034002, 0.030246, 0.026489,
    0.022839, 0.019388, 0.016203, 0.013331, 0.010799, 0.008612, 0.006762, 0.005227, 0.003978, 0.00298,
    0.002199, 0.001597, 0.001142, 0.000804, 0.000557, 0.00038, 0.000255, 0.000169,
);

@group(GROUP_MATERIAL) @binding(0) var image: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(1) var image_sampler: sampler;

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
    let texel = 1.0 / vec2f(textureDimensions(image));
    let step = select(vec2f(0.0, texel.y), vec2f(texel.x, 0.0), draw.params.x > 0.5);

    var result = textureSample(image, image_sampler, in.texcoord).rgb * WEIGHTS[0];
    for (var i = 1; i < BLUR_DIST; i++) {
        let offset = step * f32(i);
        result += textureSample(image, image_sampler, in.texcoord + offset).rgb * WEIGHTS[i];
        result += textureSample(image, image_sampler, in.texcoord - offset).rgb * WEIGHTS[i];
    }
    return vec4f(result, 1.0);
}
