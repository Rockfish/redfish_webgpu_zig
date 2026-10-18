// Room and robot parts: a per-draw color lit by the frame's ambient, directional, and
// point lights (the alarm), shaded with ink hatching. `frame` and `draw` come from
// common.wgsl.
//
// draw.params:
//   x: emissive, 0..1. The color shows unlit by this much (lamps, screens), unhatched.
//   y: cut face, 0 or 1. Faces toward the camera (+z) are darkened and hatched densely:
//      the cut through the station's hull and floors, as in a section drawing.
//   z: hatch strength, 0..1 (0 is no hatching).
//   w: hatch spacing, in meters between lines.
//
// With NORMAL_DEPTH set, the fragment writes the view-space normal (xyz) and the distance
// in front of the camera (w) instead of a color: the input to the ink outline pass
// (ink_edges.wgsl).

override NORMAL_DEPTH: bool = false;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_TEXCOORD) texcoord: vec2f,
    @location(LOCATION_NORMAL) normal: vec3f,
    @location(LOCATION_COLOR) color: vec4f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) world_position: vec3f,
    @location(1) world_normal: vec3f,
}

const CUT_FACE_SHADE = 0.35;
// How dark ink makes a surface: hatched areas go toward this fraction of their color
const INK_SHADE = 0.12;
// Tones (0 dark, 1 light) below which each layer of hatching starts
const FIRST_LAYER_TONE = 0.8;
const SECOND_LAYER_TONE = 0.5;
const THIRD_LAYER_TONE = 0.25;

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let world_position = draw.model * vec4f(in.position, 1.0);

    var out: VertexOutput;
    out.clip_position = frame.projection_view * world_position;
    out.world_position = world_position.xyz;
    // w = 0: normals are directions, so translation must not apply
    out.world_normal = (draw.normal_matrix * vec4f(in.normal, 0.0)).xyz;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let normal = normalize(in.world_normal);
    if (NORMAL_DEPTH) {
        let view_normal = (frame.view * vec4f(normal, 0.0)).xyz;
        let view_depth = -(frame.view * vec4f(in.world_position, 1.0)).z;
        return vec4f(view_normal, view_depth);
    }

    let emissive = draw.params.x;
    let is_cut_face = draw.params.y > 0.5 && normal.z > 0.5;

    var color = draw.color.rgb;
    if (is_cut_face) {
        color *= CUT_FACE_SHADE;
    }
    let light = lighting(normal, in.world_position);
    let lit = color * light;

    // Hatch lines are laid out in the part's own space (its position relative to its
    // origin), so they move with it instead of sliding across it
    let part_position = in.world_position - draw.model[3].xyz;
    let uv = faceCoords(part_position, normal) / draw.params.w;
    // A cut face is drawn as a section is: one set of diagonal lines, whatever its light
    var ink = select(hatching(uv, tone(light)), hatchLines(uv.x - uv.y, 0.35), is_cut_face);
    ink *= draw.params.z * (1.0 - emissive);

    let inked = mix(lit, lit * INK_SHADE, ink);
    return vec4f(mix(inked, draw.color.rgb, emissive), draw.color.a);
}

/// Ambient, plus Lambert diffuse from the directional light and each point light.
fn lighting(normal: vec3f, world_position: vec3f) -> vec3f {
    let lights = frame.lights;
    var light = lights.ambient;

    let to_sun = normalize(-lights.direction_light.dir);
    light += lights.direction_light.color * max(dot(normal, to_sun), 0.0);

    for (var i = 0u; i < lights.num_point_lights; i++) {
        let point = lights.point_lights[i];
        if (point.enabled == 0u) {
            continue;
        }
        let to_light = point.world_pos - world_position;
        let distance = length(to_light);
        let attenuation = 1.0 / (point.constant + point.linear * distance + point.quadratic * distance * distance);
        light += point.color * attenuation * max(dot(normal, to_light / distance), 0.0);
    }
    return light;
}

/// How lit a surface is, 0..1, from the light falling on it, not its own color: hatching
/// shows shading, as in an ink drawing, so a grey wall in full light stays clear. The
/// light's brightest channel (red alarm light counts as light), square-rooted toward
/// perceived brightness.
fn tone(light: vec3f) -> f32 {
    return sqrt(clamp(max(light.r, max(light.g, light.b)), 0.0, 1.0));
}

/// The two coordinates across a face: the axes of the plane the face mostly lies in.
fn faceCoords(position: vec3f, normal: vec3f) -> vec2f {
    let axis = abs(normal);
    if (axis.x >= axis.y && axis.x >= axis.z) {
        return position.zy;
    }
    if (axis.y >= axis.z) {
        return position.xz;
    }
    return position.xy;
}

/// Ink coverage, 0..1, for a surface of `surface_tone`: diagonal lines in the light
/// shadows, crossed lines darker, a third set darkest. Each layer's lines thicken as the
/// tone falls below where it starts.
fn hatching(uv: vec2f, surface_tone: f32) -> f32 {
    let first = layerWidth(surface_tone, FIRST_LAYER_TONE);
    let second = layerWidth(surface_tone, SECOND_LAYER_TONE);
    let third = layerWidth(surface_tone, THIRD_LAYER_TONE);
    var ink = hatchLines(uv.x + uv.y, first);
    ink = max(ink, hatchLines(uv.x - uv.y, second));
    ink = max(ink, hatchLines(uv.y + 0.5, third));
    return ink;
}

/// A layer's line width, as a fraction of the spacing: 0 at `start`, growing to 0.5 as
/// the tone falls to `start` - 0.3.
fn layerWidth(surface_tone: f32, start: f32) -> f32 {
    return clamp((start - surface_tone) / 0.3, 0.0, 1.0) * 0.5;
}

/// Parallel lines one unit apart along `coord`, `width` units wide (0..1), with edges
/// smoothed over a pixel.
fn hatchLines(coord: f32, width: f32) -> f32 {
    if (width <= 0.0) {
        return 0.0;
    }
    let from_center = abs(fract(coord) - 0.5);
    let pixel = fwidth(coord);
    return 1.0 - smoothstep(width * 0.5 - pixel, width * 0.5 + pixel, from_center);
}
