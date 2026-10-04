const std = @import("std");
const zgui = @import("zgui");
const core = @import("core");
const math = @import("math");

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const Vec4 = math.Vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const quat = math.quat;

const Allocator = std.mem.Allocator;
const ResourceManager = core.ResourceManager;

const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Texture = core.texture.Texture;
const Frame = core.Frame;
const MeshPrimitive = core.MeshPrimitive;
const Input = core.Input;
const AnimationRepeatMode = core.AnimationRepeatMode;
const character_control = @import("character_control.zig");

const ToonStateMachine = core.AnimationStateMachine(ToonAnimation);

const log = std.log.scoped(.toon_soldier);

const path_soldier = "assets/toon_shooter_kit/Characters/glTF/Character_Soldier.gltf";
const path_enemy = "assets/toon_shooter_kit/Characters/glTF/Character_Enemy.gltf";
const path_hazmat = "assets/toon_shooter_kit/Characters/glTF/Character_Hazmat.gltf";

/// The soldier's height in meters (1 world unit = 1 m); its scale follows from the
/// model's height.
const HEIGHT: f32 = 1.8;
/// How fast a planted foot moves back in the Walk and Run clips, in model units per
/// second (measured from the clips: docs/reviews/2026-10-04-link-style-controller-review.md
/// section 3.3). Moving at these speeds times the scale, the feet don't slide.
const WALK_CLIP_SPEED: f32 = 2.6;
const RUN_CLIP_SPEED: f32 = 4.5;

const ToonAnimation = enum(u32) {
    death,
    duck,
    hit_react,
    idle,
    idle_shoot,
    jump,
    jump_idle,
    jump_land,
    no,
    punch,
    run,
    run_gun,
    run_shoot,
    walk,
    walk_shoot,
    wave,
    yes,
};

const Weapon = enum {
    AK,
    GrenadeLauncher,
    Knife_1,
    Knife_2,
    Pistol,
    Revolver,
    Revolver_Small,
    RocketLauncher,
    ShortCannon,
    Shotgun,
    Shovel,
    SMG,
    Sniper,
    Sniper_2,
};

pub const ToonSoldier = struct {
    model: *core.ModelInstance,
    shader: *core.Shader,
    position: Vec3 = vec3(0.0, 0.0, 3.0),
    /// The model's scale for `HEIGHT`.
    scale: f32,
    transform: core.Transform = core.Transform.identity(),
    rotation_speed: f32 = 2.0,
    /// Meters per second.
    walk_speed: f32,
    run_speed: f32,
    /// This frame's speed, for matching the walk and run clips' rate to it.
    speed: f32 = 0.0,
    /// Plays walk and run at the rate that matches `speed`, so the feet don't slide at
    /// any speed. Off: as authored, for finding the speed where they don't.
    match_rate: bool = true,
    state_machine: ToonStateMachine,
    current_weapon: Weapon = .ShortCannon,

    const Self = @This();

    pub fn init(rm: *ResourceManager) !*ToonSoldier {
        const allocator = rm.context.alloc;

        // level_01's animated_pbr is the same shader as core pbr
        const shader = try rm.createShader("src/core/shaders/pbr.wgsl", .{
            .vertex_buffers = &MeshPrimitive.vertex_buffer_layouts,
            .material = .pbr,
            .alpha_to_coverage = true,
        });

        const model = try rm.loadModel("toon_soldier", path_soldier);
        const bounds = model.gltf_asset.calculateBoundingBox(0);
        const model_height = bounds.max.y - bounds.min.y;
        const scale = HEIGHT / model_height;
        log.info("model height {d:.2}, scale {d:.3} for {d:.2} m", .{ model_height, scale, HEIGHT });

        const configs = buildStateConfigs();
        var fsm = ToonStateMachine.init(configs, .idle, model);
        fsm.debug = true;

        const soldier = try allocator.create(ToonSoldier);
        soldier.* = .{
            .model = model,
            .shader = shader,
            .scale = scale,
            .walk_speed = WALK_CLIP_SPEED * scale,
            .run_speed = RUN_CLIP_SPEED * scale,
            .state_machine = fsm,
        };

        soldier.transform.translation = soldier.position;
        soldier.transform.scale = vec3(scale, scale, scale);
        soldier.equipWeapon(soldier.current_weapon);

        return soldier;
    }

    pub fn equipWeapon(self: *Self, weapon: Weapon) void {
        // Hide all weapons
        inline for (std.meta.fields(Weapon)) |field| {
            self.model.gltf_asset.setNodeVisibility(field.name, false);
        }
        // Show the selected weapon
        self.model.gltf_asset.setNodeVisibility(@tagName(weapon), true);
        self.current_weapon = weapon;
    }

    pub fn update(self: *Self, input: *Input) !void {
        self.matchClipRate();
        try self.state_machine.update(self.model, input.delta_time);
    }

    /// The tuning panel: speeds in meters per second and the clips' rates.
    pub fn drawGui(self: *Self) void {
        zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 320, .h = 200, .cond = .first_use_ever });
        if (zgui.begin("soldier", .{})) {
            const state = self.state_machine.getCurrentState();
            zgui.text("state: {s}", .{@tagName(state)});
            zgui.text("speed: {d:.2} m/s ({d:.2} heights/s)", .{ self.speed, self.speed / HEIGHT });
            if (clipSpeed(state)) |clip_speed| {
                zgui.text("clip foot speed: {d:.2} m/s", .{clip_speed * self.scale});
            }
            zgui.text("height: {d:.2} m, scale {d:.3}", .{ HEIGHT, self.scale });
            _ = zgui.sliderFloat("walk (m/s)", .{ .v = &self.walk_speed, .min = 0.5, .max = 5.0 });
            _ = zgui.sliderFloat("run (m/s)", .{ .v = &self.run_speed, .min = 1.0, .max = 10.0 });
            _ = zgui.checkbox("match clip rate to speed", .{ .v = &self.match_rate });
        }
        zgui.end();
    }

    /// Lit by the frame's SceneLights (redfish's PBR light uniforms were never set here).
    pub fn draw(self: *Self, frame: *const Frame) void {
        self.model.draw(frame, self.shader, self.transform.toMatrix());
    }

    pub fn processInput(self: *Self, input: *core.Input) !void {
        const dt = input.delta_time;

        // One-shot actions first, so they claim their keys before the scene's global keys
        self.processOneShotKeys(input);
        // A kick or roll plays in place: no moving or turning until it's done
        self.speed = 0.0;
        if (!self.state_machine.isInterruptible()) {
            return;
        }

        // Rotation (A/D)
        if (input.isDown(.a)) {
            self.transform.rotateAxis(vec3(0.0, 1.0, 0.0), self.rotation_speed * dt);
        }
        if (input.isDown(.d)) {
            self.transform.rotateAxis(vec3(0.0, 1.0, 0.0), -self.rotation_speed * dt);
        }

        // Locomotion, along the way the model faces (glTF models face +Z)
        const facing = self.transform.rotation.rotateVec(Vec3.Z);
        if (input.isDown(.w)) {
            const is_running = input.key_shift;
            self.speed = if (is_running) self.run_speed else self.walk_speed;
            self.transform.translation = self.transform.translation.add(facing.mulScalar(self.speed * dt));

            if (is_running) {
                _ = self.state_machine.requestState(.run_shoot);
            } else {
                _ = self.state_machine.requestState(.walk);
            }
        } else if (input.isDown(.s)) {
            self.speed = self.walk_speed;
            self.transform.translation = self.transform.translation.sub(facing.mulScalar(self.speed * dt));
            _ = self.state_machine.requestState(.walk);
        } else {
            _ = self.state_machine.requestState(.idle);
        }
    }

    /// Analog control: walks or runs along `move` (a direction on the ground from the
    /// move stick, length 0 to 1), facing where it goes; actions as `processInput`.
    pub fn drive(self: *Self, move: Vec3, input: *core.Input) void {
        self.processOneShotKeys(input);
        self.speed = 0.0;
        if (!self.state_machine.isInterruptible()) {
            return;
        }
        const gait = character_control.drive(&self.transform, move, self.walk_speed, self.run_speed, input.delta_time);
        self.speed = switch (gait) {
            .idle => 0.0,
            .walk => self.walk_speed,
            .run => self.run_speed,
        };
        _ = self.state_machine.requestState(switch (gait) {
            .idle => .idle,
            .walk => .walk,
            .run => .run,
        });
    }

    fn processOneShotKeys(self: *Self, input: *core.Input) void {
        const one_shot_keys = .{
            .{ .key = .space, .anim = ToonAnimation.jump },
            .{ .key = .one, .anim = ToonAnimation.punch },
            .{ .key = .two, .anim = ToonAnimation.duck },
            .{ .key = .three, .anim = ToonAnimation.wave },
            .{ .key = .four, .anim = ToonAnimation.yes },
            .{ .key = .five, .anim = ToonAnimation.no },
            .{ .key = .six, .anim = ToonAnimation.walk_shoot },
            .{ .key = .seven, .anim = ToonAnimation.run_shoot },
        };

        inline for (one_shot_keys) |entry| {
            if (input.pressedOnce(entry.key)) {
                _ = self.state_machine.requestState(entry.anim);
            }
        }

        // The same actions on the gamepad's face buttons
        const one_shot_buttons = .{
            .{ .button = .a, .anim = ToonAnimation.jump },
            .{ .button = .x, .anim = ToonAnimation.punch },
            .{ .button = .b, .anim = ToonAnimation.duck },
            .{ .button = .y, .anim = ToonAnimation.wave },
        };
        inline for (one_shot_buttons) |entry| {
            if (input.buttonPressedOnce(entry.button)) {
                _ = self.state_machine.requestState(entry.anim);
            }
        }
    }

    /// A walk or run plays at the rate that carries the feet at `speed`.
    fn matchClipRate(self: *Self) void {
        const clip_speed = clipSpeed(self.state_machine.getCurrentState()) orelse return;
        const rate = if (self.match_rate and self.speed > 0.0) self.speed / (clip_speed * self.scale) else 1.0;
        self.state_machine.setPlaybackRate(rate);
    }
};

/// The foot speed of a walk or run state's clip, in model units per second.
fn clipSpeed(state: ToonAnimation) ?f32 {
    return switch (state) {
        .walk, .walk_shoot => WALK_CLIP_SPEED,
        .run, .run_gun, .run_shoot => RUN_CLIP_SPEED,
        else => null,
    };
}

fn buildStateConfigs() [ToonStateMachine.count]ToonStateMachine.StateConfig {
    const Forever = AnimationRepeatMode.Forever;
    const Once = AnimationRepeatMode.Once;

    var configs: [ToonStateMachine.count]ToonStateMachine.StateConfig = undefined;

    // Locomotion (looping, interruptible)
    configs[@intFromEnum(ToonAnimation.idle)] = .{ .animation_id = 3, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.walk)] = .{ .animation_id = 13, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.run)] = .{ .animation_id = 10, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.run_gun)] = .{ .animation_id = 11, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.run_shoot)] = .{ .animation_id = 12, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.walk_shoot)] = .{ .animation_id = 14, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };

    // Idle variants (looping, interruptible)
    configs[@intFromEnum(ToonAnimation.idle_shoot)] = .{ .animation_id = 4, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.jump_idle)] = .{ .animation_id = 6, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };

    // One-shot actions (play once, return to idle, not interruptible)
    configs[@intFromEnum(ToonAnimation.punch)] = .{ .animation_id = 9, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.jump)] = .{ .animation_id = 5, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.jump_land)] = .{ .animation_id = 7, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.duck)] = .{ .animation_id = 1, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.wave)] = .{ .animation_id = 15, .repeat = Once, .crossfade_in = 0.15, .interruptible = true, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.yes)] = .{ .animation_id = 16, .repeat = Once, .crossfade_in = 0.15, .interruptible = true, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.no)] = .{ .animation_id = 8, .repeat = Once, .crossfade_in = 0.15, .interruptible = true, .return_state = .idle };

    // Reactions (play once, not interruptible)
    configs[@intFromEnum(ToonAnimation.hit_react)] = .{ .animation_id = 2, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.death)] = .{ .animation_id = 0, .repeat = Once, .crossfade_in = 0.20, .interruptible = false, .return_state = null };

    return configs;
}
