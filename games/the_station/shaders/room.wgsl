// Greybox room shapes: a per-draw color lit by the frame's ambient, directional, and point
// lights (the alarm). `frame` and `draw` come from common.wgsl.
//
// draw.params:
//   x: emissive, 0..1. The color shows unlit by this much (lamps, screens).
//   y: cut face, 0 or 1. Faces toward the camera (+z) are darkened: the cut through the
//      station's hull and floors, filled in solid as in a section drawing.

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
    let emissive = draw.params.x;
    let is_cut_face = draw.params.y > 0.5 && normal.z > 0.5;

    var color = draw.color.rgb;
    if (is_cut_face) {
        color *= CUT_FACE_SHADE;
    }

    let lit = color * lighting(normal, in.world_position);
    return vec4f(mix(lit, draw.color.rgb, emissive), draw.color.a);
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
