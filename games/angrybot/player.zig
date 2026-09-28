const std = @import("std");
const core = @import("core");
const math = @import("math");
const world = @import("state.zig");

const Allocator = std.mem.Allocator;

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const vec2 = math.vec2;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat4 = math.Mat4;

const Context = core.Context;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const State = world.State;
const Model = core.Model;
const GltfAsset = core.gltf_asset.GltfAsset;
const TextureConfig = core.texture.TextureConfig;
const Shader = core.Shader;
const AnimationClip = core.AnimationClip;
const AnimationRepeatMode = core.AnimationRepeatMode;
const WeightedAnimation = core.WeightedAnimation;

const log = std.log.scoped(.player);

pub const AnimationName = enum {
    idle,
    right,
    forward,
    back,
    left,
    dead,
};

pub const PlayerAnimations = struct {
    idle: AnimationClip,
    right: AnimationClip,
    forward: AnimationClip,
    back: AnimationClip,
    left: AnimationClip,
    dead: AnimationClip,

    const Self = @This();

    pub fn new() Self {
        // Convert ASSIMP frame-based timing to glTF time-based (assuming 24 FPS)
        const fps = 24.0;
        return .{
            .idle = AnimationClip.init(0, 55.0 / fps, 130.0 / fps, AnimationRepeatMode.Forever),
            .right = AnimationClip.init(0, 184.0 / fps, 204.0 / fps, AnimationRepeatMode.Forever),
            .forward = AnimationClip.init(0, 134.0 / fps, 154.0 / fps, AnimationRepeatMode.Forever),
            .back = AnimationClip.init(0, 159.0 / fps, 179.0 / fps, AnimationRepeatMode.Forever),
            .left = AnimationClip.init(0, 209.0 / fps, 229.0 / fps, AnimationRepeatMode.Forever),
            .dead = AnimationClip.init(0, 234.0 / fps, 293.0 / fps, AnimationRepeatMode.Once),
        };
    }

    pub fn get(self: *Self, name: AnimationName) AnimationClip {
        return switch (name) {
            .idle => self.idle,
            .right => self.right,
            .forward => self.forward,
            .back => self.back,
            .left => self.left,
            .dead => self.dead,
        };
    }
};

pub const AnimationWeights = struct {
    // Previous animation weights
    last_anim_time: f32,
    prev_idle_weight: f32,
    prev_right_weight: f32,
    prev_forward_weight: f32,
    prev_back_weight: f32,
    prev_left_weight: f32,

    const Self = @This();

    fn default() Self {
        return .{
            .last_anim_time = 0.0,
            .prev_idle_weight = 0.0,
            .prev_right_weight = 0.0,
            .prev_forward_weight = 0.0,
            .prev_back_weight = 0.0,
            .prev_left_weight = 0.0,
        };
    }
};

pub const Player = struct {
    model: *Model,
    position: Vec3,
    direction: Vec2,
    speed: f32,
    aim_theta: f32,
    last_fire_time: f32,
    is_trying_to_fire: bool,
    is_alive: bool,
    death_time: f32,
    animation_name: AnimationName,
    animations: PlayerAnimations,
    anim_weights: AnimationWeights,

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext) !*Self {
        // Modern glTF path instead of .fbx
        const model_path = "assets/angrybots_assets/Models/Player/Player.gltf";

        // Use GltfAsset instead of ModelBuilder
        var gltf_asset = try GltfAsset.init(context, gpu, "Player", model_path);

        // Define texture configuration (same settings as ASSIMP version)
        const texture_config = TextureConfig{
            .filter = .Linear,
            .flip_v = true,
            .wrap = .Clamp,
        };

        // Modern glTF texture assignment using string uniform names
        // Shaded in gamma space, as redfish (see run_app)
        gltf_asset.useGammaSpaceTextures();
        try gltf_asset.addCustomTexture("Player", "texture_diffuse", "Textures/Player_D.tga", texture_config);
        try gltf_asset.addCustomTexture("Player", "texture_specular", "Textures/Player_M.tga", texture_config);
        try gltf_asset.addCustomTexture("Player", "texture_emissive", "Textures/Player_E.tga", texture_config);
        try gltf_asset.addCustomTexture("Player", "texture_normal", "Textures/Player_NRM.tga", texture_config);
        try gltf_asset.addCustomTexture("Gun", "texture_diffuse", "Textures/Gun_D.tga", texture_config);
        try gltf_asset.addCustomTexture("Gun", "texture_specular", "Textures/Gun_M.tga", texture_config);
        try gltf_asset.addCustomTexture("Gun", "texture_emissive", "Textures/Gun_E.tga", texture_config);
        try gltf_asset.addCustomTexture("Gun", "texture_normal", "Textures/Gun_NRM.tga", texture_config);

        try gltf_asset.load();
        log.info("Player: glTF asset loaded and configured", .{});

        const model = try gltf_asset.buildModel();
        log.info("Player: model built successfully", .{});

        const player = try context.alloc.create(Player);
        player.* = Player{
            .model = model,
            .last_fire_time = 0.0,
            .is_trying_to_fire = false,
            .is_alive = true,
            .aim_theta = 0.0,
            .position = vec3(0.0, 0.0, 0.0),
            .direction = vec2(0.0, 0.0),
            .death_time = -1.0,
            .animation_name = .idle,
            .speed = world.PLAYER_SPEED,
            .animations = PlayerAnimations.new(),
            .anim_weights = AnimationWeights.default(),
        };

        // Start with idle animation
        try player.model.animator.playClip(player.animations.idle);
        return player;
    }

    pub fn setAnimation(self: *Self, animation_name: AnimationName, seconds: u32) void {
        _ = seconds; // Not used in current implementation
        if (self.animation_name != animation_name) {
            self.animation_name = animation_name;
            // Could implement animation switching if needed
        }
    }

    pub fn die(self: *Self, time: f32) void {
        self.is_alive = false;
        if (self.death_time < 0.0) {
            self.death_time = time;
        }
    }

    /// `transform` places the player (redfish's `model` uniform). Drawn in the shadow,
    /// emission, and scene passes; each uploads the same pose.
    pub fn draw(self: *Self, frame: *const Frame, shader: *const Shader, transform: Mat4) void {
        self.model.draw(frame, shader, transform);
    }

    pub fn cleanUp(self: *Self) void {
        self.model.cleanUp();
    }

    pub fn update(self: *Self, state: *State, aim_theta: f32) !void {
        const weight_animations = self.updateAnimationWeights(
            self.direction,
            aim_theta,
            state.frame_time,
        );
        // Use the new glTF animation blending system
        try self.model.updateWeightedAnimations(&weight_animations, state.frame_time);
    }

    pub fn getMuzzlePosition(self: *Self, player_transform: *const Mat4) Vec3 {
        _ = self; // Suppress unused parameter warning
        // Simple muzzle offset - adjust these values as needed for gun positioning
        const muzzle_offset = vec3(-29, 120, 92); // Forward and up from player center
        const muzzle_translation = Mat4.fromTranslation(muzzle_offset);
        const muzzle_world_position = player_transform.mulMat4(&muzzle_translation).mulVec4(vec4(0.0, 0.0, 0.0, 1.0));
        const projectile_spawn_point = muzzle_world_position.xyz();
        return projectile_spawn_point;
    }

    fn updateAnimationWeights(self: *Self, direction: Vec2, aim_theta: f32, frame_time: f32) [6]WeightedAnimation {
        const is_moving = direction.lengthSquared() > 0.1;
        const move_theta = math.atan(direction.x / direction.y) + if (direction.y < @as(f32, 0.0)) math.pi else @as(f32, 0.0);
        const theta_delta = move_theta - aim_theta;
        const anim_move = vec2(math.sin(theta_delta), math.cos(theta_delta));

        const anim_delta_time = frame_time - self.anim_weights.last_anim_time;
        self.anim_weights.last_anim_time = frame_time;

        const is_dead = self.death_time >= 0.0;

        self.anim_weights.prev_idle_weight = max(0.0, self.anim_weights.prev_idle_weight - anim_delta_time / world.ANIM_TRANSITION_TIME);
        self.anim_weights.prev_right_weight = max(0.0, self.anim_weights.prev_right_weight - anim_delta_time / world.ANIM_TRANSITION_TIME);
        self.anim_weights.prev_forward_weight = max(0.0, self.anim_weights.prev_forward_weight - anim_delta_time / world.ANIM_TRANSITION_TIME);
        self.anim_weights.prev_back_weight = max(0.0, self.anim_weights.prev_back_weight - anim_delta_time / world.ANIM_TRANSITION_TIME);
        self.anim_weights.prev_left_weight = max(0.0, self.anim_weights.prev_left_weight - anim_delta_time / world.ANIM_TRANSITION_TIME);

        var dead_weight: f32 = if (is_dead) @as(f32, 1.0) else @as(f32, 0.0);
        var idle_weight = self.anim_weights.prev_idle_weight + if (is_moving or is_dead) @as(f32, 0.0) else @as(f32, 1.0);
        var right_weight = self.anim_weights.prev_right_weight + if (is_moving) clamp0(-anim_move.x) else @as(f32, 0.0);
        var forward_weight = self.anim_weights.prev_forward_weight + if (is_moving) clamp0(anim_move.y) else @as(f32, 0.0);
        var back_weight = self.anim_weights.prev_back_weight + if (is_moving) clamp0(-anim_move.y) else @as(f32, 0.0);
        var left_weight = self.anim_weights.prev_left_weight + if (is_moving) clamp0(anim_move.x) else @as(f32, 0.0);

        const weight_sum = dead_weight + idle_weight + forward_weight + back_weight + right_weight + left_weight;
        dead_weight /= weight_sum;
        idle_weight /= weight_sum;
        forward_weight /= weight_sum;
        back_weight /= weight_sum;
        right_weight /= weight_sum;
        left_weight /= weight_sum;

        self.anim_weights.prev_idle_weight = max(self.anim_weights.prev_idle_weight, idle_weight);
        self.anim_weights.prev_right_weight = max(self.anim_weights.prev_right_weight, right_weight);
        self.anim_weights.prev_forward_weight = max(self.anim_weights.prev_forward_weight, forward_weight);
        self.anim_weights.prev_back_weight = max(self.anim_weights.prev_back_weight, back_weight);
        self.anim_weights.prev_left_weight = max(self.anim_weights.prev_left_weight, left_weight);

        const fps = 30.0;
        return .{
            WeightedAnimation.init(0, idle_weight, 55.0 / fps, 130.0 / fps, 0.0, 0.0),
            WeightedAnimation.init(0, forward_weight, 134.0 / fps, 154.0 / fps, 0.0, 0.0),
            WeightedAnimation.init(0, back_weight, 159.0 / fps, 179.0 / fps, 10.0 / fps, 0.0),
            WeightedAnimation.init(0, right_weight, 184.0 / fps, 204.0 / fps, 10.0 / fps, 0.0),
            WeightedAnimation.init(0, left_weight, 209.0 / fps, 229.0 / fps, 0.0, 0.0),
            WeightedAnimation.init(0, dead_weight, 234.0 / fps, 293.0 / fps, 0.0, self.death_time),
        };
    }
};

fn clamp0(value: f32) f32 {
    if (value < 0.0001) {
        return 0.0;
    }
    return value;
}

fn max(a: f32, b: f32) f32 {
    if (a > b) {
        return a;
    } else {
        return b;
    }
}
