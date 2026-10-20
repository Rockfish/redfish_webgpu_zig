// The robot (a glTF model of rigid parts, drawn through `ModelInstance.drawWithParams`):
// each part's material color lit by the frame's lights and shaded with ink hatching
// (ink_common.wgsl, included before this file). A `.pbr` shader, since mesh draws bind
// their glTF material at group 1; only the base color and emissive factors are used.
//
// draw.params: z, w are the hatch strength and spacing (ink_common.wgsl); x, y unused.
//
// With NORMAL_DEPTH set, the fragment writes the normal-depth target for the outline pass
// instead of a color.

override NORMAL_DEPTH: bool = false;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_NORMAL) normal: vec3f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) world_position: vec3f,
    @location(1) world_normal: vec3f,
    // The part's own coordinates (its mesh, in meters), where the hatching is laid out
    @location(2) part_position: vec3f,
    @location(3) part_normal: vec3f,
}

@group(GROUP_MATERIAL) @binding(0) var<uniform> material: MaterialUniforms;

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let world_position = draw.model * vec4f(in.position, 1.0);

    var out: VertexOutput;
    out.clip_position = frame.projection_view * world_position;
    out.world_position = world_position.xyz;
    // w = 0: normals are directions, so translation must not apply
    out.world_normal = (draw.normal_matrix * vec4f(in.normal, 0.0)).xyz;
    out.part_position = in.position;
    out.part_normal = in.normal;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let normal = normalize(in.world_normal);
    if (NORMAL_DEPTH) {
        return normalDepth(normal, in.world_position);
    }

    let color = material.base_color_factor.rgb;
    // The eye lenses glow: their emissive factor says how much they show unlit
    let emissive = clamp(max(material.emissive_factor.r, max(material.emissive_factor.g, material.emissive_factor.b)), 0.0, 1.0);

    let light = lighting(normal, in.world_position);
    // Hatched in the part's own coordinates, so the lines turn with it: in world axes they
    // slid and flickered as the parts moved, even in idle
    let surface = inked(color, light, in.part_position, normalize(in.part_normal), -1.0);
    return vec4f(mix(surface, color, emissive), 1.0);
}
