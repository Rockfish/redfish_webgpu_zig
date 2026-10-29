// The ink look shared by room.wgsl and model.wgsl (`ShaderConfig.includes`): lighting,
// hatching, and the normal-depth output for the outline pass. Uses `frame` and `draw`
// from common.wgsl.
//
// Hatch settings come in draw.params: z is the strength (0..1, 0 is none), w the spacing
// in meters between lines.

// How dark ink makes a surface: hatched areas go toward this fraction of their color
const INK_SHADE = 0.12;
// Tones (0 dark, 1 light) below which each layer of hatching starts
const FIRST_LAYER_TONE = 0.8;
const SECOND_LAYER_TONE = 0.5;
const THIRD_LAYER_TONE = 0.25;

// The hovered control's highlight (plan 022, phase B2), as if a small amber lamp caught
// it: amber, as red is kept for alarms and danger (linear)
const HIGHLIGHT_AMBER = vec3f(1.0, 0.55, 0.12);
// How much of a surface's hatching a full highlight takes away
const HIGHLIGHT_HATCH_CUT = 0.7;
// Amber light over the whole control, and more at its edges turned from the camera
const HIGHLIGHT_TINT = 0.12;
const HIGHLIGHT_RIM = 0.5;

/// What the outline pass reads (ink_edges.wgsl): the view-space normal (xyz) and the
/// distance in front of the camera (w).
fn normalDepth(normal: vec3f, world_position: vec3f) -> vec4f {
    let view_normal = (frame.view * vec4f(normal, 0.0)).xyz;
    let view_depth = -(frame.view * vec4f(world_position, 1.0)).z;
    return vec4f(view_normal, view_depth);
}

/// `color` lit by `light` and hatched by how dark `light` is, `ink_strength` strong (the
/// draw's hatch strength, or less) with the draw's spacing. The lines are laid out across
/// `hatch_position` on the plane `hatch_normal` mostly faces, in whatever space the
/// caller picks: one that moves with the part, so the lines stay on its surfaces.
/// `ink_override` >= 0 replaces the hatching (a cut face's section lines).
fn inked(color: vec3f, light: vec3f, hatch_position: vec3f, hatch_normal: vec3f, ink_strength: f32, ink_override: f32) -> vec3f {
    let lit = color * light;

    let uv = faceCoords(hatch_position, hatch_normal) / max(draw.params.w, 0.001);
    var ink = hatching(uv, tone(light));
    if (ink_override >= 0.0) {
        ink = hatchLines(uv.x - uv.y, ink_override);
    }
    ink *= ink_strength;
    return mix(lit, lit * INK_SHADE, ink);
}

/// `surface` with the hover highlight at `amount` (0..1): amber light over it, strongest
/// at the edges turned from the camera, so the control glows at its outline. Hatch it
/// with `highlightedInk` too.
fn highlighted(surface: vec3f, normal: vec3f, world_position: vec3f, amount: f32) -> vec3f {
    let to_eye = normalize(frame.view_position - world_position);
    let rim = pow(1.0 - max(dot(normal, to_eye), 0.0), 2.0);
    return surface + HIGHLIGHT_AMBER * (HIGHLIGHT_TINT + HIGHLIGHT_RIM * rim) * amount;
}

/// The draw's hatch strength, thinned by the hover highlight at `amount` (0..1; more,
/// with the panel's highlight strength over 1, thins it no further).
fn highlightedInk(amount: f32) -> f32 {
    return draw.params.z * (1.0 - HIGHLIGHT_HATCH_CUT * min(amount, 1.0));
}

/// Ambient, plus Lambert diffuse from the directional light and each point light that
/// reaches the point (a room's lights stay in the room: `pointLightReaches`).
fn lighting(normal: vec3f, world_position: vec3f) -> vec3f {
    let lights = frame.lights;
    var light = lights.ambient;

    let to_sun = normalize(-lights.direction_light.dir);
    light += lights.direction_light.color * max(dot(normal, to_sun), 0.0);

    for (var i = 0u; i < lights.num_point_lights; i++) {
        let point = lights.point_lights[i];
        if (point.enabled == 0u || !pointLightReaches(point, world_position)) {
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
