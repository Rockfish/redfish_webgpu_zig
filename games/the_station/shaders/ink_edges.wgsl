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
//   x: line width in pixels: neighbors within this radius are compared.
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
    let center = textureLoad(normal_depth, pixel, 0);

    // Every pixel within the line's radius, diagonals and the nearest ones included:
    // comparing only with four pixels `line width` away stepped over parts a few pixels
    // wide (the robot's collar, its chest port's rim), leaving dotted lines that shimmered
    // as the parts moved
    let radius = max(i32(round(draw.params.x)), 1);
    var edge = 0.0;
    for (var dy = -radius; dy <= radius; dy++) {
        for (var dx = -radius; dx <= radius; dx++) {
            let offset = vec2f(f32(dx), f32(dy));
            let distance = length(offset);
            if (distance == 0.0 || distance > f32(radius) + 0.5) {
                continue;
            }
            let neighbor_pixel = clamp(pixel + vec2i(dx, dy), vec2i(0), size - 1);
            let neighbor = textureLoad(normal_depth, neighbor_pixel, 0);
            // Pixels at the rim of the radius count partly, smoothing the line's sides
            let reach = 1.0 - smoothstep(f32(radius) - 0.5, f32(radius) + 0.5, distance);
            edge = max(edge, edgeStrength(center, neighbor) * reach);
        }
    }
    return vec4f(draw.color.rgb, draw.color.a * edge);
}

/// How surely `a` and `b` are on different surfaces, 0..1: their depths differ by more
/// than the depth threshold (relative to the nearer one), or their normals by more than
/// the normal threshold. Soft over the threshold's first half again, so an edge fades in
/// instead of popping on and off. A cleared pixel (empty space) has depth far beyond the
/// scene.
fn edgeStrength(a: vec4f, b: vec4f) -> f32 {
    let nearer = min(a.w, b.w);
    let depth_jump = abs(a.w - b.w) / max(nearer, 0.001);
    let normal_turn = 1.0 - dot(normalize(a.xyz + 1e-6), normalize(b.xyz + 1e-6));
    let depth_edge = smoothstep(draw.params.y, draw.params.y * 1.5, depth_jump);
    let crease = smoothstep(draw.params.z, draw.params.z * 1.5, normal_turn);
    return max(depth_edge, crease);
}
