// Shadow pass caster: positions from the light of the layer being drawn. Depth only; the
// pipeline has no fragment stage. Group 3 is that layer's slot of the ShadowMapArray's
// light buffer (`ShadowMapArray.bindCaster`), so each pass reads its own light.

@group(GROUP_PASS) @binding(0) var<uniform> caster_light_space: mat4x4f;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
}

@vertex
fn vs_main(in: VertexInput) -> @builtin(position) vec4f {
    return caster_light_space * draw.model * vec4f(in.position, 1.0);
}
