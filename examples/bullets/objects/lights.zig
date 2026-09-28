const core = @import("core");
const math = @import("math");
const vec3 = math.vec3;

pub const Lights = core.SceneLights;
pub const basic_lights = core.SceneLights.towerDefenseDefaults();

pub const gallery_lights = blk: {
    var lights = core.SceneLights{
        .ambient = vec3(0.35, 0.35, 0.38),
        .use_light = true,
        .direction_light = .{
            .dir = vec3(-0.8, -1.0, -0.6),
            .color = vec3(1.0, 0.95, 0.85),
        },
        .point_lights = [_]core.PointLight{.{}} ** core.lights.MAX_POINT_LIGHTS,
        .num_point_lights = 2,
    };
    // Fill light from opposite side to reduce harsh shadows
    lights.point_lights[0] = .{
        .world_pos = vec3(20.0, 15.0, 20.0),
        .color = vec3(0.6, 0.6, 0.7),
        .constant = 1.0,
        .linear = 0.0,
        .quadratic = 0.0,
        .enabled = true,
    };
    // Back fill
    lights.point_lights[1] = .{
        .world_pos = vec3(-15.0, 10.0, -15.0),
        .color = vec3(0.4, 0.4, 0.5),
        .constant = 1.0,
        .linear = 0.0,
        .quadratic = 0.0,
        .enabled = true,
    };
    break :blk lights;
};
