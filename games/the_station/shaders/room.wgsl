// Room parts (engine shapes): a per-draw color lit by the frame's ambient, directional,
// and point lights (the alarm), shaded with ink hatching (ink_common.wgsl, included
// before this file).
//
// draw.params:
//   x: emissive, 0..1. The color shows unlit by this much (lamps, screens), unhatched.
//   y: cut face, 0 or 1. Faces toward the camera (+z) are darkened and drawn with one set
//      of diagonal lines: the cut through the station's hull and floors, as in a section
//      drawing.
//   z, w: hatch strength and spacing (ink_common.wgsl).
//
// With NORMAL_DEPTH set, the fragment writes the normal-depth target for the outline pass
// instead of a color.

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
// Width of a cut face's section lines, as a fraction of the hatch spacing
const SECTION_LINE_WIDTH = 0.35;

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
        return normalDepth(normal, in.world_position);
    }

    let emissive = draw.params.x;
    let is_cut_face = draw.params.y > 0.5 && normal.z > 0.5;

    var color = draw.color.rgb;
    if (is_cut_face) {
        color *= CUT_FACE_SHADE;
    }
    let light = lighting(normal, in.world_position);
    let section_lines = select(-1.0, SECTION_LINE_WIDTH, is_cut_face);
    // Hatched in world axes, relative to the part's origin: room parts don't turn, and
    // their models are unit shapes scaled to size, so their own coordinates aren't meters
    let part_position = in.world_position - draw.model[3].xyz;
    let surface = inked(color, light, part_position, normal, section_lines);
    return vec4f(mix(surface, draw.color.rgb, emissive), draw.color.a);
}
