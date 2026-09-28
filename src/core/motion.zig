//! Time-based, goal-seeking motion: patterns that pursue a goal over many frames (plan
//! 016). `movement.zig` applies instantaneous, input-driven steps; these hold their own
//! state and feed their result to a `Movement`, a position, or a rotation, without changing
//! how `Movement` works.
//!
//! | Pattern       | State         | Result                                        |
//! |---------------|---------------|-----------------------------------------------|
//! | `SmoothFollow`| position, aim | damped camera position and look-at point      |
//! | `dampLookAt`  | none          | rotation turned part way toward a focus       |
//! | `moveToward`  | none          | position stepped toward a goal, no overshoot  |
//! | `dampVec3`    | none          | vector moved part way toward a goal           |
//! | `dampQuat`    | none          | rotation turned part way toward a goal        |
//!
//! Everything damped here goes through `dampAlpha`, which makes damping frame-rate
//! independent: the common `lerp(current, goal, k * dt)` converges at a different speed at
//! 30 and 120 fps; `lerp(current, goal, dampAlpha(rate, dt))` does not.

const std = @import("std");
const math = @import("math");
const Movement = @import("movement.zig").Movement;

const Vec3 = math.Vec3;
const Quat = math.Quat;

/// A follower (usually a camera) that trails a moving followee: it sits at
/// `followee + offset` and looks at the followee, both damped, so it eases after the
/// followee instead of being fixed to it. At a steady followee speed `v`, the follower
/// lags by about `v / rate`.
pub const SmoothFollow = struct {
    /// Approach rate per second; higher is snappier. About `1 / rate` seconds to close
    /// 63% of a gap.
    rate: f32,
    /// Where the follower sits relative to the followee, in world space.
    offset: Vec3,
    /// Damped follower position.
    position: Vec3,
    /// Damped look-at point.
    aim: Vec3,

    const Self = @This();

    /// Starts in place (at `followee + offset`, looking at the followee), so there is no
    /// swoop on the first frame.
    pub fn init(followee: Vec3, offset: Vec3, rate: f32) Self {
        return .{
            .rate = rate,
            .offset = offset,
            .position = followee.add(offset),
            .aim = followee,
        };
    }

    /// Moves the damped position and aim toward the followee and applies them to
    /// `movement` (position, and a look at the aim point).
    pub fn update(self: *Self, movement: *Movement, followee: Vec3, dt: f32) void {
        self.position = dampVec3(self.position, followee.add(self.offset), self.rate, dt);
        self.aim = dampVec3(self.aim, followee, self.rate, dt);
        movement.reset(self.position, self.aim);
    }
};

/// `rotation` turned part way toward looking from `position` at `focus`, as a turret or
/// head that settles on its target instead of snapping. With `up` as the up direction; the
/// result looks down its −Z axis, as `Transform.lookAt`.
pub fn dampLookAt(rotation: Quat, position: Vec3, focus: Vec3, up: Vec3, rate: f32, dt: f32) Quat {
    const desired = Quat.lookAtOrientation(position, focus, up);
    return dampQuat(rotation, desired, rate, dt);
}

/// `current` moved toward `target` by at most `max_speed * dt`. Arrives exactly (returns
/// `target`) instead of overshooting, and stays there on later calls.
pub fn moveToward(current: Vec3, target: Vec3, max_speed: f32, dt: f32) Vec3 {
    const to_target = target.sub(current);
    const distance = to_target.length();
    const step = max_speed * dt;

    if (distance <= step or distance == 0.0) {
        return target;
    }
    return current.add(to_target.mulScalar(step / distance));
}

/// `current` moved part way toward `target`: frame-rate independent exponential approach.
pub fn dampVec3(current: Vec3, target: Vec3, rate: f32, dt: f32) Vec3 {
    return current.lerp(target, dampAlpha(rate, dt));
}

/// `current` turned part way toward `target` (shortest arc), frame-rate independent.
pub fn dampQuat(current: Quat, target: Quat, rate: f32, dt: f32) Quat {
    return current.slerp(target, dampAlpha(rate, dt));
}

/// Fraction of the remaining distance to close this frame. Frame-rate independent: two
/// steps of `dt` close the same total as one step of `2 * dt`, because
/// `(1 - a(dt))² = e^(-2·rate·dt) = 1 - a(2·dt)`. `rate` is per second; higher is snappier.
pub fn dampAlpha(rate: f32, dt: f32) f32 {
    return 1.0 - @exp(-rate * dt);
}

test "dampAlpha: no time closes nothing, long times close almost everything" {
    try std.testing.expectEqual(@as(f32, 0.0), dampAlpha(5.0, 0.0));
    try std.testing.expect(dampAlpha(5.0, 10.0) > 0.9999);
    try std.testing.expect(dampAlpha(10.0, 0.1) > dampAlpha(5.0, 0.1));
}

test "dampVec3: one second lands in the same place at 10, 60, and 144 fps" {
    const start = Vec3.init(0.0, 0.0, 0.0);
    const goal = Vec3.init(10.0, -4.0, 2.0);
    const rate: f32 = 3.0;

    const at_10 = dampSteps(start, goal, rate, 10);
    const at_60 = dampSteps(start, goal, rate, 60);
    const at_144 = dampSteps(start, goal, rate, 144);

    try expectVec3ApproxEq(at_60, at_10, 1e-4);
    try expectVec3ApproxEq(at_60, at_144, 1e-4);

    // And it's where the closed form says: 1 - e^(-rate * 1 s) of the way
    const expected = start.lerp(goal, 1.0 - @exp(-rate));
    try expectVec3ApproxEq(expected, at_60, 1e-4);
}

test "moveToward: steps at max speed, arrives exactly, never overshoots" {
    const start = Vec3.init(0.0, 0.0, 0.0);
    const goal = Vec3.init(3.0, 0.0, 4.0); // 5 units away

    // One step of speed 2 for 1 s covers 2 units along the line
    const one_step = moveToward(start, goal, 2.0, 1.0);
    try expectVec3ApproxEq(Vec3.init(1.2, 0.0, 1.6), one_step, 1e-6);

    // A step longer than the remaining distance lands on the goal, not past it
    try expectVec3ApproxEq(goal, moveToward(one_step, goal, 10.0, 1.0), 0.0);

    // At the goal it stays there
    try expectVec3ApproxEq(goal, moveToward(goal, goal, 2.0, 1.0), 0.0);

    // Many small steps never pass the goal
    var position = start;
    for (0..100) |_| {
        position = moveToward(position, goal, 2.0, 0.1);
        try std.testing.expect(position.distance(start) <= goal.distance(start) + 1e-5);
    }
    try expectVec3ApproxEq(goal, position, 0.0);
}

test "SmoothFollow: starts in place, closes on a stationary followee without passing it" {
    const offset = Vec3.init(2.0, 4.0, 4.0);
    var follow = SmoothFollow.init(Vec3.init(0.0, 0.0, 0.0), offset, 5.0);
    var movement = Movement.init(follow.position, follow.aim);

    // The followee jumps; the follower eases after it
    const followee = Vec3.init(10.0, 0.0, 0.0);
    const goal = followee.add(offset);
    var last_gap = follow.position.distance(goal);
    for (0..120) |_| {
        follow.update(&movement, followee, 1.0 / 60.0);
        const gap = follow.position.distance(goal);
        try std.testing.expect(gap <= last_gap); // never moves away, never overshoots
        last_gap = gap;
    }
    try std.testing.expect(last_gap < 0.01);

    // The controller holds the damped pose and looks at the damped aim
    try expectVec3ApproxEq(follow.position, movement.getPosition(), 1e-6);
    try expectVec3ApproxEq(follow.aim, movement.getTarget(), 1e-6);
}

test "dampLookAt: turns part way, then settles on the focus" {
    const position = Vec3.init(0.0, 0.0, 0.0);
    const focus = Vec3.init(5.0, 0.0, 0.0); // +X
    const up = Vec3.init(0.0, 1.0, 0.0);
    const looking_down_minus_z = Quat.Identity;

    // Part way: forward has turned from -Z toward +X but not all the way
    const partly = dampLookAt(looking_down_minus_z, position, focus, up, 5.0, 0.05);
    const partly_forward = partly.forward();
    try std.testing.expect(partly_forward.x > 0.0 and partly_forward.x < 0.99);

    // Long enough: facing the focus
    var rotation = looking_down_minus_z;
    for (0..120) |_| {
        rotation = dampLookAt(rotation, position, focus, up, 5.0, 1.0 / 60.0);
    }
    try expectVec3ApproxEq(Vec3.init(1.0, 0.0, 0.0), rotation.forward(), 1e-3);
}

fn dampSteps(start: Vec3, goal: Vec3, rate: f32, steps_per_second: u32) Vec3 {
    const dt = 1.0 / @as(f32, @floatFromInt(steps_per_second));
    var position = start;
    for (0..steps_per_second) |_| {
        position = dampVec3(position, goal, rate, dt);
    }
    return position;
}

fn expectVec3ApproxEq(expected: Vec3, actual: Vec3, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.z, actual.z, tolerance);
}
