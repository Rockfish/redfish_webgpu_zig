// Port of geom_shader2.vert + sprite_shader.frag: one frame of a horizontal sprite sheet.
// `.texture` material. draw.params = (columns, seconds per sprite, age, unused), which
// redfish set as the numCols / timePerSprite / age uniforms.

@group(GROUP_MATERIAL) @binding(0) var spritesheet: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(1) var spritesheet_sampler: sampler;

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
    out.clip_position = frame.projection_view * draw.model * vec4f(in.position, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let num_cols = draw.params.x;
    let time_per_sprite = draw.params.y;
    let age = draw.params.z;

    let col = floor(age / time_per_sprite);
    let sprite_texcoord = vec2f(in.texcoord.x / num_cols + col * (1.0 / num_cols), in.texcoord.y);
    return textureSample(spritesheet, spritesheet_sampler, sprite_texcoord);
}
