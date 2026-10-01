//! Aiming and flying projectiles (plan 008): simple closed-form math, no iterative
//! solvers. Jitter on the shots and the target's own motion make anything more exact
//! pointless.

const std = @import("std");
const math = @import("math");

const Vec3 = math.Vec3;

/// Where to aim to hit a target moving at a steady velocity: where it will be when a shot
/// fired from `from` at `projectile_speed` gets there. The flight time is estimated once
/// from the current distance, which is close for targets slower than the shot.
pub fn leadPoint(from: Vec3, target: Vec3, target_velocity: Vec3, projectile_speed: f32) Vec3 {
    const flight_time = target.sub(from).length() / projectile_speed;
    return target.add(target_velocity.mulScalar(flight_time));
}

/// The launch velocity that carries a projectile from `from` to `to` in exactly
/// `flight_time` seconds under constant `gravity` (pointing down, e.g. (0, -9.8, 0)), from
/// `to = from + v0·T + ½·g·T²`. Fixing the flight time instead of the launch speed means
/// one line, no square root, always a solution, and every lob hangs in the air the same
/// time; a longer time is a higher arc, a farther target a faster shot.
pub fn launchVelocity(from: Vec3, to: Vec3, flight_time: f32, gravity: Vec3) Vec3 {
    return to.sub(from).mulScalar(1.0 / flight_time).sub(gravity.mulScalar(0.5 * flight_time));
}

/// Where a projectile launched from `from` at `velocity` is after `time` seconds under
/// constant `gravity`. For drawing a predicted arc.
pub fn positionAt(from: Vec3, velocity: Vec3, gravity: Vec3, time: f32) Vec3 {
    return from.add(velocity.mulScalar(time)).add(gravity.mulScalar(0.5 * time * time));
}

/// Moves a projectile on by `dt` under constant `gravity`. Exact for constant gravity
/// (`p += v·dt + ½·g·dt²`, then `v += g·dt`), so a shell follows the same arc at any
/// frame rate; plain `v += g·dt; p += v·dt` lands short or long by `g·T·dt / 2`.
pub fn step(position: *Vec3, velocity: *Vec3, gravity: Vec3, dt: f32) void {
    position.* = position.add(velocity.mulScalar(dt)).add(gravity.mulScalar(0.5 * dt * dt));
    velocity.* = velocity.add(gravity.mulScalar(dt));
}

test "launchVelocity: positionAt the flight time is the target" {
    const gravity = Vec3.init(0.0, -9.8, 0.0);
    const from = Vec3.init(1.0, 1.5, 2.0);
    const to = Vec3.init(-8.0, 4.0, -12.0);
    const velocity = launchVelocity(from, to, 2.5, gravity);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), positionAt(from, velocity, gravity, 2.5).sub(to).length(), 1e-4);
}

test "launchVelocity with step: lands on the target at 10, 30, and 144 fps" {
    const gravity = Vec3.init(0.0, -9.8, 0.0);
    const from = Vec3.init(0.0, 1.0, 0.0);
    const to = Vec3.init(12.0, 0.0, -9.0);
    const flight_time: f32 = 2.5;

    for ([_]u32{ 10, 30, 144 }) |fps| {
        var position = from;
        var velocity = launchVelocity(from, to, flight_time, gravity);
        const dt = 1.0 / @as(f32, @floatFromInt(fps));
        const frames: u32 = @intFromFloat(@round(flight_time * @as(f32, @floatFromInt(fps))));
        for (0..frames) |_| {
            step(&position, &velocity, gravity, dt);
        }
        try std.testing.expect(position.sub(to).length() < 0.01);
    }
}

test "launchVelocity: the same flight time for every distance, faster for farther" {
    const gravity = Vec3.init(0.0, -9.8, 0.0);
    const near = launchVelocity(Vec3.Zero, Vec3.init(0.0, 0.0, -5.0), 2.0, gravity);
    const far = launchVelocity(Vec3.Zero, Vec3.init(0.0, 0.0, -20.0), 2.0, gravity);
    // The same climb (the same hang time), more speed along the ground
    try std.testing.expectApproxEqAbs(near.y, far.y, 1e-5);
    try std.testing.expect(far.length() > near.length());
}

test "leadPoint: a stationary target is aimed at directly" {
    const target = Vec3.init(5.0, 1.0, -20.0);
    const aim = leadPoint(Vec3.Zero, target, Vec3.Zero, 30.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), aim.sub(target).length(), 1e-5);
}

test "leadPoint: leading a crossing target misses by far less than aiming at it" {
    const from = Vec3.init(0.0, 1.0, 0.0);
    const target = Vec3.init(-5.0, 1.0, -20.0);
    const target_velocity = Vec3.init(6.0, 0.0, 0.0);
    const speed: f32 = 30.0;

    const with_lead = closestMiss(from, leadPoint(from, target, target_velocity, speed), target, target_velocity, speed);
    const without_lead = closestMiss(from, target, target, target_velocity, speed);

    // Without lead the shot passes several units behind; with it, a fraction of a unit
    try std.testing.expect(without_lead > 3.0);
    try std.testing.expect(with_lead < 0.25);
}

/// The closest a shot aimed at `aim` comes to the moving target, stepped at 144 fps.
fn closestMiss(from: Vec3, aim: Vec3, target: Vec3, target_velocity: Vec3, speed: f32) f32 {
    const dt: f32 = 1.0 / 144.0;
    const shot_velocity = aim.sub(from).toNormalized().mulScalar(speed);
    var shot = from;
    var moving_target = target;
    var closest = std.math.inf(f32);
    for (0..288) |_| {
        shot = shot.add(shot_velocity.mulScalar(dt));
        moving_target = moving_target.add(target_velocity.mulScalar(dt));
        closest = @min(closest, shot.sub(moving_target).length());
    }
    return closest;
}
