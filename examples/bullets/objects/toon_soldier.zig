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

/// The three toon characters: the same rig and clips, different looks.
pub const Look = enum {
    soldier,
    enemy,
    hazmat,

    fn path(self: Look) []const u8 {
        return switch (self) {
            .soldier => "assets/toon_shooter_kit/Characters/glTF/Character_Soldier.gltf",
            .enemy => "assets/toon_shooter_kit/Characters/glTF/Character_Enemy.gltf",
            .hazmat => "assets/toon_shooter_kit/Characters/glTF/Character_Hazmat.gltf",
        };
    }
};

/// The soldier's height in meters (1 world unit = 1 m); its scale follows from the
/// model's height.
const HEIGHT: f32 = 1.8;
/// How fast a planted foot moves back in the Walk and Run clips, in model units per
/// second (measured from the clips: docs/reviews/2026-10-04-link-style-controller-review.md
/// section 3.3). Moving at these speeds times the scale, the feet don't slide.
const WALK_CLIP_SPEED: f32 = 2.6;
const RUN_CLIP_SPEED: f32 = 4.5;
/// Seconds in the air between the Jump clip (takeoff) and Jump_Land.
const AIR_TIME: f32 = 0.2;

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

pub const Weapon = enum {
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
    /// Speed and the ground movement tuning; its speed sets the walk and run clips' rate.
    motor: character_control.Motor,
    /// Plays walk and run at the rate that matches the speed, so the feet don't slide at
    /// any speed. Off: as authored, for finding the speed where they don't.
    match_rate: bool = true,
    /// Seconds in the air so far, during Jump_Idle.
    air_time: f32 = 0.0,
    /// False hides the model (first person: the camera is inside the head).
    visible: bool = true,
    state_machine: ToonStateMachine,
    current_weapon: Weapon = .ShortCannon,

    const Self = @This();

    /// `debug` logs the state machine's transitions (for the player's character, not for
    /// every squad member).
    pub fn init(rm: *ResourceManager, look: Look, weapon: Weapon, debug: bool) !*ToonSoldier {
        const allocator = rm.context.alloc;

        // level_01's animated_pbr is the same shader as core pbr
        const shader = try rm.createShader("src/core/shaders/pbr.wgsl", .{
            .vertex_buffers = &MeshPrimitive.vertex_buffer_layouts,
            .material = .pbr,
            .alpha_to_coverage = true,
        });

        const model = try rm.loadModel(@tagName(look), look.path());
        const bounds = model.gltf_asset.calculateBoundingBox(0);
        const model_height = bounds.max.y - bounds.min.y;
        const scale = HEIGHT / model_height;
        log.info("model height {d:.2}, scale {d:.3} for {d:.2} m", .{ model_height, scale, HEIGHT });

        const configs = buildStateConfigs();
        var fsm = ToonStateMachine.init(configs, .idle, model);
        fsm.debug = debug;

        const soldier = try allocator.create(ToonSoldier);
        soldier.* = .{
            .model = model,
            .shader = shader,
            .scale = scale,
            .motor = .{ .walk_speed = WALK_CLIP_SPEED * scale, .run_speed = RUN_CLIP_SPEED * scale },
            .state_machine = fsm,
        };

        soldier.transform.translation = soldier.position;
        soldier.transform.scale = vec3(scale, scale, scale);
        soldier.equipWeapon(weapon);

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

    pub fn update(self: *Self, dt: f32) !void {
        self.landAfterAirTime(dt);
        self.matchClipRate();
        try self.state_machine.update(self.model, dt);
    }

    /// The tuning panel: control style, speeds in meters per second, the Wind Waker
    /// style's turning and skid, and the clips' rates.
    pub fn drawGui(self: *Self, style: *character_control.Style) void {
        const motor = &self.motor;
        zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 360, .h = 380, .cond = .first_use_ever });
        if (zgui.begin("soldier", .{})) {
            _ = zgui.comboFromEnum("control (K)", style);

            const state = self.state_machine.getCurrentState();
            zgui.text("state: {s}{s}", .{ @tagName(state), if (motor.skidding) "  (skid)" else "" });
            zgui.text("speed: {d:.2} m/s ({d:.2} heights/s)", .{ motor.speed, motor.speed / HEIGHT });
            if (clipSpeed(state)) |clip_speed| {
                zgui.text("clip foot speed: {d:.2} m/s", .{clip_speed * self.scale});
            }
            zgui.text("height: {d:.2} m, scale {d:.3}", .{ HEIGHT, self.scale });
            _ = zgui.sliderFloat("walk (m/s)", .{ .v = &motor.walk_speed, .min = 0.5, .max = 5.0 });
            _ = zgui.sliderFloat("run (m/s)", .{ .v = &motor.run_speed, .min = 1.0, .max = 10.0 });
            _ = zgui.checkbox("match clip rate to speed", .{ .v = &self.match_rate });

            zgui.separatorText("wind waker");
            _ = zgui.sliderFloat("accel (s to run)", .{ .v = &motor.accel_time, .min = 0.02, .max = 1.0 });
            _ = zgui.sliderFloat("decel (s to stop)", .{ .v = &motor.decel_time, .min = 0.02, .max = 1.0 });
            _ = zgui.sliderFloat("turn standing (deg/s)", .{ .v = &motor.turn_rate_standing, .min = 90.0, .max = 1440.0 });
            _ = zgui.sliderFloat("turn running (deg/s)", .{ .v = &motor.turn_rate_running, .min = 90.0, .max = 1440.0 });
            _ = zgui.sliderFloat("skid angle (deg)", .{ .v = &motor.skid_angle, .min = 90.0, .max = 180.0 });
            _ = zgui.sliderFloat("skid above (x run)", .{ .v = &motor.skid_min_speed, .min = 0.0, .max = 1.0 });
            _ = zgui.sliderFloat("skid (s to stop)", .{ .v = &motor.skid_time, .min = 0.02, .max = 1.0 });
        }
        zgui.end();
    }

    /// Lit by the frame's SceneLights (redfish's PBR light uniforms were never set here).
    pub fn draw(self: *Self, frame: *const Frame) void {
        if (self.visible) {
            self.model.draw(frame, self.shader, self.transform.toMatrix());
        }
    }

    pub fn processInput(self: *Self, input: *core.Input) !void {
        const dt = input.delta_time;

        // One-shot actions first, so they claim their keys before the scene's global keys
        self.processOneShotKeys(input);
        // A punch plays in place, a jump carries on: no steering until it's done
        if (!self.state_machine.isInterruptible()) {
            self.moveDuringAction(dt);
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
        const motor = &self.motor;
        if (input.isDown(.w)) {
            const is_running = input.key_shift;
            motor.speed = if (is_running) motor.run_speed else motor.walk_speed;
            self.transform.translation = self.transform.translation.add(facing.mulScalar(motor.speed * dt));

            if (is_running) {
                _ = self.state_machine.requestState(.run_shoot);
            } else {
                _ = self.state_machine.requestState(.walk);
            }
        } else if (input.isDown(.s)) {
            motor.speed = motor.walk_speed;
            self.transform.translation = self.transform.translation.sub(facing.mulScalar(motor.speed * dt));
            _ = self.state_machine.requestState(.walk);
        } else {
            motor.stop();
            _ = self.state_machine.requestState(.idle);
        }
    }

    /// Analog control: walks or runs along `move` (a direction on the ground from the
    /// move stick, length 0 to 1) in the given style; actions as `processInput`.
    pub fn drive(self: *Self, move: Vec3, style: character_control.Style, input: *core.Input) void {
        self.processOneShotKeys(input);
        if (!self.state_machine.isInterruptible()) {
            self.moveDuringAction(input.delta_time);
            return;
        }
        const gait = self.motor.update(style, &self.transform, move, input.delta_time);
        _ = self.state_machine.requestState(switch (gait) {
            .idle => .idle,
            .walk => .walk,
            .run => .run,
        });
    }

    /// First person: moves along `move` (the move stick turned to the view) while facing
    /// `heading`, the view's; gun raised (Walk_Shoot / Run_Shoot); actions as `drive`.
    pub fn strafe(self: *Self, move: Vec3, heading: f32, input: *core.Input) void {
        self.processOneShotKeys(input);
        if (!self.state_machine.isInterruptible()) {
            self.moveDuringAction(input.delta_time);
            return;
        }
        const gait = self.motor.strafe(&self.transform, move, heading, input.delta_time);
        _ = self.state_machine.requestState(switch (gait) {
            .idle => .idle,
            .walk => .walk_shoot,
            .run => .run_shoot,
        });
    }

    /// Driven by code (a squad member), not the keys or gamepad: walks or runs along
    /// `move` (a direction on the ground, length 0 to 1) in the Wind Waker style.
    pub fn steer(self: *Self, move: Vec3, dt: f32) void {
        if (!self.state_machine.isInterruptible()) {
            self.moveDuringAction(dt);
            return;
        }
        const gait = self.motor.update(.wind_waker, &self.transform, move, dt);
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

    /// A jump carries on the way it was going at its speed; anything else stands still.
    fn moveDuringAction(self: *Self, dt: f32) void {
        switch (self.state_machine.getCurrentState()) {
            .jump, .jump_idle, .jump_land => self.motor.coast(&self.transform, dt),
            else => self.motor.stop(),
        }
    }

    /// The jump is three clips: Jump (takeoff) returns to Jump_Idle (in the air), which
    /// lands after `AIR_TIME`; Jump_Land returns to idle. Animation only, on a flat
    /// floor: the clips carry the lift.
    fn landAfterAirTime(self: *Self, dt: f32) void {
        if (self.state_machine.getCurrentState() != .jump_idle) {
            self.air_time = 0.0;
            return;
        }
        self.air_time += dt;
        if (self.air_time >= AIR_TIME) {
            self.state_machine.forceState(.jump_land);
        }
    }

    /// A walk or run plays at the rate that carries the feet at the motor's speed.
    fn matchClipRate(self: *Self) void {
        const clip_speed = clipSpeed(self.state_machine.getCurrentState()) orelse return;
        const speed = self.motor.speed;
        const rate = if (self.match_rate and speed > 0.0) speed / (clip_speed * self.scale) else 1.0;
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

    // Idle variants (looping); Jump_Idle is the jump in the air, landed by `landAfterAirTime`
    configs[@intFromEnum(ToonAnimation.idle_shoot)] = .{ .animation_id = 4, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.jump_idle)] = .{ .animation_id = 6, .repeat = Forever, .crossfade_in = 0.05, .interruptible = false, .return_state = null };

    // One-shot actions (play once, return to idle, not interruptible)
    configs[@intFromEnum(ToonAnimation.punch)] = .{ .animation_id = 9, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.jump)] = .{ .animation_id = 5, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .jump_idle };
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
