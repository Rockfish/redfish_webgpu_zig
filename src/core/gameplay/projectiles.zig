//! A turret's shots in flight, in a fixed pool, drawn instanced. Two kinds, set per pool:
//!
//! - Tracers fly straight (no gravity, no blast) and end when they hit the target, go into
//!   the floor, or run out of time.
//! - Shells fall under gravity, their nose following the arc as a finned rocket's does,
//!   and explode on the target, on the ground, or when their fuse runs out (an air burst);
//!   the blast hits the target if it is within the blast radius.
//!
//! A projectile's look is one or more parts (a tracer is one stretched cube; a rocket is a
//! body, a nose, and fins), each drawn once for the whole pool with the same instance data.

const std = @import("std");
const math = @import("math");

const Explosions = @import("explosions.zig").Explosions;
const bindings = @import("../bindings.zig");
const gpu_context = @import("../gpu_context.zig");
const shapes_module = @import("../shapes/root.zig");

const DrawUniforms = bindings.DrawUniforms;
const Frame = gpu_context.Frame;
const Shader = @import("../shader.zig").Shader;
const Shape = shapes_module.Shape;
const ballistics = @import("ballistics.zig");
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;

/// Shots in flight at once, per pool.
pub const MAX_PROJECTILES = 256;

/// Instance attributes: rotation quaternion at location 8, position at 9 (projectiles.wgsl).
pub const InstanceLayouts = shapes_module.InstancedLayouts(&.{
    .{ .format = .float32x4, .location = 8 },
    .{ .format = .float32x3, .location = 9 },
});

/// Something shots can hit: a sphere.
pub const Target = struct {
    position: Vec3,
    radius: f32,
};

/// A shot that ended this frame (`updateTargets`).
pub const Ending = struct {
    /// Where it ended: on the struck target's surface, on the floor, or where it was.
    position: Vec3,
    /// The target it struck directly, or a shell's blast reached, as an index into the
    /// targets.
    target: ?usize,
    /// It went into the floor.
    grounded: bool,
};

/// Where a shot in flight will end, if nothing stops it first (`predictedEnd`).
pub const Prediction = struct {
    position: Vec3,
    /// Seconds until then.
    time_left: f32,
    /// Seconds from launch to then: `1 - time_left / fuse` is how far along it is.
    fuse: f32,
};

/// One part of a projectile's look: a mesh placed in the projectile's own space (nose
/// down -Z).
pub const Part = struct {
    shape: *Shape,
    model: Mat4,
    color: Vec4,
};

/// Shots kept as parallel arrays: rotations and positions are the instance attributes,
/// drawn straight from the arrays.
pub const Projectiles = struct {
    /// Zero for tracers.
    gravity: Vec3 = Vec3.Zero,
    /// Zero: no explosion, only direct hits count (tracers).
    blast_radius: f32 = 0.0,
    /// Radians per second about the nose, as finned rockets often spin.
    spin: f32 = 0.0,

    count: usize = 0,
    rotations: [MAX_PROJECTILES]Quat = undefined,
    positions: [MAX_PROJECTILES]Vec3 = undefined,
    velocities: [MAX_PROJECTILES]Vec3 = undefined,
    ages: [MAX_PROJECTILES]f32 = undefined,
    /// Seconds from launch to the end of the shot: an air burst for shells, a drop for
    /// tracers.
    fuses: [MAX_PROJECTILES]f32 = undefined,
    /// Shots (or blasts) that reached the target.
    hits: u32 = 0,

    const Self = @This();

    /// Adds a shot fired `age` seconds ago from `muzzle`, already moved on by that much so
    /// a stream stays evenly spaced. When the pool is full the shot is dropped.
    pub fn spawn(self: *Self, muzzle: Vec3, velocity: Vec3, fuse: f32, age: f32) void {
        if (self.count == MAX_PROJECTILES) {
            return;
        }
        const i = self.count;
        self.count += 1;
        self.positions[i] = ballistics.positionAt(muzzle, velocity, self.gravity, age);
        self.velocities[i] = velocity.add(self.gravity.mulScalar(age));
        self.ages[i] = age;
        self.fuses[i] = fuse;
        self.rotations[i] = self.orientation(i);
    }

    /// Moves every shot on and ends the ones that are done; counts hits on `target`, and
    /// adds shells' explosions to `explosions`.
    pub fn update(self: *Self, dt: f32, target: Target, explosions: *Explosions) void {
        var endings: [MAX_PROJECTILES]Ending = undefined;
        for (self.updateTargets(dt, &.{target}, explosions, &endings)) |ending| {
            if (ending.target != null) {
                self.hits += 1;
            }
        }
    }

    /// Moves every shot on and ends the ones that are done, against several targets: the
    /// shots that ended this frame, in `endings`. Shells' explosions go into `explosions`.
    pub fn updateTargets(
        self: *Self,
        dt: f32,
        targets: []const Target,
        explosions: *Explosions,
        endings: *[MAX_PROJECTILES]Ending,
    ) []Ending {
        var ended: usize = 0;
        var i: usize = 0;
        while (i < self.count) {
            const start = self.positions[i];
            ballistics.step(&self.positions[i], &self.velocities[i], self.gravity, dt);
            self.ages[i] += dt;

            const struck = firstStruck(start, self.positions[i], targets);
            const is_grounded = self.positions[i].y <= 0.0;
            const is_spent = self.ages[i] >= self.fuses[i];
            if (struck != null or is_grounded or is_spent) {
                endings[ended] = self.end(i, start, struck, targets, explosions);
                ended += 1;
                continue;
            }

            self.rotations[i] = self.orientation(i);
            i += 1;
        }
        return endings[0..ended];
    }

    /// Where shot `i` will be when its fuse runs out (a shell's burst), from where it is
    /// now: exact under constant gravity, so warnings can mark it on the floor from launch.
    /// It can end sooner, on a target or the floor.
    pub fn predictedEnd(self: *const Self, i: usize) Prediction {
        const time_left = @max(self.fuses[i] - self.ages[i], 0.0);
        return .{
            .position = ballistics.positionAt(self.positions[i], self.velocities[i], self.gravity, time_left),
            .time_left = time_left,
            .fuse = self.fuses[i],
        };
    }

    /// Draws every shot, one instanced draw per part.
    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, parts: []const Part) void {
        const instance_data = [_][]const u8{
            std.mem.sliceAsBytes(self.rotations[0..self.count]),
            std.mem.sliceAsBytes(self.positions[0..self.count]),
        };
        for (parts) |part| {
            part.shape.drawInstanced(frame, shader, DrawUniforms.init(part.model, part.color), &instance_data, @intCast(self.count));
        }
    }

    /// Where shot `i` ended this frame's step from `start`: on the struck target's
    /// surface, or where it crossed the floor. A shell explodes there, reaching the first
    /// target its blast touches; a tracer reaches only the one it struck.
    fn end(self: *Self, i: usize, start: Vec3, struck: ?usize, targets: []const Target, explosions: *Explosions) Ending {
        const finish = self.positions[i];
        var ending: Ending = .{ .position = finish, .target = struck, .grounded = struck == null and finish.y <= 0.0 };
        if (struck) |index| {
            ending.position = surfacePoint(start, finish, targets[index]);
        } else if (ending.grounded) {
            ending.position = floorPoint(start, finish);
        }

        if (self.blast_radius > 0.0) {
            explosions.add(ending.position, self.blast_radius);
            ending.target = struck orelse firstInBlast(ending.position, self.blast_radius, targets);
        }
        self.remove(i);
        return ending;
    }

    /// Nose along the velocity, plus the spin about it.
    fn orientation(self: *const Self, i: usize) Quat {
        const roll = Quat.fromAxisAngle(Vec3.Z, self.spin * self.ages[i]);
        return facing(self.velocities[i]).mulQuat(roll);
    }

    /// Order doesn't matter, so the last shot fills the gap.
    fn remove(self: *Self, i: usize) void {
        self.count -= 1;
        self.rotations[i] = self.rotations[self.count];
        self.positions[i] = self.positions[self.count];
        self.velocities[i] = self.velocities[self.count];
        self.ages[i] = self.ages[self.count];
        self.fuses[i] = self.fuses[self.count];
    }
};

/// The first target this frame's step (`start` to `end`) passes through, testing the
/// whole segment so a fast shot can't skip past a target between frames.
fn firstStruck(start: Vec3, end: Vec3, targets: []const Target) ?usize {
    for (targets, 0..) |target, index| {
        if (closestOnSegment(start, end, target.position).sub(target.position).length() < target.radius) {
            return index;
        }
    }
    return null;
}

fn firstInBlast(burst: Vec3, blast_radius: f32, targets: []const Target) ?usize {
    for (targets, 0..) |target, index| {
        if (burst.sub(target.position).length() < blast_radius + target.radius) {
            return index;
        }
    }
    return null;
}

/// The point on the segment from `start` to `end` closest to `point`.
fn closestOnSegment(start: Vec3, end: Vec3, point: Vec3) Vec3 {
    const step = end.sub(start);
    const step_squared = step.lengthSquared();
    const t = if (step_squared > 0.0) std.math.clamp(point.sub(start).dot(step) / step_squared, 0.0, 1.0) else 0.0;
    return start.add(step.mulScalar(t));
}

/// Where a shot struck `target`: its surface, on the side of the step's closest approach.
fn surfacePoint(start: Vec3, end: Vec3, target: Target) Vec3 {
    const outward = closestOnSegment(start, end, target.position).sub(target.position);
    const length = outward.length();
    const direction = if (length > 0.0) outward.mulScalar(1.0 / length) else start.sub(target.position).toNormalized();
    return target.position.add(direction.mulScalar(target.radius));
}

/// Where the step from `start` (above the floor) to `end` (at or below it) crosses y = 0.
fn floorPoint(start: Vec3, end: Vec3) Vec3 {
    const drop = start.y - end.y;
    const t = if (drop > 0.0) start.y / drop else 1.0;
    var point = start.add(end.sub(start).mulScalar(t));
    point.y = 0.0;
    return point;
}

/// A rotation whose -Z points along `velocity`, kept upright (right is horizontal). A shell
/// arcs in the vertical plane it was launched in, so its right stays the same all the way
/// and only its pitch follows the arc: up on launch, level at the top, nose down coming in.
fn facing(velocity: Vec3) Quat {
    const forward = velocity.toNormalized();
    const right = if (@abs(forward.y) < 0.99) forward.cross(Vec3.World_Up) else Vec3.World_Right;
    return Quat.fromDirectionWithRight(forward, right);
}

test "updateTargets: a tracer ends on the surface of the target it passes through" {
    var tracers: Projectiles = .{};
    var explosions: Explosions = .{ .floor_color = Vec4.One };
    var endings: [MAX_PROJECTILES]Ending = undefined;
    const targets = [_]Target{
        .{ .position = Vec3.init(5.0, 1.0, -10.0), .radius = 1.0 },
        .{ .position = Vec3.init(0.0, 1.0, -10.0), .radius = 1.0 },
    };

    // Down -Z at 1 m height, 80 m/s: one 1/30 s step crosses the second target's middle
    tracers.spawn(Vec3.init(0.0, 1.0, -9.0), Vec3.init(0.0, 0.0, -80.0), 3.0, 0.0);
    const ended = tracers.updateTargets(1.0 / 30.0, &targets, &explosions, &endings);

    try std.testing.expectEqual(@as(usize, 1), ended.len);
    try std.testing.expectEqual(@as(?usize, 1), ended[0].target);
    try std.testing.expect(!ended[0].grounded);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ended[0].position.sub(targets[1].position).length(), 1e-4);
    try std.testing.expectEqual(@as(usize, 0), tracers.count);
}

test "updateTargets: a tracer into the floor ends where it crossed it" {
    var tracers: Projectiles = .{};
    var explosions: Explosions = .{ .floor_color = Vec4.One };
    var endings: [MAX_PROJECTILES]Ending = undefined;

    tracers.spawn(Vec3.init(0.0, 1.0, 0.0), Vec3.init(0.0, -10.0, -10.0), 3.0, 0.0);
    const ended = tracers.updateTargets(0.2, &.{}, &explosions, &endings);

    try std.testing.expectEqual(@as(usize, 1), ended.len);
    try std.testing.expect(ended[0].grounded);
    try std.testing.expectEqual(@as(?usize, null), ended[0].target);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ended[0].position.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), ended[0].position.z, 1e-4);
}

test "predictedEnd: a lobbed shell's prediction stays where it bursts" {
    const gravity = Vec3.init(0.0, -9.8, 0.0);
    var shells: Projectiles = .{ .gravity = gravity, .blast_radius = 1.0 };
    var explosions: Explosions = .{ .floor_color = Vec4.One };
    var endings: [MAX_PROJECTILES]Ending = undefined;
    const muzzle = Vec3.init(0.0, 2.0, 0.0);
    const goal = Vec3.init(6.0, 1.0, -20.0);
    const flight_time: f32 = 3.5;

    shells.spawn(muzzle, ballistics.launchVelocity(muzzle, goal, flight_time, gravity), flight_time, 0.0);
    try std.testing.expect(shells.predictedEnd(0).position.sub(goal).length() < 1e-3);
    try std.testing.expectApproxEqAbs(flight_time, shells.predictedEnd(0).time_left, 1e-6);

    // Halfway there, the same point, half the time left
    for (0..105) |_| {
        _ = shells.updateTargets(1.0 / 60.0, &.{}, &explosions, &endings);
    }
    const halfway = shells.predictedEnd(0);
    try std.testing.expect(halfway.position.sub(goal).length() < 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.75), halfway.time_left, 1e-3);
}
