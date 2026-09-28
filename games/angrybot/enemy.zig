const std = @import("std");
const math = @import("math");
const core = @import("core");
const world = @import("state.zig");
const geom = @import("geom.zig");

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const vec2 = math.vec2;
const vec3 = math.vec3;
const Mat4 = math.Mat4;

const Context = core.Context;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const State = world.State;
const Model = core.Model;
const GltfAsset = core.gltf_asset.GltfAsset;
const TextureConfig = core.texture.TextureConfig;
const Shader = core.Shader;
const Random = core.Random;

const log = std.log.scoped(.enemy);

pub const Enemy = struct {
    position: Vec3,
    dir: Vec3,
    is_alive: bool,

    const Self = @This();

    pub fn new(position: Vec3, dir: Vec3) Self {
        return .{
            .position = position,
            .dir = dir,
            .is_alive = true,
        };
    }
};

pub const EnemySystem = struct {
    count_down: f32,
    monster_y: f32,
    enemy_model: *Model,
    gltf_asset: *GltfAsset, // Keep reference for cleanup
    random: Random,

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext) !Self {
        // Modern glTF path instead of .fbx
        const model_path = "assets/angrybots_assets/Models/Eeldog/EelDog.gltf";

        // Use GltfAsset instead of ModelBuilder
        var gltf_asset = try GltfAsset.init(context, gpu, "enemy", model_path);

        // Define texture configuration (same settings as ASSIMP version)
        const texture_config = TextureConfig{
            .filter = .Linear,
            .flip_v = true,
            .wrap = .Clamp,
        };

        // Modern glTF texture assignment using string uniform names
        // Shaded in gamma space, as redfish (see run_app)
        gltf_asset.useGammaSpaceTextures();
        try gltf_asset.addCustomTexture("Eeldog", "texture_diffuse", "Eeldog_Albedo.png", texture_config);
        try gltf_asset.addCustomTexture("Eeldog", "texture_emissive", "Eeldog_Albedo.png", texture_config);
        // no normal in shader, so we can skip this
        //try gltf_asset.addCustomTexture("EelDog", "texture_normal", "Eeldog_Normal.png", texture_config);

        try gltf_asset.load();
        log.info("EnemySystem: glTF asset loaded and configured", .{});

        const enemy_model = try gltf_asset.buildModel();
        log.info("EnemySystem: model built successfully", .{});

        return .{
            .count_down = world.ENEMY_SPAWN_INTERVAL,
            .monster_y = world.MONSTER_Y,
            .enemy_model = enemy_model,
            .gltf_asset = gltf_asset,
            .random = Random.init(),
        };
    }

    pub fn update(self: *Self, state: *State) !void {
        self.count_down -= state.delta_time;
        if (self.count_down <= 0.0) {
            for (0..world.SPAWNS_PER_INTERVAL) |_| {
                const rand_num = self.random.randFloat();
                try self.spawnEnemy(state, rand_num);
            }
            self.count_down += world.ENEMY_SPAWN_INTERVAL;
        }
    }

    pub fn spawnEnemy(self: *Self, state: *State, rand_num: f32) !void {
        const theta = math.degreesToRadians(rand_num * 360.0);
        const x = state.player.position.x + math.sin(theta) * world.SPAWN_RADIUS;
        const z = state.player.position.z + math.cos(theta) * world.SPAWN_RADIUS;

        const enemy = Enemy.new(vec3(x, self.monster_y, z), vec3(0.0, 0.0, 1.0));
        try state.enemies.append(enemy);
    }

    pub fn chasePlayer(self: *Self, state: *State) void {
        _ = self;
        const player_collision_position = vec3(state.player.position.x, world.MONSTER_Y, state.player.position.z);

        for (0..state.enemies.list.items.len) |i| {
            const enemy = &state.enemies.list.items[i].?;
            var dir = state.player.position.sub(enemy.position);
            dir.y = 0.0;
            enemy.dir = dir.toNormalized();
            enemy.position = enemy.position.add(enemy.dir.mulScalar(state.delta_time * world.MONSTER_SPEED));

            if (state.player.is_alive) {
                const p1 = enemy.position.sub(enemy.dir.mulScalar(world.ENEMY_COLLIDER.length / 2.0));
                const p2 = enemy.position.sub(enemy.dir.mulScalar(world.ENEMY_COLLIDER.length / 2.0));
                const dist = geom.distanceBetweenPointAndLineSegment(player_collision_position, p1, p2);

                if (dist <= (world.PLAYER_COLLISION_RADIUS + world.ENEMY_COLLIDER.radius)) {
                    state.player.is_alive = false;
                    state.player.die(state.frame_time);
                    state.player.direction = vec2(0.0, 0.0);
                }
            }
        }
    }

    /// The wiggle's nose position and time are in the shader (player_shader.wgsl, WIGGLE)
    /// and the frame uniforms.
    pub fn drawEnemies(self: *Self, frame: *const Frame, shader: *const Shader, state: *State) void {
        for (state.enemies.list.items) |e| {
            const zero: f32 = 0.0;
            const val = if (e.?.dir.z < zero) zero else math.pi;
            const monster_theta = math.atan(e.?.dir.x / e.?.dir.z) + val;

            var model_transform = Mat4.fromTranslation(e.?.position);

            model_transform = model_transform.mulMat4(&Mat4.fromScale(Vec3.splat(0.01)));
            model_transform = model_transform.mulMat4(&Mat4.fromAxisAngle(vec3(0.0, 1.0, 0.0), monster_theta));
            model_transform = model_transform.mulMat4(&Mat4.fromAxisAngle(vec3(0.0, 0.0, 1.0), math.pi));
            // redfish added a +90° X rotation here and ignored the glTF node transforms; the
            // EelDog's node chain holds that rotation, and Model.draw applies it.

            self.enemy_model.draw(frame, shader, model_transform);
        }
    }

    pub fn cleanUp(self: *Self) void {
        self.enemy_model.cleanUp();
    }
};
