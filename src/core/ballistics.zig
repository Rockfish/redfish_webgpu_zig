//! Aiming projectiles (plan 008): simple closed-form estimates, no iterative solvers.
//! Jitter on the shots and the target's own motion make anything more exact pointless.

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
