//! The robot model from Blender (plan 021, phase C): `the-station/models/robot/robot.glb`,
//! built by `the-station/blender/build_robot.py`. Rigid parts on a node hierarchy, so the
//! animator poses nodes; no skinning.
//!
//! What the robot is doing (`Robot.task`) picks a clip, played through the animation
//! state machine with short crossfades: idle, walk (also while turning in place), push
//! (its contact at 0.45 s matches the gesture's effect time in `robot.zig`). The robot
//! starts by looking around, as if woken by the alarm.
//!
//! The model is in the-station's repo, not the engine's; without it the game draws the
//! box placeholder (`Robot.draw`).

const std = @import("std");
const core = @import("core");
const math = @import("math");

const room = @import("room.zig");
const Robot = @import("robot.zig").Robot;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const ModelInstance = core.ModelInstance;
const Shader = core.Shader;
const Mat4 = math.Mat4;
const vec4 = math.vec4;

const log = std.log.scoped(.robot_model);

pub const MODEL_PATH = "the-station/models/robot/robot.glb";

/// The robot's clips; each name is a glTF animation in the model.
const Clip = enum(u32) { idle, walk, push, look_around, startle };
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

    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, robot: *const Robot, hatching: room.Hatching) void {
        const transform = Mat4.fromTranslation(robot.position).mulMat4(&Mat4.fromRotationY(robot.yaw));
        self.instance.drawWithParams(frame, shader, transform, vec4(0.0, 0.0, hatching.strength, hatching.spacing));
    }

    pub fn cleanUp(self: *Self) void {
        self.instance.cleanUp();
    }
};

fn clipFor(robot: *const Robot) Clip {
    return switch (robot.task) {
        .idle, .outside => .idle,
        .walk, .turn => .walk,
        .act => |act| switch (act.use.action) {
            .push => .push,
            .look => .idle,
        },
    };
}

/// Each clip's glTF animation, found by name, with how it plays.
fn stateConfigs(instance: *const ModelInstance) ![Fsm.count]Fsm.StateConfig {
    var configs: [Fsm.count]Fsm.StateConfig = undefined;
    for (std.enums.values(Clip)) |clip| {
        const is_loop = clip == .idle or clip == .walk;
        configs[@intFromEnum(clip)] = .{
            .animation_id = try findAnimation(instance, @tagName(clip)),
            .repeat = if (is_loop) .Forever else .Once,
            .crossfade_in = if (clip == .push) 0.1 else 0.2,
            // The push plays to its end, so the hand reaches the button
            .interruptible = clip != .push,
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
