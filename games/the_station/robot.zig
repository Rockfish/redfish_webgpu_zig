//! The placeholder robot (plan 021, phase B): stacked boxes in the shape of the drawing
//! (box head with two round eyes, box body, thin arms and legs, flat feet), and what it
//! is doing: standing, walking somewhere, turning to a hotspot, or using it.
//!
//! The robot's space: it faces +z at yaw 0 (toward the camera), its right hand is on -x,
//! y up from the floor. The parts are rigid, each turned about a joint (hips, shoulders),
//! as the Blender model will be.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const room = @import("room.zig");
const Action = @import("interaction.zig").Action;
const Frame = core.Frame;
const Shader = core.Shader;
const motion = core.motion;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

/// Meters per second.
const WALK_SPEED: f32 = 1.2;
/// How fast it turns toward where it walks (`motion.dampAngle` rate).
const WALK_TURN_RATE: f32 = 10.0;
/// Radians per second when turning to face a hotspot.
const TURN_SPEED: f32 = 6.0;
/// Steps per second (each leg swings once per two steps).
const STEP_RATE: f32 = 3.5;
/// Leg swing either way, in radians.
const LEG_SWING: f32 = 0.45;

/// The push gesture: the arm rises, holds, and lowers. The hotspot's effect happens at
/// `effect`, when the hand is on the button.
const PUSH = Gesture{ .duration = 1.0, .effect = 0.45, .raise_end = 0.4, .lower_start = 0.6 };
/// Looking: a pause facing the hotspot; no arm.
const LOOK = Gesture{ .duration = 0.6, .effect = 0.2, .raise_end = 0.0, .lower_start = 0.0 };

const Gesture = struct {
    duration: f32,
    effect: f32,
    raise_end: f32,
    lower_start: f32,

    /// 0..1, how far the arm is raised at `time`.
    fn armRaise(self: Gesture, time: f32) f32 {
        if (self.raise_end == 0.0) {
            return 0.0;
        }
        if (time < self.raise_end) {
            return smoothstep(time / self.raise_end);
        }
        if (time < self.lower_start) {
            return 1.0;
        }
        return 1.0 - smoothstep((time - self.lower_start) / (self.duration - self.lower_start));
    }
};

/// Using a hotspot: which one, how to face it, and the gesture.
pub const Use = struct {
    hotspot: usize,
    facing: f32,
    action: Action,
};

pub const Task = union(enum) {
    idle,
    /// Walking to `target`, then using a hotspot if `then` is set.
    walk: struct { target: Vec3, then: ?Use },
    /// Turning to face the hotspot.
    turn: Use,
    /// The gesture, `time` seconds in.
    act: struct { use: Use, time: f32 },
};

pub const Robot = struct {
    position: Vec3,
    /// 0 faces +z (toward the camera).
    yaw: f32 = 0.0,
    task: Task = .idle,
    /// Walk cycle phase, radians; legs swing with its sine.
    walk_phase: f32 = 0.0,

    const Self = @This();

    /// Walk to a floor point. Ignored during a gesture, so a use isn't cut off before its
    /// effect.
    pub fn walkTo(self: *Self, target: Vec3) void {
        if (self.isActing()) {
            return;
        }
        self.task = .{ .walk = .{ .target = target, .then = null } };
    }

    /// Walk to `stand_point`, turn, and use the hotspot. Ignored during a gesture.
    pub fn useAt(self: *Self, stand_point: Vec3, use: Use) void {
        if (self.isActing()) {
            return;
        }
        self.task = .{ .walk = .{ .target = stand_point, .then = use } };
    }

    pub fn isActing(self: *const Self) bool {
        return self.task == .act;
    }

    /// Advances the task. Returns the hotspot whose effect happens this frame, if any.
    pub fn update(self: *Self, dt: f32) ?usize {
        switch (self.task) {
            .idle => {
                self.walk_phase = 0.0;
                return null;
            },
            .walk => |walk| {
                self.updateWalk(walk.target, walk.then, dt);
                return null;
            },
            .turn => |use| {
                self.yaw = motion.moveTowardAngle(self.yaw, use.facing, TURN_SPEED, dt);
                if (@abs(motion.wrapAngle(use.facing - self.yaw)) < 1e-4) {
                    self.task = .{ .act = .{ .use = use, .time = 0.0 } };
                }
                return null;
            },
            .act => |act| {
                return self.updateAct(act.use, act.time, dt);
            },
        }
    }

    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, shapes: *const room.Room) void {
        const root = Mat4.fromTranslation(self.position).mulMat4(&Mat4.fromRotationY(self.yaw));
        const leg_angle = @sin(self.walk_phase) * LEG_SWING;
        const bob = @abs(@sin(self.walk_phase)) * 0.03;
        const arm_raise = self.armRaise();

        const body = room.grey(0.72);
        const limbs = room.grey(0.35);
        const parts = [_]room.Part{
            .{ .shape = shapes.cube, .model = limb(root, vec3(0.12, 0.6, 0.0), leg_angle, vec3(0.08, 0.6, 0.08)), .color = limbs },
            .{ .shape = shapes.cube, .model = limb(root, vec3(-0.12, 0.6, 0.0), -leg_angle, vec3(0.08, 0.6, 0.08)), .color = limbs },
            .{ .shape = shapes.cube, .model = foot(root, vec3(0.12, 0.6, 0.0), leg_angle), .color = limbs },
            .{ .shape = shapes.cube, .model = foot(root, vec3(-0.12, 0.6, 0.0), -leg_angle), .color = limbs },
            .{ .shape = shapes.cube, .model = part(root, vec3(0.0, 0.84 + bob, 0.0), vec3(0.5, 0.45, 0.38)), .color = body },
            .{ .shape = shapes.cube, .model = part(root, vec3(0.0, 1.1 + bob, 0.0), vec3(0.08, 0.08, 0.08)), .color = limbs },
            .{ .shape = shapes.cube, .model = part(root, vec3(0.0, 1.28 + bob, 0.0), vec3(0.46, 0.3, 0.34)), .color = body },
            .{ .shape = shapes.cylinder, .model = eye(root, vec3(0.1, 1.29 + bob, 0.16)), .color = room.grey(0.95), .emissive = 0.8 },
            .{ .shape = shapes.cylinder, .model = eye(root, vec3(-0.1, 1.29 + bob, 0.16)), .color = room.grey(0.95), .emissive = 0.8 },
            // Left arm swings opposite the left leg; the right arm pushes
            .{ .shape = shapes.cube, .model = limb(root, vec3(0.3, 1.0 + bob, 0.0), -leg_angle * 0.6, vec3(0.07, 0.45, 0.07)), .color = limbs },
            .{ .shape = shapes.cube, .model = limb(root, vec3(-0.3, 1.0 + bob, 0.0), leg_angle * 0.6 - arm_raise * std.math.pi / 2.0, vec3(0.07, 0.45, 0.07)), .color = limbs },
        };
        for (parts) |robot_part| {
            room.drawPart(frame, shader, robot_part);
        }
    }

    /// Steps toward `target`, turning to face the way it goes; on arrival turns to the
    /// hotspot, or stands.
    fn updateWalk(self: *Self, target: Vec3, then: ?Use, dt: f32) void {
        const to_target = target.sub(self.position);
        if (to_target.length() > 0.01) {
            const travel_yaw = std.math.atan2(to_target.x, to_target.z);
            self.yaw = motion.dampAngle(self.yaw, travel_yaw, WALK_TURN_RATE, dt);
        }
        self.position = motion.moveToward(self.position, target, WALK_SPEED, dt);
        self.walk_phase += STEP_RATE * std.math.pi * dt;

        if (self.position.x == target.x and self.position.z == target.z) {
            self.walk_phase = 0.0;
            self.task = if (then) |use| .{ .turn = use } else .idle;
        }
    }

    /// Runs the gesture; returns the hotspot when the gesture passes its effect time.
    fn updateAct(self: *Self, use: Use, time: f32, dt: f32) ?usize {
        const gesture = gestureFor(use.action);
        const next_time = time + dt;
        if (next_time >= gesture.duration) {
            self.task = .idle;
        } else {
            self.task = .{ .act = .{ .use = use, .time = next_time } };
        }
        const is_effect_frame = time < gesture.effect and next_time >= gesture.effect;
        return if (is_effect_frame) use.hotspot else null;
    }

    fn armRaise(self: *const Self) f32 {
        return switch (self.task) {
            .act => |act| gestureFor(act.use.action).armRaise(act.time),
            .idle, .walk, .turn => 0.0,
        };
    }
};

fn gestureFor(action: Action) Gesture {
    return switch (action) {
        .push => PUSH,
        .look => LOOK,
    };
}

/// A box centered at `center` in the robot's space.
fn part(root: Mat4, center: Vec3, size: Vec3) Mat4 {
    return root.mulMat4(&room.box(center, size));
}

/// A box hanging from `joint`, turned about x by `angle` (positive swings it backward,
/// negative forward and up).
fn limb(root: Mat4, joint: Vec3, angle: f32, size: Vec3) Mat4 {
    const hang = room.box(vec3(0.0, -size.y / 2.0, 0.0), size);
    return root.mulMat4(&Mat4.fromTranslation(joint)).mulMat4(&Mat4.fromRotationX(angle)).mulMat4(&hang);
}

/// A flat foot at the bottom of the leg hanging from `hip`, a little forward.
fn foot(root: Mat4, hip: Vec3, angle: f32) Mat4 {
    const sole = room.box(vec3(0.0, -0.57, 0.04), vec3(0.14, 0.06, 0.24));
    return root.mulMat4(&Mat4.fromTranslation(hip)).mulMat4(&Mat4.fromRotationX(angle)).mulMat4(&sole);
}

/// A round eye on the head's front, looking along +z.
fn eye(root: Mat4, base: Vec3) Mat4 {
    return root.mulMat4(&room.cylinderModel(base, .z, 0.12, 0.04));
}

fn smoothstep(t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    return x * x * (3.0 - 2.0 * x);
}
