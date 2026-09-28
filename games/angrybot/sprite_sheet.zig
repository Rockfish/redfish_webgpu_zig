const std = @import("std");
const math = @import("math");
const core = @import("core");

const Vec3 = math.Vec3;
const Vec4 = math.Vec4;

const Texture = core.texture.Texture;

pub const SpriteSheet = struct {
    texture: *Texture,
    num_columns: f32,
    time_per_sprite: f32,

    const Self = @This();

    pub fn init(texture: *Texture, num_columns: i32, time_per_sprite: f32) Self {
        return .{
            .texture = texture,
            .num_columns = @floatFromInt(num_columns),
            .time_per_sprite = time_per_sprite,
        };
    }

    /// `DrawUniforms.params` for sprite_shader: the sheet's layout and the sprite's age.
    pub fn drawParams(self: *const Self, age: f32) Vec4 {
        return Vec4.init(self.num_columns, self.time_per_sprite, age, 0.0);
    }

    pub fn releaseGpuObjects(self: *const Self) void {
        self.texture.releaseGpuObjects();
    }
};

pub const SpriteSheetSprite = struct {
    world_position: Vec3,
    age: f32,
};
