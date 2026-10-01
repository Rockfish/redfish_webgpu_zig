//! Time-based, goal-seeking motion: patterns that pursue a goal over many frames (plan
//! 016). `movement.zig` applies instantaneous, input-driven steps; these hold their own
//! state and feed their result to a `Movement`, a position, or a rotation, without changing
//! how `Movement` works.
//!
//! | Pattern       | State         | Result                                        |
//! |---------------|---------------|-----------------------------------------------|
//! | `SmoothFollow`| position, aim | damped camera position and look-at point      |
//! | `PathFollow`  | distance      | position moving along waypoints at a speed    |
//! | `Shake`       | trauma, time  | offset added to the frame's view, after it    |
//! | `YawPitchAim` | yaw, pitch    | aim on two axes with speeds and limits        |
//! | `moveTowardAngle` | none      | angle stepped toward a goal, the short way    |
//! | `dampAngle`   | none          | angle moved part way toward a goal            |
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
const RenderContext = @import("render_context.zig").RenderContext;

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
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

/// Camera shake for impacts and explosions, with the trauma model (Squirrel Eiserloh,
/// "Math for Game Programmers: Juicing Your Cameras With Math", GDC 2016): `addTrauma` on a
/// hit; trauma (0 to 1) wears off at `decay` per second; the shake's strength is trauma²,
/// so small hits barely move the camera, big ones do, and the fade-out ends softly.
///
/// The shake is an offset applied to the frame's view after the camera controller has
/// run (`Offset.apply` on the `RenderContext`), never to the controller: its position
/// and target stay where the game put them, and the shake stops exactly when trauma
/// reaches 0.
pub const Shake = struct {
    /// 0 (calm) to 1 (the most shake).
    trauma: f32 = 0.0,
    /// Trauma lost per second: a full shake lasts `1 / decay` seconds.
    decay: f32 = 1.0,
    /// Offset at trauma 1, in world units along each axis.
    max_offset: f32 = 0.3,
    /// Rotation at trauma 1, in radians about each of the view's axes.
    max_angle: f32 = 0.05,
    /// How fast the shake wiggles, in Hz.
    frequency: f32 = 12.0,
    /// Seconds since the shake started; drives the noise.
    time: f32 = 0.0,

    const Self = @This();

    /// How far the camera is shaken this frame.
    pub const Offset = struct {
        /// World-space move of the camera.
        translation: Vec3,
        /// Turn about the view's own axes, in radians: x pitch, y yaw, z roll.
        rotation: Vec3,

        pub const none: Offset = .{ .translation = Vec3.Zero, .rotation = Vec3.Zero };

        /// `context` seen from the shaken camera: moved by `translation`, then turned by
        /// `rotation` about its own axes. The camera itself isn't touched.
        pub fn apply(self: Offset, context: RenderContext) RenderContext {
            // The camera's world transform becomes move * camera * turn, so the view (its
            // inverse) becomes turn⁻¹ * view * move⁻¹.
            const move_back = Mat4.fromTranslation(self.translation.mulScalar(-1.0));
            const turn_back = Mat4.fromAxisAngle(Vec3.init(0.0, 0.0, 1.0), -self.rotation.z)
                .mulMat4(&Mat4.fromAxisAngle(Vec3.init(0.0, 1.0, 0.0), -self.rotation.y))
                .mulMat4(&Mat4.fromAxisAngle(Vec3.init(1.0, 0.0, 0.0), -self.rotation.x));
            const view = turn_back.mulMat4(&context.view).mulMat4(&move_back);

            var shaken = context;
            shaken.view = view;
            shaken.projection_view = context.projection.mulMat4(&view);
            shaken.view_position = context.view_position.add(self.translation);
            return shaken;
        }
    };

    /// A hit: more trauma, at most 1.
    pub fn addTrauma(self: *Self, amount: f32) void {
        self.trauma = @min(self.trauma + amount, 1.0);
    }

    /// Advances the shake by `dt` and returns this frame's offset (`Offset.none` once
    /// trauma is gone).
    pub fn update(self: *Self, dt: f32) Offset {
        self.trauma = @max(self.trauma - self.decay * dt, 0.0);
        if (self.trauma == 0.0) {
            self.time = 0.0;
            return .none;
        }
        self.time += dt;

        const strength = self.trauma * self.trauma;
        const phase = self.time * self.frequency;
        const move = self.max_offset * strength;
        const turn = self.max_angle * strength;
        return .{
            .translation = Vec3.init(shakeNoise(0, phase) * move, shakeNoise(1, phase) * move, shakeNoise(2, phase) * move),
            .rotation = Vec3.init(shakeNoise(3, phase) * turn, shakeNoise(4, phase) * turn, shakeNoise(5, phase) * turn),
        };
    }
};

/// Smooth noise in -1..1 for channel `channel` at `phase` (time × frequency): three sines
/// whose frequencies aren't whole multiples of each other, so the sum doesn't visibly
/// repeat, each channel shifted so the axes move independently. Smooth where random
/// numbers per frame would jitter, and the same at any frame rate.
fn shakeNoise(channel: u32, phase: f32) f32 {
    const shift = @as(f32, @floatFromInt(channel)) * 1.7;
    const tau = 2.0 * std.math.pi;
    return 0.5 * @sin(tau * phase + shift) +
        0.3 * @sin(tau * phase * 2.13 + shift * 2.9) +
        0.2 * @sin(tau * phase * 4.37 + shift * 5.3);
}

/// A position moving along waypoints at a steady speed: a scripted camera flythrough, a
/// patrol route, a moving platform. Progress is distance traveled along the path, not
/// time, so the speed is the same however the points are spaced.
///
/// `shape` joins the points with straight segments or with a Catmull-Rom curve through
/// them; `repeat` says what happens at the end. Allocates nothing: `points` belongs to the
/// caller and must outlive this. Segment lengths are recomputed on each call, which is
/// cheap for the tens of points a path has.
pub const PathFollow = struct {
    /// At least two.
    points: []const Vec3,
    /// Units per second along the path.
    speed: f32,
    shape: Shape = .linear,
    repeat: Repeat = .once,
    /// Distance traveled from the first point, 0 to `length()`.
    distance: f32 = 0.0,
    /// 1 moving toward the last point, -1 toward the first (only `ping_pong` turns back).
    heading: f32 = 1.0,
    /// Set when a `.once` path reaches its last point; `update` then stays there.
    finished: bool = false,

    const Self = @This();

    pub const Shape = enum {
        /// Straight segments; the direction changes abruptly at each point.
        linear,
        /// A smooth curve through every point: each segment is a cubic Hermite curve
        /// whose tangent at a point is `(next - previous) / 2`, the same basis as glTF's
        /// cubic-spline animation (animator.zig) with tangents taken from the neighbors.
        catmull_rom,
    };

    pub const Repeat = enum {
        /// Stop at the last point.
        once,
        /// Go on from the last point back to the first: the path is closed.
        loop,
        /// Turn back at each end.
        ping_pong,
    };

    /// Moves `speed * dt` along the path and returns the new position.
    pub fn update(self: *Self, dt: f32) Vec3 {
        const total = self.length();
        if (self.finished or total == 0.0) {
            return self.position();
        }

        self.distance += self.heading * self.speed * dt;
        switch (self.repeat) {
            .once => if (self.distance >= total) {
                self.distance = total;
                self.finished = true;
            },
            .loop => self.distance = @mod(self.distance, total),
            .ping_pong => {
                // Fold back into 0..total, turning around at each end passed
                while (self.distance > total or self.distance < 0.0) {
                    if (self.distance > total) {
                        self.distance = 2.0 * total - self.distance;
                        self.heading = -1.0;
                    } else {
                        self.distance = -self.distance;
                        self.heading = 1.0;
                    }
                }
            },
        }
        return self.position();
    }

    /// Where `distance` is on the path.
    pub fn position(self: *const Self) Vec3 {
        const at = self.locate(self.distance);
        return self.segmentPoint(at.segment, at.t);
    }

    /// Unit direction of travel at the current position, for facing along the path.
    /// Reverses with `heading`.
    pub fn tangent(self: *const Self) Vec3 {
        const at = self.locate(self.distance);
        return self.segmentDerivative(at.segment, at.t).mulScalar(self.heading).toNormalized();
    }

    /// Total length: through all points, and back to the first for `.loop`.
    pub fn length(self: *const Self) f32 {
        var total: f32 = 0.0;
        for (0..self.segmentCount()) |segment| {
            total += self.segmentLength(segment);
        }
        return total;
    }

    /// Segment `i` joins point `i` to point `i + 1`; a loop adds last-to-first.
    fn segmentCount(self: *const Self) usize {
        return if (self.repeat == .loop) self.points.len else self.points.len - 1;
    }

    /// The segment containing `distance`, and how far along it (0 to 1). Within a curved
    /// segment the fraction grows linearly with distance, so speed along a Catmull-Rom
    /// curve is steady from segment to segment and close to steady within one.
    fn locate(self: *const Self, distance: f32) struct { segment: usize, t: f32 } {
        const count = self.segmentCount();
        var remaining = distance;
        for (0..count) |segment| {
            const segment_length = self.segmentLength(segment);
            if (remaining <= segment_length or segment == count - 1) {
                const t = if (segment_length > 0.0) remaining / segment_length else 0.0;
                return .{ .segment = segment, .t = std.math.clamp(t, 0.0, 1.0) };
            }
            remaining -= segment_length;
        }
        unreachable;
    }

    fn segmentLength(self: *const Self, segment: usize) f32 {
        switch (self.shape) {
            .linear => {
                const ends = self.segmentEnds(segment);
                return ends.start.distance(ends.end);
            },
            // Sum of short chords along the curve
            .catmull_rom => {
                var total: f32 = 0.0;
                var previous = self.segmentPoint(segment, 0.0);
                for (1..CURVE_SAMPLES + 1) |i| {
                    const t = @as(f32, @floatFromInt(i)) / CURVE_SAMPLES;
                    const point = self.segmentPoint(segment, t);
                    total += previous.distance(point);
                    previous = point;
                }
                return total;
            },
        }
    }

    const CURVE_SAMPLES = 16;

    fn segmentPoint(self: *const Self, segment: usize, t: f32) Vec3 {
        const ends = self.segmentEnds(segment);
        return switch (self.shape) {
            .linear => ends.start.lerp(ends.end, t),
            .catmull_rom => blk: {
                const tangents = self.catmullRomTangents(segment);
                break :blk hermite(ends.start, tangents.start, ends.end, tangents.end, t);
            },
        };
    }

    fn segmentDerivative(self: *const Self, segment: usize, t: f32) Vec3 {
        const ends = self.segmentEnds(segment);
        return switch (self.shape) {
            .linear => ends.end.sub(ends.start),
            .catmull_rom => blk: {
                const tangents = self.catmullRomTangents(segment);
                break :blk hermiteDerivative(ends.start, tangents.start, ends.end, tangents.end, t);
            },
        };
    }

    fn segmentEnds(self: *const Self, segment: usize) struct { start: Vec3, end: Vec3 } {
        return .{ .start = self.points[segment], .end = self.points[(segment + 1) % self.points.len] };
    }

    /// `(next - previous) / 2` at both ends of `segment`. Past the ends of an open path the
    /// missing neighbor is mirrored (`2 * end - inner`), which keeps the curve heading
    /// straight out of its first and last points; a loop wraps around.
    fn catmullRomTangents(self: *const Self, segment: usize) struct { start: Vec3, end: Vec3 } {
        const n = self.points.len;
        const p1 = self.points[segment];
        const p2 = self.points[(segment + 1) % n];
        const p0 = if (segment > 0 or self.repeat == .loop)
            self.points[(segment + n - 1) % n]
        else
            p1.mulScalar(2.0).sub(p2);
        const p3 = if (segment + 2 < n or self.repeat == .loop)
            self.points[(segment + 2) % n]
        else
            p2.mulScalar(2.0).sub(p1);
        return .{ .start = p2.sub(p0).mulScalar(0.5), .end = p3.sub(p1).mulScalar(0.5) };
    }
};

/// Cubic Hermite curve from `p0` (tangent `m0`) to `p1` (tangent `m1`) at `t` in 0..1.
fn hermite(p0: Vec3, m0: Vec3, p1: Vec3, m1: Vec3, t: f32) Vec3 {
    const t2 = t * t;
    const t3 = t2 * t;
    return p0.mulScalar(2.0 * t3 - 3.0 * t2 + 1.0)
        .add(m0.mulScalar(t3 - 2.0 * t2 + t))
        .add(p1.mulScalar(-2.0 * t3 + 3.0 * t2))
        .add(m1.mulScalar(t3 - t2));
}

/// d/dt of `hermite`.
fn hermiteDerivative(p0: Vec3, m0: Vec3, p1: Vec3, m1: Vec3, t: f32) Vec3 {
    const t2 = t * t;
    return p0.mulScalar(6.0 * t2 - 6.0 * t)
        .add(m0.mulScalar(3.0 * t2 - 4.0 * t + 1.0))
        .add(p1.mulScalar(-6.0 * t2 + 6.0 * t))
        .add(m1.mulScalar(3.0 * t2 - 2.0 * t));
}

/// Aim on two separate axes, as a turret: yaw turns the body about +Y, pitch tilts the
/// barrel; each axis has its own speed, pitch has limits, and yaw may be limited to a
/// sector. For a single body that turns freely (a sensor head, a camera), `dampLookAt` is
/// simpler.
///
/// Angles in radians, in the turret's own space: yaw 0 and pitch 0 look down -Z, positive
/// yaw turns left (counterclockwise seen from above), positive pitch raises the aim. The
/// aim moves toward `target_yaw` / `target_pitch` in one of two styles: `rate_limited`, at
/// a constant angular speed that arrives exactly (a motor-driven mount), or `damped`, a
/// quick snap that settles.
pub const YawPitchAim = struct {
    yaw: f32 = 0.0,
    pitch: f32 = 0.0,
    target_yaw: f32 = 0.0,
    target_pitch: f32 = 0.0,
    slew: Slew,
    min_pitch: f32 = -std.math.pi / 2.0,
    max_pitch: f32 = std.math.pi / 2.0,
    /// A sector turret's yaw range, min and max. Null: yaw turns all the way around and
    /// takes the short way to its target.
    yaw_limits: ?[2]f32 = null,

    const Self = @This();

    pub const Slew = union(enum) {
        /// Radians per second on each axis.
        rate_limited: struct { yaw_speed: f32, pitch_speed: f32 },
        /// Approach rate per second on each axis (`dampAlpha`); higher is snappier.
        damped: struct { yaw_rate: f32, pitch_rate: f32 },
    };

    /// Aim toward `toward`, a direction in the turret's own space (it needn't be
    /// normalized). Pitch is clamped to the limits, yaw to the sector if there is one.
    pub fn aimAt(self: *Self, toward: Vec3) void {
        const horizontal = @sqrt(toward.x * toward.x + toward.z * toward.z);
        self.setTarget(std.math.atan2(-toward.x, -toward.z), std.math.atan2(toward.y, horizontal));
    }

    /// Aim toward these angles, clamped to the limits.
    pub fn setTarget(self: *Self, yaw: f32, pitch: f32) void {
        self.target_yaw = if (self.yaw_limits) |limits| std.math.clamp(yaw, limits[0], limits[1]) else wrapAngle(yaw);
        self.target_pitch = std.math.clamp(pitch, self.min_pitch, self.max_pitch);
    }

    /// Moves both axes toward their targets.
    pub fn update(self: *Self, dt: f32) void {
        switch (self.slew) {
            .rate_limited => |speeds| {
                self.yaw = self.stepYaw(speeds.yaw_speed * dt);
                self.pitch = moveTowardScalar(self.pitch, self.target_pitch, speeds.pitch_speed * dt);
            },
            .damped => |rates| {
                const yaw_alpha = dampAlpha(rates.yaw_rate, dt);
                self.yaw = if (self.yaw_limits != null)
                    self.yaw + (self.target_yaw - self.yaw) * yaw_alpha
                else
                    dampAngle(self.yaw, self.target_yaw, rates.yaw_rate, dt);
                self.pitch += (self.target_pitch - self.pitch) * dampAlpha(rates.pitch_rate, dt);
            },
        }
    }

    /// A yaw step of at most `max_step`. With a sector, yaw is a plain angle inside the
    /// limits: the short way around could cross the part the turret can't turn through.
    fn stepYaw(self: *const Self, max_step: f32) f32 {
        if (self.yaw_limits != null) {
            return moveTowardScalar(self.yaw, self.target_yaw, max_step);
        }
        return wrapAngle(self.yaw + std.math.clamp(wrapAngle(self.target_yaw - self.yaw), -max_step, max_step));
    }

    /// Where the aim points now, a unit vector in the turret's own space.
    pub fn direction(self: *const Self) Vec3 {
        return yawPitchDirection(self.yaw, self.pitch);
    }

    /// True when the aim is within `tolerance` radians of the target direction.
    pub fn isAligned(self: *const Self, tolerance: f32) bool {
        const target = yawPitchDirection(self.target_yaw, self.target_pitch);
        return self.direction().dot(target) >= @cos(tolerance);
    }
};

fn yawPitchDirection(yaw: f32, pitch: f32) Vec3 {
    const horizontal = @cos(pitch);
    return Vec3.init(-@sin(yaw) * horizontal, @sin(pitch), -@cos(yaw) * horizontal);
}

/// `current` stepped toward `target` by at most `max_step`, no overshoot.
fn moveTowardScalar(current: f32, target: f32, max_step: f32) f32 {
    return current + std.math.clamp(target - current, -max_step, max_step);
}

/// `current` angle stepped toward `target` by at most `max_speed * dt` radians, the short
/// way around. Arrives exactly and doesn't overshoot. The result is in -π..π.
pub fn moveTowardAngle(current: f32, target: f32, max_speed: f32, dt: f32) f32 {
    const step = max_speed * dt;
    return wrapAngle(current + std.math.clamp(wrapAngle(target - current), -step, step));
}

/// `current` angle moved part way toward `target`, the short way around: frame-rate
/// independent, as `dampVec3`. The result is in -π..π.
pub fn dampAngle(current: f32, target: f32, rate: f32, dt: f32) f32 {
    return wrapAngle(current + wrapAngle(target - current) * dampAlpha(rate, dt));
}

/// `angle` as the same direction in -π..π: the short way from 170° to -170° is +20°, not
/// -340°.
pub fn wrapAngle(angle: f32) f32 {
    const tau = 2.0 * std.math.pi;
    const wrapped = angle - tau * @floor((angle + std.math.pi) / tau);
    return if (wrapped == -std.math.pi) std.math.pi else wrapped;
}

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

/// An L-shaped route: 3 units along X, then 4 along Z. Length 7 open, 12 closed.
const test_route = [_]Vec3{
    Vec3.init(0.0, 0.0, 0.0),
    Vec3.init(3.0, 0.0, 0.0),
    Vec3.init(3.0, 0.0, 4.0),
};

test "PathFollow once: passes each point at its distance, stops at the last" {
    var path: PathFollow = .{ .points = &test_route, .speed = 1.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), path.length(), 1e-6);

    try expectVec3ApproxEq(test_route[1], path.update(3.0), 1e-5);
    try expectVec3ApproxEq(Vec3.init(3.0, 0.0, 2.0), path.update(2.0), 1e-5);
    try std.testing.expect(!path.finished);

    // Past the end: stops on the last point and stays there
    try expectVec3ApproxEq(test_route[2], path.update(10.0), 1e-5);
    try std.testing.expect(path.finished);
    try expectVec3ApproxEq(test_route[2], path.update(1.0), 1e-5);
}

test "PathFollow loop: one full length later it is back at the start, and goes on" {
    var path: PathFollow = .{ .points = &test_route, .speed = 2.0, .repeat = .loop };
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), path.length(), 1e-5);

    try expectVec3ApproxEq(test_route[0], path.update(6.0), 1e-4);
    try expectVec3ApproxEq(test_route[1], path.update(1.5), 1e-4);
    try std.testing.expect(!path.finished);
}

test "PathFollow ping-pong: turns back at the end, and its tangent turns with it" {
    var path: PathFollow = .{ .points = &test_route, .speed = 1.0, .repeat = .ping_pong };

    _ = path.update(1.0);
    try expectVec3ApproxEq(Vec3.init(1.0, 0.0, 0.0), path.tangent(), 1e-5);

    // 7 units out and 1 back: one unit short of the last point, heading back along -Z
    try expectVec3ApproxEq(Vec3.init(3.0, 0.0, 3.0), path.update(7.0), 1e-5);
    try expectVec3ApproxEq(Vec3.init(0.0, 0.0, -1.0), path.tangent(), 1e-5);

    // All the way back to the first point, then out again
    try expectVec3ApproxEq(Vec3.init(1.0, 0.0, 0.0), path.update(7.0), 1e-5);
    try expectVec3ApproxEq(Vec3.init(1.0, 0.0, 0.0), path.tangent(), 1e-5);
}

test "PathFollow: one second lands in the same place at 10, 60, and 144 fps" {
    for ([_]PathFollow.Shape{ .linear, .catmull_rom }) |shape| {
        var at: [3]Vec3 = undefined;
        for ([_]u32{ 10, 60, 144 }, 0..) |steps, i| {
            var path: PathFollow = .{ .points = &test_route, .speed = 5.0, .shape = shape };
            const dt = 1.0 / @as(f32, @floatFromInt(steps));
            for (0..steps) |_| {
                at[i] = path.update(dt);
            }
        }
        try expectVec3ApproxEq(at[1], at[0], 1e-4);
        try expectVec3ApproxEq(at[1], at[2], 1e-4);
    }
}

test "PathFollow Catmull-Rom: goes through every point without the linear path's corner" {
    var linear: PathFollow = .{ .points = &test_route, .speed = 1.0 };
    var curve: PathFollow = .{ .points = &test_route, .speed = 1.0, .shape = .catmull_rom };

    // Through every point: segment ends are the points
    for (0..2) |segment| {
        try expectVec3ApproxEq(test_route[segment], curve.segmentPoint(segment, 0.0), 1e-6);
        try expectVec3ApproxEq(test_route[segment + 1], curve.segmentPoint(segment, 1.0), 1e-6);
    }

    // Just before and after the middle point: the line turns 90 degrees there, the curve
    // doesn't change direction
    const corner = linear.segmentLength(0);
    const curve_corner = curve.segmentLength(0);
    linear.distance = corner - 0.01;
    const linear_before = linear.tangent();
    linear.distance = corner + 0.01;
    try std.testing.expect(linear_before.dot(linear.tangent()) < 0.01);

    curve.distance = curve_corner - 0.01;
    const curve_before = curve.tangent();
    curve.distance = curve_corner + 0.01;
    try std.testing.expect(curve_before.dot(curve.tangent()) > 0.99);
}

test "Shake: calm until hit, never past its maximum, calm again after 1 / decay seconds" {
    var shake: Shake = .{ .decay = 2.0, .max_offset = 0.5, .max_angle = 0.1 };
    try std.testing.expectEqual(Shake.Offset.none, shake.update(1.0 / 60.0));

    shake.addTrauma(0.6);
    shake.addTrauma(0.6);
    try std.testing.expectEqual(@as(f32, 1.0), shake.trauma); // at most 1

    // Strength is trauma²: every offset within max × trauma²
    var moved = false;
    for (0..60) |_| {
        const offset = shake.update(1.0 / 120.0);
        const strength = shake.trauma * shake.trauma;
        for ([_]f32{ offset.translation.x, offset.translation.y, offset.translation.z }) |value| {
            try std.testing.expect(@abs(value) <= 0.5 * strength + 1e-6);
            moved = moved or value != 0.0;
        }
        for ([_]f32{ offset.rotation.x, offset.rotation.y, offset.rotation.z }) |value| {
            try std.testing.expect(@abs(value) <= 0.1 * strength + 1e-6);
        }
    }
    try std.testing.expect(moved);

    // 1 / decay = 0.5 s in all: the remaining 0.5 - 60 / 120 = 0 s, so it's calm and stays so
    try std.testing.expectEqual(Shake.Offset.none, shake.update(1.0 / 120.0));
    try std.testing.expectEqual(Shake.Offset.none, shake.update(1.0));
}

test "Shake: the same shake at 10, 60, and 144 fps" {
    var at: [3]Shake.Offset = undefined;
    for ([_]u32{ 10, 60, 144 }, 0..) |steps, i| {
        var shake: Shake = .{ .decay = 0.5 };
        shake.addTrauma(1.0);
        const dt = 0.5 / @as(f32, @floatFromInt(steps));
        for (0..steps) |_| {
            at[i] = shake.update(dt);
        }
    }
    try expectVec3ApproxEq(at[1].translation, at[0].translation, 1e-4);
    try expectVec3ApproxEq(at[1].translation, at[2].translation, 1e-4);
    try expectVec3ApproxEq(at[1].rotation, at[2].rotation, 1e-4);
}

test "Shake.Offset.apply: moves the view with the camera and leaves the rest" {
    const view = Mat4.lookAtRhGl(Vec3.init(0.0, 2.0, 5.0), Vec3.Zero, Vec3.init(0.0, 1.0, 0.0));
    const projection = Mat4.perspectiveRhZo(1.0, 1.5, 0.1, 100.0);
    const context: RenderContext = .{
        .projection = projection,
        .projection_view = projection.mulMat4(&view),
        .view = view,
        .view_position = Vec3.init(0.0, 2.0, 5.0),
    };

    // No offset: unchanged
    try std.testing.expectEqual(context.view, Shake.Offset.none.apply(context).view);

    // A pure move: a point moved with the camera looks the same as before
    const offset: Shake.Offset = .{ .translation = Vec3.init(0.2, -0.1, 0.3), .rotation = Vec3.Zero };
    const shaken = offset.apply(context);
    const point = Vec3.init(1.0, 0.5, -2.0);
    const before = context.view.mulVec4(math.vec4(point.x, point.y, point.z, 1.0));
    const moved = point.add(offset.translation);
    const after = shaken.view.mulVec4(math.vec4(moved.x, moved.y, moved.z, 1.0));
    try std.testing.expectApproxEqAbs(before.x, after.x, 1e-5);
    try std.testing.expectApproxEqAbs(before.y, after.y, 1e-5);
    try std.testing.expectApproxEqAbs(before.z, after.z, 1e-5);
    try expectVec3ApproxEq(Vec3.init(0.2, 1.9, 5.3), shaken.view_position, 1e-6);
}

fn deg(degrees: f32) f32 {
    return std.math.degreesToRadians(degrees);
}

test "wrapAngle: the same direction in -π..π" {
    try std.testing.expectApproxEqAbs(deg(20.0), wrapAngle(deg(380.0)), 1e-5);
    try std.testing.expectApproxEqAbs(deg(-170.0), wrapAngle(deg(190.0)), 1e-5);
    try std.testing.expectApproxEqAbs(deg(10.0), wrapAngle(deg(10.0)), 1e-6);
    try std.testing.expectApproxEqAbs(std.math.pi, wrapAngle(-std.math.pi), 1e-6);
}

test "moveTowardAngle: the short way across ±180°, arrives exactly, no overshoot" {
    // 170° to -170° is 20° the short way: up through 180°, not down through 0
    const speed = deg(10.0); // per second
    const one_second = moveTowardAngle(deg(170.0), deg(-170.0), speed, 1.0);
    try std.testing.expectApproxEqAbs(deg(180.0), @abs(one_second), 1e-5);

    var angle = deg(170.0);
    for (0..30) |_| {
        angle = moveTowardAngle(angle, deg(-170.0), speed, 0.1);
        try std.testing.expect(@abs(wrapAngle(angle - deg(170.0))) <= deg(20.0) + 1e-5);
    }
    try std.testing.expectApproxEqAbs(deg(-170.0), angle, 1e-5);
}

test "dampAngle: the short way, and the same at 10, 60, and 144 fps" {
    var at: [3]f32 = undefined;
    for ([_]u32{ 10, 60, 144 }, 0..) |steps, i| {
        var angle = deg(170.0);
        for (0..steps) |_| {
            angle = dampAngle(angle, deg(-170.0), 2.0, 1.0 / @as(f32, @floatFromInt(steps)));
        }
        at[i] = angle;
    }
    try std.testing.expectApproxEqAbs(at[1], at[0], 1e-4);
    try std.testing.expectApproxEqAbs(at[1], at[2], 1e-4);
    // Went up through 180° (now on the negative side), not back through 0
    try std.testing.expect(at[1] < deg(-170.0) + deg(20.0) and at[1] < 0.0);
}

test "YawPitchAim rate-limited: per-axis speeds, arrives on time, faces the direction" {
    var aim: YawPitchAim = .{ .slew = .{ .rate_limited = .{ .yaw_speed = deg(90.0), .pitch_speed = deg(30.0) } } };
    // Left and up: yaw 90° (toward -X), pitch 30°
    aim.aimAt(Vec3.init(-1.0, @tan(deg(30.0)), 0.0));
    try std.testing.expectApproxEqAbs(deg(90.0), aim.target_yaw, 1e-5);
    try std.testing.expectApproxEqAbs(deg(30.0), aim.target_pitch, 1e-5);

    // Half a second: half the yaw, half the pitch (each at its own speed)
    aim.update(0.5);
    try std.testing.expectApproxEqAbs(deg(45.0), aim.yaw, 1e-5);
    try std.testing.expectApproxEqAbs(deg(15.0), aim.pitch, 1e-5);
    try std.testing.expect(!aim.isAligned(deg(2.0)));

    aim.update(0.6);
    try std.testing.expect(aim.isAligned(deg(0.01)));
    const expected = Vec3.init(-1.0, @tan(deg(30.0)), 0.0).toNormalized();
    try expectVec3ApproxEq(expected, aim.direction(), 1e-5);
}

test "YawPitchAim: pitch stays within its limits" {
    var aim: YawPitchAim = .{
        .slew = .{ .damped = .{ .yaw_rate = 5.0, .pitch_rate = 5.0 } },
        .min_pitch = deg(-10.0),
        .max_pitch = deg(60.0),
    };
    aim.aimAt(Vec3.init(0.0, -5.0, -1.0)); // steeply down
    try std.testing.expectApproxEqAbs(deg(-10.0), aim.target_pitch, 1e-5);
    for (0..120) |_| {
        aim.update(1.0 / 60.0);
        try std.testing.expect(aim.pitch >= deg(-10.0) - 1e-5);
    }
}

test "YawPitchAim with a sector: never turns through the part it can't" {
    // A sector of -170°..170°: the 20° around the back (180°) is out of reach
    var aim: YawPitchAim = .{
        .slew = .{ .rate_limited = .{ .yaw_speed = deg(90.0), .pitch_speed = deg(90.0) } },
        .yaw = deg(-160.0),
        .yaw_limits = .{ deg(-170.0), deg(170.0) },
    };
    aim.setTarget(deg(160.0), 0.0);

    // The short way (20°, through 180°) is blocked: it goes the long way, through 0
    aim.update(0.1);
    try std.testing.expect(aim.yaw > deg(-160.0));
    for (0..60) |_| {
        aim.update(1.0 / 15.0);
        try std.testing.expect(aim.yaw >= deg(-170.0) and aim.yaw <= deg(170.0));
    }
    try std.testing.expectApproxEqAbs(deg(160.0), aim.yaw, 1e-4);

    // A target outside the sector is clamped to its edge
    aim.setTarget(deg(179.0), 0.0);
    try std.testing.expectApproxEqAbs(deg(170.0), aim.target_yaw, 1e-5);
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
