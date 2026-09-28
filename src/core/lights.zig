//! Scene lighting, carried to every shader in the frame uniforms (group 0). Replaces
//! redfish's `SceneLights.apply(shader)`, which set named uniforms per shader and did
//! nothing for PBR shaders.

const std = @import("std");
const math = @import("math");
const bindings = @import("bindings.zig");

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const LightsUniforms = bindings.LightsUniforms;

pub const MAX_POINT_LIGHTS: usize = bindings.MAX_POINT_LIGHTS;

pub const DirectionLight = struct {
    dir: Vec3,
    color: Vec3,
};

pub const PointLight = struct {
    world_pos: Vec3 = vec3(0.0, 0.0, 0.0),
    color: Vec3 = vec3(1.0, 1.0, 1.0),
    constant: f32 = 1.0,
    linear: f32 = 0.5,
    quadratic: f32 = 3.0,
    enabled: bool = false,
};

pub const SceneLights = struct {
    ambient: Vec3,
    use_light: bool,
    direction_light: DirectionLight,
    point_lights: [MAX_POINT_LIGHTS]PointLight,
    num_point_lights: i32,
    /// Fade PBR specular toward zero as the view grazes a surface. A stylistic option,
    /// not physically based: it keeps backlit edges seen edge-on from blowing out to white
    /// under a strong light. Off by default.
    fade_grazing_specular: bool = false,

    const Self = @This();

    pub fn init() Self {
        return .{
            .ambient = vec3(0.2, 0.2, 0.2),
            .use_light = true,
            .direction_light = .{
                .dir = vec3(-1.0, -1.0, -1.0),
                .color = vec3(1.0, 1.0, 1.0),
            },
            .point_lights = [_]PointLight{.{}} ** MAX_POINT_LIGHTS,
            .num_point_lights = 0,
        };
    }

    pub fn towerDefenseDefaults() Self {
        return .{
            .ambient = vec3(0.3, 0.3, 0.3),
            .use_light = true,
            .direction_light = .{
                .dir = vec3(-1.5, -2.0, -1.0),
                .color = vec3(0.95, 0.88, 0.72),
            },
            .point_lights = [_]PointLight{.{}} ** MAX_POINT_LIGHTS,
            .num_point_lights = 0,
        };
    }

    pub fn setPointLight(self: *Self, index: usize, light: PointLight) void {
        if (index >= MAX_POINT_LIGHTS) return;
        self.point_lights[index] = light;
        // Recalculate num_point_lights from highest enabled index + 1
        self.num_point_lights = 0;
        for (0..MAX_POINT_LIGHTS) |i| {
            if (self.point_lights[i].enabled) {
                self.num_point_lights = @intCast(i + 1);
            }
        }
    }

    /// For `FrameUniforms.lights`, written once per frame.
    pub fn uniforms(self: *const Self) LightsUniforms {
        var result: LightsUniforms = .{
            .ambient = self.ambient,
            .use_light = @intFromBool(self.use_light),
            .direction_light = .{ .dir = self.direction_light.dir, .color = self.direction_light.color },
            .num_point_lights = @intCast(@max(self.num_point_lights, 0)),
            .fade_grazing_specular = @intFromBool(self.fade_grazing_specular),
        };
        for (self.point_lights, &result.point_lights) |light, *out| {
            out.* = .{
                .world_pos = light.world_pos,
                .constant = light.constant,
                .color = light.color,
                .linear = light.linear,
                .quadratic = light.quadratic,
                .enabled = @intFromBool(light.enabled),
            };
        }
        return result;
    }
};

test "uniforms carries point lights and the count" {
    var lights = SceneLights.init();
    lights.setPointLight(1, .{ .world_pos = vec3(1.0, 2.0, 3.0), .enabled = true });

    const u = lights.uniforms();
    try std.testing.expectEqual(@as(u32, 2), u.num_point_lights);
    try std.testing.expectEqual(@as(u32, 1), u.point_lights[1].enabled);
    try std.testing.expectEqual(@as(f32, 2.0), u.point_lights[1].world_pos.y);
    try std.testing.expectEqual(@as(u32, 1), u.use_light);
}
