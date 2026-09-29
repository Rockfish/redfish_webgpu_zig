// glTF metallic-roughness PBR, ported from redfish's pbr.vert / pbr.frag.
// Changes: no manual gamma (the surface is sRGB), emissive = factor * texture as glTF
// specifies, alpha MASK discards (or, with MSAA, smooths its edge through alpha-to-coverage),
// lights from the frame's SceneLights (group 0).
// Skinning reads `joints` (group 2) from `draw.joint_offset`, for live and baked animation
// alike; this replaces redfish's separate pbr_anim_baked.vert.

@group(GROUP_MATERIAL) @binding(0) var<uniform> material: MaterialUniforms;
@group(GROUP_MATERIAL) @binding(1) var base_color_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(2) var metallic_roughness_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(3) var normal_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(4) var occlusion_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(5) var emissive_texture: texture_2d<f32>;
@group(GROUP_MATERIAL) @binding(6) var base_color_sampler: sampler;
@group(GROUP_MATERIAL) @binding(7) var metallic_roughness_sampler: sampler;
@group(GROUP_MATERIAL) @binding(8) var normal_sampler: sampler;
@group(GROUP_MATERIAL) @binding(9) var occlusion_sampler: sampler;
@group(GROUP_MATERIAL) @binding(10) var emissive_sampler: sampler;

/// True in pipelines with alpha-to-coverage on (`ShaderConfig.alpha_to_coverage`, set per
/// variant: multisampled and not blended). The fragment's alpha then sets how many of the
/// pixel's samples it covers, so it must be 1 for opaque surfaces, and for MASK it is the
/// sharpened alpha from `maskCoverage`.
override ALPHA_TO_COVERAGE: bool = false;

const PI: f32 = 3.14159265359;
/// NdotV below which specular fades out when `frame.lights.fade_grazing_specular` is on.
const GRAZING_FADE_END: f32 = 0.3;

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_TEXCOORD) texcoord: vec2f,
    @location(LOCATION_NORMAL) normal: vec3f,
    @location(LOCATION_TANGENT) tangent: vec4f,
    @location(LOCATION_COLOR) color: vec4f,
    @location(LOCATION_JOINTS) joints: vec4u,
    @location(LOCATION_WEIGHTS) weights: vec4f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) world_position: vec3f,
    @location(1) texcoord: vec2f,
    @location(2) color: vec4f,
    @location(3) normal: vec3f,
    @location(4) tangent: vec3f,
    @location(5) bitangent: vec3f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    // Skinned: blend the joint matrices by weight. The node transform is not applied
    // (glTF); draw.model is the model transform alone.
    let skin = skinMatrix(in.joints, in.weights);
    let skin3 = mat3x3f(skin[0].xyz, skin[1].xyz, skin[2].xyz);

    let world_position = draw.model * skin * vec4f(in.position, 1.0);

    // World-space TBN; the tangent is re-orthogonalized against the normal.
    let normal = normalize((draw.normal_matrix * vec4f(skin3 * in.normal, 0.0)).xyz);
    var tangent = normalize((draw.model * vec4f(skin3 * in.tangent.xyz, 0.0)).xyz);
    tangent = normalize(tangent - dot(tangent, normal) * normal);
    let bitangent = cross(normal, tangent) * in.tangent.w;

    var out: VertexOutput;
    out.clip_position = frame.projection_view * world_position;
    out.world_position = world_position.xyz;
    out.texcoord = in.texcoord;
    out.color = in.color;
    out.normal = normal;
    out.tangent = tangent;
    out.bitangent = bitangent;
    return out;
}

fn hasFlag(flag: u32) -> bool {
    return (material.flags & flag) != 0u;
}

@fragment
fn fs_main(in: VertexOutput, @builtin(front_facing) front_facing: bool) -> @location(0) vec4f {
    // Sample everything up front: missing textures are 1x1 defaults (white, flat normal),
    // so the multiplications below are neutral for them.
    let base_color_sample = textureSample(base_color_texture, base_color_sampler, in.texcoord);
    let metallic_roughness_sample = textureSample(metallic_roughness_texture, metallic_roughness_sampler, in.texcoord);
    let normal_sample = textureSample(normal_texture, normal_sampler, in.texcoord).xyz;
    let occlusion_sample = textureSample(occlusion_texture, occlusion_sampler, in.texcoord).r;
    let emissive_sample = textureSample(emissive_texture, emissive_sampler, in.texcoord).rgb;

    var base_color = material.base_color_factor * base_color_sample * in.color;
    // Derivatives must be taken before any discard (uniform control flow)
    let alpha_change = fwidth(base_color.a);
    var output_alpha = base_color.a;
    if (ALPHA_TO_COVERAGE) {
        output_alpha = 1.0;
        if (hasFlag(MATERIAL_FLAG_ALPHA_MASK)) {
            output_alpha = maskCoverage(base_color.a, alpha_change);
        }
    } else if (hasFlag(MATERIAL_FLAG_ALPHA_MASK) && base_color.a < material.alpha_cutoff) {
        discard;
    }
    // Minimum brightness keeps very dark materials visible (as redfish)
    base_color = vec4f(max(base_color.rgb, vec3f(0.05)), base_color.a);

    // glTF: metallic in blue, roughness in green
    let metallic = material.metallic_factor * metallic_roughness_sample.b;
    let roughness = clamp(material.roughness_factor * metallic_roughness_sample.g, 0.1, 0.9);

    let lights = frame.lights;
    var color = base_color.rgb;
    if (lights.use_light != 0u) {
        if (hasFlag(MATERIAL_FLAG_HAS_NORMALS)) {
            var normal = normalize(in.normal);
            if (hasFlag(MATERIAL_FLAG_NORMAL_TEXTURE)) {
                let tbn = mat3x3f(normalize(in.tangent), normalize(in.bitangent), normal);
                normal = normalize(tbn * (normal_sample * 2.0 - 1.0));
            }
            normal = viewFacingNormal(normal, in.world_position, front_facing);
            color = sceneLight(in.world_position, normal, base_color.rgb, metallic, roughness);
        } else {
            // Without normals there is no direct lighting; a flat base keeps it visible (as redfish)
            color = base_color.rgb * 0.3;
        }
        color += lights.ambient * base_color.rgb;
    }
    color *= occlusion_sample;
    color += material.emissive_factor * emissive_sample;

    // Reinhard tone mapping; the sRGB surface does the gamma encode
    color = color / (color + vec3f(1.0));
    return vec4f(color, output_alpha);
}

/// Alpha for alpha-to-coverage on a MASK material: 0 below the cutoff, 1 above, with the
/// step spread over the one pixel where alpha crosses it. `alpha_change` is how much alpha
/// changes across that pixel (`fwidth`). Plain alpha would be wrong here: coverage would
/// follow the texture's alpha everywhere instead of cutting at `alpha_cutoff`.
fn maskCoverage(alpha: f32, alpha_change: f32) -> f32 {
    return clamp((alpha - material.alpha_cutoff) / max(alpha_change, 1e-4) + 0.5, 0.0, 1.0);
}

/// The shading normal of the visible side. Back faces (double-sided materials) use the
/// flipped normal, as glTF requires; redfish lit them with the front's, so the underside of
/// a bevel caught the light above it. A smoothed normal that still turns away from the
/// viewer at a silhouette is bent back just past perpendicular, so the surface isn't lit
/// as if seen from behind.
fn viewFacingNormal(normal_in: vec3f, world_position: vec3f, front_facing: bool) -> vec3f {
    var normal = select(-normal_in, normal_in, front_facing);
    let view_dir = normalize(frame.view_position - world_position);
    let n_dot_v = dot(normal, view_dir);
    if (n_dot_v < 0.0) {
        normal = normalize(normal - view_dir * (n_dot_v * 1.01));
    }
    return normal;
}

/// The frame's direction light plus its enabled point lights.
fn sceneLight(world_position: vec3f, normal: vec3f, base_color: vec3f, metallic: f32, roughness: f32) -> vec3f {
    let lights = frame.lights;
    let view_dir = normalize(frame.view_position - world_position);

    var color = brdf(normal, view_dir, normalize(-lights.direction_light.dir), lights.direction_light.color, base_color, metallic, roughness);
    for (var i = 0u; i < min(lights.num_point_lights, MAX_POINT_LIGHTS); i++) {
        let light = lights.point_lights[i];
        if (light.enabled == 0u) {
            continue;
        }
        let to_light = light.world_pos - world_position;
        let distance = length(to_light);
        let attenuation = 1.0 / (light.constant + light.linear * distance + light.quadratic * distance * distance);
        color += brdf(normal, view_dir, normalize(to_light), light.color * attenuation, base_color, metallic, roughness);
    }
    return color;
}

/// Cook-Torrance (GGX, Schlick) for one light. Two changes from redfish's pbr.frag, which
/// lit silhouettes on the shadow side: Fresnel uses the half vector (VdotH), not NdotV,
/// which went to 1 around every silhouette; and the geometry term uses the direct-light
/// k = (roughness + 1)² / 8, where redfish's alpha / 2 (0.005 at the 0.1 roughness floor)
/// let specular grow like 1 / (4k NdotL) as NdotV went to 0.
fn brdf(normal: vec3f, view_dir: vec3f, light_dir: vec3f, radiance: vec3f, base_color: vec3f, metallic: f32, roughness: f32) -> vec3f {
    let half_dir = normalize(light_dir + view_dir);

    let n_dot_l = max(dot(normal, light_dir), 0.0);
    let n_dot_v = max(dot(normal, view_dir), 0.0);
    let n_dot_h = max(dot(normal, half_dir), 0.0);
    let v_dot_h = max(dot(view_dir, half_dir), 0.0);

    // Fresnel-Schlick
    let f0 = mix(vec3f(0.04), base_color, metallic);
    let fresnel = f0 + (1.0 - f0) * pow(1.0 - v_dot_h, 5.0);

    // GGX distribution
    let alpha = roughness * roughness;
    let alpha2 = alpha * alpha;
    let denom = n_dot_h * n_dot_h * (alpha2 - 1.0) + 1.0;
    let distribution = alpha2 / (PI * denom * denom);

    // Schlick-GGX geometry, direct lighting
    let k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    let geometry = (n_dot_v / (n_dot_v * (1.0 - k) + k)) * (n_dot_l / (n_dot_l * (1.0 - k) + k));

    var specular = (fresnel * distribution * geometry) / (4.0 * n_dot_v * n_dot_l + 0.0001);
    // Optional, stylistic: no glancing glare on edges seen edge-on (SceneLights)
    if (frame.lights.fade_grazing_specular != 0u) {
        specular *= smoothstep(0.0, GRAZING_FADE_END, n_dot_v);
    }
    let diffuse = (vec3f(1.0) - fresnel) * (1.0 - metallic) * base_color / PI;
    return (diffuse + specular) * n_dot_l * radiance;
}
