// Ink outlines: a full-screen quad over the scene that draws a dark line wherever the
// normal-depth target (room.wgsl with NORMAL_DEPTH) changes sharply between neighboring
// pixels. A jump in depth is a silhouette (an object against what's behind it); a turn
// of the normal is a crease (a box's edge, a wall meeting the floor). Alpha blended.
//
// Group 1 (`.texture` material): the normal-depth target. It has the window's pixel size,
// so pixels are read directly with textureLoad; the sampler isn't used.
//
// draw.color: the ink color (rgb) and opacity (a).
// draw.params:
//   x: line width in pixels (the distance to the neighbors compared).
//   y: depth threshold, as a fraction of the depth (0.05: a 5% jump is an edge).
//   z: normal threshold, 0..2 (1 - the cosine of the angle between normals).

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
}

@group(1) @binding(0) var normal_depth: texture_2d<f32>;

@vertex
fn vs_main(in: VertexInput) -> @builtin(position) vec4f {
    // The engine's square spans -0.5..0.5; doubled, it covers the screen
    return vec4f(in.position.xy * 2.0, 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) position: vec4f) -> @location(0) vec4f {
    let size = vec2i(textureDimensions(normal_depth));
    let pixel = vec2i(position.xy);
    let step = max(i32(draw.params.x), 1);
    let center = textureLoad(normal_depth, pixel, 0);

    var edge = 0.0;
    let offsets = array<vec2i, 4>(vec2i(step, 0), vec2i(-step, 0), vec2i(0, step), vec2i(0, -step));
    for (var i = 0; i < 4; i++) {
        let neighbor_pixel = clamp(pixel + offsets[i], vec2i(0), size - 1);
        let neighbor = textureLoad(normal_depth, neighbor_pixel, 0);
        edge = max(edge, edgeStrength(center, neighbor));
    }
    return vec4f(draw.color.rgb, draw.color.a * edge);
}

/// 1 where `a` and `b` are on different surfaces: their depths differ by more than the
/// depth threshold (relative to the nearer one), or their normals by more than the normal
/// threshold. A cleared pixel (empty space) has depth far beyond the scene.
fn edgeStrength(a: vec4f, b: vec4f) -> f32 {
    let nearer = min(a.w, b.w);
    let depth_jump = abs(a.w - b.w) / max(nearer, 0.001);
    let normal_turn = 1.0 - dot(normalize(a.xyz + 1e-6), normalize(b.xyz + 1e-6));
    let is_depth_edge = depth_jump > draw.params.y;
    let is_crease = normal_turn > draw.params.z;
    return select(0.0, 1.0, is_depth_edge || is_crease);
}
