const std = @import("std");
const core = @import("core");
const math = @import("math");
const containers = @import("containers");
const SpriteSheet = @import("sprite_sheet.zig").SpriteSheet;

const ManagedArrayList = containers.ManagedArrayList;

const Context = core.Context;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Mat4 = math.Mat4;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Texture = core.texture.Texture;
const TextureConfig = core.texture.TextureConfig;

const vec3 = math.vec3;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;

const SpriteAge = struct {
    age: f32,
};

pub const MuzzleFlash = struct {
    unit_square: *Shape,
    muzzle_flash_impact_sprite: SpriteSheet,
    muzzle_flash_sprites_age: ManagedArrayList(?SpriteAge),

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext, unit_square: *Shape) !Self {
        // is_srgb off: gamma-space shading, see run_app
        const texture_config: TextureConfig = .{ .wrap = .Repeat, .is_srgb = false };

        const texture_muzzle_flash_sprite_sheet = try Texture.initFromFile(
            context,
            gpu,
            "assets/angrybots_assets/Textures/Bullet/muzzle_spritesheet.png",
            texture_config,
        );

        const muzzle_flash_impact_sprite = SpriteSheet.init(
            texture_muzzle_flash_sprite_sheet,
            6,
            0.03,
        );

        return .{
            .unit_square = unit_square,
            .muzzle_flash_impact_sprite = muzzle_flash_impact_sprite,
            .muzzle_flash_sprites_age = ManagedArrayList(?SpriteAge).init(context.alloc),
        };
    }

    const Tester = struct {
        max_age: f32 = 0.0,
        pub fn predicate(self: *const @This(), spriteAge: SpriteAge) bool {
            return spriteAge.age < self.max_age;
        }
    };

    pub fn update(self: *Self, delta_time: f32) void {
        if (self.muzzle_flash_sprites_age.list.items.len != 0) {
            for (0..self.muzzle_flash_sprites_age.list.items.len) |i| {
                self.muzzle_flash_sprites_age.list.items[i].?.age += delta_time;
            }
            const max_age = self.muzzle_flash_impact_sprite.num_columns * self.muzzle_flash_impact_sprite.time_per_sprite;

            const tester = Tester{ .max_age = max_age };

            core.utils.retain(
                SpriteAge,
                Tester,
                &self.muzzle_flash_sprites_age,
                tester,
            );
        }
    }

    pub fn getMinAge(self: *const Self) f32 {
        var min_age: f32 = 5000;
        for (self.muzzle_flash_sprites_age.list.items) |spriteAge| {
            min_age = @min(min_age, spriteAge.?.age);
        }
        return min_age;
    }

    pub fn addFlash(self: *Self) !void {
        const sprite_age = SpriteAge{ .age = 0.0 };
        try self.muzzle_flash_sprites_age.append(sprite_age);
    }

    pub fn draw(self: *const Self, frame: *const Frame, sprite_shader: *const Shader, projectile_spawn_point: Vec3) void {
        if (self.muzzle_flash_sprites_age.list.items.len == 0) {
            return;
        }

        self.muzzle_flash_impact_sprite.texture.bind(frame);

        const scale: f32 = 50.0;

        var model = Mat4.fromTranslation(projectile_spawn_point).mulMat4(&Mat4.fromScale(vec3(scale, scale, scale)));

        model = model.mulMat4(&Mat4.fromRotationX(math.degreesToRadians(-90.0)));
        model = model.mulMat4(&Mat4.fromRotationZ(math.degreesToRadians(-90.0)));
        model = model.mulMat4(&Mat4.fromTranslation(vec3(0.7, -0.5, -0.7))); // adjust for position in the texture

        for (self.muzzle_flash_sprites_age.list.items) |sprite_age| {
            if (sprite_age) |s_age| {
                var draw_uniforms = DrawUniforms.init(model, Vec4.init(1.0, 1.0, 1.0, 1.0));
                draw_uniforms.params = self.muzzle_flash_impact_sprite.drawParams(s_age.age);
                self.unit_square.draw(frame, sprite_shader, draw_uniforms);
            }
        }
    }

    pub fn releaseGpuObjects(self: *const Self) void {
        self.muzzle_flash_impact_sprite.releaseGpuObjects();
    }
};
