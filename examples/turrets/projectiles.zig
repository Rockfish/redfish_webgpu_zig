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
const core = @import("core");
const math = @import("math");

const Explosions = @import("explosions.zig").Explosions;

const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const ballistics = core.ballistics;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;

/// Shots in flight at once, per pool.
const MAX_PROJECTILES = 256;

/// Instance attributes: rotation quaternion at location 8, position at 9 (projectiles.wgsl).
pub const InstanceLayouts = core.shapes.InstancedLayouts(&.{
    .{ .format = .float32x4, .location = 8 },
    .{ .format = .float32x3, .location = 9 },
});

/// What `update` reports about the target this frame.
pub const Target = struct {
    position: Vec3,
    radius: f32,
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
        var i: usize = 0;
        while (i < self.count) {
            const start = self.positions[i];
            ballistics.step(&self.positions[i], &self.velocities[i], self.gravity, dt);
            self.ages[i] += dt;

            const is_direct_hit = segmentDistance(start, self.positions[i], target.position) < target.radius;
            const is_grounded = self.positions[i].y <= 0.0;
            const is_spent = self.ages[i] >= self.fuses[i];
            if (is_direct_hit or is_grounded or is_spent) {
                self.end(i, is_direct_hit, target, explosions);
                continue;
            }

            self.rotations[i] = self.orientation(i);
            i += 1;
        }
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

    /// A shell explodes where it ended (on the floor if it went into it), hitting the
    /// target if the blast reaches it; a tracer counts only a direct hit.
    fn end(self: *Self, i: usize, is_direct_hit: bool, target: Target, explosions: *Explosions) void {
        if (self.blast_radius > 0.0) {
            var burst = self.positions[i];
            burst.y = @max(burst.y, 0.0);
            explosions.add(burst, self.blast_radius);
            if (burst.sub(target.position).length() < self.blast_radius + target.radius) {
                self.hits += 1;
            }
        } else if (is_direct_hit) {
            self.hits += 1;
        }
        self.remove(i);
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

/// The closest `point` comes to the segment from `start` to `end`: this frame's step, so a
/// fast shot can't skip past the target between frames.
fn segmentDistance(start: Vec3, end: Vec3, point: Vec3) f32 {
    const step = end.sub(start);
    const step_squared = step.lengthSquared();
    const t = if (step_squared > 0.0) std.math.clamp(point.sub(start).dot(step) / step_squared, 0.0, 1.0) else 0.0;
    return start.add(step.mulScalar(t)).sub(point).length();
}

/// A rotation whose -Z points along `velocity`, kept upright (right is horizontal). A shell
/// arcs in the vertical plane it was launched in, so its right stays the same all the way
/// and only its pitch follows the arc: up on launch, level at the top, nose down coming in.
fn facing(velocity: Vec3) Quat {
    const forward = velocity.toNormalized();
    const right = if (@abs(forward.y) < 0.99) forward.cross(Vec3.World_Up) else Vec3.World_Right;
    return Quat.fromDirectionWithRight(forward, right);
}
