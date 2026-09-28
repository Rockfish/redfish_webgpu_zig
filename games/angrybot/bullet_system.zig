const std = @import("std");
const core = @import("core");
const math = @import("math");
const containers = @import("containers");
//const aabb = @import("aabb.zig");
const geom = @import("geom.zig");
const sprites = @import("sprite_sheet.zig");
const world = @import("state.zig");
const Enemy = @import("enemy.zig").Enemy;

const ManagedArrayList = containers.ManagedArrayList;

const Context = core.Context;
const AABB = core.AABB;
const State = world.State;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const SpriteSheet = sprites.SpriteSheet;
const SpriteSheetSprite = sprites.SpriteSheetSprite;

const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;

const Texture = core.texture.Texture;
const TextureConfig = core.texture.TextureConfig;
const TextureWrap = core.texture.TextureWrap;
const TextureFilter = core.texture.TextureFilter;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.Bullets);

/// Shape buffers, then per instance: rotation quaternion at 8, position at 9.
const BulletLayouts = core.shapes.InstancedLayouts(&.{
    .{ .format = .float32x4, .location = 8 },
    .{ .format = .float32x3, .location = 9 },
});

/// For the bullet shader (instanced_quat.wgsl).
pub const vertex_buffer_layouts = BulletLayouts.layouts;

pub const BulletGroup = struct {
    start_index: usize,
    group_size: u32,
    time_to_live: f32,

    pub fn deinit(self: *BulletGroup) void {
        _ = self;
    }

    const Self = @This();

    pub fn new(start_index: usize, group_size: u32, time_to_live: f32) Self {
        return .{
            .start_index = start_index,
            .group_size = group_size,
            .time_to_live = time_to_live,
        };
    }
};

const SCALE_VEC: Vec3 = vec3(world.BULLET_SCALE, world.BULLET_SCALE, world.BULLET_SCALE);
const BULLET_NORMAL: Vec3 = vec3(0.0, 1.0, 0.0);
const CANONICAL_DIR: Vec3 = vec3(0.0, 0.0, 1.0);
const UP_VEC = vec3(0.0, 1.0, 0.0); // rotate around y

const BULLET_ENEMY_MAX_COLLISION_DIST: f32 = world.BULLET_COLLIDER.length / 2.0 + world.BULLET_COLLIDER.radius + world.ENEMY_COLLIDER.length / 2.0 + world.ENEMY_COLLIDER.radius;

// Trim off margin around the bullet image
// const TEXTURE_MARGIN: f32 = 0.0625;
// const TEXTURE_MARGIN: f32 = 0.2;
const TEXTURE_MARGIN: f32 = 0.1;

// A horizontal and a vertical quad, so the bullet shows from above and from the side.
// redfish kept horizontal-only and vertical-only variants too; only this one was used.
const BULLET_POSITIONS = [_][3]f32{
    .{ world.BULLET_SCALE * (-0.243), 0.0, world.BULLET_SCALE * (-1.0) },
    .{ world.BULLET_SCALE * (-0.243), 0.0, world.BULLET_SCALE * 0.0 },
    .{ world.BULLET_SCALE * 0.243, 0.0, world.BULLET_SCALE * 0.0 },
    .{ world.BULLET_SCALE * 0.243, 0.0, world.BULLET_SCALE * (-1.0) },
    .{ 0.0, world.BULLET_SCALE * (-0.243), world.BULLET_SCALE * (-1.0) },
    .{ 0.0, world.BULLET_SCALE * (-0.243), world.BULLET_SCALE * 0.0 },
    .{ 0.0, world.BULLET_SCALE * 0.243, world.BULLET_SCALE * 0.0 },
    .{ 0.0, world.BULLET_SCALE * 0.243, world.BULLET_SCALE * (-1.0) },
};

const BULLET_TEXCOORDS = [_][2]f32{
    .{ 1.0 - TEXTURE_MARGIN, 0.0 + TEXTURE_MARGIN },
    .{ 0.0 + TEXTURE_MARGIN, 0.0 + TEXTURE_MARGIN },
    .{ 0.0 + TEXTURE_MARGIN, 1.0 - TEXTURE_MARGIN },
    .{ 1.0 - TEXTURE_MARGIN, 1.0 - TEXTURE_MARGIN },
    .{ 1.0 - TEXTURE_MARGIN, 0.0 + TEXTURE_MARGIN },
    .{ 0.0 + TEXTURE_MARGIN, 0.0 + TEXTURE_MARGIN },
    .{ 0.0 + TEXTURE_MARGIN, 1.0 - TEXTURE_MARGIN },
    .{ 1.0 - TEXTURE_MARGIN, 1.0 - TEXTURE_MARGIN },
};

const BULLET_INDICES = [_]u32{
    0, 1, 2,
    0, 2, 3,
    4, 5, 6,
    4, 6, 7,
};

pub const BulletSystem = struct {
    bullet_positions: ManagedArrayList(Vec3),
    bullet_rotations: ManagedArrayList(Quat),
    bullet_directions: ManagedArrayList(Vec3),
    // precalculated rotations
    x_rotations: ManagedArrayList(Quat),
    y_rotations: ManagedArrayList(Quat),
    bullet_shape: *Shape,
    bullet_groups: ManagedArrayList(BulletGroup),
    bullet_texture: *Texture,
    bullet_impact_spritesheet: SpriteSheet,
    bullet_impact_sprites: ManagedArrayList(?SpriteSheetSprite),
    unit_square: *Shape,

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext, unit_square: *Shape) !Self {
        const texture_config = TextureConfig{
            .flip_v = false,
            .is_srgb = false, // gamma-space shading, see run_app
            .filter = .Nearest,
            .wrap = .Repeat,
        };

        const bullet_texture = try Texture.initFromFile(
            context,
            gpu,
            "assets/angrybots_assets/Textures/Bullet/bullet_texture_transparent.png",
            texture_config,
        );
        const texture_impact_sprite_sheet = try Texture.initFromFile(
            context,
            gpu,
            "assets/angrybots_assets/Textures/Bullet/impact_spritesheet_with_00.png",
            texture_config,
        );

        const bullet_impact_spritesheet = SpriteSheet.init(texture_impact_sprite_sheet, 11, 0.05);

        // Pre calculate the bullet spread rotations. Only needs to be done once.
        var x_rotations = ManagedArrayList(Quat).init(context.alloc);
        var y_rotations = ManagedArrayList(Quat).init(context.alloc);

        const rotation_per_bullet = world.ROTATION_PER_BULLET * math.pi / 180.0;
        const spread_amount_f32: f32 = @floatFromInt(world.SPREAD_AMOUNT);
        const spread_centering = rotation_per_bullet * (spread_amount_f32 - @as(f32, 1.0)) / @as(f32, 4.0);

        for (0..world.SPREAD_AMOUNT) |i| {
            const i_f32: f32 = @floatFromInt(i);
            const y_rot = Quat.fromAxisAngle(
                vec3(0.0, 1.0, 0.0),
                rotation_per_bullet * ((i_f32 - world.SPREAD_AMOUNT) / @as(f32, 2.0)) + spread_centering,
            );
            const x_rot = Quat.fromAxisAngle(
                vec3(1.0, 0.0, 0.0),
                rotation_per_bullet * ((i_f32 - world.SPREAD_AMOUNT) / @as(f32, 2.0)) + spread_centering + math.pi,
            );
            // std.debug.print("x_rot = {any}\n", .{x_rot});
            try x_rotations.append(x_rot);
            try y_rotations.append(y_rot);
        }

        // Blended, both sides, no depth writes, as redfish set around the bullet draw.
        const bullet_shape = try core.shapes.initGpuBuffers(context.alloc, gpu, .custom, &BULLET_POSITIONS, &BULLET_TEXCOORDS, &.{}, &.{}, &BULLET_INDICES);
        bullet_shape.is_transparent = true;
        bullet_shape.is_double_sided = true;
        bullet_shape.is_depth_write = false;

        const bullet_store: BulletSystem = .{
            .bullet_positions = ManagedArrayList(Vec3).init(context.alloc),
            .bullet_rotations = ManagedArrayList(Quat).init(context.alloc),
            .bullet_directions = ManagedArrayList(Vec3).init(context.alloc),
            .x_rotations = x_rotations,
            .y_rotations = y_rotations,
            .bullet_groups = ManagedArrayList(BulletGroup).init(context.alloc),
            .bullet_impact_sprites = ManagedArrayList(?SpriteSheetSprite).init(context.alloc),
            .bullet_shape = bullet_shape,
            .bullet_texture = bullet_texture,
            .bullet_impact_spritesheet = bullet_impact_spritesheet,
            .unit_square = unit_square,
        };

        log.info("bullet_store created", .{});
        return bullet_store;
    }

    pub fn createBullets(self: *Self, aim_theta: f32, projectile_spawn_point: Vec3) !bool {
        const aim_quat = Quat.fromAxisAngle(UP_VEC, aim_theta);

        const current_len = self.bullet_positions.items().len;
        const bullet_group_size = world.SPREAD_AMOUNT * world.SPREAD_AMOUNT;

        const bullet_group = BulletGroup.new(current_len, bullet_group_size, world.BULLET_LIFETIME);

        try self.bullet_positions.resize(current_len + bullet_group_size);
        try self.bullet_rotations.resize(current_len + bullet_group_size);
        try self.bullet_directions.resize(current_len + bullet_group_size);

        const start: usize = current_len;
        const end = start + bullet_group_size;

        for (start..end) |index| {
            const count = index - start;
            const i = @divTrunc(count, world.SPREAD_AMOUNT);
            const j = @mod(count, world.SPREAD_AMOUNT);

            const y_quat = aim_quat.mulQuat(self.y_rotations.items()[i]);
            const rot_quat = y_quat.mulQuat(self.x_rotations.items()[j]);

            const direction = rot_quat.rotateVec(CANONICAL_DIR);

            self.bullet_positions.items()[index] = projectile_spawn_point;
            self.bullet_rotations.items()[index] = rot_quat;
            self.bullet_directions.items()[index] = direction;
        }

        try self.bullet_groups.append(bullet_group);
        return true;
    }

    pub fn updateBullets(self: *Self, state: *State) !void {
        if (self.bullet_positions.items().len == 0) {
            return;
        }

        const use_aabb = state.enemies.items().len != 0;
        const num_sub_groups: u32 = if (use_aabb) @as(u32, @intCast(9)) else @as(u32, @intCast(1));

        const delta_position_magnitude = state.delta_time * world.BULLET_SPEED;

        var first_live_bullet_group: usize = 0;

        for (self.bullet_groups.items()) |*group| {
            group.time_to_live -= state.delta_time;

            if (group.time_to_live <= 0.0) {
                first_live_bullet_group += 1;
            } else {
                const bullet_group_start_index = group.start_index;
                const num_bullets_in_group = group.group_size;
                const sub_group_size: u32 = @divTrunc(num_bullets_in_group, num_sub_groups);

                for (0..num_sub_groups) |sub_group| {
                    var bullet_start = sub_group_size * sub_group;

                    var bullet_end = if (sub_group == (num_sub_groups - 1))
                        num_bullets_in_group
                    else
                        (bullet_start + sub_group_size);

                    bullet_start += bullet_group_start_index;
                    bullet_end += bullet_group_start_index;

                    for (bullet_start..bullet_end) |bullet_index| {
                        var direction = self.bullet_directions.items()[bullet_index];
                        const change = direction.mulScalar(delta_position_magnitude);

                        var position = self.bullet_positions.items()[bullet_index];
                        position = position.sub(change);
                        self.bullet_positions.items()[bullet_index] = position;
                    }

                    var subgroup_bound_box = AABB.init();

                    if (use_aabb) {
                        for (bullet_start..bullet_end) |bullet_index| {
                            subgroup_bound_box.expandWithVec3(self.bullet_positions.items()[bullet_index]);
                        }
                        subgroup_bound_box.expandBy(BULLET_ENEMY_MAX_COLLISION_DIST);
                    }

                    for (0..state.enemies.items().len) |i| {
                        const enemy = &state.enemies.items()[i].?;

                        if (use_aabb and !subgroup_bound_box.containsPoint(enemy.position)) {
                            continue;
                        }
                        for (bullet_start..bullet_end) |bullet_index| {
                            if (bulletCollidesWithEnemy(
                                &self.bullet_positions.items()[bullet_index],
                                &self.bullet_directions.items()[bullet_index],
                                enemy,
                            )) {
                                log.info("enemy killed", .{});
                                enemy.is_alive = false;
                                break;
                            }
                        }
                    }
                }
            }
        }

        var first_live_bullet: usize = 0;

        if (first_live_bullet_group != 0) {
            first_live_bullet =
                self.bullet_groups.items()[first_live_bullet_group - 1].start_index + self.bullet_groups.items()[first_live_bullet_group - 1].group_size;
            // self.bullet_groups.drain(0..first_live_bullet_group);
            try core.utils.removeRange(BulletGroup, &self.bullet_groups, 0, first_live_bullet_group);
        }

        if (first_live_bullet != 0) {
            try core.utils.removeRange(Vec3, &self.bullet_positions, 0, first_live_bullet);
            try core.utils.removeRange(Vec3, &self.bullet_directions, 0, first_live_bullet);
            try core.utils.removeRange(Quat, &self.bullet_rotations, 0, first_live_bullet);

            for (self.bullet_groups.items()) |*group| {
                group.start_index -= first_live_bullet;
            }
        }

        if (self.bullet_impact_sprites.items().len != 0) {
            for (0..self.bullet_impact_sprites.items().len) |i| {
                self.bullet_impact_sprites.items()[i].?.age = self.bullet_impact_sprites.items()[i].?.age + state.delta_time;
            }

            const sprite_duration = self.bullet_impact_spritesheet.num_columns * self.bullet_impact_spritesheet.time_per_sprite;

            const sprite_tester = SpriteAgeTester{ .sprite_duration = sprite_duration };

            core.utils.retain(
                SpriteSheetSprite,
                SpriteAgeTester,
                &self.bullet_impact_sprites,
                sprite_tester,
            );
        }

        for (state.enemies.items()) |enemy| {
            if (!enemy.?.is_alive) {
                const sprite_sheet_sprite = SpriteSheetSprite{ .age = 0.0, .world_position = enemy.?.position };
                try self.bullet_impact_sprites.append(sprite_sheet_sprite);
                try state.burn_marks.addMark(enemy.?.position);
                state.sound_engine.playSound(.Explosion);
            }
        }

        const enemyTester = EnemyTester{};
        // state.enemies.retain(|e| e.is_alive);
        core.utils.retain(
            Enemy,
            EnemyTester,
            &state.enemies,
            enemyTester,
        );
    }

    const SpriteAgeTester = struct {
        sprite_duration: f32,
        pub fn predicate(self: *const SpriteAgeTester, sprite: SpriteSheetSprite) bool {
            return sprite.age < self.sprite_duration;
        }
    };

    const EnemyTester = struct {
        pub fn predicate(self: *const EnemyTester, enemy: Enemy) bool {
            _ = self;
            return enemy.is_alive;
        }
    };

    /// Every live bullet in one instanced draw. Instance data goes through the frame's
    /// vertex ring, so it's copied per draw (redfish re-uploaded two VBOs).
    pub fn drawBullets(self: *Self, frame: *const Frame, shader: *const Shader) void {
        const count = self.bullet_positions.items().len;
        if (count == 0) {
            return;
        }

        self.bullet_texture.bind(frame);

        const instance_data = [_][]const u8{
            std.mem.sliceAsBytes(self.bullet_rotations.items()),
            std.mem.sliceAsBytes(self.bullet_positions.items()),
        };
        const draw_uniforms = DrawUniforms.init(Mat4.Identity, vec4(1.0, 1.0, 1.0, 1.0));
        self.bullet_shape.drawInstanced(frame, shader, draw_uniforms, &instance_data, @intCast(count));
    }

    pub fn drawBulletImpacts(self: *const Self, frame: *const Frame, sprite_shader: *const Shader) void {
        if (self.bullet_impact_sprites.itemsConst().len == 0) {
            return;
        }

        self.bullet_impact_spritesheet.texture.bind(frame);

        const scale: f32 = 2.0; // 0.25f32;

        for (self.bullet_impact_sprites.itemsConst()) |sprite| {
            var model = Mat4.fromTranslation(sprite.?.world_position);
            model = model.mulMat4(&Mat4.fromRotationX(math.degreesToRadians(-90.0)));
            model = model.mulMat4(&Mat4.fromScale(vec3(scale, scale, scale)));

            var draw_uniforms = DrawUniforms.init(model, vec4(1.0, 1.0, 1.0, 1.0));
            draw_uniforms.params = self.bullet_impact_spritesheet.drawParams(sprite.?.age);
            self.unit_square.draw(frame, sprite_shader, draw_uniforms);
        }
    }

    pub fn releaseGpuObjects(self: *Self) void {
        self.bullet_shape.releaseGpuObjects();
        self.bullet_texture.releaseGpuObjects();
        self.bullet_impact_spritesheet.releaseGpuObjects();
    }
};

fn bulletCollidesWithEnemy(position: *Vec3, direction: *Vec3, enemy: *Enemy) bool {
    if (position.distance(enemy.position) > BULLET_ENEMY_MAX_COLLISION_DIST) {
        return false;
    }

    // Start and end position of the capsule length for the bullet and the enemy
    const a0 = position.sub(direction.mulScalar(world.BULLET_COLLIDER.length / 2.0));
    const a1 = position.add(direction.mulScalar(world.BULLET_COLLIDER.length / 2.0));
    const b0 = enemy.position.sub(enemy.dir.mulScalar(world.ENEMY_COLLIDER.length / 2.0));
    const b1 = enemy.position.add(enemy.dir.mulScalar(world.ENEMY_COLLIDER.length / 2.0));

    const closet_distance = geom.distanceBetweenLineSegments(a0, a1, b0, b1);

    return closet_distance <= (world.BULLET_COLLIDER.radius + world.ENEMY_COLLIDER.radius);
}
