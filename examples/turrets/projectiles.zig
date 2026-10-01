//! A turret's shots in flight: straight-flying tracers in a fixed pool, drawn instanced
//! (one draw for the pool). A shot ends when it hits the target, goes into the floor, or
//! runs out of time.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;

/// Shots in flight at once, per turret.
const MAX_PROJECTILES = 256;
/// Seconds a shot flies before it's dropped.
const LIFETIME: f32 = 3.0;

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

/// Shots kept as parallel arrays: rotations and positions are the instance attributes,
/// drawn straight from the arrays.
pub const Projectiles = struct {
    count: usize = 0,
    rotations: [MAX_PROJECTILES]Quat = undefined,
    positions: [MAX_PROJECTILES]Vec3 = undefined,
    velocities: [MAX_PROJECTILES]Vec3 = undefined,
    ages: [MAX_PROJECTILES]f32 = undefined,
    /// Shots that reached the target.
    hits: u32 = 0,

    const Self = @This();

    /// Adds a shot fired `age` seconds ago from `muzzle`, already moved on by that much so
    /// a stream stays evenly spaced. When the pool is full the shot is dropped.
    pub fn spawn(self: *Self, muzzle: Vec3, velocity: Vec3, age: f32) void {
        if (self.count == MAX_PROJECTILES) {
            return;
        }
        const i = self.count;
        self.count += 1;
        self.positions[i] = muzzle.add(velocity.mulScalar(age));
        self.velocities[i] = velocity;
        self.rotations[i] = facing(velocity);
        self.ages[i] = age;
    }

    /// Moves every shot on and drops the ones that are done; counts hits on `target`.
    pub fn update(self: *Self, dt: f32, target: Target) void {
        var i: usize = 0;
        while (i < self.count) {
            const start = self.positions[i];
            self.positions[i] = start.add(self.velocities[i].mulScalar(dt));
            self.ages[i] += dt;

            const is_hit = segmentDistance(start, self.positions[i], target.position) < target.radius;
            if (is_hit) {
                self.hits += 1;
            }
            if (is_hit or self.positions[i].y < 0.0 or self.ages[i] > LIFETIME) {
                self.remove(i);
                continue;
            }
            i += 1;
        }
    }

    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, tracer: *const Shape, color: Vec4) void {
        const instance_data = [_][]const u8{
            std.mem.sliceAsBytes(self.rotations[0..self.count]),
            std.mem.sliceAsBytes(self.positions[0..self.count]),
        };
        tracer.drawInstanced(frame, shader, DrawUniforms.init(Mat4.Identity, color), &instance_data, @intCast(self.count));
    }

    /// Order doesn't matter, so the last shot fills the gap.
    fn remove(self: *Self, i: usize) void {
        self.count -= 1;
        self.rotations[i] = self.rotations[self.count];
        self.positions[i] = self.positions[self.count];
        self.velocities[i] = self.velocities[self.count];
        self.ages[i] = self.ages[self.count];
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

/// A rotation whose -Z points along `velocity`, kept upright (right is horizontal), so the
/// stretched tracer lies along its path.
fn facing(velocity: Vec3) Quat {
    const forward = velocity.toNormalized();
    const right = if (@abs(forward.y) < 0.99) forward.cross(Vec3.World_Up) else Vec3.World_Right;
    return Quat.fromDirectionWithRight(forward, right);
}
