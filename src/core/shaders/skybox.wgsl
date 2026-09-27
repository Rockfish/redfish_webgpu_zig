// Cube-map skybox (port of redfish's skybox.vert / .frag). The view's translation is
// dropped here, so the box stays centered on the camera; clip.xyww puts every fragment at
// depth 1, drawn with a LessEqual depth test and no depth write.

@group(GROUP_MATERIAL) @binding(0) var skybox_texture: texture_cube<f32>;
@group(GROUP_MATERIAL) @binding(1) var skybox_sampler: sampler;

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) direction: vec3f,
}

@vertex
fn vs_main(@location(LOCATION_POSITION) position: vec3f) -> VertexOutput {
    let view_rotation = mat3x3f(frame.view[0].xyz, frame.view[1].xyz, frame.view[2].xyz);
    let clip = frame.projection * vec4f(view_rotation * position, 1.0);

    var out: VertexOutput;
    out.clip_position = clip.xyww;
    out.direction = position;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return textureSample(skybox_texture, skybox_sampler, in.direction);
}
