//! The robot (plan 021, phase B): what it is doing: standing, walking a path, turning to
//! a hotspot, using it, or on a ladder (stepping on, climbing, stepping off). Drawn as the
//! Blender model (`robot_model.zig`) or the box placeholder (`robot_placeholder.zig`).
//!
//! The robot's space: it faces +z at yaw 0 (toward the camera), its right hand is on -x,
//! y up from the floor.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const Action = @import("interaction.zig").Action;
const Path = @import("navigation.zig").Path;
const motion = core.motion;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

/// Meters per second.
const WALK_SPEED: f32 = 1.2;
/// Meters per second, up or down a ladder.
const CLIMB_SPEED: f32 = 0.6;
/// How fast it turns toward where it walks (`motion.dampAngle` rate).
const WALK_TURN_RATE: f32 = 10.0;
/// Radians per second when turning to face a hotspot.
const TURN_SPEED: f32 = 6.0;
/// Steps per second (each leg swings once per two steps).
const STEP_RATE: f32 = 3.5;

/// The push gesture: the arm rises, holds, and lowers. The hotspot's effect happens at
/// `effect`, when the hand is on the button.
const PUSH = Gesture{ .duration = 1.0, .effect = 0.45, .raise_end = 0.4, .lower_start = 0.6, .reach = std.math.pi / 2.0 };
/// The push to a control above the shoulders: the same, the arm higher.
const PUSH_HIGH = Gesture{ .duration = 1.0, .effect = 0.45, .raise_end = 0.4, .lower_start = 0.6, .reach = std.math.pi * 2.0 / 3.0 };
/// Looking: a pause facing the hotspot; no arm.
const LOOK = Gesture{ .duration = 0.6, .effect = 0.2, .raise_end = 0.0, .lower_start = 0.0, .reach = 0.0 };

const Gesture = struct {
    duration: f32,
    effect: f32,
    raise_end: f32,
    lower_start: f32,
    /// How far up the arm swings from hanging down, in radians (the placeholder's arm;
    /// the model's clips have their own).
    reach: f32,

    /// The arm's angle up from hanging at `time`, radians: up to `reach` and back.
    fn armAngle(self: Gesture, time: f32) f32 {
        return self.reach * self.armRaise(time);
    }

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

/// A ladder through the floors, with a stop on each floor it passes: where the robot
/// gets on and off.
pub const Ladder = struct {
    /// From the top down.
    stops: []const LadderStop,
    /// The robot's yaw on the ladder, facing it.
    facing: f32,
};

pub const LadderStop = struct {
    /// Where the robot stands on the ladder: on the rung at the floor, over a hole in it,
    /// or at the ladder's foot.
    position: Vec3,
    /// The floor beside it, where it steps on from and off to.
    exit: Vec3,
};

/// A ladder and one of its stops: where the robot gets on, climbs to, or gets off.
pub const AtStop = struct {
    ladder: Ladder,
    stop: usize,

    fn position(self: AtStop) Vec3 {
        return self.ladder.stops[self.stop].position;
    }

    fn exit(self: AtStop) Vec3 {
        return self.ladder.stops[self.stop].exit;
    }
};

pub const Direction = enum { up, down };

/// What the robot does when a walk ends.
pub const Arrival = union(enum) {
    stand,
    use: Use,
    /// Step onto the ladder at the stop (the walk ends at its exit).
    mount: AtStop,
};

/// Walking a path (`navigation.findPath`), toward `path.points[next]`.
pub const Walk = struct {
    path: Path,
    next: usize = 0,
    then: Arrival,
};

pub const Task = union(enum) {
    idle,
    walk: Walk,
    /// Turning to face the hotspot.
    turn: Use,
    /// The gesture, `time` seconds in.
    act: struct { use: Use, time: f32 },
    /// Stepping from the floor onto the ladder at the stop, then turning to face it.
    mount: AtStop,
    /// On the ladder: climbing toward the stop, or holding on there.
    ladder: AtStop,
    /// Stepping off the ladder at the stop to its exit; then the pending walk.
    dismount: AtStop,
};

pub const Robot = struct {
    position: Vec3,
    /// 0 faces +z (toward the camera).
    yaw: f32 = 0.0,
    task: Task = .idle,
    /// Walk cycle phase, radians; legs swing with its sine.
    walk_phase: f32 = 0.0,
    /// The last walk asked for while busy (a gesture, the ladder), started after.
    pending: ?Walk = null,

    const Self = @This();

    /// Walks `path`, then does `then`. During a gesture, after it, so a use isn't cut off
    /// before its effect; on the ladder, after reaching its stop (`climbTo`) and stepping
    /// off (the path starts at the stop's exit: `walkStart`).
    pub fn walk(self: *Self, path: Path, then: Arrival) void {
        const next: Walk = .{ .path = path, .then = then };
        switch (self.task) {
            .act, .mount, .dismount, .ladder => self.pending = next,
            .idle, .walk, .turn => {
                self.pending = null;
                self.task = .{ .walk = next };
            },
        }
    }

    /// Where a walk asked for now starts from: the stop's exit while on the ladder.
    pub fn walkStart(self: *const Self) Vec3 {
        if (self.currentLadder()) |at| {
            return at.exit();
        }
        return self.position;
    }

    /// The ladder and the stop it is getting on at, climbing to, or getting off at; null
    /// off the ladder.
    pub fn currentLadder(self: *const Self) ?AtStop {
        return switch (self.task) {
            .mount, .ladder, .dismount => |at| at,
            .idle, .walk, .turn, .act => null,
        };
    }

    /// The next stop up or down from where the robot is on the ladder, or null (the end
    /// of the ladder, or off it).
    pub fn nextStop(self: *const Self, direction: Direction) ?usize {
        const at = switch (self.task) {
            .ladder => |at| at,
            .idle, .walk, .turn, .act, .mount, .dismount => return null,
        };
        const y = self.position.y;
        return switch (direction) {
            // Stops go from the top down: the last one above, the first one below
            .up => {
                var found: ?usize = null;
                for (at.ladder.stops, 0..) |stop, index| {
                    if (stop.position.y > y) {
                        found = index;
                    }
                }
                return found;
            },
            .down => for (at.ladder.stops, 0..) |stop, index| {
                if (stop.position.y < y) {
                    break index;
                }
            } else null,
        };
    }

    /// Climbs to the next stop up or down, if there is one. Only on the ladder.
    pub fn climb(self: *Self, direction: Direction) void {
        if (self.nextStop(direction)) |stop| {
            self.pending = null;
            self.climbTo(stop);
        }
    }

    /// Climbs to `stop` (where a walk asked for meanwhile steps off). Only on the ladder.
    pub fn climbTo(self: *Self, stop: usize) void {
        switch (self.task) {
            .ladder => |at| self.task = .{ .ladder = .{ .ladder = at.ladder, .stop = stop } },
            .idle, .walk, .turn, .act, .mount, .dismount => {},
        }
    }

    /// On the ladder and moving up or down it.
    pub fn isClimbing(self: *const Self) bool {
        return switch (self.task) {
            .ladder => |at| self.position.y != at.position().y,
            .idle, .walk, .turn, .act, .mount, .dismount => false,
        };
    }

    pub fn isActing(self: *const Self) bool {
        return self.task == .act;
    }

    /// Advances the task. Returns the hotspot whose effect happens this frame, if any.
    pub fn update(self: *Self, dt: f32) ?usize {
        switch (self.task) {
            .idle => self.walk_phase = 0.0,
            .walk => |walk_task| self.updateWalk(walk_task, dt),
            .turn => |use| {
                self.yaw = motion.moveTowardAngle(self.yaw, use.facing, TURN_SPEED, dt);
                if (@abs(motion.wrapAngle(use.facing - self.yaw)) < 1e-4) {
                    self.task = .{ .act = .{ .use = use, .time = 0.0 } };
                }
            },
            .act => |act| return self.updateAct(act.use, act.time, dt),
            .mount => |at| self.updateMount(at, dt),
            .ladder => |at| self.updateLadder(at, dt),
            .dismount => |at| self.updateDismount(at, dt),
        }
        return null;
    }

    /// Steps along the path, turning to face the way it goes; at its end does what
    /// `then` says.
    fn updateWalk(self: *Self, walk_task: Walk, dt: f32) void {
        if (!self.stepToward(walk_task.path.points[walk_task.next], dt)) {
            return;
        }
        if (walk_task.next + 1 < walk_task.path.len) {
            var next = walk_task;
            next.next += 1;
            self.task = .{ .walk = next };
            return;
        }
        self.walk_phase = 0.0;
        self.task = switch (walk_task.then) {
            .stand => .idle,
            .use => |use| .{ .turn = use },
            .mount => |at| .{ .mount = at },
        };
    }

    /// Onto the ladder at the stop, then turns to it; steps straight off again if a walk
    /// was asked for meanwhile.
    fn updateMount(self: *Self, at: AtStop, dt: f32) void {
        if (!self.stepToward(at.position(), dt)) {
            return;
        }
        self.walk_phase = 0.0;
        if (self.pending != null) {
            self.task = .{ .dismount = at };
            return;
        }
        self.yaw = motion.moveTowardAngle(self.yaw, at.ladder.facing, TURN_SPEED, dt);
        if (@abs(motion.wrapAngle(at.ladder.facing - self.yaw)) < 1e-4) {
            self.task = .{ .ladder = at };
        }
    }

    /// Climbs toward the stop; there, with a walk waiting, steps off.
    fn updateLadder(self: *Self, at: AtStop, dt: f32) void {
        self.position = motion.moveToward(self.position, at.position(), CLIMB_SPEED, dt);
        const is_at_stop = self.position.y == at.position().y;
        if (is_at_stop and self.pending != null) {
            self.task = .{ .dismount = at };
        }
    }

    fn updateDismount(self: *Self, at: AtStop, dt: f32) void {
        if (!self.stepToward(at.exit(), dt)) {
            return;
        }
        self.walk_phase = 0.0;
        self.task = .idle;
        if (self.pending) |pending| {
            self.pending = null;
            self.task = .{ .walk = pending };
        }
    }

    /// One frame of walking toward `goal`, facing the way it goes. True on arrival.
    fn stepToward(self: *Self, goal: Vec3, dt: f32) bool {
        const to_goal = goal.sub(self.position);
        if (@sqrt(to_goal.x * to_goal.x + to_goal.z * to_goal.z) > 0.01) {
            const travel_yaw = std.math.atan2(to_goal.x, to_goal.z);
            self.yaw = motion.dampAngle(self.yaw, travel_yaw, WALK_TURN_RATE, dt);
        }
        self.position = motion.moveToward(self.position, goal, WALK_SPEED, dt);
        self.walk_phase += STEP_RATE * std.math.pi * dt;
        return self.position.x == goal.x and self.position.y == goal.y and self.position.z == goal.z;
    }

    /// Runs the gesture; returns the hotspot when the gesture passes its effect time.
    fn updateAct(self: *Self, use: Use, time: f32, dt: f32) ?usize {
        const gesture = gestureFor(use.action);
        const next_time = time + dt;
        if (next_time >= gesture.duration) {
            self.task = .idle;
            if (self.pending) |pending| {
                self.pending = null;
                self.task = .{ .walk = pending };
            }
        } else {
            self.task = .{ .act = .{ .use = use, .time = next_time } };
        }
        const is_effect_frame = time < gesture.effect and next_time >= gesture.effect;
        return if (is_effect_frame) use.hotspot else null;
    }

    /// The placeholder's pushing arm, raised from hanging, in radians
    /// (`robot_placeholder.zig`; the model's clips have their own).
    pub fn armAngle(self: *const Self) f32 {
        return switch (self.task) {
            .act => |act| gestureFor(act.use.action).armAngle(act.time),
            .idle, .walk, .turn, .mount, .ladder, .dismount => 0.0,
        };
    }
};

/// Whether the robot pushes with its left arm when facing `facing`: when its right side
/// is turned away from the camera (facing the left wall), so the push shows. Its right
/// side points along (-cos yaw, 0, sin yaw); toward the back wall either arm shows, and
/// it uses the right.
pub fn usesLeftArm(facing: f32) bool {
    return @sin(facing) < -0.1;
}

fn gestureFor(action: Action) Gesture {
    return switch (action) {
        .push => PUSH,
        .push_high => PUSH_HIGH,
        .look => LOOK,
    };
}

fn smoothstep(t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    return x * x * (3.0 - 2.0 * x);
}
