const std = @import("std");
const core = @import("core");
const math = @import("math");

const Vec2 = math.Vec2;
const vec2 = math.vec2;
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

const SpacesuitStateMachine = core.AnimationStateMachine(SpacesuitStateEnum);

const path = "assets/models/Spacesuit/Spacesuit_converted.gltf";

const SpacesuitStateEnum = enum(u32) {
    death,
    gun_shoot,
    hit_recieve,
    hit_recieve_2,
    idle,
    idle_gun,
    idle_gun_pointing,
    idle_gun_shoot,
    idle_neutral,
    idle_sword,
    interact,
    kick_left,
    kick_right,
    punch_left,
    punch_right,
    roll,
    run,
    run_back,
    run_left,
    run_right,
    run_shoot,
    sword_slash,
    walk,
    wave,
};

fn buildStateConfigs() [SpacesuitStateMachine.count]SpacesuitStateMachine.StateConfig {
    const Forever = AnimationRepeatMode.Forever;
    const Once = AnimationRepeatMode.Once;

    var configs: [SpacesuitStateMachine.count]SpacesuitStateMachine.StateConfig = undefined;

    // Locomotion (looping, interruptible)
    configs[@intFromEnum(SpacesuitStateEnum.idle)] = .{ .animation_id = 4, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(SpacesuitStateEnum.walk)] = .{ .animation_id = 22, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(SpacesuitStateEnum.run)] = .{ .animation_id = 16, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(SpacesuitStateEnum.run_back)] = .{ .animation_id = 17, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(SpacesuitStateEnum.run_left)] = .{ .animation_id = 18, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(SpacesuitStateEnum.run_right)] = .{ .animation_id = 19, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(SpacesuitStateEnum.run_shoot)] = .{ .animation_id = 20, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };

    // Idle variants (looping, interruptible)
    configs[@intFromEnum(SpacesuitStateEnum.idle_gun)] = .{ .animation_id = 5, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(SpacesuitStateEnum.idle_gun_pointing)] = .{ .animation_id = 6, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(SpacesuitStateEnum.idle_gun_shoot)] = .{ .animation_id = 7, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(SpacesuitStateEnum.idle_neutral)] = .{ .animation_id = 8, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(SpacesuitStateEnum.idle_sword)] = .{ .animation_id = 9, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };

    // One-shot actions (play once, return to idle, not interruptible)
    configs[@intFromEnum(SpacesuitStateEnum.punch_left)] = .{ .animation_id = 13, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(SpacesuitStateEnum.punch_right)] = .{ .animation_id = 14, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(SpacesuitStateEnum.kick_left)] = .{ .animation_id = 11, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(SpacesuitStateEnum.kick_right)] = .{ .animation_id = 12, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(SpacesuitStateEnum.sword_slash)] = .{ .animation_id = 21, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(SpacesuitStateEnum.gun_shoot)] = .{ .animation_id = 1, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(SpacesuitStateEnum.roll)] = .{ .animation_id = 15, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(SpacesuitStateEnum.interact)] = .{ .animation_id = 10, .repeat = Once, .crossfade_in = 0.15, .interruptible = true, .return_state = .idle };
    configs[@intFromEnum(SpacesuitStateEnum.wave)] = .{ .animation_id = 23, .repeat = Once, .crossfade_in = 0.15, .interruptible = true, .return_state = .idle };

    // Reactions (play once, not interruptible)
    configs[@intFromEnum(SpacesuitStateEnum.hit_recieve)] = .{ .animation_id = 2, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(SpacesuitStateEnum.hit_recieve_2)] = .{ .animation_id = 3, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(SpacesuitStateEnum.death)] = .{ .animation_id = 0, .repeat = Once, .crossfade_in = 0.20, .interruptible = false, .return_state = null };

    return configs;
}

pub const Spacesuit = struct {
    model: *core.ModelInstance,
    shader: *core.Shader,
    position: Vec3 = vec3(5.0, 0.0, 5.0),
    direction: Vec2 = vec2(0.0, 0.0),
    scale: Vec3 = vec3(0.02, 0.02, 0.02),
    transform: core.Transform = core.Transform.identity(),
    rotation_speed: f32 = 2.0,
    /// Speeds in units per second (redfish moved a fixed step per frame with vsync off, so
    /// the speed depended on frame rate, ~0.1 units/s at 60 fps) and the ground movement.
    motor: character_control.Motor = .{ .walk_speed = 1.5, .run_speed = 4.5 },
    state_machine: SpacesuitStateMachine,

    const Self = @This();

    pub fn init(rm: *ResourceManager) !*Spacesuit {
        const allocator = rm.context.alloc;

        // level_01's animated_pbr is the same shader as core pbr
        const shader = try rm.createShader("src/core/shaders/pbr.wgsl", .{
            .vertex_buffers = &MeshPrimitive.vertex_buffer_layouts,
            .material = .pbr,
            .alpha_to_coverage = true,
        });

        const model = try rm.loadModel("spacesuit", path);

        const configs = buildStateConfigs();
        var fsm = SpacesuitStateMachine.init(configs, .idle, model);
        fsm.debug = true;

        const spacesuit = try allocator.create(Spacesuit);
        spacesuit.* = .{
            .model = model,
            .shader = shader,
            .state_machine = fsm,
        };

        spacesuit.transform.translation = spacesuit.position;
        spacesuit.transform.scale = spacesuit.scale;

        return spacesuit;
    }

    pub fn update(self: *Self, input: *Input) !void {
        try self.state_machine.update(self.model, input.delta_time);
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

        // Locomotion
        if (input.isDown(.w)) {
            const is_running = input.key_shift;
            const speed = if (is_running) self.motor.run_speed else self.motor.walk_speed;
            const fwd = self.transform.forward();
            self.transform.translation = self.transform.translation.sub(fwd.mulScalar(speed * dt));

            if (is_running) {
                _ = self.state_machine.requestState(.run);
            } else {
                _ = self.state_machine.requestState(.walk);
            }
        } else if (input.isDown(.s)) {
            const fwd = self.transform.forward();
            self.transform.translation = self.transform.translation.add(fwd.mulScalar(self.motor.walk_speed * dt));
            _ = self.state_machine.requestState(.run_back);
        } else {
            _ = self.state_machine.requestState(.idle);
        }
    }

    /// Analog control: walks or runs along `move` (a direction on the ground from the
    /// move stick, length 0 to 1) in the given style; actions as `processInput`.
    pub fn drive(self: *Self, move: Vec3, style: character_control.Style, input: *core.Input) void {
        self.processOneShotKeys(input);
        if (!self.state_machine.isInterruptible()) {
            self.motor.stop();
            return;
        }
        const gait = self.motor.update(style, &self.transform, move, input.delta_time);
        _ = self.state_machine.requestState(switch (gait) {
            .idle => .idle,
            .walk => .walk,
            .run => .run,
        });
    }

    fn processOneShotKeys(self: *Self, input: *core.Input) void {
        const one_shot_keys = .{
            .{ .key = .space, .anim = SpacesuitStateEnum.roll },
            .{ .key = .one, .anim = SpacesuitStateEnum.punch_left },
            .{ .key = .two, .anim = SpacesuitStateEnum.punch_right },
            .{ .key = .three, .anim = SpacesuitStateEnum.kick_left },
            .{ .key = .four, .anim = SpacesuitStateEnum.kick_right },
            .{ .key = .five, .anim = SpacesuitStateEnum.sword_slash },
            .{ .key = .six, .anim = SpacesuitStateEnum.gun_shoot },
        };

        inline for (one_shot_keys) |entry| {
            if (input.pressedOnce(entry.key)) {
                _ = self.state_machine.requestState(entry.anim);
            }
        }

        // The same actions on the gamepad's face buttons
        const one_shot_buttons = .{
            .{ .button = .a, .anim = SpacesuitStateEnum.roll },
            .{ .button = .x, .anim = SpacesuitStateEnum.punch_left },
            .{ .button = .b, .anim = SpacesuitStateEnum.kick_right },
            .{ .button = .y, .anim = SpacesuitStateEnum.sword_slash },
        };
        inline for (one_shot_buttons) |entry| {
            if (input.buttonPressedOnce(entry.button)) {
                _ = self.state_machine.requestState(entry.anim);
            }
        }
    }
};
