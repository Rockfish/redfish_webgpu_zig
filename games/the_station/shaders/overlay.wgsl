// Sprites over the frame in screen space (overlay.zig): the cursor, later the inventory
// bar. A textured quad from a sprite sheet, alpha blended, unlit.
//
// draw.model: the engine's square (-0.5..0.5) placed in clip space (overlay.zig).
// draw.color: tint (rgb) and opacity (a).
// draw.params: xy the sprite's top-left in the sheet, zw its size, both in uv (0..1, v
// down: the sheet is loaded without the flip).

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) uv: vec2f,
}

@group(GROUP_MATERIAL) @binding(0) var sprite_sheet: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(1) var sprite_sampler: sampler;

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    // The square's corner, 0..1 from the sprite's top-left
    let corner = vec2f(in.position.x + 0.5, 0.5 - in.position.y);

    var out: VertexOutput;
    out.clip_position = draw.model * vec4f(in.position, 1.0);
    out.uv = draw.params.xy + corner * draw.params.zw;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return textureSample(sprite_sheet, sprite_sampler, in.uv) * draw.color;
}
