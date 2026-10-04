//! Steering behaviors for characters on the ground (Craig Reynolds, "Steering Behaviors
//! For Autonomous Characters", GDC 1999; boids, 1987): each returns a desired velocity
//! on the ground (y = 0), in meters per second. A character adds several with weights and
//! feeds the sum to its movement (a squad member's motor turns, accelerates, and picks
//! walk or run from it, so the sum never moves anyone directly).
//!
//! | Behavior     | Pulls                                                  |
//! |--------------|--------------------------------------------------------|
//! | `seek`       | toward a point at full speed                           |
//! | `arrive`     | toward a point, slowing inside a radius, still at it   |
//! | `flee`       | away from a threat inside a radius, harder when closer |
//! | `separation` | away from neighbors inside a radius                    |
//! | `cohesion`   | toward the neighbors' center                           |
//! | `alignment`  | toward the neighbors' average velocity                 |
//! | `Wander`     | a heading that drifts smoothly at random               |

const std = @import("std");
const math = @import("math");
const motion = @import("../motion.zig");
const Random = @import("../random.zig").Random;

const Vec3 = math.Vec3;

/// Toward `target` at `max_speed`.
pub fn seek(position: Vec3, target: Vec3, max_speed: f32) Vec3 {
    return direction(position, target).mulScalar(max_speed);
}

/// Toward `target`: `max_speed` until within `slow_radius`, then slower in proportion to
/// the distance, zero at the target.
pub fn arrive(position: Vec3, target: Vec3, max_speed: f32, slow_radius: f32) Vec3 {
    const distance = groundDistance(position, target);
    const speed = max_speed * @min(distance / slow_radius, 1.0);
    return direction(position, target).mulScalar(speed);
}

/// Away from `threat` while within `radius`: `max_speed` at the threat, falling to zero
/// at the radius.
pub fn flee(position: Vec3, threat: Vec3, max_speed: f32, radius: f32) Vec3 {
    const distance = groundDistance(position, threat);
    if (distance >= radius) {
        return Vec3.Zero;
    }
    return direction(threat, position).mulScalar(max_speed * (1.0 - distance / radius));
}

/// Away from each neighbor within `radius`, each push 1 at contact falling to 0 at the
/// radius, summed: a unitless push, scaled by the caller. `neighbors` may include
/// `position` itself (skipped).
pub fn separation(position: Vec3, neighbors: []const Vec3, radius: f32) Vec3 {
    var push = Vec3.Zero;
    for (neighbors) |neighbor| {
        const distance = groundDistance(position, neighbor);
        if (distance == 0.0 or distance >= radius) {
            continue;
        }
        push = push.add(direction(neighbor, position).mulScalar(1.0 - distance / radius));
    }
    return push;
}

/// Toward the neighbors' center at `max_speed`, slowing within `slow_radius` of it (as
/// `arrive`). Zero with no neighbors.
pub fn cohesion(position: Vec3, neighbors: []const Vec3, max_speed: f32, slow_radius: f32) Vec3 {
    if (neighbors.len == 0) {
        return Vec3.Zero;
    }
    var sum = Vec3.Zero;
    for (neighbors) |neighbor| {
        sum = sum.add(neighbor);
    }
    return arrive(position, sum.mulScalar(1.0 / @as(f32, @floatFromInt(neighbors.len))), max_speed, slow_radius);
}

/// The neighbors' average velocity on the ground. Zero with no neighbors.
pub fn alignment(velocities: []const Vec3) Vec3 {
    if (velocities.len == 0) {
        return Vec3.Zero;
    }
    var sum = Vec3.Zero;
    for (velocities) |velocity| {
        sum = sum.add(flat(velocity));
    }
    return sum.mulScalar(1.0 / @as(f32, @floatFromInt(velocities.len)));
}

/// A heading that drifts smoothly: every `interval` seconds (give or take half) it picks a
/// new goal up to `spread` radians either side of where it is, and turns toward it at
/// `rate` (`dampAngle`). New random numbers only at the picks, not every frame, so the
/// drift is smooth and the same at any frame rate.
pub const Wander = struct {
    heading: f32 = 0.0,
    goal: f32 = 0.0,
    interval: f32 = 2.0,
    spread: f32 = std.math.pi / 2.0,
    rate: f32 = 1.5,
    /// Seconds until the next pick.
    timer: f32 = 0.0,

    const Self = @This();

    /// Moves the heading on and returns it (radians about +Y from +Z).
    pub fn update(self: *Self, random: *Random, dt: f32) f32 {
        self.timer -= dt;
        if (self.timer <= 0.0) {
            self.goal = motion.wrapAngle(self.heading + random.randClamped() * self.spread);
            self.timer = self.interval * (0.5 + random.randFloat());
        }
        self.heading = motion.dampAngle(self.heading, self.goal, self.rate, dt);
        return self.heading;
    }

    /// The heading as a unit direction on the ground.
    pub fn direction(self: *const Self) Vec3 {
        return Vec3.init(@sin(self.heading), 0.0, @cos(self.heading));
    }
};

/// The unit direction on the ground from `from` to `to`; zero when they're at the same
/// spot.
fn direction(from: Vec3, to: Vec3) Vec3 {
    const offset = flat(to.sub(from));
    const length = offset.length();
    return if (length > 0.0) offset.mulScalar(1.0 / length) else Vec3.Zero;
}

fn groundDistance(a: Vec3, b: Vec3) f32 {
    return flat(b.sub(a)).length();
}

fn flat(v: Vec3) Vec3 {
    return Vec3.init(v.x, 0.0, v.z);
}

const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "arrive: full speed far out, slower inside the radius, still at the target" {
    const target = Vec3.init(0.0, 0.0, 0.0);
    try expectApproxEqAbs(@as(f32, 3.0), arrive(Vec3.init(10.0, 0.0, 0.0), target, 3.0, 2.0).length(), 1e-5);
    try expectApproxEqAbs(@as(f32, 1.5), arrive(Vec3.init(1.0, 0.0, 0.0), target, 3.0, 2.0).length(), 1e-5);
    try expectApproxEqAbs(@as(f32, 0.0), arrive(target, target, 3.0, 2.0).length(), 1e-6);
    // Toward the target, on the ground whatever the heights
    const pull = arrive(Vec3.init(10.0, 1.0, 0.0), target, 3.0, 2.0);
    try expectApproxEqAbs(@as(f32, -3.0), pull.x, 1e-5);
    try expectApproxEqAbs(@as(f32, 0.0), pull.y, 1e-6);
}

test "flee: away inside the radius, harder when closer, nothing outside" {
    const threat = Vec3.init(0.0, 0.0, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), flee(Vec3.init(5.0, 0.0, 0.0), threat, 4.0, 5.0).length(), 1e-6);
    const near = flee(Vec3.init(1.0, 0.0, 0.0), threat, 4.0, 5.0);
    const nearer = flee(Vec3.init(0.5, 0.0, 0.0), threat, 4.0, 5.0);
    try std.testing.expect(near.x > 0.0);
    try std.testing.expect(nearer.x > near.x);
}

test "separation: pushes apart from close neighbors only, skipping itself" {
    const position = Vec3.init(0.0, 0.0, 0.0);
    const neighbors = [_]Vec3{ position, Vec3.init(0.5, 0.0, 0.0), Vec3.init(0.0, 0.0, 5.0) };
    const push = separation(position, &neighbors, 1.0);
    try expectApproxEqAbs(@as(f32, -0.5), push.x, 1e-5);
    try expectApproxEqAbs(@as(f32, 0.0), push.z, 1e-6);
}

test "cohesion and alignment: toward the center, along the average velocity" {
    const neighbors = [_]Vec3{ Vec3.init(4.0, 0.0, 0.0), Vec3.init(4.0, 0.0, 2.0) };
    const pull = cohesion(Vec3.Zero, &neighbors, 2.0, 1.0);
    try expectApproxEqAbs(@as(f32, 2.0), pull.length(), 1e-5);
    try std.testing.expect(pull.x > 0.0 and pull.z > 0.0);

    const velocities = [_]Vec3{ Vec3.init(1.0, 5.0, 0.0), Vec3.init(3.0, 0.0, 0.0) };
    try expectApproxEqAbs(@as(f32, 2.0), alignment(&velocities).x, 1e-6);
    try expectApproxEqAbs(@as(f32, 0.0), alignment(&velocities).y, 1e-6);
}

test "Wander: drifts within its spread of where it was at each pick, smoothly" {
    var random = Random.init();
    var wander: Wander = .{ .interval = 0.5, .spread = 0.5, .rate = 4.0 };
    var previous = wander.heading;
    for (0..600) |_| {
        const heading = wander.update(&random, 1.0 / 60.0);
        // Never jumps: at most rate * dt of the gap (≤ spread + previous gap) per frame
        try std.testing.expect(@abs(motion.wrapAngle(heading - previous)) < 0.1);
        previous = heading;
    }
    try expectApproxEqAbs(@as(f32, 1.0), wander.direction().length(), 1e-5);
}
