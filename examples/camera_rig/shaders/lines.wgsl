// Colored 1 px line segments (core Lines layout): the focus path. Same as the bullets
// example's lines.wgsl.

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_COLOR) color: vec4f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) color: vec4f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clip_position = frame.projection_view * vec4f(in.position, 1.0);
    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return in.color;
}
