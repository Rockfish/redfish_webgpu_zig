// Draws one layer of the shadow map array as a grayscale quad: the debug overlay. The quad
// is the unit square, placed directly in clip space by `draw.model` (no camera).
//
// The map is read with `textureLoad`, which needs no sampler, so group 3's comparison
// sampler (declared by the layout, unused here) doesn't get in the way.
//
// Per-draw values: `draw.params.xy` is the depth range shown black to white; `draw.params.z`
// is the layer. An orthographic light (the directional one) stores depth linearly, so 0..1
// shows near to far plane; a perspective one (the spotlight) bunches depth near 1.

@group(GROUP_PASS) @binding(0) var shadow_maps: texture_depth_2d_array;

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
    out.clip_position = draw.model * vec4f(in.position, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    // The square's texcoord y runs up; texture rows run down from the top-left origin.
    let size = vec2f(textureDimensions(shadow_maps));
    let texel = vec2i(vec2f(in.texcoord.x, 1.0 - in.texcoord.y) * (size - 1.0));
    let depth = textureLoad(shadow_maps, texel, i32(draw.params.z), 0);

    let range = draw.params.xy;
    let shade = clamp((depth - range.x) / max(range.y - range.x, 1e-5), 0.0, 1.0);
    return vec4f(shade, shade, shade, 1.0);
}
