// A fill of the whole window in one color (overlay.zig, `Overlay.fill`): the fade between
// floors. Unlit, alpha blended.
//
// draw.model: the engine's square (-0.5..0.5) scaled to clip space.
// draw.color: the color (rgb) and opacity (a).

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
}

@vertex
fn vs_main(in: VertexInput) -> @builtin(position) vec4f {
    return draw.model * vec4f(in.position, 1.0);
}

@fragment
fn fs_main() -> @location(0) vec4f {
    return draw.color;
}
