// Port of redfish's player_shader (baked vertex + fragment) for animation_example.
// Custom textures arrive in the PBR material slots: base color = texture_diffuse,
// metallic-roughness slot = texture_specular. No shadow map (port Step 9). redfish never
// set this example's direction light, so the look was ambient x diffuse plus a little
// specular; here the frame's point light drives the diffuse and specular terms.

@group(GROUP_MATERIAL) @binding(0) var<uniform> material: MaterialUniforms;
@group(GROUP_MATERIAL) @binding(1) var diffuse_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(2) var specular_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(6) var diffuse_sampler: sampler;
@group(GROUP_MATERIAL) @binding(7) var specular_sampler: sampler;

/// animation_example's `ambient` uniform.
const AMBIENT = vec3f(0.8, 0.7, 0.8);
const SHININESS: f32 = 24.0;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_TEXCOORD) texcoord: vec2f,
    @location(LOCATION_NORMAL) normal: vec3f,
    @location(LOCATION_JOINTS) joints: vec4u,
    @location(LOCATION_WEIGHTS) weights: vec4f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) world_position: vec3f,
    @location(1) texcoord: vec2f,
    @location(2) normal: vec3f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let skin = skinMatrix(in.joints, in.weights);
    let skin3 = mat3x3f(skin[0].xyz, skin[1].xyz, skin[2].xyz);
    let world_position = draw.model * skin * vec4f(in.position, 1.0);

    var out: VertexOutput;
    out.clip_position = frame.projection_view * world_position;
    out.world_position = world_position.xyz;
    out.texcoord = in.texcoord;
    out.normal = normalize((draw.normal_matrix * vec4f(skin3 * in.normal, 0.0)).xyz);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let diffuse_sample = textureSample(diffuse_texture, diffuse_sampler, in.texcoord);
    let specular_sample = textureSample(specular_texture, specular_sampler, in.texcoord);

    // Custom texture first, then the material color; magenta flags a missing texture
    var color = vec4f(1.0, 0.0, 1.0, 1.0);
    if ((material.flags & MATERIAL_FLAG_BASE_COLOR_TEXTURE) != 0u) {
        color = diffuse_sample;
    } else if (material.base_color_factor.a > 0.0) {
        color = material.base_color_factor;
    }

    let normal = normalize(in.normal);
    let light_dir = normalize(frame.light_position - in.world_position);
    let diffuse = max(dot(normal, light_dir), 0.0);

    var lit = AMBIENT * color.rgb + 0.7 * frame.light_color * diffuse * color.rgb;

    let view_dir = normalize(frame.view_position - in.world_position);
    let reflect_dir = reflect(-light_dir, normal);
    let specular = pow(max(dot(view_dir, reflect_dir), 0.0), SHININESS);
    var specular_color = vec3f(0.5);
    if ((material.flags & MATERIAL_FLAG_METALLIC_ROUGHNESS_TEXTURE) != 0u) {
        specular_color = specular_sample.rgb;
    }
    lit += specular * specular_color * frame.light_color + vec3f(specular * 0.1);

    return vec4f(lit, color.a);
}
