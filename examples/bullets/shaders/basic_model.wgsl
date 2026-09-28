// Port of basic_model.vert / .frag for untextured shapes (the ruins OBJs): draw.color,
// or the vertex color with DRAW_FLAG_VERTEX_COLOR, lit by the frame's SceneLights.
// As redfish: point lights use normalize(world_pos), a direction from the origin.

struct VertexInput {
    @location(LOCATION_POSITION) position: vec3f,
    @location(LOCATION_NORMAL) normal: vec3f,
    @location(LOCATION_COLOR) color: vec4f,
}

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) normal: vec3f,
    @location(1) color: vec4f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let use_vertex_color = (draw.flags & DRAW_FLAG_VERTEX_COLOR) != 0u;
    var out: VertexOutput;
    out.clip_position = frame.projection_view * draw.model * vec4f(in.position, 1.0);
    out.normal = (draw.normal_matrix * vec4f(in.normal, 0.0)).xyz;
    out.color = select(draw.color, in.color, use_vertex_color);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return vec4f(basicLighting(in.normal, in.color.rgb), in.color.a);
}

fn basicLighting(normal_in: vec3f, color: vec3f) -> vec3f {
    let lights = frame.lights;
    if (lights.use_light == 0u) {
        return color;
    }
    let normal = normalize(normal_in);
    var lighting = lights.direction_light.color * max(dot(normal, normalize(-lights.direction_light.dir)), 0.0);
    for (var i = 0u; i < min(lights.num_point_lights, MAX_POINT_LIGHTS); i++) {
        let light = lights.point_lights[i];
        lighting += light.color * max(dot(normal, normalize(light.world_pos)), 0.0);
    }
    return (lights.ambient + lighting) * color;
}
