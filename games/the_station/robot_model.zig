//! The robot model from Blender (plan 021, phase C): `the-station/models/robot/robot.glb`,
//! built by `the-station/blender/build_robot.py`. Rigid parts on a node hierarchy, so the
//! animator poses nodes; no skinning.
//!
//! What the robot is doing (`Robot.task`) picks a clip, played through the animation
//! state machine with short crossfades: idle, walk (also while turning in place and
//! stepping on and off a ladder), push or push_left (push_high, push_high_left for a
//! control above the shoulders), with the arm nearer the camera
//! (`robot.usesLeftArm`; contact at 0.45 s, the gesture's effect time in `robot.zig`),
//! climb and ladder_hold on a ladder. The robot starts by
//! looking around, as if woken by the alarm.
//!
//! The model is in the-station's repo, not the engine's; without it the game draws the
//! box placeholder (`Robot.draw`).

const std = @import("std");
const core = @import("core");
const math = @import("math");

const room_kit = @import("room_kit.zig");
const robot_module = @import("robot.zig");
const Robot = robot_module.Robot;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const ModelInstance = core.ModelInstance;
const Shader = core.Shader;
const Mat4 = math.Mat4;
const vec4 = math.vec4;

const log = std.log.scoped(.robot_model);

pub const MODEL_PATH = "the-station/models/robot/robot.glb";

/// The robot's clips; each name is a glTF animation in the model.
const Clip = enum(u32) { idle, walk, push, push_left, push_high, push_high_left, look_around, startle, climb, ladder_hold };
const Fsm = core.AnimationStateMachine(Clip);

pub const RobotModel = struct {
    instance: *ModelInstance,
    fsm: Fsm,

    const Self = @This();

    /// Null, with a warning, when the model can't be loaded (no the-station checkout).
    pub fn load(context: core.Context, gpu: *GpuContext) ?Self {
        const instance = ModelInstance.initWithConfig(context, gpu, .{
            .name = "robot",
            .file_path = MODEL_PATH,
            .animator_type = .live_animator,
        }) catch |err| {
            log.warn("{s} not loaded ({s}); drawing the placeholder robot", .{ MODEL_PATH, @errorName(err) });
            return null;
        };
        const configs = stateConfigs(instance) catch |err| {
            log.warn("{s}: {s}; drawing the placeholder robot", .{ MODEL_PATH, @errorName(err) });
            instance.cleanUp();
            return null;
        };
        return .{ .instance = instance, .fsm = Fsm.init(configs, .look_around, instance) };
    }

    /// Plays the clip for what the robot is doing. The opening look-around plays out
    /// unless the robot starts walking.
    pub fn update(self: *Self, robot: *const Robot, dt: f32) !void {
        const wanted = clipFor(robot);
        const current = self.fsm.getCurrentState();
        const is_waking = current == .look_around or current == .startle;
        if (!(wanted == .idle and is_waking)) {
            _ = self.fsm.requestState(wanted);
        }
        try self.fsm.update(self.instance, dt);
    }

    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, robot: *const Robot, hatching: room_kit.Hatching) void {
        const transform = Mat4.fromTranslation(robot.position).mulMat4(&Mat4.fromRotationY(robot.yaw));
        self.instance.drawWithParams(frame, shader, transform, vec4(0.0, 0.0, hatching.strength, hatching.spacing));
    }

    pub fn cleanUp(self: *Self) void {
        self.instance.cleanUp();
    }
};

fn clipFor(robot: *const Robot) Clip {
    return switch (robot.task) {
        .idle => .idle,
        .walk, .turn, .mount, .dismount => .walk,
        .act => |act| switch (act.use.action) {
            .push => if (robot_module.usesLeftArm(act.use.facing)) .push_left else .push,
            .push_high => if (robot_module.usesLeftArm(act.use.facing)) .push_high_left else .push_high,
            .look => .idle,
        },
        .ladder => if (robot.isClimbing()) .climb else .ladder_hold,
    };
}

/// Each clip's glTF animation, found by name, with how it plays.
fn stateConfigs(instance: *const ModelInstance) ![Fsm.count]Fsm.StateConfig {
    var configs: [Fsm.count]Fsm.StateConfig = undefined;
    for (std.enums.values(Clip)) |clip| {
        const is_push = switch (clip) {
            .push, .push_left, .push_high, .push_high_left => true,
            .idle, .walk, .look_around, .startle, .climb, .ladder_hold => false,
        };
        const is_loop = clip == .idle or clip == .walk or clip == .climb or clip == .ladder_hold;
        configs[@intFromEnum(clip)] = .{
            .animation_id = try findAnimation(instance, @tagName(clip)),
            .repeat = if (is_loop) .Forever else .Once,
            .crossfade_in = if (is_push) 0.1 else 0.2,
            // The push plays to its end, so the hand reaches the button
            .interruptible = !is_push,
            .return_state = if (is_loop) null else .idle,
        };
    }
    return configs;
}

fn findAnimation(instance: *const ModelInstance, name: []const u8) !u32 {
    const animations = instance.gltf_asset.gltf.animations orelse return error.NoAnimations;
    for (animations, 0..) |animation, i| {
        if (animation.name) |animation_name| {
            if (std.mem.eql(u8, animation_name, name)) {
                return @intCast(i);
            }
        }
    }
    log.warn("{s}: no animation named {s}", .{ MODEL_PATH, name });
    return error.MissingAnimation;
}
